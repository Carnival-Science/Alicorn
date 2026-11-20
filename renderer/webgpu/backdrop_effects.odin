package webgpu_renderer

import alicorn "../../runtime"
import cpu_renderer "../cpu"
import "vendor:wgpu"

WEBGPU_BACKDROP_EFFECT_FILTER_FORMAT :: wgpu.TextureFormat.RGBA16Float
WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES :: u64(48 * 1024 * 1024)
WEBGPU_BACKDROP_EFFECT_VERTEX_COUNT :: cpu_renderer.BACKDROP_EFFECT_MAX_MESH_VERTICES
WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES :: u64(WEBGPU_BACKDROP_EFFECT_VERTEX_COUNT * size_of(cpu_renderer.Vertex))
WEBGPU_BACKDROP_PREFIX_CLEAR :: wgpu.Color{0.035, 0.045, 0.065, 1}

BACKDROP_EFFECT_WGSL :: #load("shaders/backdrop_effects.wgsl", string)

Backdrop_Effect_Texture_Set :: struct {
	textures: [3]wgpu.Texture,
	views: [3]wgpu.TextureView,
	bind_groups: [3]wgpu.BindGroup,
	width, height: u32,
	bytes: u64,
	last_use_serial: u64,
}

Backdrop_Effect_Retired_Set :: struct {
	set: Backdrop_Effect_Texture_Set,
	retire_after_serial: u64,
}

// Renderer-owned bounded backdrop cache. Prefix capture is supplied by the
// shared compositor using its already prepared paint meshes. This module owns
// only sampleable targets, shared WGSL filtering/composition, and retirement;
// it never sees a native swapchain or submits the host's queue.
Backdrop_Effect_Renderer :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	output_format: wgpu.TextureFormat,
	shader: wgpu.ShaderModule,
	view_layout: wgpu.BindGroupLayout,
	texture_layout: wgpu.BindGroupLayout,
	pipeline_layout: wgpu.PipelineLayout,
	filter_pipeline: wgpu.RenderPipeline,
	composite_pipeline: wgpu.RenderPipeline,
	filter_view_buffer, composite_view_buffer: wgpu.Buffer,
	filter_view_bind_group, composite_view_bind_group: wgpu.BindGroup,
	sampler: wgpu.Sampler,
	vertex_buffer: wgpu.Buffer,
	set: Backdrop_Effect_Texture_Set,
	retired: [dynamic]Backdrop_Effect_Retired_Set,
	vertices: [dynamic]cpu_renderer.Vertex,
	plan: cpu_renderer.Backdrop_Effect_Plan,
	mesh_plan: cpu_renderer.Backdrop_Effect_Plan,
	plan_valid, output_valid, pending_encoded, pending_used: bool,
	completed_serial: u64,
	resident_bytes, peak_bytes: u64,
	mesh_rebuild_count, vertex_upload_count, vertex_upload_bytes: u64,
	capture_count, horizontal_pass_count, vertical_pass_count, composite_count, cache_hits: u64,
}

Backdrop_Effect_Create :: proc(
	device: wgpu.Device,
	queue: wgpu.Queue,
	output_format: wgpu.TextureFormat,
) -> (renderer: Backdrop_Effect_Renderer, ok: bool) {
	if device == nil || queue == nil || output_format == .Undefined { return }
	renderer.device, renderer.queue, renderer.output_format = device, queue, output_format
	renderer.retired = make([dynamic]Backdrop_Effect_Retired_Set, 0, 4)
	renderer.vertices = make([dynamic]cpu_renderer.Vertex, WEBGPU_BACKDROP_EFFECT_VERTEX_COUNT)
	defer if !ok { Backdrop_Effect_Destroy(&renderer) }

	renderer.filter_view_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU backdrop filter viewport",
		usage={.Uniform, .CopyDst},
		size=VIEW_UNIFORM_BYTES,
	})
	if renderer.filter_view_buffer == nil { return }
	renderer.composite_view_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU backdrop composite viewport",
		usage={.Uniform, .CopyDst},
		size=VIEW_UNIFORM_BUFFER_BYTES,
	})
	if renderer.composite_view_buffer == nil { return }
	view_entry := wgpu.BindGroupLayoutEntry{
		binding=0,
		visibility={.Vertex},
		buffer={type=.Uniform, hasDynamicOffset=true, minBindingSize=VIEW_UNIFORM_BYTES},
	}
	renderer.view_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU backdrop viewport layout",
		entryCount=1,
		entries=&view_entry,
	})
	if renderer.view_layout == nil { return }
	filter_view_entry := wgpu.BindGroupEntry{binding=0, buffer=renderer.filter_view_buffer, size=VIEW_UNIFORM_BYTES}
	renderer.filter_view_bind_group = wgpu.DeviceCreateBindGroup(device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU backdrop filter viewport",
		layout=renderer.view_layout,
		entryCount=1,
		entries=&filter_view_entry,
	})
	if renderer.filter_view_bind_group == nil { return }
	composite_view_entry := wgpu.BindGroupEntry{binding=0, buffer=renderer.composite_view_buffer, size=VIEW_UNIFORM_BYTES}
	renderer.composite_view_bind_group = wgpu.DeviceCreateBindGroup(device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU backdrop composite viewport",
		layout=renderer.view_layout,
		entryCount=1,
		entries=&composite_view_entry,
	})
	if renderer.composite_view_bind_group == nil { return }
	texture_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding=0, visibility={.Fragment}, texture={sampleType=.Float, viewDimension=._2D}},
		{binding=1, visibility={.Fragment}, sampler={type=.Filtering}},
	}
	renderer.texture_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU backdrop texture layout",
		entryCount=uint(len(texture_entries)),
		entries=&texture_entries[0],
	})
	if renderer.texture_layout == nil { return }
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
	layouts := [2]wgpu.BindGroupLayout{renderer.view_layout, renderer.texture_layout}
	renderer.pipeline_layout = wgpu.DeviceCreatePipelineLayout(device, &wgpu.PipelineLayoutDescriptor{
		label="Alicorn WebGPU backdrop pipeline layout",
		bindGroupLayoutCount=uint(len(layouts)),
		bindGroupLayouts=&layouts[0],
	})
	if renderer.pipeline_layout == nil { return }
	renderer.shader = wgpu.DeviceCreateShaderModule(device, &wgpu.ShaderModuleDescriptor{
		label="Alicorn WebGPU backdrop WGSL",
		nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL, code=BACKDROP_EFFECT_WGSL},
	})
	if renderer.shader == nil { return }
	renderer.filter_pipeline = backdrop_effect_pipeline_create(
		device, renderer.pipeline_layout, renderer.shader, WEBGPU_BACKDROP_EFFECT_FILTER_FORMAT,
		wgpu.BlendState{
			color={operation=.Add, srcFactor=.One, dstFactor=.One},
			alpha={operation=.Add, srcFactor=.One, dstFactor=.One},
		},
		"Alicorn WebGPU backdrop Gaussian filter",
	)
	if renderer.filter_pipeline == nil { return }
	renderer.composite_pipeline = backdrop_effect_pipeline_create(
		device, renderer.pipeline_layout, renderer.shader, output_format,
		wgpu.BlendState{
			color={operation=.Add, srcFactor=.One, dstFactor=.OneMinusSrcAlpha},
			alpha={operation=.Add, srcFactor=.One, dstFactor=.OneMinusSrcAlpha},
		},
		"Alicorn WebGPU backdrop composite",
	)
	if renderer.composite_pipeline == nil { return }
	renderer.vertex_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU backdrop retained mesh",
		usage={.Vertex, .CopyDst},
		size=WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES,
	})
	if renderer.vertex_buffer == nil { return }
	renderer.resident_bytes = WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES
	renderer.peak_bytes = renderer.resident_bytes
	ok = true
	return
}

backdrop_effect_pipeline_create :: proc(
	device: wgpu.Device,
	layout: wgpu.PipelineLayout,
	shader: wgpu.ShaderModule,
	format: wgpu.TextureFormat,
	blend: wgpu.BlendState,
	label: string,
) -> wgpu.RenderPipeline {
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
	blend_state := blend
	target := wgpu.ColorTargetState{format=format, blend=&blend_state, writeMask=wgpu.ColorWriteMaskFlags_All}
	fragment := wgpu.FragmentState{module=shader, entryPoint="fs_main", targetCount=1, targets=&target}
	return wgpu.DeviceCreateRenderPipeline(device, &wgpu.RenderPipelineDescriptor{
		label=label,
		layout=layout,
		vertex={module=shader, entryPoint="vs_main", bufferCount=1, buffers=&vertex_layout},
		primitive={topology=.TriangleList, frontFace=.CCW, cullMode=.None},
		multisample={count=1, mask=0xFFFFFFFF},
		fragment=&fragment,
	})
}

Backdrop_Effect_Prepare :: proc(
	renderer: ^Backdrop_Effect_Renderer,
	plan: cpu_renderer.Backdrop_Effect_Plan,
	resident_budget_bytes: u64 = WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES,
) -> bool {
	if renderer == nil || renderer.device == nil { return false }
	backdrop_effect_retire_completed(renderer)
	if !plan.active || !cpu_renderer.Backdrop_Effect_Plan_Valid(plan) { return false }
	texture_bytes := u64(plan.width)*u64(plan.height)*20
	if texture_bytes+WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES > resident_budget_bytes { return false }
	if renderer.set.textures[0] == nil || renderer.set.width != plan.width || renderer.set.height != plan.height {
		if renderer.set.textures[0] != nil {
			if renderer.set.last_use_serial > renderer.completed_serial {
				if renderer.resident_bytes+texture_bytes > resident_budget_bytes { return false }
				append(&renderer.retired, Backdrop_Effect_Retired_Set{renderer.set, renderer.set.last_use_serial})
				renderer.set = {}
			} else {
				old_bytes := renderer.set.bytes
				backdrop_effect_set_destroy(&renderer.set)
				renderer.resident_bytes -= old_bytes
				renderer.set = {}
			}
		}
		if renderer.resident_bytes+texture_bytes > resident_budget_bytes { return false }
		set, ok := backdrop_effect_set_create(renderer, plan.width, plan.height, texture_bytes)
		if !ok { return false }
		renderer.set = set
		renderer.resident_bytes += texture_bytes
		renderer.peak_bytes = max(renderer.peak_bytes, renderer.resident_bytes)
	}
	if renderer.plan_valid && renderer.plan == plan && renderer.output_valid {
		renderer.cache_hits += 1
		renderer.pending_encoded = false
		renderer.pending_used = false
		return true
	}
	if renderer.plan_valid && renderer.plan == plan && renderer.pending_encoded {
		renderer.pending_used = false
		return true
	}
	mesh_changed := !renderer.plan_valid || !backdrop_effect_mesh_plan_equal(renderer.mesh_plan, plan)
	renderer.plan = plan
	renderer.plan_valid = true
	renderer.output_valid = false
	renderer.pending_encoded = false
	renderer.pending_used = false
	if mesh_changed {
		mesh: [WEBGPU_BACKDROP_EFFECT_VERTEX_COUNT]cpu_renderer.Vertex
		count, _, built := cpu_renderer.Backdrop_Effect_Build_Mesh(plan, &mesh)
		if !built || count <= 0 || count > len(mesh) { return false }
		resize(&renderer.vertices, count)
		copy(renderer.vertices[:], mesh[:count])
		wgpu.QueueWriteBuffer(renderer.queue, renderer.vertex_buffer, 0, raw_data(renderer.vertices[:]), uint(count*size_of(cpu_renderer.Vertex)))
		renderer.mesh_plan = plan
		renderer.mesh_rebuild_count += 1
		renderer.vertex_upload_count += 1
		renderer.vertex_upload_bytes += u64(count*size_of(cpu_renderer.Vertex))
	}
	backdrop_effect_filter_view_buffer_write(renderer, plan.width, plan.height)
	return true
}

backdrop_effect_mesh_plan_equal :: proc(a, b: cpu_renderer.Backdrop_Effect_Plan) -> bool {
	return a.source_bounds == b.source_bounds && a.width == b.width && a.height == b.height &&
	       a.scale == b.scale && a.sigma_pixels == b.sigma_pixels && a.filter_tap_count == b.filter_tap_count
}

backdrop_effect_filter_view_buffer_write :: proc(renderer: ^Backdrop_Effect_Renderer, width, height: u32) {
	if renderer == nil || renderer.queue == nil || renderer.filter_view_buffer == nil { return }
	values := [4]f32{f32(width), f32(height), 0, 0}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.filter_view_buffer, 0, raw_data(values[:]), uint(size_of(values)))
}

backdrop_effect_set_create :: proc(
	renderer: ^Backdrop_Effect_Renderer,
	width, height: u32,
	bytes: u64,
) -> (set: Backdrop_Effect_Texture_Set, ok: bool) {
	if renderer == nil || width == 0 || height == 0 { return }
	set.width, set.height, set.bytes = width, height, bytes
	formats := [3]wgpu.TextureFormat{renderer.output_format, WEBGPU_BACKDROP_EFFECT_FILTER_FORMAT, WEBGPU_BACKDROP_EFFECT_FILTER_FORMAT}
	defer if !ok { backdrop_effect_set_destroy(&set) }
	for index in 0..<3 {
		set.textures[index] = wgpu.DeviceCreateTexture(renderer.device, &wgpu.TextureDescriptor{
			label="Alicorn WebGPU backdrop target",
			usage={.RenderAttachment, .TextureBinding},
			dimension=._2D,
			size={width=width, height=height, depthOrArrayLayers=1},
			format=formats[index],
			mipLevelCount=1,
			sampleCount=1,
		})
		if set.textures[index] == nil { return }
		set.views[index] = wgpu.TextureCreateView(set.textures[index])
		if set.views[index] == nil { return }
		entries := [2]wgpu.BindGroupEntry{
			{binding=0, textureView=set.views[index]},
			{binding=1, sampler=renderer.sampler},
		}
		set.bind_groups[index] = wgpu.DeviceCreateBindGroup(renderer.device, &wgpu.BindGroupDescriptor{
			label="Alicorn WebGPU backdrop sampled target",
			layout=renderer.texture_layout,
			entryCount=uint(len(entries)),
			entries=&entries[0],
		})
		if set.bind_groups[index] == nil { return }
	}
	ok = true
	return
}

backdrop_effect_set_destroy :: proc(set: ^Backdrop_Effect_Texture_Set) {
	if set == nil { return }
	for index in 0..<3 {
		if set.bind_groups[index] != nil { wgpu.BindGroupRelease(set.bind_groups[index]) }
		if set.views[index] != nil { wgpu.TextureViewRelease(set.views[index]) }
		if set.textures[index] != nil { wgpu.TextureRelease(set.textures[index]) }
	}
	set^ = {}
}

@(private)
backdrop_effect_set_abandon_after_device_loss :: proc(set: ^Backdrop_Effect_Texture_Set) {
	if set == nil { return }
	set^ = {}
}

Backdrop_Effect_Source_View :: proc(renderer: ^Backdrop_Effect_Renderer) -> wgpu.TextureView {
	if renderer == nil { return nil }
	return renderer.set.views[0]
}

Backdrop_Effect_Needs_Capture :: proc(renderer: ^Backdrop_Effect_Renderer) -> bool {
	return renderer != nil && renderer.plan_valid && !renderer.output_valid && !renderer.pending_encoded
}

Backdrop_Effect_Source_Origin :: proc(plan: cpu_renderer.Backdrop_Effect_Plan) -> [2]int {
	if !cpu_renderer.Backdrop_Effect_Plan_Valid(plan) || !plan.active { return {} }
	left, top, _, _ := cpu_renderer.Logical_To_Pixel_Bounds(plan.source_bounds, plan.scale, plan.scale)
	return [2]int{left, top}
}

Backdrop_Effect_Encode_Filter :: proc(
	renderer: ^Backdrop_Effect_Renderer,
	encoder: wgpu.CommandEncoder,
) -> bool {
	if renderer == nil || encoder == nil || !renderer.plan_valid || renderer.set.views[0] == nil { return false }
	if renderer.output_valid || renderer.pending_encoded { return true }
	for axis in 0..<2 {
		target_index := 1+axis
		attachment := wgpu.RenderPassColorAttachment{
			view=renderer.set.views[target_index],
			depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp=.Clear,
			storeOp=.Store,
			clearValue={0, 0, 0, 0},
		}
		pass := wgpu.CommandEncoderBeginRenderPass(encoder, &wgpu.RenderPassDescriptor{
			colorAttachmentCount=1,
			colorAttachments=&attachment,
		})
		if pass == nil { return false }
		defer {
			wgpu.RenderPassEncoderEnd(pass)
			wgpu.RenderPassEncoderRelease(pass)
		}
		wgpu.RenderPassEncoderSetPipeline(pass, renderer.filter_pipeline)
		if !webgpu_view_bind_group_set(pass, 0, renderer.filter_view_bind_group, 0) { return false }
		source_index := axis
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, renderer.set.bind_groups[source_index])
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0, WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES)
		first := u32(axis * renderer.plan.filter_tap_count * 6)
		wgpu.RenderPassEncoderDraw(pass, u32(renderer.plan.filter_tap_count*6), 1, first, 0)
		if axis == 0 { renderer.horizontal_pass_count += 1 } else { renderer.vertical_pass_count += 1 }
	}
	renderer.pending_encoded = true
	renderer.capture_count += 1
	return true
}

Backdrop_Effect_Draw_Composite :: proc(
	renderer: ^Backdrop_Effect_Renderer,
	pass: wgpu.RenderPassEncoder,
	plan: cpu_renderer.Backdrop_Effect_Plan,
	target_width, target_height: u32,
	target_origin_px: [2]int = {},
	view_slot: u32 = 0,
) -> bool {
	if renderer == nil || pass == nil || !renderer.plan_valid || renderer.plan != plan ||
	   !(renderer.output_valid || renderer.pending_encoded) || target_width == 0 || target_height == 0 ||
	   view_slot >= VIEW_UNIFORM_SLOT_COUNT {
		return false
	}
	x0, y0, x1, y1 := cpu_renderer.Logical_To_Pixel_Bounds(plan.output_clip, plan.scale, plan.scale)
	if target_origin_px[0] != 0 || target_origin_px[1] != 0 {
		clip := cpu_renderer.Pixel_Rect_Translate_Clip(
			cpu_renderer.Pixel_Rect{x0, y0, x1-x0, y1-y0},
			target_origin_px[0], target_origin_px[1], int(target_width), int(target_height),
		)
		x0, y0, x1, y1 = clip.x, clip.y, clip.x+clip.w, clip.y+clip.h
	} else {
		x0, y0 = max(x0, 0), max(y0, 0)
		x1, y1 = min(x1, int(target_width)), min(y1, int(target_height))
	}
	if x1 <= x0 || y1 <= y0 { return true }
	values := [4]f32{f32(target_width), f32(target_height), f32(target_origin_px[0]), f32(target_origin_px[1])}
	view_offset := u64(view_slot*VIEW_UNIFORM_CAPTURE_OFFSET)
	wgpu.QueueWriteBuffer(renderer.queue, renderer.composite_view_buffer, view_offset, raw_data(values[:]), uint(size_of(values)))
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.composite_pipeline)
	if !webgpu_view_bind_group_set(pass, 0, renderer.composite_view_bind_group, view_slot) { return false }
	wgpu.RenderPassEncoderSetBindGroup(pass, 1, renderer.set.bind_groups[2])
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0, WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES)
	wgpu.RenderPassEncoderSetScissorRect(pass, u32(x0), u32(y0), u32(x1-x0), u32(y1-y0))
	wgpu.RenderPassEncoderDraw(pass, 6, 1, u32(plan.filter_tap_count*12), 0)
	renderer.pending_used = true
	renderer.composite_count += 1
	return true
}

Backdrop_Effect_Commit_Submission :: proc(renderer: ^Backdrop_Effect_Renderer, serial: u64) {
	if renderer == nil || serial == 0 { return }
	used_this_submission := renderer.pending_used || renderer.pending_encoded
	if renderer.pending_encoded {
		renderer.output_valid = true
		renderer.pending_encoded = false
	}
	if used_this_submission {
		renderer.set.last_use_serial = serial
		renderer.pending_used = false
	}
}

Backdrop_Effect_Abort :: proc(renderer: ^Backdrop_Effect_Renderer) {
	if renderer == nil { return }
	if renderer.pending_encoded { renderer.output_valid = false }
	renderer.pending_encoded = false
	renderer.pending_used = false
}

Backdrop_Effect_Complete_Submission :: proc(renderer: ^Backdrop_Effect_Renderer, serial: u64) {
	if renderer == nil { return }
	renderer.completed_serial = max(renderer.completed_serial, serial)
	backdrop_effect_retire_completed(renderer)
}

backdrop_effect_retire_completed :: proc(renderer: ^Backdrop_Effect_Renderer) {
	if renderer == nil { return }
	for index := len(renderer.retired)-1; index >= 0; index -= 1 {
		if renderer.retired[index].retire_after_serial > renderer.completed_serial { continue }
		bytes := renderer.retired[index].set.bytes
		backdrop_effect_set_destroy(&renderer.retired[index].set)
		renderer.resident_bytes -= bytes
		ordered_remove(&renderer.retired, index)
	}
}

Backdrop_Effect_Destroy :: proc(renderer: ^Backdrop_Effect_Renderer) {
	backdrop_effect_destroy(renderer, true)
}

@(private)
Backdrop_Effect_Abandon_After_Device_Loss :: proc(renderer: ^Backdrop_Effect_Renderer) {
	backdrop_effect_destroy(renderer, false)
}

@(private)
backdrop_effect_destroy :: proc(renderer: ^Backdrop_Effect_Renderer, release_gpu: bool) {
	if renderer == nil { return }
	if release_gpu {
		backdrop_effect_set_destroy(&renderer.set)
		for &retired in renderer.retired { backdrop_effect_set_destroy(&retired.set) }
		if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
		if renderer.filter_pipeline != nil { wgpu.RenderPipelineRelease(renderer.filter_pipeline) }
		if renderer.composite_pipeline != nil { wgpu.RenderPipelineRelease(renderer.composite_pipeline) }
		if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
		if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
		if renderer.texture_layout != nil { wgpu.BindGroupLayoutRelease(renderer.texture_layout) }
		if renderer.filter_view_bind_group != nil { wgpu.BindGroupRelease(renderer.filter_view_bind_group) }
		if renderer.composite_view_bind_group != nil { wgpu.BindGroupRelease(renderer.composite_view_bind_group) }
		if renderer.view_layout != nil { wgpu.BindGroupLayoutRelease(renderer.view_layout) }
		if renderer.filter_view_buffer != nil { wgpu.BufferRelease(renderer.filter_view_buffer) }
		if renderer.composite_view_buffer != nil { wgpu.BufferRelease(renderer.composite_view_buffer) }
		if renderer.sampler != nil { wgpu.SamplerRelease(renderer.sampler) }
	} else {
		backdrop_effect_set_abandon_after_device_loss(&renderer.set)
		for &retired in renderer.retired { backdrop_effect_set_abandon_after_device_loss(&retired.set) }
	}
	delete(renderer.vertices)
	delete(renderer.retired)
	renderer^ = {}
}
