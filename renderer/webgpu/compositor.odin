package webgpu_renderer

import alicorn "../../runtime"
import "vendor:wgpu"

Compositor_Result :: enum {
	Ok,
	Invalid_Input,
	Unsupported_Command,
	Resource_Failure,
}

// WebGPU_Compositor owns the shared renderer resources for one Runtime and
// one WebGPU device. It does not acquire surfaces, create encoders, submit
// queues, or depend on SDL/browser APIs. Hosts prepare retained products, ask
// it to encode one target pass, then acknowledge uploads after submission.
WebGPU_Compositor :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	solid: Solid_Renderer,
	text: Text_Renderer,
	icons: Icon_Renderer,
	prepared_runtime: ^alicorn.Runtime,
	prepared_revision: u64,
	prepared_commands: rawptr,
	prepared_command_count: int,
	prepared_width, prepared_height: u32,
	prepared_scale_x, prepared_scale_y: f32,
	prepared_valid: bool,
}

Compositor_Create :: proc(
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
) -> (compositor: WebGPU_Compositor, ok: bool) {
	if device == nil || queue == nil { return }
	compositor.device, compositor.queue, compositor.format = device, queue, format
	defer if !ok { Compositor_Destroy(&compositor) }
	compositor.solid, ok = Solid_Create(device, queue, format)
	if !ok { return }
	compositor.text, ok = Text_Create(device, queue, format)
	if !ok { return }
	compositor.icons, ok = Icon_Create(device, queue, format)
	if !ok { return }
	ok = true
	return
}

// Compositor_Prepare validates command families before any GPU writes, then
// prepares the CPU-retained solid, text, and icon products. The order of commands is
// not changed; Compositor_Encode will issue draws in the original paint order.
Compositor_Prepare :: proc(
	compositor: ^WebGPU_Compositor,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	scratch_allocator := context.temp_allocator,
) -> Compositor_Result {
	if compositor == nil || rt == nil || compositor.device == nil || compositor.queue == nil ||
	   target_width == 0 || target_height == 0 ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	for command in display.commands {
		if !alicorn.paint_command_is_surface(command) && !alicorn.paint_command_is_text(command) &&
		   !alicorn.paint_command_is_icon(command) {
			return .Unsupported_Command
		}
	}
	compositor.prepared_valid = false
	if result := Solid_Prepare(&compositor.solid, rt, display, target_width, target_height, scale_x, scale_y); result != .Ok {
		return compositor_result_from_solid(result)
	}
	if result := Text_Prepare(
		&compositor.text, rt, display, target_width, target_height, scale_x, scale_y, scratch_allocator,
	); result != .Ok {
		return compositor_result_from_text(result)
	}
	if result := Icon_Prepare(&compositor.icons, display, target_width, target_height, scale_x, scale_y); result != .Ok {
		return compositor_result_from_icon(result)
	}
	compositor.prepared_runtime = rt
	compositor.prepared_revision = display.revision
	compositor.prepared_commands = raw_data(display.commands)
	compositor.prepared_command_count = len(display.commands)
	compositor.prepared_width, compositor.prepared_height = target_width, target_height
	compositor.prepared_scale_x, compositor.prepared_scale_y = scale_x, scale_y
	compositor.prepared_valid = true
	return .Ok
}

// Compositor_Encode opens exactly one render pass and dispatches each supported
// retained command at its original index. This shared composition path lets
// surfaces, shaped text, and tinted icons interleave without sorting or
// host-specific compositor code. Surface acquisition and queue submission
// remain owned by the platform host.
Compositor_Encode :: proc(
	compositor: ^WebGPU_Compositor,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target: wgpu.TextureView,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	encoder: wgpu.CommandEncoder,
	clear_target: bool,
	clear_color: wgpu.Color,
) -> Compositor_Result {
	if compositor == nil || rt == nil || target == nil || encoder == nil ||
	   !compositor.prepared_valid || compositor.prepared_runtime != rt ||
	   compositor.prepared_revision != display.revision ||
	   compositor.prepared_commands != raw_data(display.commands) ||
	   compositor.prepared_command_count != len(display.commands) ||
	   compositor.prepared_width != target_width || compositor.prepared_height != target_height ||
	   compositor.prepared_scale_x != scale_x || compositor.prepared_scale_y != scale_y {
		return .Invalid_Input
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
		if alicorn.paint_command_is_surface(command) {
			if result := Solid_Draw_Command(
				&compositor.solid, pass, command_index, command,
				target_width, target_height, scale_x, scale_y,
			); result != .Ok {
				return compositor_result_from_solid(result)
			}
		} else if alicorn.paint_command_is_text(command) {
			if result := Text_Draw_Command(
				&compositor.text, pass, command_index, command,
				target_width, target_height, scale_x, scale_y,
			); result != .Ok {
				return compositor_result_from_text(result)
			}
		} else {
			if result := Icon_Draw_Command(
				&compositor.icons, pass, command_index, command, target_width, target_height,
			); result != .Ok {
				return compositor_result_from_icon(result)
			}
		}
	}
	return .Ok
}

// Call only after the host has submitted the command buffer. If a prepared
// frame is abandoned, leaving atlas generations dirty makes them retryable.
Compositor_Commit_Submission :: proc(compositor: ^WebGPU_Compositor, rt: ^alicorn.Runtime) {
	if compositor == nil || rt == nil || compositor.prepared_runtime != rt { return }
	Text_Commit_Submission(&compositor.text, rt)
}

Compositor_Destroy :: proc(compositor: ^WebGPU_Compositor) {
	if compositor == nil { return }
	Text_Destroy(&compositor.text)
	Icon_Destroy(&compositor.icons)
	Solid_Destroy(&compositor.solid)
	compositor^ = {}
}

compositor_result_from_solid :: proc(result: Solid_Result) -> Compositor_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Unsupported_Command: return .Unsupported_Command
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}

compositor_result_from_text :: proc(result: Text_Result) -> Compositor_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}

compositor_result_from_icon :: proc(result: Icon_Result) -> Compositor_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}
