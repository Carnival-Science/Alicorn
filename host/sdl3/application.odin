#+build !js

package sdl3_host

import alicorn "alicorn:runtime"
import presentation_host "alicorn:host/presentation"
import "core:c"
import "vendor:sdl3"
import "vendor:wgpu"

SDL3_WebGPU_Application_Result :: enum {
	Ok,
	Invalid_Input,
	Window_Failure,
	Runtime_Failure,
	Presenter_Failure,
}

SDL3_WebGPU_Application_Event_Result :: enum {
	Ignored,
	Handled,
	Wake,
	Close_Requested,
	Failure,
}

SDL3_WebGPU_Application_Step :: struct {
	status: alicorn.Hosted_Runtime_Status,
	presentation: presentation_host.Hosted_Surface_Result,
	has_more_work: bool,
	next_wake_ns: u64,
}

SDL3_WebGPU_Text_Input_State :: struct {
	active: bool,
	owner: alicorn.Node_ID,
	composition_owner: alicorn.Node_ID,
	window_focused: bool,
	last_area: alicorn.Text_Input_Area,
	last_area_valid: bool,
}

// SDL3_WebGPU_Application joins an SDL-owned window/event identity, one
// Hosted_Runtime, and the shared WebGPU surface presenter. Adapter, device,
// queue, and surface creation remain the embedding host's responsibility.
// Methods run on the SDL owner thread. The owner must keep this value and the
// borrowed WGPU objects alive until destroy returns true.
SDL3_WebGPU_Application :: struct {
	hosted: alicorn.Hosted_Runtime,
	presenter: presentation_host.Hosted_Surface_Presenter,
	window: ^sdl3.Window,
	window_id: sdl3.WindowID,
	wake_event_type: sdl3.EventType,
	pointer_buttons: Pointer_Button_State,
	modifiers: sdl3.Keymod,
	text_input: SDL3_WebGPU_Text_Input_State,
	dpi_scale: f32,
	clear_color: wgpu.Color,
	last_logical_width, last_logical_height: int,
	last_pixel_width, last_pixel_height: int,
	next_wake_ns: u64,
	visible: bool,
	initialized: bool,
	presenter_device_lost: bool,
}

@(private)
sdl3_webgpu_application_post_wake :: proc(data: rawptr) -> bool {
	application := cast(^SDL3_WebGPU_Application)data
	if application == nil || !application.initialized || application.wake_event_type == {} { return false }
	event := sdl3.Event{type=application.wake_event_type}
	return sdl3.PushEvent(&event)
}

@(private)
sdl3_webgpu_application_wake :: proc(data: rawptr) {
	_ = sdl3_webgpu_application_post_wake(data)
}

@(private)
sdl3_webgpu_application_window_metrics :: proc(
	window: ^sdl3.Window,
) -> (logical_width, logical_height, pixel_width, pixel_height: int, ok: bool) {
	if window == nil { return }
	logical_w, logical_h: i32
	pixel_w, pixel_h: i32
	if !sdl3.GetWindowSize(window, &logical_w, &logical_h) ||
	   !sdl3.GetWindowSizeInPixels(window, &pixel_w, &pixel_h) {
		return
	}
	if logical_w < 0 || logical_h < 0 || pixel_w < 0 || pixel_h < 0 { return }
	return int(logical_w), int(logical_h), int(pixel_w), int(pixel_h), true
}

// Initialize around an SDL window and WebGPU surface created by the caller.
// The host callback is replaced with an SDL user event so worker and queue
// completion wakes enter the normal event loop without polling.
sdl3_webgpu_application_init :: proc(
	application: ^SDL3_WebGPU_Application,
	hosted_config: alicorn.Hosted_Runtime_Config,
	window: ^sdl3.Window,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> SDL3_WebGPU_Application_Result {
	if application == nil || application.initialized || hosted_config.render == nil ||
	   window == nil || surface == nil || device == nil || queue == nil ||
	   configuration.format == .Undefined || configuration.width == 0 || configuration.height == 0 {
		return .Invalid_Input
	}
	logical_width, logical_height, pixel_width, pixel_height, metrics_ok := sdl3_webgpu_application_window_metrics(window)
	if !metrics_ok || logical_width == 0 || logical_height == 0 || pixel_width == 0 || pixel_height == 0 {
		return .Window_Failure
	}
	wake_event := sdl3.EventType(sdl3.RegisterEvents(1))
	if wake_event == {} { return .Window_Failure }
	application^ = SDL3_WebGPU_Application{
		window=window,
		window_id=sdl3.GetWindowID(window),
		wake_event_type=wake_event,
		modifiers=sdl3.GetModState(),
		text_input=SDL3_WebGPU_Text_Input_State{
			window_focused=sdl3.GetKeyboardFocus() == window,
		},
		dpi_scale=f32(pixel_width) / f32(logical_width),
		clear_color=clear_color,
		last_logical_width=logical_width,
		last_logical_height=logical_height,
		last_pixel_width=pixel_width,
		last_pixel_height=pixel_height,
		visible=true,
		initialized=true,
	}
	if application.window_id == 0 { application^ = {}; return .Window_Failure }
	dpi := f32(pixel_width) / f32(logical_width)
	config := hosted_config
	config.logical_width, config.logical_height = logical_width, logical_height
	config.pixel_width, config.pixel_height = pixel_width, pixel_height
	config.dpi_scale = dpi
	config.post_wake_data = rawptr(application)
	config.post_wake = sdl3_webgpu_application_post_wake
	if alicorn.hosted_runtime_init(&application.hosted, config) != .Ok {
		application^ = {}
		return .Runtime_Failure
	}
	if result := sdl3_webgpu_application_attach_presenter(
		application, surface, device, queue, configuration,
	); result != .Ok {
		_ = alicorn.hosted_runtime_destroy(&application.hosted)
		application^ = {}
		return .Presenter_Failure
	}
	application.initialized = true
	return .Ok
}

// Attach or reattach the device-bound presenter while keeping the same
// Hosted_Runtime, SDL input state, and native text-input owner. After loss,
// callers must first mark and detach the old presenter once its queue callbacks
// have drained.
sdl3_webgpu_application_attach_presenter :: proc(
	application: ^SDL3_WebGPU_Application,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
) -> SDL3_WebGPU_Application_Result {
	if application == nil || !application.initialized || application.hosted.state == nil ||
	   surface == nil || device == nil || queue == nil || configuration.format == .Undefined ||
	   application.presenter.state != nil {
		return .Invalid_Input
	}
	logical_width, logical_height, pixel_width, pixel_height, metrics_ok :=
		sdl3_webgpu_application_window_metrics(application.window)
	if !metrics_ok { return .Window_Failure }
	if logical_width > 0 && logical_height > 0 && pixel_width > 0 && pixel_height > 0 {
		application.last_logical_width, application.last_logical_height = logical_width, logical_height
		application.last_pixel_width, application.last_pixel_height = pixel_width, pixel_height
		application.dpi_scale = f32(pixel_width) / f32(logical_width)
	}
	if application.last_logical_width <= 0 || application.last_logical_height <= 0 ||
	   application.last_pixel_width <= 0 || application.last_pixel_height <= 0 {
		return .Window_Failure
	}
	surface_configuration := configuration
	surface_configuration.width = u32(application.last_pixel_width)
	surface_configuration.height = u32(application.last_pixel_height)
	if result := presentation_host.hosted_surface_presenter_init(
		&application.presenter,
		&application.hosted,
		surface,
		device,
		queue,
		surface_configuration,
		application.last_logical_width,
		application.last_logical_height,
		application.dpi_scale,
		rawptr(application),
		sdl3_webgpu_application_wake,
		application.clear_color,
	); result != .Ok {
		return .Presenter_Failure
	}
	application.presenter_device_lost = false
	renderable := application.visible && logical_width > 0 && logical_height > 0 &&
		pixel_width > 0 && pixel_height > 0
	if alicorn.hosted_runtime_set_renderable(&application.hosted, renderable) != .Ok {
		_ = presentation_host.hosted_surface_presenter_destroy(&application.presenter)
		return .Presenter_Failure
	}
	if logical_width == 0 || logical_height == 0 || pixel_width == 0 || pixel_height == 0 {
		resize_result := presentation_host.hosted_surface_presenter_resize(
			&application.presenter,
			logical_width,
			logical_height,
			pixel_width,
			pixel_height,
			application.dpi_scale,
		)
		if resize_result != .Suspended {
			_ = presentation_host.hosted_surface_presenter_destroy(&application.presenter)
			return .Presenter_Failure
		}
	}
	if !application.visible {
		if presentation_host.hosted_surface_presenter_set_visible(&application.presenter, false) != .Ok {
			_ = presentation_host.hosted_surface_presenter_destroy(&application.presenter)
			return .Presenter_Failure
		}
	}
	return .Ok
}

// A loss invalidates the old presenter immediately. Its Runtime and input
// bridges remain live for reattachment to a replacement device.
sdl3_webgpu_application_mark_device_lost :: proc(application: ^SDL3_WebGPU_Application) {
	if application == nil || !application.initialized { return }
	application.presenter_device_lost = true
	presentation_host.hosted_surface_presenter_mark_device_lost(&application.presenter)
	_ = alicorn.hosted_runtime_set_renderable(&application.hosted, false)
}

sdl3_webgpu_application_detach_lost_presenter :: proc(
	application: ^SDL3_WebGPU_Application,
) -> bool {
	if application == nil || !application.initialized { return true }
	if !application.presenter_device_lost { return false }
	return presentation_host.hosted_surface_presenter_destroy_after_device_loss(&application.presenter)
}

sdl3_webgpu_application_pointer :: proc(
	application: ^SDL3_WebGPU_Application,
	event: alicorn.Pointer_Event,
) -> alicorn.Hosted_Runtime_Status {
	if application == nil || !application.initialized { return .Closed }
	_, status := alicorn.hosted_runtime_pointer(&application.hosted, event)
	return status
}

sdl3_webgpu_application_resize :: proc(application: ^SDL3_WebGPU_Application) -> presentation_host.Hosted_Surface_Result {
	if application == nil || !application.initialized { return .Invalid_Input }
	lw, lh, pw, ph, ok := sdl3_webgpu_application_window_metrics(application.window)
	if !ok { return .Invalid_Input }
	dpi := application.dpi_scale
	if lw > 0 && pw > 0 { dpi = f32(pw) / f32(lw) }
	else if lh > 0 && ph > 0 { dpi = f32(ph) / f32(lh) }
	if lw > 0 && lh > 0 && pw > 0 && ph > 0 {
		application.last_logical_width, application.last_logical_height = lw, lh
		application.last_pixel_width, application.last_pixel_height = pw, ph
	}
	if application.presenter.state == nil || application.presenter_device_lost {
		if alicorn.hosted_runtime_resize(&application.hosted, lw, lh, pw, ph, dpi) != .Ok {
			return .Invalid_Input
		}
		renderable := !application.presenter_device_lost && application.visible &&
			lw > 0 && lh > 0 && pw > 0 && ph > 0
		if alicorn.hosted_runtime_set_renderable(&application.hosted, renderable) != .Ok {
			return .Invalid_Input
		}
		application.dpi_scale = dpi
		if renderable { return .Ok }
		return .Suspended
	}
	result := presentation_host.hosted_surface_presenter_resize(
		&application.presenter, lw, lh, pw, ph, dpi,
	)
	if result == .Ok || result == .Suspended { application.dpi_scale = dpi }
	return result
}

sdl3_webgpu_application_set_visible :: proc(
	application: ^SDL3_WebGPU_Application,
	visible: bool,
) -> presentation_host.Hosted_Surface_Result {
	if application == nil || !application.initialized { return .Invalid_Input }
	application.visible = visible
	if application.presenter.state == nil || application.presenter_device_lost {
		lw, lh, pw, ph, ok := sdl3_webgpu_application_window_metrics(application.window)
		if !ok { return .Invalid_Input }
		renderable := !application.presenter_device_lost && visible &&
			lw > 0 && lh > 0 && pw > 0 && ph > 0
		if alicorn.hosted_runtime_set_renderable(&application.hosted, renderable) != .Ok {
			return .Invalid_Input
		}
		return .Ok
	}
	return presentation_host.hosted_surface_presenter_set_visible(&application.presenter, visible)
}

// Step after a bounded SDL event batch or scheduled wake. Retry_Later receives
// one bounded 60 Hz deadline; the host should use SDL_WaitEventTimeout for that
// deadline and continue to pump WGPU callbacks while work is in flight.
sdl3_webgpu_application_step :: proc(
	application: ^SDL3_WebGPU_Application,
	now_ns: u64,
) -> SDL3_WebGPU_Application_Step {
	if application == nil || !application.initialized {
		return {status=.Closed, presentation=.Invalid_Input}
	}
	if application.presenter.state == nil || application.presenter_device_lost {
		return {status=.Ok, presentation=.No_Frame}
	}
	step, presentation := presentation_host.hosted_surface_presenter_step(&application.presenter, now_ns)
	if step.status != .Ok { return {status=step.status, presentation=presentation} }
	if !sdl3_webgpu_application_sync_text_input(application) {
		return {status=.Invalid_Argument, presentation=presentation}
	}
	application.next_wake_ns = step.next_wake_ns
	if presentation == .Retry_Later {
		retry_ns := now_ns + 16_666_667
		if application.next_wake_ns == 0 || retry_ns < application.next_wake_ns {
			application.next_wake_ns = retry_ns
		}
	}
	return {
		status=step.status,
		presentation=presentation,
		has_more_work=step.has_more_work,
		next_wake_ns=application.next_wake_ns,
	}
}

sdl3_webgpu_application_has_in_flight :: proc(application: ^SDL3_WebGPU_Application) -> bool {
	return application != nil && application.initialized &&
		presentation_host.hosted_surface_presenter_has_in_flight(&application.presenter)
}

// Route native input to the retained Runtime without exposing SDL types to it.
sdl3_webgpu_application_handle_event :: proc(
	application: ^SDL3_WebGPU_Application,
	event: sdl3.Event,
) -> SDL3_WebGPU_Application_Event_Result {
	if application == nil || !application.initialized { return .Failure }
	if event.type == application.wake_event_type { return .Wake }
	if event.type == .QUIT { return .Close_Requested }
	if event.type == .WINDOW_CLOSE_REQUESTED && event.window.windowID == application.window_id {
		return .Close_Requested
	}
	event_window := event_window_id_from_sdl(event)
	if event_window != 0 && event_window != application.window_id { return .Ignored }
	#partial switch event.type {
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		result := sdl3_webgpu_application_resize(application)
		if result != .Ok && result != .Suspended { return .Failure }
		return .Handled
	case .WINDOW_HIDDEN, .WINDOW_MINIMIZED:
		if sdl3_webgpu_application_set_visible(application, false) != .Ok { return .Failure }
		return .Handled
	case .WINDOW_SHOWN, .WINDOW_RESTORED:
		if sdl3_webgpu_application_set_visible(application, true) != .Ok { return .Failure }
		return .Handled
	case .WINDOW_FOCUS_GAINED:
		application.text_input.window_focused = true
		application.modifiers = sdl3.GetModState()
		if alicorn.hosted_runtime_focus_changed(&application.hosted, true) != .Ok { return .Failure }
		if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
		return .Handled
	case .WINDOW_FOCUS_LOST:
		application.text_input.window_focused = false
		// hosted_runtime_focus_changed sends the application-side composition
		// cancellation; clear the SDL tracker first to avoid a duplicate cancel.
		application.text_input.composition_owner = 0
		pointer_button_state_clear(&application.pointer_buttons)
		application.modifiers = {}
		if alicorn.hosted_runtime_focus_changed(&application.hosted, false) != .Ok { return .Failure }
		if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
		return .Handled
	case .KEY_DOWN, .KEY_UP:
		pointer_modifier_state_update(&application.modifiers, event)
		if event.type == .KEY_UP { return .Ignored }
		return sdl3_webgpu_application_key_down(application, event.key)
	case .TEXT_INPUT:
		return sdl3_webgpu_application_text_input(application, event.text)
	case .TEXT_EDITING:
		return sdl3_webgpu_application_text_editing(application, event.edit)
	case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		value, ok := pointer_event_from_sdl(event, application.modifiers, &application.pointer_buttons)
		if !ok { return .Ignored }
		value.timestamp_ns = u64(sdl3.GetTicksNS())
		if status := sdl3_webgpu_application_pointer(application, value); status != .Ok { return .Failure }
		if event.type == .MOUSE_BUTTON_DOWN && !sdl3_webgpu_application_sync_text_input(application) {
			return .Failure
		}
		return .Handled
	case .MOUSE_WHEEL:
		value := scroll_event_from_sdl(event.wheel, pointer_modifiers_from_sdl(application.modifiers))
		_, status := alicorn.hosted_runtime_scroll(&application.hosted, value)
		if status != .Ok { return .Failure }
		return .Handled
	case:
		return .Ignored
	}
}

// Destroy is nonblocking. Keep pumping WGPU callbacks and retry after the
// completion wake while the presenter has submitted frames in flight.
sdl3_webgpu_application_destroy :: proc(application: ^SDL3_WebGPU_Application) -> bool {
	if application == nil { return false }
	if !application.initialized { return true }
	if application.presenter.state != nil {
		if application.presenter_device_lost {
			if !presentation_host.hosted_surface_presenter_destroy_after_device_loss(&application.presenter) {
				return false
			}
		} else if !presentation_host.hosted_surface_presenter_destroy(&application.presenter) {
			return false
		}
	}
	application.text_input.window_focused = false
	application.text_input.composition_owner = 0
	if alicorn.hosted_runtime_focus_changed(&application.hosted, false) != .Ok ||
		!sdl3_webgpu_application_sync_text_input(application) {
		return false
	}
	if alicorn.hosted_runtime_destroy(&application.hosted) != .Ok { return false }
	application^ = {}
	return true
}
