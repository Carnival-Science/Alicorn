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

SOLID_WGSL :: `
struct View_Uniform {
	physical_size: vec2<f32>,
	_padding: vec2<f32>,
};
@group(0) @binding(0) var<uniform> view: View_Uniform;

struct Vertex_Input {
	@location(0) position: vec3<f32>,
	@location(1) color: vec4<f32>,
};
struct Vertex_Output {
	@builtin(position) position: vec4<f32>,
	@location(0) color: vec4<f32>,
};

@vertex fn vs_main(input: Vertex_Input) -> Vertex_Output {
	var output: Vertex_Output;
	let top_left_ndc = input.position.xy / view.physical_size * 2.0 - vec2<f32>(1.0, 1.0);
	output.position = vec4<f32>(top_left_ndc.x, -top_left_ndc.y, input.position.z, 1.0);
	output.color = input.color;
	return output;
}

@fragment fn fs_main(input: Vertex_Output) -> @location(0) vec4<f32> {
	return input.color;
}
`

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
	scissor: cpu_renderer.Pixel_Rect,
	has_scissor: bool,
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
	vertices: [dynamic]cpu_renderer.Vertex,
	draws: [dynamic]Solid_Draw,
	mesh_cache_valid: bool,
	mesh_runtime: ^alicorn.Runtime,
	mesh_revision: u64,
	mesh_width, mesh_height: u32,
	mesh_scale_x, mesh_scale_y: f32,
	viewport_uniform_valid: bool,
	viewport_width, viewport_height: u32,
	mesh_rebuild_count, vertex_upload_count, viewport_upload_count: u64,
	vertex_upload_bytes: u64,
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
	renderer.draws = make([dynamic]Solid_Draw, 0, 1024)
	defer if !ok { Solid_Destroy(&renderer) }

	renderer.uniform_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU solid viewport",
		usage={.Uniform, .CopyDst},
		size=u64(size_of([4]f32)),
	})
	if renderer.uniform_buffer == nil { return }

	attrs := [2]wgpu.VertexAttribute{
		{format=.Float32x3, offset=u64(offset_of(cpu_renderer.Vertex, position)), shaderLocation=0},
		{format=.Float32x4, offset=u64(offset_of(cpu_renderer.Vertex, color)), shaderLocation=1},
	}
	vertex_layout := wgpu.VertexBufferLayout{
		stepMode=.Vertex,
		arrayStride=u64(size_of(cpu_renderer.Vertex)),
		attributeCount=uint(len(attrs)),
		attributes=&attrs[0],
	}
	layout_entry := wgpu.BindGroupLayoutEntry{
		binding=0,
		visibility={.Vertex},
		buffer={type=.Uniform, minBindingSize=u64(size_of([4]f32))},
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
			bufferCount=1,
			buffers=&vertex_layout,
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
			size=u64(size_of([4]f32)),
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
		   !alicorn.paint_command_is_icon(command) && !alicorn.paint_command_is_image(command) {
			return .Unsupported_Command
		}
	}

	mesh_changed := !renderer.mesh_cache_valid || renderer.mesh_runtime != rt ||
		renderer.mesh_revision != display.revision || renderer.mesh_width != target_width ||
		renderer.mesh_height != target_height || renderer.mesh_scale_x != scale_x || renderer.mesh_scale_y != scale_y
	if mesh_changed {
		renderer.mesh_cache_valid = false
		clear(&renderer.vertices)
		clear(&renderer.draws)
		required_vertices := 0
		for command in commands {
			if !alicorn.paint_command_is_surface(command) { continue }
			count, visible := cpu_renderer.Solid_Surface_Vertex_Count(
				rt, command, scale_x, scale_y, int(target_width), int(target_height),
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
			mesh := cpu_renderer.Append_Surface_Mesh(
				&renderer.vertices, rt, command, scale_x, scale_y,
				int(target_width), int(target_height),
			)
			if mesh.vertex_count <= 0 { continue }
			if mesh.first_vertex < 0 || mesh.vertex_count > math_bits.INT_MAX-mesh.first_vertex ||
				u64(mesh.first_vertex+mesh.vertex_count) > 0xFFFFFFFF {
				return .Resource_Failure
			}
			append(&renderer.draws, Solid_Draw{
				first_vertex=u32(mesh.first_vertex),
				vertex_count=u32(mesh.vertex_count),
				command_index=command_index,
				scissor=mesh.scissor,
				has_scissor=mesh.has_scissor,
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
		renderer.mesh_revision = display.revision
		renderer.mesh_width, renderer.mesh_height = target_width, target_height
		renderer.mesh_scale_x, renderer.mesh_scale_y = scale_x, scale_y
		renderer.mesh_cache_valid = true
		renderer.mesh_rebuild_count += 1
	}
	if !renderer.viewport_uniform_valid || renderer.viewport_width != target_width || renderer.viewport_height != target_height {
		viewport := [4]f32{f32(target_width), f32(target_height), 0, 0}
		wgpu.QueueWriteBuffer(renderer.queue, renderer.uniform_buffer, 0, raw_data(viewport[:]), uint(size_of(viewport)))
		renderer.viewport_uniform_valid = true
		renderer.viewport_width, renderer.viewport_height = target_width, target_height
		renderer.viewport_upload_count += 1
	}
	return .Ok
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
) -> Solid_Result {
	if renderer == nil || pass == nil || renderer.pipeline == nil || renderer.vertex_buffer == nil ||
	   renderer.bind_group == nil || command_index < 0 || target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(math_bits.INT_MAX) || u64(target_height) > u64(math_bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	if !alicorn.paint_command_is_surface(command) { return .Ok }
	if !renderer.mesh_cache_valid || renderer.mesh_width != target_width || renderer.mesh_height != target_height ||
	   renderer.mesh_scale_x != scale_x || renderer.mesh_scale_y != scale_y {
		return .Invalid_Input
	}
	if len(renderer.vertices) == 0 { return .Ok }
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0,
		u64(len(renderer.vertices)*size_of(cpu_renderer.Vertex)))
	for draw in renderer.draws {
		if draw.command_index != command_index { continue }
		scissor := draw.scissor
		if !draw.has_scissor {
			scissor = cpu_renderer.Pixel_Rect{0, 0, int(target_width), int(target_height)}
		}
		if scissor.w <= 0 || scissor.h <= 0 { continue }
		wgpu.RenderPassEncoderSetScissorRect(pass, u32(scissor.x), u32(scissor.y), u32(scissor.w), u32(scissor.h))
		wgpu.RenderPassEncoderDraw(pass, draw.vertex_count, 1, draw.first_vertex, 0)
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
	if renderer == nil { return }
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	if renderer.bind_group != nil { wgpu.BindGroupRelease(renderer.bind_group) }
	if renderer.pipeline != nil { wgpu.RenderPipelineRelease(renderer.pipeline) }
	if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
	if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
	if renderer.bind_group_layout != nil { wgpu.BindGroupLayoutRelease(renderer.bind_group_layout) }
	if renderer.uniform_buffer != nil { wgpu.BufferRelease(renderer.uniform_buffer) }
	delete(renderer.vertices)
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
