package webgpu_renderer

import alicorn "../../runtime"
import cpu_renderer "../cpu"
import "vendor:wgpu"

Compositor_Result :: enum {
	Ok,
	Invalid_Input,
	Unsupported_Command,
	Resource_Failure,
}

WEBGPU_COMPOSITOR_MAX_BACKDROP_EFFECTS :: 4

Backdrop_Effect_Entry :: struct {
	runtime: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	marker_index: int,
	plan: cpu_renderer.Backdrop_Effect_Plan,
	renderer: Backdrop_Effect_Renderer,
	live, ready: bool,
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
	backdrops: [dynamic]Backdrop_Effect_Entry,
	prepared_runtime: ^alicorn.Runtime,
	prepared_revision: u64,
	prepared_commands: rawptr,
	prepared_command_count: int,
	prepared_width, prepared_height: u32,
	prepared_scale_x, prepared_scale_y: f32,
	prepared_valid: bool,
	encode_pending: bool,
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
	compositor.backdrops = make([dynamic]Backdrop_Effect_Entry, 0, WEBGPU_COMPOSITOR_MAX_BACKDROP_EFFECTS)
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

compositor_backdrop_entry_find :: proc(
	compositor: ^WebGPU_Compositor,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
) -> int {
	if compositor == nil || rt == nil || owner == 0 { return -1 }
	for entry, index in compositor.backdrops {
		if entry.runtime == rt && entry.owner == owner { return index }
	}
	return -1
}

compositor_backdrop_resident_bytes_except :: proc(compositor: ^WebGPU_Compositor, except_index: int) -> u64 {
	if compositor == nil { return 0 }
	bytes := u64(0)
	for entry, index in compositor.backdrops {
		if index != except_index { bytes += entry.renderer.resident_bytes }
	}
	return bytes
}

compositor_backdrop_renderer_quiescent :: proc(renderer: ^Backdrop_Effect_Renderer) -> bool {
	if renderer == nil || renderer.pending_encoded || renderer.pending_used { return false }
	if renderer.set.last_use_serial > renderer.completed_serial { return false }
	for retired in renderer.retired {
		if retired.retire_after_serial > renderer.completed_serial { return false }
	}
	return true
}

compositor_backdrop_prune_inactive :: proc(compositor: ^WebGPU_Compositor) {
	if compositor == nil { return }
	for index := len(compositor.backdrops)-1; index >= 0; index -= 1 {
		entry := &compositor.backdrops[index]
		if entry.live || !compositor_backdrop_renderer_quiescent(&entry.renderer) { continue }
		Backdrop_Effect_Destroy(&entry.renderer)
		ordered_remove(&compositor.backdrops, index)
	}
}

compositor_backdrop_entry_for_marker :: proc(compositor: ^WebGPU_Compositor, marker_index: int) -> ^Backdrop_Effect_Entry {
	if compositor == nil { return nil }
	for &entry in compositor.backdrops {
		if entry.ready && entry.marker_index == marker_index { return &entry }
	}
	return nil
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
	// A new prepare without a matching submit means the previous encoded frame
	// was abandoned. Its retained effect output is not a completed cache entry.
	if compositor.encode_pending {
		for &entry in compositor.backdrops { Backdrop_Effect_Abort(&entry.renderer) }
		compositor.capture_view_slots_used = 0
		compositor.encode_pending = false
	}
	for &entry in compositor.backdrops {
		entry.live = false
		entry.ready = false
		entry.marker_index = -1
	}
	compositor.prepared_valid = false
	for command in display.commands {
		if !alicorn.paint_command_is_surface(command) && !alicorn.paint_command_is_geometry(command) && !alicorn.paint_command_is_text(command) &&
		   !alicorn.paint_command_is_icon(command) && !alicorn.paint_command_is_image(command) &&
		   !alicorn.paint_command_is_backdrop_effect(command) {
			return .Unsupported_Command
		}
	}
	// Preserve entries for markers still present in this frame before pruning
	// caches whose last submitted use has completed.
	for command in display.commands {
		if !alicorn.paint_command_is_backdrop_effect(command) { continue }
		if index := compositor_backdrop_entry_find(compositor, rt, command.owner); index >= 0 {
			compositor.backdrops[index].live = true
		}
	}
	compositor_backdrop_prune_inactive(compositor)
	for command, index in display.commands {
		if !alicorn.paint_command_is_backdrop_effect(command) { continue }
		if abs(scale_x-scale_y) > 0.001 { continue }
		payload, payload_ok := command.payload.(alicorn.Backdrop_Effect_Paint)
		if !payload_ok || command.owner == 0 { continue }
		entry_index := compositor_backdrop_entry_find(compositor, rt, command.owner)
		if entry_index < 0 {
			if len(compositor.backdrops) >= WEBGPU_COMPOSITOR_MAX_BACKDROP_EFFECTS { continue }
			append(&compositor.backdrops, Backdrop_Effect_Entry{
				runtime=rt, owner=command.owner, marker_index=index,
			})
			entry_index = len(compositor.backdrops)-1
		}
		entry := &compositor.backdrops[entry_index]
		entry.live = true
		entry.marker_index = index
		generation := cpu_renderer.Backdrop_Effect_Prefix_Generation_For_Runtime(
			rt, display.commands[:index], command.bounds, command.clip, scale_x, scale_y, payload.sigma,
		)
		plan, valid := cpu_renderer.Backdrop_Effect_Plan_Make(cpu_renderer.Backdrop_Effect_Request{
			enabled=true,
			key=u64(command.owner),
			source_generation=generation,
			region=command.bounds,
			clip=command.clip,
			scale=scale_x,
			sigma=payload.sigma,
			depth=1,
		})
		if !valid || !plan.active { continue }
		other_bytes := compositor_backdrop_resident_bytes_except(compositor, entry_index)
		if other_bytes >= WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES { continue }
		available_bytes := WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES-other_bytes
		if entry.renderer.device == nil {
			minimum_bytes := u64(plan.width)*u64(plan.height)*20 + WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES
			if minimum_bytes > available_bytes { continue }
			renderer, created := Backdrop_Effect_Create(compositor.device, compositor.queue, compositor.format)
			if !created { continue }
			entry.renderer = renderer
		}
		if Backdrop_Effect_Prepare(&entry.renderer, plan, available_bytes) {
			entry.plan = plan
			entry.ready = true
		}
	}
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
	return compositor_encode(
		compositor, rt, display, target, target_width, target_height, scale_x, scale_y, encoder,
		clear_target, clear_color, capture_view, capture_origin_px, capture_view_slot,
		command_start, command_end, false,
	)
}

// The private escape hatch is restricted to the compositor's halo-expanded
// backdrop capture. Keep it out of the host-facing cropped-target contract.
compositor_encode :: proc(
	compositor: ^WebGPU_Compositor,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target: wgpu.TextureView,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	encoder: wgpu.CommandEncoder,
	clear_target: bool,
	clear_color: wgpu.Color,
	capture_view: bool,
	capture_origin_px: [2]int,
	capture_view_slot: u32,
	command_start, command_end: int,
	capture_allow_outside: bool,
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
		   (capture_view_slot > VIEW_UNIFORM_MAX_CAPTURE_VIEWS &&
		    !(capture_allow_outside && capture_view_slot == VIEW_UNIFORM_EFFECT_CAPTURE_SLOT)) {
			return .Invalid_Input
		}
		if capture_allow_outside {
			if capture_view_slot != VIEW_UNIFORM_EFFECT_CAPTURE_SLOT ||
			   target_width > cpu_renderer.BACKDROP_EFFECT_MAX_DIMENSION || target_height > cpu_renderer.BACKDROP_EFFECT_MAX_DIMENSION ||
			   abs(i64(capture_origin_px[0])) > cpu_renderer.BACKDROP_EFFECT_MAX_COORD ||
			   abs(i64(capture_origin_px[1])) > cpu_renderer.BACKDROP_EFFECT_MAX_COORD {
				return .Invalid_Input
			}
		} else if capture_origin_px[0] < 0 || capture_origin_px[1] < 0 ||
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
	// Prepare effect outputs in paint order. A later marker's capture recursively
	// encodes the earlier marker composites into its prefix, preserving stacking.
	for marker_index in command_start..<draw_command_end {
		entry := compositor_backdrop_entry_for_marker(compositor, marker_index)
		if entry == nil { continue }
		if Backdrop_Effect_Needs_Capture(&entry.renderer) {
			origin := Backdrop_Effect_Source_Origin(entry.plan)
			if result := compositor_encode(
				compositor, rt, display, Backdrop_Effect_Source_View(&entry.renderer),
				entry.plan.width, entry.plan.height, scale_x, scale_y, encoder,
				true, WEBGPU_BACKDROP_PREFIX_CLEAR,
				true, origin, VIEW_UNIFORM_EFFECT_CAPTURE_SLOT,
				0, marker_index, true,
			); result != .Ok {
				return result
			}
		}
		if !Backdrop_Effect_Encode_Filter(&entry.renderer, encoder) { return .Resource_Failure }
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
		} else if alicorn.paint_command_is_backdrop_effect(command) {
			if entry := compositor_backdrop_entry_for_marker(compositor, command_index); entry != nil {
				origin := [2]int{}
				if capture_view { origin = capture_origin_px }
				if !Backdrop_Effect_Draw_Composite(
					&entry.renderer, pass, entry.plan, target_width, target_height, origin,
					capture_view_slot if capture_view else 0,
				) {
					return .Resource_Failure
				}
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
	compositor.encode_pending = true
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
	for &entry in compositor.backdrops { Backdrop_Effect_Commit_Submission(&entry.renderer, serial) }
	compositor.capture_view_slots_used = 0
	compositor.encode_pending = false
	return serial
}

// Call from a queue-work-done callback using the serial returned by the
// matching Compositor_Commit_Submission. Images retired by release or cache
// pressure remain resident until their final submitted use has completed.
Compositor_Complete_Submission :: proc(compositor: ^WebGPU_Compositor, serial: u64) -> bool {
	if compositor == nil || serial > compositor.images.submitted_serial || serial > compositor.surfaces.submitted_serial { return false }
	image_ok := Image_Complete_Submission(&compositor.images, serial)
	surface_ok := Surface_Complete_Submission(&compositor.surfaces, serial)
	for &entry in compositor.backdrops { Backdrop_Effect_Complete_Submission(&entry.renderer, serial) }
	return image_ok && surface_ok
}

// Call when a prepared command encoder is abandoned before QueueSubmit.
Compositor_Abort_Submission :: proc(compositor: ^WebGPU_Compositor) {
	if compositor == nil { return }
	for &entry in compositor.backdrops { Backdrop_Effect_Abort(&entry.renderer) }
	compositor.capture_view_slots_used = 0
	compositor.encode_pending = false
}

Compositor_Destroy :: proc(compositor: ^WebGPU_Compositor) {
	compositor_destroy(compositor, true)
}

// Abandon device-owned handles only after the host has confirmed device loss
// and drained callbacks. wgpu-native owns reclamation for those handles; the
// renderer still frees its CPU-side retained caches and dynamic arrays.
Compositor_Abandon_After_Device_Loss :: proc(compositor: ^WebGPU_Compositor) {
	compositor_destroy(compositor, false)
}

@(private)
compositor_destroy :: proc(compositor: ^WebGPU_Compositor, release_gpu: bool) {
	if compositor == nil { return }
	if release_gpu {
		Image_Destroy(&compositor.images)
		Surface_Destroy(&compositor.surfaces)
		for &entry in compositor.backdrops { Backdrop_Effect_Destroy(&entry.renderer) }
		Text_Destroy(&compositor.text)
		Icon_Destroy(&compositor.icons)
		Solid_Destroy(&compositor.solid)
	} else {
		Image_Abandon_After_Device_Loss(&compositor.images)
		Surface_Abandon_After_Device_Loss(&compositor.surfaces)
		for &entry in compositor.backdrops { Backdrop_Effect_Abandon_After_Device_Loss(&entry.renderer) }
		Text_Abandon_After_Device_Loss(&compositor.text)
		Icon_Abandon_After_Device_Loss(&compositor.icons)
		Solid_Abandon_After_Device_Loss(&compositor.solid)
	}
	delete(compositor.backdrops)
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
