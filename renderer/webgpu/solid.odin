package webgpu_renderer

import "vendor:wgpu"
import math_bits "core:math/bits"
import alicorn "../../runtime"
import cpu_renderer "../cpu"

// Surface-only WebGPU pass used as the first production-paint migration slice.
// It consumes the same CPU mesh products as SDL_GPU, borrows the Runtime's
// completed paint list only for this call, and leaves target acquisition and
// queue submission to the platform host.
SOLID_INITIAL_VERTEX_CAPACITY :: 4096

SOLID_WGSL :: #load("shaders/solid.wgsl", string)

Solid_Result :: enum {
	Ok,
	Invalid_Input,
	Unsupported_Command,
	Resource_Failure,
}

Solid_Draw :: struct {
	first_vertex: u32,
	vertex_count: u32,
	command_index: int,
	translation_index: u32,
}

Solid_Renderer :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	shader: wgpu.ShaderModule,
	bind_group_layout: wgpu.BindGroupLayout,
	pipeline_layout: wgpu.PipelineLayout,
	pipeline: wgpu.RenderPipeline,
	uniform_buffer: wgpu.Buffer,
	bind_group: wgpu.BindGroup,
	vertex_buffer: wgpu.Buffer,
	vertex_capacity: int,
	translation_buffer: wgpu.Buffer,
	translation_capacity: int,
	vertices: [dynamic]cpu_renderer.Vertex,
	translations: [dynamic][2]f32,
	draws: [dynamic]Solid_Draw,
	mesh_cache_valid: bool,
	translation_cache_valid: bool,
	translation_buffer_dirty: bool,
	mesh_runtime: ^alicorn.Runtime,
	mesh_fingerprint: u64,
	translation_fingerprint: u64,
	mesh_width, mesh_height: u32,
	mesh_scale_x, mesh_scale_y: f32,
	viewport_uniform_valid: bool,
	viewport_width, viewport_height: u32,
	mesh_rebuild_count, vertex_upload_count, translation_upload_count, viewport_upload_count: u64,
	vertex_upload_bytes: u64,
	translation_upload_bytes: u64,
}

Solid_Create :: proc(
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
) -> (renderer: Solid_Renderer, ok: bool) {
	if device == nil || queue == nil { return }
	renderer.device = device
	renderer.queue = queue
	renderer.format = format
	renderer.vertex_capacity = SOLID_INITIAL_VERTEX_CAPACITY
	renderer.vertices = make([dynamic]cpu_renderer.Vertex, 0, SOLID_INITIAL_VERTEX_CAPACITY)
	renderer.translations = make([dynamic][2]f32, 0, 1024)
	renderer.draws = make([dynamic]Solid_Draw, 0, 1024)
	defer if !ok { Solid_Destroy(&renderer) }

	renderer.uniform_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU solid viewport",
		usage={.Uniform, .CopyDst},
		size=VIEW_UNIFORM_BUFFER_BYTES,
	})
	if renderer.uniform_buffer == nil { return }

	attrs := [2]wgpu.VertexAttribute{
		{format=.Float32x3, offset=u64(offset_of(cpu_renderer.Vertex, position)), shaderLocation=0},
		{format=.Float32x4, offset=u64(offset_of(cpu_renderer.Vertex, color)), shaderLocation=1},
	}
	translation_attrs := [1]wgpu.VertexAttribute{
		{format=.Float32x2, offset=0, shaderLocation=2},
	}
	vertex_layout := wgpu.VertexBufferLayout{
		stepMode=.Vertex,
		arrayStride=u64(size_of(cpu_renderer.Vertex)),
		attributeCount=uint(len(attrs)),
		attributes=&attrs[0],
	}
	translation_layout := wgpu.VertexBufferLayout{
		stepMode=.Instance,
		arrayStride=u64(size_of([2]f32)),
		attributeCount=uint(len(translation_attrs)),
		attributes=&translation_attrs[0],
	}
	vertex_layouts := [2]wgpu.VertexBufferLayout{vertex_layout, translation_layout}
	layout_entry := wgpu.BindGroupLayoutEntry{
		binding=0,
		visibility={.Vertex},
		buffer={type=.Uniform, hasDynamicOffset=true, minBindingSize=VIEW_UNIFORM_BYTES},
	}
	renderer.bind_group_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU solid viewport layout",
		entryCount=1,
		entries=&layout_entry,
	})
	if renderer.bind_group_layout == nil { return }
	renderer.pipeline_layout = wgpu.DeviceCreatePipelineLayout(device, &wgpu.PipelineLayoutDescriptor{
		label="Alicorn WebGPU solid pipeline layout",
		bindGroupLayoutCount=1,
		bindGroupLayouts=&renderer.bind_group_layout,
	})
	if renderer.pipeline_layout == nil { return }
	renderer.shader = wgpu.DeviceCreateShaderModule(device, &wgpu.ShaderModuleDescriptor{
		label="Alicorn WebGPU solid WGSL",
		nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL, code=SOLID_WGSL},
	})
	if renderer.shader == nil { return }

	blend := wgpu.BlendState{
		color={operation=.Add, srcFactor=.SrcAlpha, dstFactor=.OneMinusSrcAlpha},
		alpha={operation=.Add, srcFactor=.One, dstFactor=.OneMinusSrcAlpha},
	}
	target := wgpu.ColorTargetState{format=format, blend=&blend, writeMask=wgpu.ColorWriteMaskFlags_All}
	fragment := wgpu.FragmentState{
		module=renderer.shader,
		entryPoint="fs_main",
		targetCount=1,
		targets=&target,
	}
	renderer.pipeline = wgpu.DeviceCreateRenderPipeline(device, &wgpu.RenderPipelineDescriptor{
		label="Alicorn WebGPU solid pipeline",
		layout=renderer.pipeline_layout,
		vertex={
			module=renderer.shader,
			entryPoint="vs_main",
			bufferCount=uint(len(vertex_layouts)),
			buffers=&vertex_layouts[0],
		},
		primitive={topology=.TriangleList, frontFace=.CCW, cullMode=.None},
		multisample={count=1, mask=0xFFFFFFFF},
		fragment=&fragment,
	})
	if renderer.pipeline == nil { return }
	renderer.bind_group = wgpu.DeviceCreateBindGroup(device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU solid viewport binding",
		layout=renderer.bind_group_layout,
		entryCount=1,
		entries=&wgpu.BindGroupEntry{
			binding=0,
			buffer=renderer.uniform_buffer,
			size=VIEW_UNIFORM_BYTES,
		},
	})
	if renderer.bind_group == nil { return }
	if !solid_vertex_buffer_ensure(&renderer, renderer.vertex_capacity) { return }
	ok = true
	return
}

// Solid_Prepare consumes the surface commands in a borrowed finalized display
// list and uploads their cached CPU mesh before a render pass begins. Text
// commands may be interleaved; other command families are rejected so callers
// cannot mistake a partial frame for complete rendering.
Solid_Prepare :: proc(
	renderer: ^Solid_Renderer,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
) -> Solid_Result {
	if renderer == nil || rt == nil ||
	   renderer.device == nil || renderer.queue == nil || renderer.pipeline == nil ||
	   renderer.bind_group == nil || renderer.vertex_buffer == nil ||
	   target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(math_bits.INT_MAX) || u64(target_height) > u64(math_bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	commands := display.commands

	for command in commands {
		if !alicorn.paint_command_is_surface(command) && !alicorn.paint_command_is_geometry(command) && !alicorn.paint_command_is_text(command) &&
		   !alicorn.paint_command_is_icon(command) && !alicorn.paint_command_is_image(command) &&
		   !alicorn.paint_command_is_backdrop_effect(command) {
			return .Unsupported_Command
		}
	}

	fingerprint := cpu_renderer.Solid_Surface_Mesh_Fingerprint(
		rt, commands, scale_x, scale_y, int(target_width), int(target_height),
	)
	mesh_changed := !renderer.mesh_cache_valid || renderer.mesh_runtime != rt ||
		renderer.mesh_fingerprint != fingerprint || renderer.mesh_scale_x != scale_x || renderer.mesh_scale_y != scale_y
	if mesh_changed {
		renderer.mesh_cache_valid = false
		clear(&renderer.vertices)
		clear(&renderer.draws)
		required_vertices := 0
		for command in commands {
			if !alicorn.paint_command_is_surface(command) { continue }
			mesh_command := command
			mesh_command.translation = {}
			count, visible := cpu_renderer.Solid_Surface_Vertex_Count(
				rt, mesh_command, scale_x, scale_y, int(target_width), int(target_height), unbounded=true,
			)
			if visible {
				if count < 0 || required_vertices > math_bits.INT_MAX-count { return .Resource_Failure }
				required_vertices += count
			}
		}
		if required_vertices > 0 {
			if !solid_vertex_buffer_ensure(renderer, required_vertices) { return .Resource_Failure }
			reserve(&renderer.vertices, required_vertices)
		}
		for command, command_index in commands {
			if !alicorn.paint_command_is_surface(command) { continue }
			mesh_command := command
			mesh_command.translation = {}
			mesh := cpu_renderer.Append_Surface_Mesh(
				&renderer.vertices, rt, mesh_command, scale_x, scale_y,
				int(target_width), int(target_height), unbounded=true,
			)
			if mesh.vertex_count <= 0 { continue }
			if mesh.first_vertex < 0 || mesh.vertex_count > math_bits.INT_MAX-mesh.first_vertex ||
				u64(mesh.first_vertex+mesh.vertex_count) > 0xFFFFFFFF {
				return .Resource_Failure
			}
			if u64(len(renderer.draws)) >= 0xFFFFFFFF { return .Resource_Failure }
			append(&renderer.draws, Solid_Draw{
				first_vertex=u32(mesh.first_vertex),
				vertex_count=u32(mesh.vertex_count),
				command_index=command_index,
				translation_index=u32(len(renderer.draws)),
			})
		}
		if len(renderer.vertices) != required_vertices { return .Resource_Failure }
		if len(renderer.vertices) > 0 {
			upload_bytes := len(renderer.vertices)*size_of(cpu_renderer.Vertex)
			wgpu.QueueWriteBuffer(renderer.queue, renderer.vertex_buffer, 0, raw_data(renderer.vertices[:]), uint(upload_bytes))
			renderer.vertex_upload_count += 1
			renderer.vertex_upload_bytes += u64(upload_bytes)
		}
		renderer.mesh_runtime = rt
		renderer.mesh_fingerprint = fingerprint
		renderer.mesh_scale_x, renderer.mesh_scale_y = scale_x, scale_y
		renderer.mesh_cache_valid = true
		renderer.mesh_rebuild_count += 1
	}
	renderer.mesh_width, renderer.mesh_height = target_width, target_height
	if !solid_translation_sync(renderer, commands, scale_x, scale_y) {
		return .Resource_Failure
	}
	if !renderer.viewport_uniform_valid || renderer.viewport_width != target_width || renderer.viewport_height != target_height {
		if !webgpu_view_uniform_write(renderer.queue, renderer.uniform_buffer, target_width, target_height) {
			return .Resource_Failure
		}
		renderer.viewport_uniform_valid = true
		renderer.viewport_width, renderer.viewport_height = target_width, target_height
		renderer.viewport_upload_count += 1
	}
	return .Ok
}

@(private)
solid_translation_sync :: proc(
	renderer: ^Solid_Renderer,
	commands: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
) -> bool {
	if len(renderer.draws) > 0 && !solid_translation_buffer_ensure(renderer, len(renderer.draws)) {
		return false
	}
	clear(&renderer.translations)
	translation_hash := u64(1469598103934665603)
	translation_hash = alicorn.hash_mix(translation_hash, u64(len(renderer.draws)))
	for &draw in renderer.draws {
		if draw.command_index < 0 || draw.command_index >= len(commands) { return false }
		command := commands[draw.command_index]
		translation := [2]f32{command.translation[0]*scale_x, command.translation[1]*scale_y}
		append(&renderer.translations, translation)
		translation_hash = alicorn.hash_mix(translation_hash, u64(draw.command_index))
		translation_hash = alicorn.hash_mix(translation_hash, u64(transmute(u32)translation[0]))
		translation_hash = alicorn.hash_mix(translation_hash, u64(transmute(u32)translation[1]))
	}
	if !renderer.translation_cache_valid || renderer.translation_fingerprint != translation_hash ||
	   renderer.translation_buffer_dirty {
		if len(renderer.translations) > 0 {
			upload_bytes := len(renderer.translations)*size_of([2]f32)
			wgpu.QueueWriteBuffer(renderer.queue, renderer.translation_buffer, 0,
				raw_data(renderer.translations[:]), uint(upload_bytes))
			renderer.translation_upload_count += 1
			renderer.translation_upload_bytes += u64(upload_bytes)
		}
		renderer.translation_fingerprint = translation_hash
		renderer.translation_cache_valid = true
		renderer.translation_buffer_dirty = false
	}
	return true
}

// Solid_Draw_Command draws the prepared solid geometry associated with one
// command. It is intentionally render-pass agnostic so a shared compositor
// can preserve paint order with text and later renderer families.
Solid_Draw_Command :: proc(
	renderer: ^Solid_Renderer,
	pass: wgpu.RenderPassEncoder,
	command_index: int,
	command: alicorn.Paint_Command,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	view_slot: u32 = 0,
	capture_origin_px: [2]int = {},
	prepared_width: u32 = 0,
	prepared_height: u32 = 0,
) -> Solid_Result {
	if renderer == nil || pass == nil || renderer.pipeline == nil || renderer.vertex_buffer == nil ||
	   renderer.bind_group == nil || command_index < 0 || target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(math_bits.INT_MAX) || u64(target_height) > u64(math_bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	if !alicorn.paint_command_is_surface(command) { return .Ok }
	mesh_width, mesh_height := prepared_width, prepared_height
	if mesh_width == 0 { mesh_width = target_width }
	if mesh_height == 0 { mesh_height = target_height }
	if !renderer.mesh_cache_valid || renderer.mesh_width != mesh_width || renderer.mesh_height != mesh_height ||
	   renderer.mesh_scale_x != scale_x || renderer.mesh_scale_y != scale_y {
		return .Invalid_Input
	}
	if len(renderer.vertices) == 0 { return .Ok }
	if len(renderer.draws) > 0 && (renderer.translation_buffer == nil ||
	   len(renderer.translations) != len(renderer.draws)) {
		return .Invalid_Input
	}
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.pipeline)
	if !webgpu_view_bind_group_set(pass, 0, renderer.bind_group, view_slot) { return .Invalid_Input }
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0,
		u64(len(renderer.vertices)*size_of(cpu_renderer.Vertex)))
	if len(renderer.translations) > 0 {
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 1, renderer.translation_buffer, 0,
			u64(len(renderer.translations)*size_of([2]f32)))
	}
	for draw in renderer.draws {
		if draw.command_index != command_index { continue }
		if draw.translation_index >= u32(len(renderer.translations)) { return .Invalid_Input }
		scissor_width, scissor_height := int(target_width), int(target_height)
		if view_slot != 0 {
			scissor_width, scissor_height = int(mesh_width), int(mesh_height)
		}
		scissor := cpu_renderer.Solid_Pixel_Scissor(command, scale_x, scale_y, scissor_width, scissor_height)
		if view_slot != 0 {
			scissor = cpu_renderer.Pixel_Rect_Translate_Clip(
				scissor, capture_origin_px[0], capture_origin_px[1], int(target_width), int(target_height),
			)
		}
		if scissor.w <= 0 || scissor.h <= 0 { continue }
		wgpu.RenderPassEncoderSetScissorRect(pass, u32(scissor.x), u32(scissor.y), u32(scissor.w), u32(scissor.h))
		wgpu.RenderPassEncoderDraw(pass, draw.vertex_count, 1, draw.first_vertex, draw.translation_index)
	}
	return .Ok
}

// Solid_Encode is a surface-only convenience path retained for early
// feasibility probes. Production composition should use Solid_Prepare and
// Solid_Draw_Command from the shared WebGPU compositor.
Solid_Encode :: proc(
	renderer: ^Solid_Renderer,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target: wgpu.TextureView,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	encoder: wgpu.CommandEncoder,
	clear_target: bool,
	clear_color: wgpu.Color,
) -> Solid_Result {
	if target == nil || encoder == nil { return .Invalid_Input }
	for command in display.commands {
		if !alicorn.paint_command_is_surface(command) { return .Unsupported_Command }
	}
	if result := Solid_Prepare(renderer, rt, display, target_width, target_height, scale_x, scale_y); result != .Ok {
		return result
	}
	attachment := wgpu.RenderPassColorAttachment{
		view=target,
		depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,
		loadOp=.Load,
		storeOp=.Store,
	}
	if clear_target {
		attachment.loadOp = .Clear
		attachment.clearValue = clear_color
	}
	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &wgpu.RenderPassDescriptor{
		colorAttachmentCount=1,
		colorAttachments=&attachment,
	})
	if pass == nil { return .Resource_Failure }
	defer {
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}
	for command, command_index in display.commands {
		if result := Solid_Draw_Command(renderer, pass, command_index, command,
			target_width, target_height, scale_x, scale_y); result != .Ok {
			return result
		}
	}
	return .Ok
}

// The host must ensure the renderer is no longer used before destroying it.
// Replacing a grown buffer only releases this renderer's reference; it does
// not explicitly destroy a buffer that an earlier queue submission may use.
Solid_Destroy :: proc(renderer: ^Solid_Renderer) {
	solid_destroy(renderer, true)
}

@(private)
Solid_Abandon_After_Device_Loss :: proc(renderer: ^Solid_Renderer) {
	solid_destroy(renderer, false)
}

@(private)
solid_destroy :: proc(renderer: ^Solid_Renderer, release_gpu: bool) {
	if renderer == nil { return }
	if release_gpu {
		if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
		if renderer.translation_buffer != nil { wgpu.BufferRelease(renderer.translation_buffer) }
		if renderer.bind_group != nil { wgpu.BindGroupRelease(renderer.bind_group) }
		if renderer.pipeline != nil { wgpu.RenderPipelineRelease(renderer.pipeline) }
		if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
		if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
		if renderer.bind_group_layout != nil { wgpu.BindGroupLayoutRelease(renderer.bind_group_layout) }
		if renderer.uniform_buffer != nil { wgpu.BufferRelease(renderer.uniform_buffer) }
	}
	delete(renderer.vertices)
	delete(renderer.translations)
	delete(renderer.draws)
	renderer^ = {}
}

solid_vertex_buffer_ensure :: proc(renderer: ^Solid_Renderer, required_vertices: int) -> bool {
	if required_vertices <= renderer.vertex_capacity && renderer.vertex_buffer != nil { return true }
	if required_vertices < 0 || required_vertices > math_bits.INT_MAX/size_of(cpu_renderer.Vertex) { return false }
	new_capacity := max(renderer.vertex_capacity, SOLID_INITIAL_VERTEX_CAPACITY)
	for new_capacity < required_vertices {
		if new_capacity > math_bits.INT_MAX/2 { new_capacity = required_vertices; break }
		new_capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU solid vertices",
		usage={.Vertex, .CopyDst},
		size=u64(new_capacity*size_of(cpu_renderer.Vertex)),
	})
	if buffer == nil { return false }
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	renderer.vertex_buffer = buffer
	renderer.vertex_capacity = new_capacity
	return true
}

solid_translation_buffer_ensure :: proc(renderer: ^Solid_Renderer, required_translations: int) -> bool {
	if required_translations <= renderer.translation_capacity && renderer.translation_buffer != nil { return true }
	if required_translations <= 0 || required_translations > math_bits.INT_MAX/size_of([2]f32) { return false }
	new_capacity := max(renderer.translation_capacity, 64)
	for new_capacity < required_translations {
		if new_capacity > math_bits.INT_MAX/2 { new_capacity = required_translations; break }
		new_capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU solid per-draw transforms",
		usage={.Vertex, .CopyDst},
		size=u64(new_capacity*size_of([2]f32)),
	})
	if buffer == nil { return false }
	if renderer.translation_buffer != nil { wgpu.BufferRelease(renderer.translation_buffer) }
	renderer.translation_buffer = buffer
	renderer.translation_capacity = new_capacity
	renderer.translation_buffer_dirty = true
	return true
}
