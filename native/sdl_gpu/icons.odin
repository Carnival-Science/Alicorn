package alicorn_sdl_gpu

import "core:c"
import "core:math"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
import "vendor:sdl3"

NATIVE_ICON_INITIAL_VERTICES :: 4096

Native_Icon_Draw :: struct {
    first_vertex, vertex_count: sdl3.Uint32,
    page: int,
}

// Owns immutable device-local mask textures independently of Runa's text atlas.
// The host's solid renderer owns this renderer's lifetime as its compositor bundle.
Native_Icon_Renderer :: struct {
    device: ^sdl3.GPUDevice,
    runtime: ^alicorn.Runtime,
    pipeline: ^sdl3.GPUGraphicsPipeline,
    sampler: ^sdl3.GPUSampler,
    pages: [len(alicorn.ICON_ATLAS_PAGES)]^sdl3.GPUTexture,
    vertex_buffer: ^sdl3.GPUBuffer,
    vertex_transfer: ^sdl3.GPUTransferBuffer,
    vertices: [dynamic]Native_Text_Vertex,
    vertex_capacity: int,
    draws: [dynamic]Native_Icon_Draw,
    upload_pending, mesh_valid: bool,
    mesh_fingerprint: u64,
    atlas_uploads, atlas_upload_bytes, vertices_uploaded, vertex_upload_bytes, mesh_rebuilds, mesh_cache_hits: u64,
    capacity: Native_Device_Stall_Stats,
}

native_icon_upload_atlases :: proc(renderer: ^Native_Icon_Renderer) -> bool {
    total := 0
    for page in alicorn.ICON_ATLAS_PAGES { total += len(page.pixels) }
    transfer := sdl3.CreateGPUTransferBuffer(renderer.device, sdl3.GPUTransferBufferCreateInfo{usage=.UPLOAD, size=sdl3.Uint32(total)})
    if transfer == nil { return false }
    defer sdl3.ReleaseGPUTransferBuffer(renderer.device, transfer)
    mapped := sdl3.MapGPUTransferBuffer(renderer.device, transfer, false)
    if mapped == nil { return false }
    bytes := cast([^]u8)mapped
    offset := 0
    for page, index in alicorn.ICON_ATLAS_PAGES {
        for value, i in page.pixels { bytes[offset+i] = value }
        offset += len(page.pixels)
    }
    sdl3.UnmapGPUTransferBuffer(renderer.device, transfer)
    for page, index in alicorn.ICON_ATLAS_PAGES {
        renderer.pages[index] = sdl3.CreateGPUTexture(renderer.device, sdl3.GPUTextureCreateInfo{
            type=.D2, format=.R8_UNORM, usage={.SAMPLER}, width=sdl3.Uint32(page.width), height=sdl3.Uint32(page.height),
            layer_count_or_depth=1, num_levels=1, sample_count=._1,
        })
        if renderer.pages[index] == nil { return false }
    }
    command := sdl3.AcquireGPUCommandBuffer(renderer.device)
    if command == nil { return false }
    copy_pass := sdl3.BeginGPUCopyPass(command)
    if copy_pass == nil { _ = sdl3.CancelGPUCommandBuffer(command); return false }
    offset = 0
    for page, index in alicorn.ICON_ATLAS_PAGES {
        // R8 row pitches are multiples of 256; all page offsets are multiples
        // of 512. One staging buffer is filled before any copy references it.
        source := sdl3.GPUTextureTransferInfo{transfer_buffer=transfer, offset=sdl3.Uint32(offset), pixels_per_row=sdl3.Uint32(page.width), rows_per_layer=sdl3.Uint32(page.height)}
        destination := sdl3.GPUTextureRegion{texture=renderer.pages[index], w=sdl3.Uint32(page.width), h=sdl3.Uint32(page.height), d=1}
        sdl3.UploadToGPUTexture(copy_pass, source, destination, false)
        offset += len(page.pixels)
    }
    sdl3.EndGPUCopyPass(copy_pass)
    if !sdl3.SubmitGPUCommandBuffer(command) { return false }
    if !sdl3.WaitForGPUIdle(renderer.device) { return false }
    renderer.atlas_uploads = u64(len(renderer.pages))
    renderer.atlas_upload_bytes = u64(total)
    return true
}

native_icon_destroy :: proc(renderer: ^Native_Icon_Renderer) {
    if renderer.vertex_transfer != nil { sdl3.ReleaseGPUTransferBuffer(renderer.device, renderer.vertex_transfer) }
    if renderer.vertex_buffer != nil { sdl3.ReleaseGPUBuffer(renderer.device, renderer.vertex_buffer) }
    for page in renderer.pages { if page != nil { sdl3.ReleaseGPUTexture(renderer.device, page) } }
    if renderer.sampler != nil { sdl3.ReleaseGPUSampler(renderer.device, renderer.sampler) }
    if renderer.pipeline != nil { sdl3.ReleaseGPUGraphicsPipeline(renderer.device, renderer.pipeline) }
    delete(renderer.vertices); delete(renderer.draws)
    renderer^ = {}
}

native_icon_make :: proc(device: ^sdl3.GPUDevice, swapchain_format: sdl3.GPUTextureFormat, runtime: ^alicorn.Runtime) -> (renderer: Native_Icon_Renderer, ok: bool) {
	if device == nil { return renderer, false }
	renderer.device = device
	renderer.runtime = runtime
	if !alicorn.icon_atlas_validate() { return renderer, false }
	defer if !ok { native_icon_destroy(&renderer) }
	renderer.vertex_capacity = NATIVE_ICON_INITIAL_VERTICES
	renderer.capacity.peak_capacity = renderer.vertex_capacity
	renderer.vertices = make([dynamic]Native_Text_Vertex, 0, 4096)
	renderer.draws = make([dynamic]Native_Icon_Draw, 0, 1024)

	vertex_shader := native_text_shader(device, .VERTEX, false)
    fragment_shader := native_fragment_shader(device, GPU_ICON_FRAG_DXIL, GPU_ICON_FRAG_MSL, GPU_ICON_FRAG_SPV)
	if vertex_shader == nil || fragment_shader == nil {
		if vertex_shader != nil { sdl3.ReleaseGPUShader(device, vertex_shader) }
		if fragment_shader != nil { sdl3.ReleaseGPUShader(device, fragment_shader) }
		return renderer, false
	}
	vertex_buffers := [1]sdl3.GPUVertexBufferDescription{{slot=0, pitch=sdl3.Uint32(size_of(Native_Text_Vertex)), input_rate=.VERTEX}}
	attributes := [3]sdl3.GPUVertexAttribute{
		{location=0, buffer_slot=0, format=.FLOAT3, offset=0},
		{location=1, buffer_slot=0, format=.FLOAT4, offset=sdl3.Uint32(size_of([3]f32))},
		{location=2, buffer_slot=0, format=.FLOAT2, offset=sdl3.Uint32(size_of([3]f32) + size_of([4]f32))},
	}
	targets := [1]sdl3.GPUColorTargetDescription{{format=swapchain_format, blend_state=NATIVE_SOURCE_OVER_BLEND}}
	pipeline_info := sdl3.GPUGraphicsPipelineCreateInfo{
		vertex_shader=vertex_shader, fragment_shader=fragment_shader,
		vertex_input_state=sdl3.GPUVertexInputState{
			vertex_buffer_descriptions=&vertex_buffers[0], num_vertex_buffers=1,
			vertex_attributes=&attributes[0], num_vertex_attributes=3,
		},
		primitive_type=.TRIANGLELIST,
		rasterizer_state=sdl3.GPURasterizerState{fill_mode=.FILL, cull_mode=.NONE, front_face=.COUNTER_CLOCKWISE, enable_depth_clip=true},
		target_info=sdl3.GPUGraphicsPipelineTargetInfo{color_target_descriptions=&targets[0], num_color_targets=1},
	}
	renderer.pipeline = sdl3.CreateGPUGraphicsPipeline(device, pipeline_info)
	sdl3.ReleaseGPUShader(device, vertex_shader)
	sdl3.ReleaseGPUShader(device, fragment_shader)
	if renderer.pipeline == nil { return renderer, false }

	renderer.sampler = sdl3.CreateGPUSampler(device, sdl3.GPUSamplerCreateInfo{
		min_filter=.LINEAR, mag_filter=.LINEAR, mipmap_mode=.NEAREST,
		address_mode_u=.CLAMP_TO_EDGE, address_mode_v=.CLAMP_TO_EDGE, address_mode_w=.CLAMP_TO_EDGE,
		max_lod=1,
	})
	renderer.vertex_buffer = sdl3.CreateGPUBuffer(device, sdl3.GPUBufferCreateInfo{
		usage=sdl3.GPUBufferUsageFlags{.VERTEX},
		size=sdl3.Uint32(renderer.vertex_capacity * size_of(Native_Text_Vertex)),
	})
	renderer.vertex_transfer = sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.UPLOAD,
		size=sdl3.Uint32(renderer.vertex_capacity * size_of(Native_Text_Vertex)),
	})
	if renderer.sampler == nil || renderer.vertex_buffer == nil || renderer.vertex_transfer == nil {
		return renderer, false
	}
	if !native_icon_upload_atlases(&renderer) { return renderer, false }
	return renderer, true
}

// Uses the same finalized edge conversion as surfaces, clipping and text.
// Clipping changes UVs, never the raster resource size or the widget geometry.
native_icon_build :: proc(renderer: ^Native_Icon_Renderer, display: []alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: sdl3.Uint32) -> bool {
    fingerprint := cpu_renderer.Icon_Mesh_Fingerprint(display, scale_x, scale_y, int(target_w), int(target_h))
    if renderer.mesh_valid && fingerprint == renderer.mesh_fingerprint { renderer.mesh_cache_hits += 1; return true }
    clear(&renderer.vertices); clear(&renderer.draws)
    for draw in display { append(&renderer.draws, Native_Icon_Draw{}) }
    required := 0
    for draw in display { if alicorn.paint_command_is_icon(draw) { required += 6 } }
    if !native_vertex_buffer_ensure_capacity(
		renderer.device, &renderer.vertex_buffer, &renderer.vertex_transfer,
		&renderer.vertex_capacity, required, &renderer.capacity,
	) { return false }
    for draw, index in display {
        if !alicorn.paint_command_is_icon(draw) { continue }
        first := sdl3.Uint32(len(renderer.vertices))
        entry, added := cpu_renderer.Icon_Quad(&renderer.vertices, draw, scale_x, scale_y, int(target_w), int(target_h))
        if added { renderer.draws[index] = Native_Icon_Draw{first, 6, entry.page} }
    }
    renderer.mesh_valid = true; renderer.mesh_fingerprint = fingerprint
    renderer.upload_pending = len(renderer.vertices) > 0
    renderer.mesh_rebuilds += 1
    return true
}

native_icon_render_batch :: proc(renderer: ^Native_Icon_Renderer, command: ^sdl3.GPUCommandBuffer, target: ^sdl3.GPUTexture, target_w, target_h: sdl3.Uint32, draws: []Native_Icon_Draw) -> bool {
    has_draw := false
    for draw in draws { if draw.vertex_count > 0 { has_draw = true; break } }
    if !has_draw { return true }
    uniforms := Native_Text_Uniforms{
        proj_view=[4][4]f32{{2/f32(target_w),0,0,0},{0,-2/f32(target_h),0,0},{0,0,1,0},{-1,1,0,1}},
        model=[4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}},
    }
    sdl3.PushGPUVertexUniformData(command, 0, &uniforms, sdl3.Uint32(size_of(Native_Text_Uniforms)))
    target_info := sdl3.GPUColorTargetInfo{texture=target, load_op=.LOAD, store_op=.STORE}
    pass := sdl3.BeginGPURenderPass(command, &target_info, 1, nil)
    if pass == nil { return false }
    sdl3.BindGPUGraphicsPipeline(pass, renderer.pipeline)
    sdl3.SetGPUViewport(pass, sdl3.GPUViewport{0,0,f32(target_w),f32(target_h),0,1})
    binding := sdl3.GPUBufferBinding{buffer=renderer.vertex_buffer}
    sdl3.BindGPUVertexBuffers(pass, 0, &binding, 1)
    previous_page := -1
    for draw in draws {
        if draw.vertex_count == 0 { continue }
        if draw.page != previous_page {
            sampler := sdl3.GPUTextureSamplerBinding{texture=renderer.pages[draw.page], sampler=renderer.sampler}
            sdl3.BindGPUFragmentSamplers(pass, 0, &sampler, 1)
            previous_page = draw.page
        }
        sdl3.DrawGPUPrimitives(pass, draw.vertex_count, 1, draw.first_vertex, 0)
    }
    sdl3.EndGPURenderPass(pass)
    return true
}
