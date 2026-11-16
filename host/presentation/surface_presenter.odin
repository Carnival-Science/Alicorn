package presentation_host

import "core:mem"
import "base:runtime"
import alicorn "alicorn:runtime"
import "vendor:wgpu"
import webgpu_renderer "alicorn:renderer/webgpu"

Hosted_Surface_Result :: enum {
	Ok,
	No_Frame,
	Suspended,
	Retry_Later,
	Reconfigure_Required,
	Hidden,
	Invalid_Input,
	Resource_Failure,
	Render_Failure,
	Surface_Acquire_Failure,
	Present_Failure,
}

Hosted_Surface_Wake_Proc :: proc(data: rawptr)

// Hosted_Surface_Presenter binds one Hosted_Runtime to a host-created WebGPU
// surface. The embedding host still owns adapter/device/queue/surface creation,
// platform sizing, and demand scheduling. It must keep this value, Runtime, and
// WGPU objects alive until destroy returns true. All methods run on the platform's
// owner thread; queue completion is delivered asynchronously by WebGPU.
Hosted_Surface_Presenter :: struct {
	state: rawptr,
}

@(private)
hosted_surface_presenter_state :: struct {
	allocator: mem.Allocator,
	hosted: ^alicorn.Hosted_Runtime,
	runtime: ^alicorn.Runtime,
	device: wgpu.Device,
	queue: wgpu.Queue,
	surface: wgpu.Surface,
	configuration: wgpu.SurfaceConfiguration,
	renderer: webgpu_renderer.WebGPU_Presenter,
	logical_width, logical_height: int,
	scale_x, scale_y: f32,
	visible: bool,
	drawable: bool,
	clear_color: wgpu.Color,
	wake_data: rawptr,
	wake: Hosted_Surface_Wake_Proc,
	completion_failed: bool,
	presentation_failed: bool,
}

@(private)
hosted_surface_completion :: struct {
	allocator: mem.Allocator,
	state: ^hosted_surface_presenter_state,
	submission: webgpu_renderer.WebGPU_Submission,
}

@(private)
hosted_surface_state :: proc(presenter: ^Hosted_Surface_Presenter) -> ^hosted_surface_presenter_state {
	if presenter == nil || presenter.state == nil { return nil }
	return cast(^hosted_surface_presenter_state)presenter.state
}

// Initialize presentation for a WebGPU surface already created by the host.
// The supplied format, present mode, and alpha mode must come from that
// surface's capabilities. Configuration usage is narrowed to render output.
hosted_surface_presenter_init :: proc(
	presenter: ^Hosted_Surface_Presenter,
	hosted: ^alicorn.Hosted_Runtime,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	logical_width, logical_height: int,
	dpi_scale: f32,
	wake_data: rawptr,
	wake: Hosted_Surface_Wake_Proc,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> Hosted_Surface_Result {
	if presenter == nil || presenter.state != nil || hosted == nil || surface == nil ||
	   device == nil || queue == nil || wake == nil || logical_width <= 0 || logical_height <= 0 ||
	   configuration.width == 0 || configuration.height == 0 || configuration.format == .Undefined {
		return .Invalid_Input
	}
	runtime, borrow_status := alicorn.hosted_runtime_borrow(hosted)
	if borrow_status != .Ok || runtime == nil { return .Invalid_Input }
	state := new(hosted_surface_presenter_state, allocator=context.allocator)
	if state == nil { return .Resource_Failure }
	state.allocator = context.allocator
	state.hosted, state.runtime = hosted, runtime
	state.device, state.queue, state.surface = device, queue, surface
	state.configuration = configuration
	state.configuration.device = device
	state.configuration.usage = {.RenderAttachment}
	state.configuration.width = configuration.width
	state.configuration.height = configuration.height
	state.logical_width, state.logical_height = logical_width, logical_height
	state.scale_x = f32(configuration.width) / f32(logical_width)
	state.scale_y = f32(configuration.height) / f32(logical_height)
	state.visible, state.drawable = true, true
	state.clear_color = clear_color
	state.wake_data, state.wake = wake_data, wake
	renderer, renderer_ok := webgpu_renderer.WebGPU_Presenter_Create(
		device, queue, configuration.format, runtime,
	)
	if !renderer_ok {
		free(state, allocator=state.allocator)
		return .Resource_Failure
	}
	state.renderer = renderer
	if status := alicorn.hosted_runtime_resize(
		hosted, logical_width, logical_height,
		int(configuration.width), int(configuration.height), dpi_scale,
	); status != .Ok {
		_ = webgpu_renderer.WebGPU_Presenter_Destroy(&state.renderer)
		free(state, allocator=state.allocator)
		return .Invalid_Input
	}
	wgpu.SurfaceConfigure(surface, &state.configuration)
	presenter.state = rawptr(state)
	return .Ok
}

// Resize the retained Runtime and configure the surface as one owner-thread
// operation. A zero drawable size suspends presentation without configuring an
// invalid 0x0 WebGPU surface; restoring a nonzero size schedules the Runtime's
// retained display through hosted_runtime_resize and wakes the host scheduler.
hosted_surface_presenter_resize :: proc(
	presenter: ^Hosted_Surface_Presenter,
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil || logical_width < 0 || logical_height < 0 || pixel_width < 0 || pixel_height < 0 {
		return .Invalid_Input
	}
	if status := alicorn.hosted_runtime_resize(
		state.hosted, logical_width, logical_height, pixel_width, pixel_height, dpi_scale,
	); status != .Ok {
		return .Invalid_Input
	}
	state.logical_width, state.logical_height = logical_width, logical_height
	if pixel_width == 0 || pixel_height == 0 || logical_width == 0 || logical_height == 0 {
		state.drawable = false
		if status := alicorn.hosted_runtime_set_renderable(state.hosted, false); status != .Ok {
			return .Invalid_Input
		}
		return .Suspended
	}
	state.drawable = true
	state.configuration.width = u32(pixel_width)
	state.configuration.height = u32(pixel_height)
	state.scale_x = f32(pixel_width) / f32(logical_width)
	state.scale_y = f32(pixel_height) / f32(logical_height)
	wgpu.SurfaceConfigure(state.surface, &state.configuration)
	if status := alicorn.hosted_runtime_set_renderable(state.hosted, state.visible); status != .Ok {
		return .Invalid_Input
	}
	if state.visible && state.wake != nil { state.wake(state.wake_data) }
	return .Ok
}

// Suspend or resume retained presentation when the host's visibility changes.
// Drawable size and visibility are tracked independently so a resize while
// hidden cannot accidentally re-enable frame scheduling.
hosted_surface_presenter_set_visible :: proc(
	presenter: ^Hosted_Surface_Presenter,
	visible: bool,
) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil { return .Invalid_Input }
	if state.visible == visible { return .Ok }
	state.visible = visible
	if status := alicorn.hosted_runtime_set_renderable(
		state.hosted, state.visible && state.drawable,
	); status != .Ok {
		return .Invalid_Input
	}
	if visible && state.drawable && state.wake != nil { state.wake(state.wake_data) }
	return .Ok
}

// Host callback adapter for visibility changes. Pass a stable presenter
// pointer as callback data when a host coordinates visibility and scheduling.
hosted_surface_visibility_changed :: proc(data: rawptr, visible: bool) {
	presenter := cast(^Hosted_Surface_Presenter)data
	_ = hosted_surface_presenter_set_visible(presenter, visible)
}

// Step once after a bounded input batch or scheduled wake. At most one Runtime
// description and one surface submission are performed. The host scheduler
// should use step.next_wake_ns, keep running when has_more_work is true, wait
// for Hosted_Surface_Wake_Proc after asynchronous queue completion, and retry
// Retry_Later with a bounded timer rather than a busy loop.
hosted_surface_presenter_step :: proc(
	presenter: ^Hosted_Surface_Presenter,
	now_ns: u64,
) -> (step: alicorn.Hosted_Step_Result, presentation: Hosted_Surface_Result) {
	state := hosted_surface_state(presenter)
	if state == nil { return alicorn.Hosted_Step_Result{status=.Closed}, .Invalid_Input }
	step = alicorn.hosted_runtime_step(state.hosted, now_ns)
	if step.status != .Ok { return step, .Invalid_Input }
	if !step.render_required { return step, .No_Frame }
	presentation = hosted_surface_present_pending(presenter)
	return
}

// hosted_surface_presenter_has_in_flight reports whether the host must keep
// pumping WebGPU completion callbacks before blocking indefinitely for input.
hosted_surface_presenter_has_in_flight :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	return state != nil && webgpu_renderer.WebGPU_Presenter_In_Flight(&state.renderer) > 0
}

@(private)
hosted_surface_present_pending :: proc(presenter: ^Hosted_Surface_Presenter) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil { return .Invalid_Input }
	if state.presentation_failed { return .Present_Failure }
	if state.completion_failed { return .Resource_Failure }
	if state.configuration.width == 0 || state.configuration.height == 0 { return .Suspended }
	if !webgpu_renderer.WebGPU_Presenter_Can_Encode(&state.renderer) { return .Retry_Later }
	display, display_ready := alicorn.paint_display_list(state.runtime)
	if !display_ready || display.revision == 0 { return .No_Frame }

	surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Retry_Later
	case .Outdated, .Lost:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		wgpu.SurfaceConfigure(state.surface, &state.configuration)
		if state.wake != nil { state.wake(state.wake_data) }
		return .Reconfigure_Required
	case .Occluded:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Hidden
	case .Error:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Surface_Acquire_Failure
	}
	if surface_texture.texture == nil { return .Present_Failure }
	defer wgpu.TextureRelease(surface_texture.texture)
	view := wgpu.TextureCreateView(surface_texture.texture)
	if view == nil { return .Resource_Failure }
	defer wgpu.TextureViewRelease(view)
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { return .Resource_Failure }
	defer wgpu.CommandEncoderRelease(encoder)
	if result := webgpu_renderer.WebGPU_Presenter_Encode(
		&state.renderer, display, encoder, view,
		state.configuration.width, state.configuration.height,
		state.scale_x, state.scale_y, true, state.clear_color,
	); result != .Ok {
		return .Render_Failure
	}
	command := wgpu.CommandEncoderFinish(encoder)
	if command == nil {
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		return .Resource_Failure
	}
	defer wgpu.CommandBufferRelease(command)
	completion := new(hosted_surface_completion, allocator=state.allocator)
	if completion == nil {
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		return .Resource_Failure
	}
	completion.allocator = state.allocator
	completion.state = state
	wgpu.QueueSubmit(state.queue, {command})
	submission, submitted := webgpu_renderer.WebGPU_Presenter_Submission_Succeeded(&state.renderer)
	if !submitted {
		free(completion, allocator=completion.allocator)
		state.completion_failed = true
		return .Resource_Failure
	}
	completion.submission = submission
	wgpu.QueueOnSubmittedWorkDone(state.queue, {
		mode=.AllowProcessEvents,
		callback=hosted_surface_presenter_queue_done,
		userdata1=rawptr(completion),
	})
	if !hosted_surface_present_succeeded(state.surface) {
		state.presentation_failed = true
		return .Present_Failure
	}
	return .Ok
}

@(private)
hosted_surface_presenter_queue_done :: proc "c" (
	status: wgpu.QueueWorkDoneStatus,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	completion := cast(^hosted_surface_completion)userdata1
	if completion == nil { return }
	state := completion.state
	if state != nil {
		if !webgpu_renderer.WebGPU_Presenter_Complete_Submission(&state.renderer, completion.submission) {
			state.completion_failed = true
		}
		if status != .Success { state.completion_failed = true }
		if state.wake != nil { state.wake(state.wake_data) }
	}
	free(completion, allocator=completion.allocator)
}

// Destroy is nonblocking. It returns false while GPU work is in flight; keep
// this value and the Hosted_Runtime alive, then retry after the completion wake.
// Surface, device, and queue handles are borrowed and remain host-owned.
hosted_surface_presenter_destroy :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if !webgpu_renderer.WebGPU_Presenter_Destroy(&state.renderer) { return false }
	wgpu.SurfaceUnconfigure(state.surface)
	allocator := state.allocator
	free(state, allocator=allocator)
	presenter^ = {}
	return true
}
