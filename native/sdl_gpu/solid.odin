package alicorn_sdl_gpu

import "core:c"
import "core:time"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
import "vendor:sdl3"

// Solid rectangles use the same simple sampled-white shader contract as the
// geometry renderer, but own their vertex storage so surface batches cannot
// overwrite a geometry mesh that is still needed later in the display list.
// Geometry is clipped on the CPU; text and geometry remain ordering barriers.
NATIVE_SOLID_INITIAL_VERTICES :: 65536
// The build-sample ring is bounded like the host diagnostics sample windows.
// It records one pass through native_solid_build per presented application
// frame so exit reports can print a real distribution instead of a mean.
NATIVE_SOLID_BUILD_SAMPLES :: 240

Native_Solid_Draw :: struct {
	first_vertex:  sdl3.Uint32,
	vertex_count:  sdl3.Uint32,
	scissor:      sdl3.Rect,
	has_scissor:   bool,
}

Native_Solid_Renderer :: struct {
	icons: Native_Icon_Renderer,
	images: Native_Image_Renderer,
	device:          ^sdl3.GPUDevice,
	runtime:         ^alicorn.Runtime,
	pipeline:        ^sdl3.GPUGraphicsPipeline,
	sampler:         ^sdl3.GPUSampler,
	white_texture:   ^sdl3.GPUTexture,
	vertex_buffer:   ^sdl3.GPUBuffer,
	vertex_transfer: ^sdl3.GPUTransferBuffer,
	vertices:        [dynamic]Native_Text_Vertex,
	vertex_capacity: int,
	draws:           [dynamic]Native_Solid_Draw,
	white_initialized: bool,
	upload_pending:  bool,
	batches:         u64,
	vertices_uploaded: u64,
	vertex_upload_bytes: u64,
	// Measurement-only attribution. native_solid_build rebuilds the complete
	// solid stream on every presentation; these counters separate visibility
	// resolution from vertex expansion and expose draw-call and buffer-growth
	// pressure without changing the path.
	capacity:            Native_Device_Stall_Stats,
	build_calls:         u64,
	build_ns:            u64,
	visibility_ns:       u64,
	expand_ns:           u64,
	build_samples:       [NATIVE_SOLID_BUILD_SAMPLES]u64,
	build_sample_count:  int,
	draw_calls:          u64,
	commands_considered: u64,
	commands_visible:    u64,
}

native_solid_make :: proc(device: ^sdl3.GPUDevice, swapchain_format: sdl3.GPUTextureFormat, runtime: ^alicorn.Runtime) -> (renderer: Native_Solid_Renderer, ok: bool) {
	renderer.device = device
	renderer.runtime = runtime
	defer if !ok { native_solid_destroy(&renderer) }
	renderer.vertex_capacity = NATIVE_SOLID_INITIAL_VERTICES
	renderer.capacity.peak_capacity = renderer.vertex_capacity
	renderer.vertices = make([dynamic]Native_Text_Vertex, 0, 4096)
	renderer.draws = make([dynamic]Native_Solid_Draw, 0, 1024)

	vertex_shader := native_text_shader(device, .VERTEX, false)
	fragment_shader := native_text_shader(device, .FRAGMENT, true)
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
		min_filter=.NEAREST, mag_filter=.NEAREST, mipmap_mode=.NEAREST,
		address_mode_u=.CLAMP_TO_EDGE, address_mode_v=.CLAMP_TO_EDGE, address_mode_w=.CLAMP_TO_EDGE,
		max_lod=1,
	})
	renderer.white_texture = sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=.R8G8B8A8_UNORM,
		usage=sdl3.GPUTextureUsageFlags{.SAMPLER, .COLOR_TARGET},
		width=1, height=1, layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
	renderer.vertex_buffer = sdl3.CreateGPUBuffer(device, sdl3.GPUBufferCreateInfo{
		usage=sdl3.GPUBufferUsageFlags{.VERTEX},
		size=sdl3.Uint32(renderer.vertex_capacity * size_of(Native_Text_Vertex)),
	})
	renderer.vertex_transfer = sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.UPLOAD,
		size=sdl3.Uint32(renderer.vertex_capacity * size_of(Native_Text_Vertex)),
	})
	if renderer.sampler == nil || renderer.white_texture == nil || renderer.vertex_buffer == nil || renderer.vertex_transfer == nil {
		return renderer, false
	}
	icon_ok := false
	renderer.icons, icon_ok = native_icon_make(device, swapchain_format, runtime)
	if !icon_ok { return renderer, false }
	image_ok := false
	renderer.images, image_ok = native_image_make(device, swapchain_format, runtime)
	if !image_ok { return renderer, false }
	return renderer, true
}

native_solid_destroy :: proc(renderer: ^Native_Solid_Renderer) {
	native_image_destroy(&renderer.images)
	native_icon_destroy(&renderer.icons)
	if renderer.vertex_transfer != nil { sdl3.ReleaseGPUTransferBuffer(renderer.device, renderer.vertex_transfer) }
	if renderer.vertex_buffer != nil { sdl3.ReleaseGPUBuffer(renderer.device, renderer.vertex_buffer) }
	if renderer.white_texture != nil { sdl3.ReleaseGPUTexture(renderer.device, renderer.white_texture) }
	if renderer.sampler != nil { sdl3.ReleaseGPUSampler(renderer.device, renderer.sampler) }
	if renderer.pipeline != nil { sdl3.ReleaseGPUGraphicsPipeline(renderer.device, renderer.pipeline) }
	delete(renderer.vertices)
	delete(renderer.draws)
	renderer^ = {}
}

// native_solid_record_build appends one build duration to the bounded sample
// ring. The ring keeps exit and diagnostics reports distributional (p50/p95/p99)
// without allocating a growing log.
native_solid_record_build :: proc(renderer: ^Native_Solid_Renderer, elapsed_ns: u64) {
	renderer.build_calls += 1
	renderer.build_ns += elapsed_ns
	if renderer.build_sample_count >= NATIVE_SOLID_BUILD_SAMPLES {
		for index in 1..<NATIVE_SOLID_BUILD_SAMPLES {
			renderer.build_samples[index-1] = renderer.build_samples[index]
		}
		renderer.build_samples[NATIVE_SOLID_BUILD_SAMPLES-1] = elapsed_ns
	} else {
		renderer.build_samples[renderer.build_sample_count] = elapsed_ns
		renderer.build_sample_count += 1
	}
}

native_solid_build :: proc(
	renderer: ^Native_Solid_Renderer,
	display: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_w, target_h: sdl3.Uint32,
) -> bool {
	clear(&renderer.vertices)
	clear(&renderer.draws)
	build_start := time.now()
	required_vertices := 0
	renderer.commands_considered += u64(len(display))
	for draw in display {
		count, visible := cpu_renderer.Solid_Surface_Vertex_Count(
			renderer.runtime, draw, scale_x, scale_y, int(target_w), int(target_h),
		)
		if visible {
			required_vertices += count
			renderer.commands_visible += 1
		}
	}
	visibility_done := time.now()
	renderer.visibility_ns += u64(time.duration_nanoseconds(time.since(build_start)))
	if required_vertices > cap(renderer.vertices) {
		reserve(&renderer.vertices, required_vertices)
	}
	for _ in display { append(&renderer.draws, Native_Solid_Draw{}) }
	for draw, index in display {
		mesh := cpu_renderer.Append_Surface_Mesh(
			&renderer.vertices, renderer.runtime, draw,
			scale_x, scale_y, int(target_w), int(target_h),
		)
		if mesh.vertex_count <= 0 { continue }
		renderer.draws[index] = Native_Solid_Draw{
			first_vertex=sdl3.Uint32(mesh.first_vertex),
			vertex_count=sdl3.Uint32(mesh.vertex_count),
			scissor=sdl3.Rect{
				c.int(mesh.scissor.x), c.int(mesh.scissor.y),
				c.int(mesh.scissor.w), c.int(mesh.scissor.h),
			},
			has_scissor=mesh.has_scissor,
		}
	}
	renderer.expand_ns += u64(time.duration_nanoseconds(time.since(visibility_done)))
	if len(renderer.vertices) > renderer.vertex_capacity && !native_vertex_buffer_ensure_capacity(
		renderer.device, &renderer.vertex_buffer, &renderer.vertex_transfer,
		&renderer.vertex_capacity, len(renderer.vertices), &renderer.capacity,
	) {
		return false
	}
	native_solid_record_build(renderer, u64(time.duration_nanoseconds(time.since(build_start))))
	renderer.upload_pending = len(renderer.vertices) > 0
	return true
}

native_solid_render_batch :: proc(
	renderer: ^Native_Solid_Renderer,
	command: ^sdl3.GPUCommandBuffer,
	target: ^sdl3.GPUTexture,
	target_w, target_h: sdl3.Uint32,
	draws: []Native_Solid_Draw,
) -> bool {
	has_draw := false
	for draw in draws {
		if draw.vertex_count > 0 { has_draw = true; break }
	}
	if !has_draw { return true }
	uniforms := Native_Text_Uniforms{
		proj_view = [4][4]f32{
			{2/f32(target_w), 0, 0, 0},
			{0, -2/f32(target_h), 0, 0},
			{0, 0, 1, 0},
			{-1, 1, 0, 1},
		},
		model = [4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}},
	}
	sdl3.PushGPUVertexUniformData(command, 0, &uniforms, sdl3.Uint32(size_of(Native_Text_Uniforms)))
	target_info := sdl3.GPUColorTargetInfo{texture=target, load_op=.LOAD, store_op=.STORE}
	pass := sdl3.BeginGPURenderPass(command, &target_info, 1, nil)
	if pass == nil { return false }
	sdl3.BindGPUGraphicsPipeline(pass, renderer.pipeline)
	sdl3.SetGPUViewport(pass, sdl3.GPUViewport{0, 0, f32(target_w), f32(target_h), 0, 1})
	binding := sdl3.GPUBufferBinding{buffer=renderer.vertex_buffer, offset=0}
	sdl3.BindGPUVertexBuffers(pass, 0, &binding, 1)
	texture_binding := sdl3.GPUTextureSamplerBinding{texture=renderer.white_texture, sampler=renderer.sampler}
	sdl3.BindGPUFragmentSamplers(pass, 0, &texture_binding, 1)
	for draw in draws {
		if draw.vertex_count > 0 {
			if draw.has_scissor { sdl3.SetGPUScissor(pass, draw.scissor) }
			else { sdl3.SetGPUScissor(pass, sdl3.Rect{0, 0, c.int(target_w), c.int(target_h)}) }
			sdl3.DrawGPUPrimitives(pass, draw.vertex_count, 1, draw.first_vertex, 0)
			renderer.draw_calls += 1
		}
	}
	sdl3.EndGPURenderPass(pass)
	renderer.batches += 1
	return true
}

native_solid_commit_submission :: proc(renderer: ^Native_Solid_Renderer) {
	renderer.icons.upload_pending = false
	renderer.upload_pending = false
	renderer.images.upload_pending = false
	native_image_commit_submission(&renderer.images)
}
