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
	images: Image_Renderer,
	surfaces: Surface_Renderer,
	prepared_runtime: ^alicorn.Runtime,
	prepared_revision: u64,
	prepared_commands: rawptr,
	prepared_command_count: int,
	prepared_width, prepared_height: u32,
	prepared_scale_x, prepared_scale_y: f32,
	prepared_valid: bool,
	capture_view_slots_used: u64,
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
	compositor.images, ok = Image_Create(device, queue, format)
	if !ok { return }
	compositor.surfaces, ok = Surface_Create(device, queue, format)
	if !ok { return }
	ok = true
	return
}

// Compositor_Prepare validates command families before any GPU writes, then
// prepares the CPU-retained solid, text, icon, and image products. The order of
// commands is not changed; Compositor_Encode dispatches in retained paint order.
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
		if !alicorn.paint_command_is_surface(command) && !alicorn.paint_command_is_geometry(command) && !alicorn.paint_command_is_text(command) &&
		   !alicorn.paint_command_is_icon(command) && !alicorn.paint_command_is_image(command) {
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
	if result := Image_Prepare(&compositor.images, rt, display, target_width, target_height, scale_x, scale_y); result != .Ok {
		return compositor_result_from_image(result)
	}
	if result := Surface_Prepare(&compositor.surfaces, rt, display, target_width, target_height, scale_x, scale_y); result != .Ok {
		return compositor_result_from_surface(result)
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
// remain owned by the platform host. Capture mode draws the already prepared
// full-display meshes into a caller-supplied cropped target; its view slot must
// be unique until the host commits the submission. The caller owns that target.
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
	capture_view := false,
	capture_origin_px: [2]int = {},
	capture_view_slot: u32 = 0,
	command_start := 0,
	command_end := -1,
) -> Compositor_Result {
	if compositor == nil || rt == nil || target == nil || encoder == nil ||
	   !compositor.prepared_valid || compositor.prepared_runtime != rt ||
	   compositor.prepared_revision != display.revision ||
	   compositor.prepared_commands != raw_data(display.commands) ||
	   compositor.prepared_command_count != len(display.commands) ||
	   compositor.prepared_scale_x != scale_x || compositor.prepared_scale_y != scale_y {
		return .Invalid_Input
	}
	draw_command_end := command_end
	if draw_command_end < 0 { draw_command_end = len(display.commands) }
	if command_start < 0 || draw_command_end < command_start || draw_command_end > len(display.commands) {
		return .Invalid_Input
	}
	if capture_view {
		if capture_view_slot == 0 || capture_view_slot >= VIEW_UNIFORM_SLOT_COUNT ||
		   capture_origin_px[0] < 0 || capture_origin_px[1] < 0 ||
		   i64(capture_origin_px[0])+i64(target_width) > i64(compositor.prepared_width) ||
		   i64(capture_origin_px[1])+i64(target_height) > i64(compositor.prepared_height) {
			return .Invalid_Input
		}
		if !webgpu_view_capture_slot_available(compositor.capture_view_slots_used, capture_view_slot) {
			return .Invalid_Input
		}
		if !compositor_capture_view_upload(compositor, target_width, target_height, capture_origin_px, capture_view_slot) {
			return .Resource_Failure
		}
	} else if capture_view_slot != 0 || capture_origin_px[0] != 0 || capture_origin_px[1] != 0 ||
	   compositor.prepared_width != target_width || compositor.prepared_height != target_height {
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
	if capture_view && !webgpu_view_capture_slot_claim(&compositor.capture_view_slots_used, capture_view_slot) {
		return .Invalid_Input
	}
	defer {
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}
	for command_index in command_start..<draw_command_end {
		command := display.commands[command_index]
		if alicorn.paint_command_is_surface(command) {
			if result := Solid_Draw_Command(
				&compositor.solid, pass, command_index, command,
				target_width, target_height, scale_x, scale_y,
				capture_view_slot, capture_origin_px, compositor.prepared_width, compositor.prepared_height,
			); result != .Ok {
				return compositor_result_from_solid(result)
			}
		} else if alicorn.paint_command_is_text(command) {
			if result := Text_Draw_Command(
				&compositor.text, pass, command_index, command,
				target_width, target_height, scale_x, scale_y,
				capture_view_slot, capture_origin_px, compositor.prepared_width, compositor.prepared_height,
			); result != .Ok {
				return compositor_result_from_text(result)
			}
		} else if alicorn.paint_command_is_icon(command) {
			if result := Icon_Draw_Command(
				&compositor.icons, pass, command_index, command, target_width, target_height, capture_view_slot,
			); result != .Ok {
				return compositor_result_from_icon(result)
			}
		} else if alicorn.paint_command_is_image(command) {
			if result := Image_Draw_Command(
				&compositor.images, pass, rt, command_index, command, target_width, target_height, capture_view_slot,
			); result != .Ok {
				return compositor_result_from_image(result)
			}
		} else {
			if result := Surface_Draw_Command(
				&compositor.surfaces, pass, command_index, command, target_width, target_height,
				capture_view_slot, capture_origin_px,
			); result != .Ok {
				return compositor_result_from_surface(result)
			}
		}
	}
	return .Ok
}

compositor_capture_view_upload :: proc(
	compositor: ^WebGPU_Compositor,
	width, height: u32,
	origin_px: [2]int,
	view_slot: u32,
) -> bool {
	return compositor != nil && view_slot > 0 && view_slot < VIEW_UNIFORM_SLOT_COUNT &&
		webgpu_view_uniform_write(compositor.queue, compositor.solid.uniform_buffer, width, height, origin_px, view_slot) &&
		webgpu_view_uniform_write(compositor.queue, compositor.text.view_buffer, width, height, origin_px, view_slot) &&
		webgpu_view_uniform_write(compositor.queue, compositor.icons.view_buffer, width, height, origin_px, view_slot) &&
		webgpu_view_uniform_write(compositor.queue, compositor.images.view_buffer, width, height, origin_px, view_slot) &&
		webgpu_view_uniform_write(compositor.queue, compositor.surfaces.view_buffer, width, height, origin_px, view_slot)
}

// Call only after the host has submitted the command buffer. If a prepared
// frame is abandoned, leaving atlas generations dirty makes them retryable.
Compositor_Commit_Submission :: proc(compositor: ^WebGPU_Compositor, rt: ^alicorn.Runtime) -> u64 {
	if compositor == nil || rt == nil || compositor.prepared_runtime != rt || !compositor.prepared_valid { return 0 }
	if compositor.images.submitted_serial != compositor.surfaces.submitted_serial { return 0 }
	Text_Commit_Submission(&compositor.text, rt)
	serial := Image_Commit_Submission(&compositor.images, rt)
	if serial == 0 || !Surface_Commit_Submission(&compositor.surfaces, serial) { return 0 }
	compositor.capture_view_slots_used = 0
	return serial
}

// Call from a queue-work-done callback using the serial returned by the
// matching Compositor_Commit_Submission. Images retired by release or cache
// pressure remain resident until their final submitted use has completed.
Compositor_Complete_Submission :: proc(compositor: ^WebGPU_Compositor, serial: u64) -> bool {
	if compositor == nil || serial > compositor.images.submitted_serial || serial > compositor.surfaces.submitted_serial { return false }
	image_ok := Image_Complete_Submission(&compositor.images, serial)
	surface_ok := Surface_Complete_Submission(&compositor.surfaces, serial)
	return image_ok && surface_ok
}

Compositor_Destroy :: proc(compositor: ^WebGPU_Compositor) {
	if compositor == nil { return }
	Image_Destroy(&compositor.images)
	Surface_Destroy(&compositor.surfaces)
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

compositor_result_from_image :: proc(result: Image_Result) -> Compositor_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}

compositor_result_from_surface :: proc(result: Surface_Result) -> Compositor_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Unsupported_Command: return .Unsupported_Command
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}
