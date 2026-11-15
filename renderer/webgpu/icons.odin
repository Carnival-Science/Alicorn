package webgpu_renderer

import "core:math/bits"
import alicorn "../../runtime"
import cpu_renderer "../cpu"
import "vendor:wgpu"

ICON_INITIAL_VERTEX_CAPACITY :: 1024

ICON_WGSL :: `
struct View_Uniform {
	physical_size: vec2<f32>,
	_padding: vec2<f32>,
};
@group(0) @binding(0) var<uniform> view: View_Uniform;
@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct Vertex_Input {
	@location(0) position: vec3<f32>,
	@location(1) color: vec4<f32>,
	@location(2) uv: vec2<f32>,
};
struct Vertex_Output {
	@builtin(position) position: vec4<f32>,
	@location(0) color: vec4<f32>,
	@location(1) uv: vec2<f32>,
};

@vertex fn vs_main(input: Vertex_Input) -> Vertex_Output {
	var output: Vertex_Output;
	let top_left_ndc = input.position.xy / view.physical_size * 2.0 - vec2<f32>(1.0, 1.0);
	output.position = vec4<f32>(top_left_ndc.x, -top_left_ndc.y, input.position.z, 1.0);
	output.color = input.color;
	output.uv = input.uv;
	return output;
}

@fragment fn fs_main(input: Vertex_Output) -> @location(0) vec4<f32> {
	let coverage = textureSample(atlas_texture, atlas_sampler, input.uv).r;
	return vec4<f32>(input.color.rgb, coverage * input.color.a);
}
`

Icon_Result :: enum {
	Ok,
	Invalid_Input,
	Resource_Failure,
}

Icon_Draw :: struct {
	first_vertex, vertex_count: u32,
	command_index: int,
	page_index: int,
}

Icon_GPU_Page :: struct {
	texture: wgpu.Texture,
	view: wgpu.TextureView,
	bind_group: wgpu.BindGroup,
	initialized: bool,
}

// Icon_Renderer owns device-local copies of the immutable compiled icon atlas
// and cached CPU-generated icon meshes. Atlas pages are created lazily when a
// retained paint list first uses them. It borrows the finalized paint list only
// during Prepare/Draw and never owns the device, queue, target, or submission.
Icon_Renderer :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	shader: wgpu.ShaderModule,
	view_layout: wgpu.BindGroupLayout,
	atlas_layout: wgpu.BindGroupLayout,
	pipeline_layout: wgpu.PipelineLayout,
	pipeline: wgpu.RenderPipeline,
	sampler: wgpu.Sampler,
	view_buffer: wgpu.Buffer,
	view_bind_group: wgpu.BindGroup,
	vertex_buffer: wgpu.Buffer,
	vertex_capacity: int,
	vertices: [dynamic]cpu_renderer.Vertex,
	draws: [dynamic]Icon_Draw,
	pages: [len(alicorn.ICON_ATLAS_PAGES)]Icon_GPU_Page,
	mesh_valid: bool,
	mesh_fingerprint: u64,
	viewport_valid: bool,
	viewport_width, viewport_height: u32,
	mesh_rebuild_count, mesh_cache_hits: u64,
	vertex_upload_count, vertex_upload_bytes: u64,
	atlas_page_upload_count, atlas_upload_bytes: u64,
	viewport_upload_count: u64,
}

Icon_Create :: proc(device: wgpu.Device, queue: wgpu.Queue, format: wgpu.TextureFormat) -> (renderer: Icon_Renderer, ok: bool) {
	if device == nil || queue == nil || !alicorn.icon_atlas_validate() { return }
	renderer.device, renderer.queue, renderer.format = device, queue, format
	renderer.vertex_capacity = ICON_INITIAL_VERTEX_CAPACITY
	renderer.vertices = make([dynamic]cpu_renderer.Vertex, 0, ICON_INITIAL_VERTEX_CAPACITY)
	renderer.draws = make([dynamic]Icon_Draw, 0, 128)
	defer if !ok { Icon_Destroy(&renderer) }

	renderer.view_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU icon viewport",
		usage={.Uniform, .CopyDst},
		size=u64(size_of([4]f32)),
	})
	if renderer.view_buffer == nil { return }
	view_entry := wgpu.BindGroupLayoutEntry{
		binding=0,
		visibility={.Vertex},
		buffer={type=.Uniform, minBindingSize=u64(size_of([4]f32))},
	}
	renderer.view_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU icon viewport layout",
		entryCount=1,
		entries=&view_entry,
	})
	if renderer.view_layout == nil { return }
	renderer.view_bind_group = wgpu.DeviceCreateBindGroup(device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU icon viewport binding",
		layout=renderer.view_layout,
		entryCount=1,
		entries=&wgpu.BindGroupEntry{binding=0, buffer=renderer.view_buffer, size=u64(size_of([4]f32))},
	})
	if renderer.view_bind_group == nil { return }

	atlas_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding=0, visibility={.Fragment}, texture={sampleType=.Float, viewDimension=._2D}},
		{binding=1, visibility={.Fragment}, sampler={type=.Filtering}},
	}
	renderer.atlas_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU icon atlas layout",
		entryCount=uint(len(atlas_entries)),
		entries=&atlas_entries[0],
	})
	if renderer.atlas_layout == nil { return }
	renderer.sampler = wgpu.DeviceCreateSampler(device, &wgpu.SamplerDescriptor{
		addressModeU=.ClampToEdge,
		addressModeV=.ClampToEdge,
		addressModeW=.ClampToEdge,
		magFilter=.Linear,
		minFilter=.Linear,
		mipmapFilter=.Nearest,
		lodMinClamp=0,
		lodMaxClamp=1,
		maxAnisotropy=1,
	})
	if renderer.sampler == nil { return }

	bind_layouts := [2]wgpu.BindGroupLayout{renderer.view_layout, renderer.atlas_layout}
	renderer.pipeline_layout = wgpu.DeviceCreatePipelineLayout(device, &wgpu.PipelineLayoutDescriptor{
		label="Alicorn WebGPU icon pipeline layout",
		bindGroupLayoutCount=uint(len(bind_layouts)),
		bindGroupLayouts=&bind_layouts[0],
	})
	if renderer.pipeline_layout == nil { return }
	renderer.shader = wgpu.DeviceCreateShaderModule(device, &wgpu.ShaderModuleDescriptor{
		label="Alicorn WebGPU icon WGSL",
		nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL, code=ICON_WGSL},
	})
	if renderer.shader == nil { return }
	attrs := [3]wgpu.VertexAttribute{
		{format=.Float32x3, offset=u64(offset_of(cpu_renderer.Vertex, position)), shaderLocation=0},
		{format=.Float32x4, offset=u64(offset_of(cpu_renderer.Vertex, color)), shaderLocation=1},
		{format=.Float32x2, offset=u64(offset_of(cpu_renderer.Vertex, uv)), shaderLocation=2},
	}
	vertex_layout := wgpu.VertexBufferLayout{
		stepMode=.Vertex,
		arrayStride=u64(size_of(cpu_renderer.Vertex)),
		attributeCount=uint(len(attrs)),
		attributes=&attrs[0],
	}
	blend := wgpu.BlendState{
		color={operation=.Add, srcFactor=.SrcAlpha, dstFactor=.OneMinusSrcAlpha},
		alpha={operation=.Add, srcFactor=.One, dstFactor=.OneMinusSrcAlpha},
	}
	target := wgpu.ColorTargetState{format=format, blend=&blend, writeMask=wgpu.ColorWriteMaskFlags_All}
	fragment := wgpu.FragmentState{module=renderer.shader, entryPoint="fs_main", targetCount=1, targets=&target}
	renderer.pipeline = wgpu.DeviceCreateRenderPipeline(device, &wgpu.RenderPipelineDescriptor{
		label="Alicorn WebGPU icon pipeline",
		layout=renderer.pipeline_layout,
		vertex={module=renderer.shader, entryPoint="vs_main", bufferCount=1, buffers=&vertex_layout},
		primitive={topology=.TriangleList, frontFace=.CCW, cullMode=.None},
		multisample={count=1, mask=0xFFFFFFFF},
		fragment=&fragment,
	})
	if renderer.pipeline == nil { return }
	ok = true
	return
}

// Icon_Prepare reuses the shared CPU mesh builder, lazily uploads immutable
// R8 atlas pages, and uploads icon vertices only when their content changes.
Icon_Prepare :: proc(
	renderer: ^Icon_Renderer,
	display: alicorn.Paint_Display_List_View,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
) -> Icon_Result {
	if renderer == nil || renderer.device == nil || renderer.queue == nil || renderer.pipeline == nil ||
	   renderer.vertex_capacity <= 0 || target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(bits.INT_MAX) || u64(target_height) > u64(bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	fingerprint := cpu_renderer.Icon_Mesh_Fingerprint(display.commands, scale_x, scale_y, int(target_width), int(target_height))
	if renderer.mesh_valid && renderer.mesh_fingerprint == fingerprint {
		renderer.mesh_cache_hits += 1
		return .Ok
	}
	renderer.mesh_valid = false
	clear(&renderer.vertices)
	clear(&renderer.draws)
	icon_count := 0
	for command in display.commands { if alicorn.paint_command_is_icon(command) { icon_count += 1 } }
	if icon_count > bits.INT_MAX/6 || icon_count*6 > bits.INT_MAX/size_of(cpu_renderer.Vertex) {
		return .Resource_Failure
	}
	if icon_count > 0 { reserve(&renderer.vertices, icon_count*6) }
	for command, command_index in display.commands {
		if !alicorn.paint_command_is_icon(command) { continue }
		first_vertex := len(renderer.vertices)
		entry, added := cpu_renderer.Icon_Quad(
			&renderer.vertices, command, scale_x, scale_y, int(target_width), int(target_height),
		)
		if !added { continue }
		if entry.page < 0 || entry.page >= len(renderer.pages) || first_vertex < 0 ||
		   len(renderer.vertices)-first_vertex != 6 {
			return .Resource_Failure
		}
		append(&renderer.draws, Icon_Draw{u32(first_vertex), 6, command_index, entry.page})
	}
	for draw in renderer.draws {
		if !icon_atlas_page_ensure(renderer, draw.page_index) { return .Resource_Failure }
	}
	if len(renderer.vertices) > 0 {
		if len(renderer.vertices) > bits.INT_MAX/size_of(cpu_renderer.Vertex) { return .Resource_Failure }
		if !icon_vertex_buffer_ensure(renderer, len(renderer.vertices)) { return .Resource_Failure }
		upload_bytes := len(renderer.vertices)*size_of(cpu_renderer.Vertex)
		wgpu.QueueWriteBuffer(renderer.queue, renderer.vertex_buffer, 0, raw_data(renderer.vertices[:]), uint(upload_bytes))
		renderer.vertex_upload_count += 1
		renderer.vertex_upload_bytes += u64(upload_bytes)
	}
	renderer.mesh_fingerprint = fingerprint
	renderer.mesh_valid = true
	renderer.mesh_rebuild_count += 1
	if !renderer.viewport_valid || renderer.viewport_width != target_width || renderer.viewport_height != target_height {
		viewport := [4]f32{f32(target_width), f32(target_height), 0, 0}
		wgpu.QueueWriteBuffer(renderer.queue, renderer.view_buffer, 0, raw_data(viewport[:]), uint(size_of(viewport)))
		renderer.viewport_valid = true
		renderer.viewport_width, renderer.viewport_height = target_width, target_height
		renderer.viewport_upload_count += 1
	}
	return .Ok
}

Icon_Draw_Command :: proc(
	renderer: ^Icon_Renderer,
	pass: wgpu.RenderPassEncoder,
	command_index: int,
	command: alicorn.Paint_Command,
	target_width, target_height: u32,
) -> Icon_Result {
	if command_index < 0 || target_width == 0 || target_height == 0 {
		return .Invalid_Input
	}
	if !alicorn.paint_command_is_icon(command) { return .Ok }
	if renderer == nil || pass == nil { return .Invalid_Input }
	draw_found := false
	for draw in renderer.draws { if draw.command_index == command_index { draw_found = true; break } }
	if !draw_found { return .Ok }
	if renderer.pipeline == nil || renderer.vertex_buffer == nil || renderer.view_bind_group == nil {
		return .Invalid_Input
	}
	if !renderer.mesh_valid { return .Invalid_Input }
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.view_bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0,
		u64(len(renderer.vertices)*size_of(cpu_renderer.Vertex)))
	// Icon geometry is already clipped by the shared CPU quad builder. Restore
	// the full target scissor because preceding surface/text commands may leave
	// a narrower scissor active on this render pass.
	wgpu.RenderPassEncoderSetScissorRect(pass, 0, 0, target_width, target_height)
	for draw in renderer.draws {
		if draw.command_index != command_index { continue }
		if draw.page_index < 0 || draw.page_index >= len(renderer.pages) { return .Resource_Failure }
		page := renderer.pages[draw.page_index]
		if !page.initialized || page.bind_group == nil { return .Resource_Failure }
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, page.bind_group)
		wgpu.RenderPassEncoderDraw(pass, draw.vertex_count, 1, draw.first_vertex, 0)
	}
	return .Ok
}

Icon_Destroy :: proc(renderer: ^Icon_Renderer) {
	if renderer == nil { return }
	for &page in renderer.pages {
		if page.bind_group != nil { wgpu.BindGroupRelease(page.bind_group) }
		if page.view != nil { wgpu.TextureViewRelease(page.view) }
		if page.texture != nil { wgpu.TextureRelease(page.texture) }
	}
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	if renderer.pipeline != nil { wgpu.RenderPipelineRelease(renderer.pipeline) }
	if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
	if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
	if renderer.atlas_layout != nil { wgpu.BindGroupLayoutRelease(renderer.atlas_layout) }
	if renderer.view_bind_group != nil { wgpu.BindGroupRelease(renderer.view_bind_group) }
	if renderer.view_layout != nil { wgpu.BindGroupLayoutRelease(renderer.view_layout) }
	if renderer.view_buffer != nil { wgpu.BufferRelease(renderer.view_buffer) }
	if renderer.sampler != nil { wgpu.SamplerRelease(renderer.sampler) }
	delete(renderer.vertices)
	delete(renderer.draws)
	renderer^ = {}
}

icon_atlas_page_ensure :: proc(renderer: ^Icon_Renderer, page_index: int) -> bool {
	if renderer == nil || page_index < 0 || page_index >= len(renderer.pages) || renderer.atlas_layout == nil || renderer.sampler == nil {
		return false
	}
	page := &renderer.pages[page_index]
	if page.initialized { return true }
	data := alicorn.ICON_ATLAS_PAGES[page_index]
	texture := wgpu.DeviceCreateTexture(renderer.device, &wgpu.TextureDescriptor{
		label="Alicorn WebGPU immutable icon atlas",
		usage={.TextureBinding, .CopyDst},
		dimension=._2D,
		size={width=u32(data.width), height=u32(data.height), depthOrArrayLayers=1},
		format=.R8Unorm,
		mipLevelCount=1,
		sampleCount=1,
	})
	if texture == nil { return false }
	texture_view := wgpu.TextureCreateView(texture)
	if texture_view == nil { wgpu.TextureRelease(texture); return false }
	entries := [2]wgpu.BindGroupEntry{
		{binding=0, textureView=texture_view},
		{binding=1, sampler=renderer.sampler},
	}
	bind_group := wgpu.DeviceCreateBindGroup(renderer.device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU icon atlas page",
		layout=renderer.atlas_layout,
		entryCount=uint(len(entries)),
		entries=&entries[0],
	})
	if bind_group == nil { wgpu.TextureViewRelease(texture_view); wgpu.TextureRelease(texture); return false }
	destination := wgpu.TexelCopyTextureInfo{texture=texture, aspect=.All}
	layout := wgpu.TexelCopyBufferLayout{bytesPerRow=u32(data.width), rowsPerImage=u32(data.height)}
	extent := wgpu.Extent3D{width=u32(data.width), height=u32(data.height), depthOrArrayLayers=1}
	wgpu.QueueWriteTexture(renderer.queue, &destination, raw_data(data.pixels), uint(len(data.pixels)), &layout, &extent)
	page.texture, page.view, page.bind_group = texture, texture_view, bind_group
	page.initialized = true
	renderer.atlas_page_upload_count += 1
	renderer.atlas_upload_bytes += u64(len(data.pixels))
	return true
}

icon_vertex_buffer_ensure :: proc(renderer: ^Icon_Renderer, required_vertices: int) -> bool {
	if required_vertices <= renderer.vertex_capacity && renderer.vertex_buffer != nil { return true }
	if required_vertices < 0 || required_vertices > bits.INT_MAX/size_of(cpu_renderer.Vertex) { return false }
	capacity := max(renderer.vertex_capacity, ICON_INITIAL_VERTEX_CAPACITY)
	for capacity < required_vertices {
		if capacity > bits.INT_MAX/2 { capacity = required_vertices; break }
		capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU icon vertices",
		usage={.Vertex, .CopyDst},
		size=u64(capacity*size_of(cpu_renderer.Vertex)),
	})
	if buffer == nil { return false }
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	renderer.vertex_buffer = buffer
	renderer.vertex_capacity = capacity
	return true
}
