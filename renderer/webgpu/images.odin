package webgpu_renderer

import "core:math/bits"
import alicorn "../../runtime"
import cpu_renderer "../cpu"
import "vendor:wgpu"

IMAGE_INITIAL_VERTEX_CAPACITY :: 1024
IMAGE_GPU_CACHE_BUDGET_BYTES :: 128 * 1024 * 1024

IMAGE_WGSL :: #load("shaders/images.wgsl", string)

Image_Result :: enum {
	Ok,
	Invalid_Input,
	Resource_Failure,
}

Image_Draw :: struct {
	first_vertex, vertex_count: u32,
	command_index: int,
	runtime: ^alicorn.Runtime,
	handle: alicorn.Image_Handle,
}

Image_GPU_Resource :: struct {
	runtime: ^alicorn.Runtime,
	handle: alicorn.Image_Handle,
	texture: wgpu.Texture,
	view: wgpu.TextureView,
	bind_group: wgpu.BindGroup,
	byte_size: u64,
	last_use_serial: u64,
	lru_stamp: u64,
	live_in_frame: bool,
}

Image_Retired_Resource :: struct {
	resource: Image_GPU_Resource,
	retire_after_serial: u64,
}

Image_Request :: struct {
	runtime: ^alicorn.Runtime,
	handle: alicorn.Image_Handle,
	pixels: alicorn.Image_Pixels_View,
}

// Image_Renderer retains device copies of Runtime-owned RGBA8 pixels. Handles
// are scoped by Runtime identity because Image_Handle values are Runtime-local.
// Cache residency is bounded; replaced GPU resources remain in a retirement
// queue until the host reports completion of their last-use submission.
Image_Renderer :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	shader: wgpu.ShaderModule,
	view_layout: wgpu.BindGroupLayout,
	image_layout: wgpu.BindGroupLayout,
	pipeline_layout: wgpu.PipelineLayout,
	pipeline: wgpu.RenderPipeline,
	sampler: wgpu.Sampler,
	view_buffer: wgpu.Buffer,
	view_bind_group: wgpu.BindGroup,
	vertex_buffer: wgpu.Buffer,
	vertex_capacity: int,
	vertices: [dynamic]cpu_renderer.Vertex,
	draws: [dynamic]Image_Draw,
	resources: [dynamic]Image_GPU_Resource,
	retired: [dynamic]Image_Retired_Resource,
	resident_bytes: u64,
	submitted_serial, completed_serial: u64,
	lru_clock: u64,
	mesh_valid: bool,
	mesh_fingerprint: u64,
	viewport_valid: bool,
	viewport_width, viewport_height: u32,
	mesh_rebuild_count, mesh_cache_hits: u64,
	vertex_upload_count, vertex_upload_bytes: u64,
	texture_upload_count, texture_upload_bytes: u64,
	resource_eviction_count, resource_retirement_count, resource_release_count: u64,
	viewport_upload_count: u64,
}

Image_Create :: proc(
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
) -> (renderer: Image_Renderer, ok: bool) {
	if device == nil || queue == nil { return }
	renderer.device, renderer.queue, renderer.format = device, queue, format
	renderer.vertex_capacity = IMAGE_INITIAL_VERTEX_CAPACITY
	renderer.vertices = make([dynamic]cpu_renderer.Vertex, 0, IMAGE_INITIAL_VERTEX_CAPACITY)
	renderer.draws = make([dynamic]Image_Draw, 0, 64)
	renderer.resources = make([dynamic]Image_GPU_Resource, 0, 16)
	renderer.retired = make([dynamic]Image_Retired_Resource, 0, 8)
	defer if !ok { Image_Destroy(&renderer) }

	renderer.view_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU image viewport",
		usage={.Uniform, .CopyDst},
		size=VIEW_UNIFORM_BUFFER_BYTES,
	})
	if renderer.view_buffer == nil { return }
	view_entry := wgpu.BindGroupLayoutEntry{
		binding=0,
		visibility={.Vertex},
		buffer={type=.Uniform, hasDynamicOffset=true, minBindingSize=VIEW_UNIFORM_BYTES},
	}
	renderer.view_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU image viewport layout",
		entryCount=1,
		entries=&view_entry,
	})
	if renderer.view_layout == nil { return }
	renderer.view_bind_group = wgpu.DeviceCreateBindGroup(device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU image viewport binding",
		layout=renderer.view_layout,
		entryCount=1,
		entries=&wgpu.BindGroupEntry{binding=0, buffer=renderer.view_buffer, size=VIEW_UNIFORM_BYTES},
	})
	if renderer.view_bind_group == nil { return }

	image_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding=0, visibility={.Fragment}, texture={sampleType=.Float, viewDimension=._2D}},
		{binding=1, visibility={.Fragment}, sampler={type=.Filtering}},
	}
	renderer.image_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU image texture layout",
		entryCount=uint(len(image_entries)),
		entries=&image_entries[0],
	})
	if renderer.image_layout == nil { return }
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

	layouts := [2]wgpu.BindGroupLayout{renderer.view_layout, renderer.image_layout}
	renderer.pipeline_layout = wgpu.DeviceCreatePipelineLayout(device, &wgpu.PipelineLayoutDescriptor{
		label="Alicorn WebGPU image pipeline layout",
		bindGroupLayoutCount=uint(len(layouts)),
		bindGroupLayouts=&layouts[0],
	})
	if renderer.pipeline_layout == nil { return }
	renderer.shader = wgpu.DeviceCreateShaderModule(device, &wgpu.ShaderModuleDescriptor{
		label="Alicorn WebGPU image WGSL",
		nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL, code=IMAGE_WGSL},
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
		label="Alicorn WebGPU image pipeline",
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

Image_Prepare :: proc(
	renderer: ^Image_Renderer,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
) -> Image_Result {
	if renderer == nil || rt == nil || renderer.device == nil || renderer.queue == nil || renderer.pipeline == nil ||
	   renderer.vertex_capacity <= 0 || target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(bits.INT_MAX) || u64(target_height) > u64(bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}

	requests := make([dynamic]Image_Request, 0, 8, allocator=context.temp_allocator)
	defer delete(requests)
	for &resource in renderer.resources { resource.live_in_frame = false }
	for command in display.commands {
		paint, is_image := command.payload.(alicorn.Image_Paint)
		if !is_image { continue }
		pixels, valid := alicorn.image_resolve(rt, paint.image)
		if !valid { continue }
		if pixels.width <= 0 || pixels.height <= 0 || len(pixels.rgba8) != pixels.width*pixels.height*4 {
			return .Resource_Failure
		}
		index := image_resource_index(renderer, rt, paint.image)
		if index >= 0 {
			renderer.resources[index].live_in_frame = true
			renderer.lru_clock += 1
			renderer.resources[index].lru_stamp = renderer.lru_clock
			continue
		}
		already_requested := false
		for request in requests {
			if request.runtime == rt && request.handle == paint.image { already_requested = true; break }
		}
		if !already_requested { append(&requests, Image_Request{rt, paint.image, pixels}) }
	}

	// A Runtime may release an image after it was last painted. Retire such
	// textures even when the paint list still contains an old handle.
	for index := len(renderer.resources)-1; index >= 0; index -= 1 {
		resource := renderer.resources[index]
		if resource.runtime != rt { continue }
		_, valid := alicorn.image_resolve(rt, resource.handle)
		if !valid { image_resource_retire_index(renderer, index) }
	}

	incoming_bytes: u64 = 0
	for request in requests {
		bytes := u64(request.pixels.width)*u64(request.pixels.height)*4
		if bytes == 0 || bytes > IMAGE_GPU_CACHE_BUDGET_BYTES || incoming_bytes > IMAGE_GPU_CACHE_BUDGET_BYTES-bytes {
			return .Resource_Failure
		}
		incoming_bytes += bytes
	}
	if incoming_bytes > IMAGE_GPU_CACHE_BUDGET_BYTES { return .Resource_Failure }
	for renderer.resident_bytes > IMAGE_GPU_CACHE_BUDGET_BYTES-incoming_bytes {
		candidate := image_lru_evictable_index(renderer)
		if candidate < 0 { return .Resource_Failure }
		image_resource_retire_index(renderer, candidate)
	}

	created := make([dynamic]alicorn.Image_Handle, 0, len(requests), allocator=context.temp_allocator)
	defer delete(created)
	for request in requests {
		resource, ok := image_resource_create(renderer, rt, request)
		if !ok {
			for handle in created {
				index := image_resource_index(renderer, rt, handle)
				if index >= 0 { image_resource_release_index(renderer, index) }
			}
			return .Resource_Failure
		}
		append(&renderer.resources, resource)
		renderer.resident_bytes += resource.byte_size
		append(&created, request.handle)
	}

	fingerprint := cpu_renderer.Image_Mesh_Fingerprint(
		display.commands, scale_x, scale_y, int(target_width), int(target_height),
	)
	for command in display.commands {
		paint, is_image := command.payload.(alicorn.Image_Paint)
		if !is_image { continue }
		_, valid := alicorn.image_resolve(rt, paint.image)
		fingerprint = alicorn.hash_mix(fingerprint, 1 if valid else 0)
		if valid {
			pixels, _ := alicorn.image_resolve(rt, paint.image)
			fingerprint = alicorn.hash_mix(fingerprint, u64(pixels.width))
			fingerprint = alicorn.hash_mix(fingerprint, u64(pixels.height))
		}
	}
	if renderer.mesh_valid && renderer.mesh_fingerprint == fingerprint {
		renderer.mesh_cache_hits += 1
		image_viewport_upload_if_needed(renderer, target_width, target_height)
		return .Ok
	}
	renderer.mesh_valid = false
	clear(&renderer.vertices)
	clear(&renderer.draws)
	image_count := 0
	for command in display.commands {
		if alicorn.paint_command_is_image(command) {
			paint, _ := command.payload.(alicorn.Image_Paint)
			if _, valid := alicorn.image_resolve(rt, paint.image); valid { image_count += 1 }
		}
	}
	if image_count > bits.INT_MAX/6 || image_count*6 > bits.INT_MAX/size_of(cpu_renderer.Vertex) {
		return .Resource_Failure
	}
	if image_count > 0 { reserve(&renderer.vertices, image_count*6) }
	for command, command_index in display.commands {
		paint, is_image := command.payload.(alicorn.Image_Paint)
		if !is_image { continue }
		if image_resource_index(renderer, rt, paint.image) < 0 { continue }
		first_vertex := len(renderer.vertices)
		if !cpu_renderer.Image_Quad(&renderer.vertices, command, scale_x, scale_y, int(target_width), int(target_height)) { continue }
		if first_vertex < 0 || len(renderer.vertices)-first_vertex != 6 { return .Resource_Failure }
		append(&renderer.draws, Image_Draw{u32(first_vertex), 6, command_index, rt, paint.image})
	}
	if len(renderer.vertices) > 0 {
		if len(renderer.vertices) > bits.INT_MAX/size_of(cpu_renderer.Vertex) { return .Resource_Failure }
		if !image_vertex_buffer_ensure(renderer, len(renderer.vertices)) { return .Resource_Failure }
		upload_bytes := len(renderer.vertices)*size_of(cpu_renderer.Vertex)
		wgpu.QueueWriteBuffer(renderer.queue, renderer.vertex_buffer, 0, raw_data(renderer.vertices[:]), uint(upload_bytes))
		renderer.vertex_upload_count += 1
		renderer.vertex_upload_bytes += u64(upload_bytes)
	}
	renderer.mesh_fingerprint = fingerprint
	renderer.mesh_valid = true
	renderer.mesh_rebuild_count += 1
	image_viewport_upload_if_needed(renderer, target_width, target_height)
	return .Ok
}

Image_Draw_Command :: proc(
	renderer: ^Image_Renderer,
	pass: wgpu.RenderPassEncoder,
	rt: ^alicorn.Runtime,
	command_index: int,
	command: alicorn.Paint_Command,
	target_width, target_height: u32,
	view_slot: u32 = 0,
) -> Image_Result {
	if command_index < 0 || target_width == 0 || target_height == 0 { return .Invalid_Input }
	if !alicorn.paint_command_is_image(command) { return .Ok }
	if renderer == nil || pass == nil || rt == nil { return .Invalid_Input }
	draw: ^Image_Draw = nil
	for &candidate in renderer.draws {
		if candidate.command_index == command_index { draw = &candidate; break }
	}
	if draw == nil { return .Ok }
	if draw.runtime != rt || renderer.pipeline == nil || renderer.vertex_buffer == nil || renderer.view_bind_group == nil || !renderer.mesh_valid {
		return .Invalid_Input
	}
	resource_index := image_resource_index(renderer, rt, draw.handle)
	if resource_index < 0 { return .Resource_Failure }
	resource := renderer.resources[resource_index]
	if resource.bind_group == nil { return .Resource_Failure }
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.pipeline)
	if !webgpu_view_bind_group_set(pass, 0, renderer.view_bind_group, view_slot) { return .Invalid_Input }
	wgpu.RenderPassEncoderSetBindGroup(pass, 1, resource.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0,
		u64(len(renderer.vertices)*size_of(cpu_renderer.Vertex)))
	// Image_Quad clips UVs and geometry together. Reset scissor after preceding
	// families that may have left a narrow scissor on the shared render pass.
	wgpu.RenderPassEncoderSetScissorRect(pass, 0, 0, target_width, target_height)
	wgpu.RenderPassEncoderDraw(pass, draw.vertex_count, 1, draw.first_vertex, 0)
	return .Ok
}

// Image_Commit_Submission assigns a serial only after QueueSubmit succeeds.
// The host must later pass that serial to Image_Complete_Submission from its
// queue-work-done callback; retired texture resources remain bounded meanwhile.
Image_Commit_Submission :: proc(renderer: ^Image_Renderer, rt: ^alicorn.Runtime) -> u64 {
	if renderer == nil || rt == nil || renderer.submitted_serial == max(u64) { return 0 }
	renderer.submitted_serial += 1
	serial := renderer.submitted_serial
	for draw in renderer.draws {
		if draw.runtime != rt { continue }
		index := image_resource_index(renderer, rt, draw.handle)
		if index >= 0 { renderer.resources[index].last_use_serial = serial }
	}
	return serial
}

Image_Complete_Submission :: proc(renderer: ^Image_Renderer, completed_serial: u64) -> bool {
	if renderer == nil || completed_serial > renderer.submitted_serial { return false }
	if completed_serial <= renderer.completed_serial { return true }
	renderer.completed_serial = completed_serial
	for index := len(renderer.retired)-1; index >= 0; index -= 1 {
		if renderer.retired[index].retire_after_serial > completed_serial { continue }
		resource := renderer.retired[index].resource
		byte_size := resource.byte_size
		image_resource_release_gpu(&resource)
		renderer.resident_bytes -= byte_size
		renderer.resource_release_count += 1
		image_retired_remove(renderer, index)
	}
	return true
}

Image_Destroy :: proc(renderer: ^Image_Renderer) {
	if renderer == nil { return }
	for &resource in renderer.resources { image_resource_release_gpu(&resource) }
	for &retired in renderer.retired { image_resource_release_gpu(&retired.resource) }
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	if renderer.pipeline != nil { wgpu.RenderPipelineRelease(renderer.pipeline) }
	if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
	if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
	if renderer.image_layout != nil { wgpu.BindGroupLayoutRelease(renderer.image_layout) }
	if renderer.view_bind_group != nil { wgpu.BindGroupRelease(renderer.view_bind_group) }
	if renderer.view_layout != nil { wgpu.BindGroupLayoutRelease(renderer.view_layout) }
	if renderer.view_buffer != nil { wgpu.BufferRelease(renderer.view_buffer) }
	if renderer.sampler != nil { wgpu.SamplerRelease(renderer.sampler) }
	delete(renderer.vertices)
	delete(renderer.draws)
	delete(renderer.resources)
	delete(renderer.retired)
	renderer^ = {}
}

image_resource_create :: proc(
	renderer: ^Image_Renderer,
	rt: ^alicorn.Runtime,
	request: Image_Request,
) -> (resource: Image_GPU_Resource, ok: bool) {
	if renderer == nil || rt == nil || request.runtime != rt || request.pixels.width <= 0 || request.pixels.height <= 0 ||
	   len(request.pixels.rgba8) != request.pixels.width*request.pixels.height*4 || renderer.image_layout == nil || renderer.sampler == nil {
		return
	}
	texture_format := renderer.format
	if renderer.format == .RGBA8UnormSrgb || renderer.format == .BGRA8UnormSrgb {
		texture_format = .RGBA8UnormSrgb
	} else {
		texture_format = .RGBA8Unorm
	}
	texture := wgpu.DeviceCreateTexture(renderer.device, &wgpu.TextureDescriptor{
		label="Alicorn Runtime image",
		usage={.TextureBinding, .CopyDst},
		dimension=._2D,
		size={width=u32(request.pixels.width), height=u32(request.pixels.height), depthOrArrayLayers=1},
		format=texture_format,
		mipLevelCount=1,
		sampleCount=1,
	})
	if texture == nil { return }
	defer if !ok {
		if resource.bind_group != nil { wgpu.BindGroupRelease(resource.bind_group) }
		if resource.view != nil { wgpu.TextureViewRelease(resource.view) }
		wgpu.TextureRelease(texture)
	}
	view := wgpu.TextureCreateView(texture)
	if view == nil { return }
	entries := [2]wgpu.BindGroupEntry{{binding=0, textureView=view}, {binding=1, sampler=renderer.sampler}}
	bind_group := wgpu.DeviceCreateBindGroup(renderer.device, &wgpu.BindGroupDescriptor{
		label="Alicorn Runtime image binding",
		layout=renderer.image_layout,
		entryCount=uint(len(entries)),
		entries=&entries[0],
	})
	if bind_group == nil { wgpu.TextureViewRelease(view); return }
	bytes_per_row := u32(request.pixels.width*4)
	layout := wgpu.TexelCopyBufferLayout{bytesPerRow=bytes_per_row, rowsPerImage=u32(request.pixels.height)}
	destination := wgpu.TexelCopyTextureInfo{texture=texture, aspect=.All}
	extent := wgpu.Extent3D{width=u32(request.pixels.width), height=u32(request.pixels.height), depthOrArrayLayers=1}
	wgpu.QueueWriteTexture(renderer.queue, &destination, raw_data(request.pixels.rgba8), uint(len(request.pixels.rgba8)), &layout, &extent)
	resource = Image_GPU_Resource{
		runtime=rt,
		handle=request.handle,
		texture=texture,
		view=view,
		bind_group=bind_group,
		byte_size=u64(len(request.pixels.rgba8)),
		live_in_frame=true,
	}
	renderer.texture_upload_count += 1
	renderer.texture_upload_bytes += resource.byte_size
	ok = true
	return
}

image_resource_release_gpu :: proc(resource: ^Image_GPU_Resource) {
	if resource == nil { return }
	if resource.bind_group != nil { wgpu.BindGroupRelease(resource.bind_group) }
	if resource.view != nil { wgpu.TextureViewRelease(resource.view) }
	if resource.texture != nil { wgpu.TextureRelease(resource.texture) }
	resource^ = {}
}

image_resource_retire_index :: proc(renderer: ^Image_Renderer, index: int) {
	if renderer == nil || index < 0 || index >= len(renderer.resources) { return }
	resource := renderer.resources[index]
	if resource.last_use_serial <= renderer.completed_serial {
		byte_size := resource.byte_size
		image_resource_release_gpu(&resource)
		renderer.resident_bytes -= byte_size
		renderer.resource_release_count += 1
	} else {
		append(&renderer.retired, Image_Retired_Resource{resource, resource.last_use_serial})
		renderer.resource_retirement_count += 1
	}
	renderer.resource_eviction_count += 1
	image_resource_remove(renderer, index)
}

image_resource_release_index :: proc(renderer: ^Image_Renderer, index: int) {
	if renderer == nil || index < 0 || index >= len(renderer.resources) { return }
	resource := renderer.resources[index]
	byte_size := resource.byte_size
	image_resource_release_gpu(&resource)
	renderer.resident_bytes -= byte_size
	renderer.resource_release_count += 1
	image_resource_remove(renderer, index)
}

image_resource_index :: proc(renderer: ^Image_Renderer, rt: ^alicorn.Runtime, handle: alicorn.Image_Handle) -> int {
	if renderer == nil || rt == nil { return -1 }
	for resource, index in renderer.resources {
		if resource.runtime == rt && resource.handle == handle { return index }
	}
	return -1
}

image_lru_evictable_index :: proc(renderer: ^Image_Renderer) -> int {
	if renderer == nil { return -1 }
	best := -1
	for resource, index in renderer.resources {
		if resource.live_in_frame { continue }
		if best < 0 || resource.lru_stamp < renderer.resources[best].lru_stamp { best = index }
	}
	return best
}

image_resource_remove :: proc(renderer: ^Image_Renderer, index: int) {
	for i in index+1..<len(renderer.resources) { renderer.resources[i-1] = renderer.resources[i] }
	pop(&renderer.resources)
}

image_retired_remove :: proc(renderer: ^Image_Renderer, index: int) {
	for i in index+1..<len(renderer.retired) { renderer.retired[i-1] = renderer.retired[i] }
	pop(&renderer.retired)
}

image_vertex_buffer_ensure :: proc(renderer: ^Image_Renderer, required_vertices: int) -> bool {
	if required_vertices <= renderer.vertex_capacity && renderer.vertex_buffer != nil { return true }
	if required_vertices < 0 || required_vertices > bits.INT_MAX/size_of(cpu_renderer.Vertex) { return false }
	capacity := max(renderer.vertex_capacity, IMAGE_INITIAL_VERTEX_CAPACITY)
	for capacity < required_vertices {
		if capacity > bits.INT_MAX/2 { capacity = required_vertices; break }
		capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU image vertices",
		usage={.Vertex, .CopyDst},
		size=u64(capacity*size_of(cpu_renderer.Vertex)),
	})
	if buffer == nil { return false }
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	renderer.vertex_buffer = buffer
	renderer.vertex_capacity = capacity
	return true
}

image_viewport_upload_if_needed :: proc(renderer: ^Image_Renderer, width, height: u32) {
	if renderer.viewport_valid && renderer.viewport_width == width && renderer.viewport_height == height { return }
	if !webgpu_view_uniform_write(renderer.queue, renderer.view_buffer, width, height) { return }
	renderer.viewport_valid = true
	renderer.viewport_width, renderer.viewport_height = width, height
	renderer.viewport_upload_count += 1
}
