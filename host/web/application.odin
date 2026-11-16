#+build js wasm32, js wasm64p32

package web_host

import alicorn "alicorn:runtime"
import "core:sys/wasm/js"
import "vendor:wgpu"

Browser_Application_Result :: enum {
	Ok,
	Invalid_Input,
	Runtime_Failure,
	Presenter_Failure,
	Input_Failure,
}

Browser_Application_Wake_Proc :: proc(data: rawptr)

// Browser_Application joins one Hosted_Runtime, canvas input bridge, and the
// shared WebGPU surface presenter. It borrows the WebGPU objects and callback
// state; the embedding module must keep them alive until destroy returns true.
// All methods run on the browser/WASM owner thread.
Browser_Application :: struct {
	hosted: alicorn.Hosted_Runtime,
	presenter: Browser_Surface_Presenter,
	input: Browser_Input,
	device: wgpu.Device,
	queue: wgpu.Queue,
	surface: wgpu.Surface,
	configuration: wgpu.SurfaceConfiguration,
	canvas_id: string,
	text_input_id: string,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	next_wake_ns: u64,
	initialized: bool,
	input_detached: bool,
}

Browser_Application_Step :: struct {
	status: alicorn.Hosted_Runtime_Status,
	presentation: Browser_Surface_Result,
	has_more_work: bool,
	next_wake_ns: u64,
}

@(private)
browser_application_id_is_safe :: proc(id: string) -> bool {
	if len(id) == 0 { return false }
	for ch in id {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		     (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
			return false
		}
	}
	return true
}

@(private)
browser_application_post_wake :: proc(data: rawptr) -> bool {
	application := cast(^Browser_Application)data
	if application == nil || application.wake == nil { return false }
	application.wake(application.wake_data)
	return true
}

// Initialize an application on a host-created WebGPU surface. The Runtime
// metrics are derived from the canvas's CSS bounds and device pixel ratio;
// the supplied surface format and alpha mode must come from its capabilities.
// The host supplies a wake callback that schedules one demand-driven frame.
browser_application_init :: proc(
	application: ^Browser_Application,
	hosted_config: alicorn.Hosted_Runtime_Config,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	canvas_id: string,
	platform: Browser_Platform,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	text_input_id: string = "",
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> Browser_Application_Result {
	if application == nil || application.initialized || hosted_config.render == nil ||
	   surface == nil || device == nil || queue == nil || wake == nil ||
	   !browser_application_id_is_safe(canvas_id) ||
	   (text_input_id != "" && (!browser_application_id_is_safe(text_input_id) || text_input_id == canvas_id)) ||
	   configuration.format == .Undefined {
		return .Invalid_Input
	}
	rect := js.get_bounding_client_rect(canvas_id)
	dpi := max(js.device_pixel_ratio(), 0.01)
	logical_width, logical_height := max(1, int(rect.width)), max(1, int(rect.height))
	pixel_width, pixel_height := max(1, int(rect.width*dpi)), max(1, int(rect.height*dpi))
	surface_configuration := configuration
	surface_configuration.width = u32(pixel_width)
	surface_configuration.height = u32(pixel_height)
	js.set_element_key_f64(canvas_id, "width", f64(pixel_width))
	js.set_element_key_f64(canvas_id, "height", f64(pixel_height))
	application^ = Browser_Application{
		surface=surface,
		device=device,
		queue=queue,
		configuration=surface_configuration,
		canvas_id=canvas_id,
		text_input_id=text_input_id,
		wake_data=wake_data,
		wake=wake,
	}
	config := hosted_config
	config.logical_width, config.logical_height = logical_width, logical_height
	config.pixel_width, config.pixel_height = pixel_width, pixel_height
	config.dpi_scale = f32(dpi)
	config.post_wake_data = rawptr(application)
	config.post_wake = browser_application_post_wake
	if status := alicorn.hosted_runtime_init(&application.hosted, config); status != .Ok {
		application^ = {}
		return .Runtime_Failure
	}
	if result := browser_surface_presenter_init(
		&application.presenter,
		&application.hosted,
		surface,
		device,
		queue,
		surface_configuration,
		logical_width,
		logical_height,
		f32(dpi),
		rawptr(application),
		browser_application_wake,
		clear_color,
	); result != .Ok {
		_ = alicorn.hosted_runtime_destroy(&application.hosted)
		application^ = {}
		return .Presenter_Failure
	}
	if !browser_input_install(
		&application.input,
		&application.hosted,
		canvas_id,
		platform,
		rawptr(application),
		browser_application_wake,
		rawptr(application),
		browser_application_visibility_changed,
		text_input_id,
	) {
		_ = browser_surface_presenter_destroy(&application.presenter)
		_ = alicorn.hosted_runtime_destroy(&application.hosted)
		application^ = {}
		return .Input_Failure
	}
	application.initialized = true
	return .Ok
}

@(private)
browser_application_wake :: proc(data: rawptr) {
	application := cast(^Browser_Application)data
	if application != nil && application.wake != nil { application.wake(application.wake_data) }
}

browser_application_visibility_changed :: proc(data: rawptr, visible: bool) {
	application := cast(^Browser_Application)data
	if application == nil || !application.initialized { return }
	if result := browser_surface_presenter_set_visible(&application.presenter, visible); result != .Ok {
		return
	}
}

// Resize from current CSS dimensions. Zero-sized canvases suspend presentation
// without configuring an invalid WebGPU surface; restoring size wakes the host.
browser_application_resize :: proc(application: ^Browser_Application) -> Browser_Surface_Result {
	if application == nil || !application.initialized { return .Invalid_Input }
	rect := js.get_bounding_client_rect(application.canvas_id)
	dpi := max(js.device_pixel_ratio(), 0.01)
	logical_width, logical_height := max(0, int(rect.width)), max(0, int(rect.height))
	pixel_width, pixel_height := max(0, int(rect.width*dpi)), max(0, int(rect.height*dpi))
	js.set_element_key_f64(application.canvas_id, "width", f64(max(pixel_width, 1)))
	js.set_element_key_f64(application.canvas_id, "height", f64(max(pixel_height, 1)))
	application.configuration.width = u32(max(pixel_width, 1))
	application.configuration.height = u32(max(pixel_height, 1))
	return browser_surface_presenter_resize(
		&application.presenter,
		logical_width,
		logical_height,
		pixel_width,
		pixel_height,
		f32(dpi),
	)
}

// Step the retained Runtime and perform at most one presentation attempt. The
// caller passes next_wake_ns and has_more_work to its demand-driven scheduler.
browser_application_step :: proc(application: ^Browser_Application, now_ns: u64) -> Browser_Application_Step {
	if application == nil || !application.initialized {
		return Browser_Application_Step{status=.Closed, presentation=.Invalid_Input}
	}
	step, presentation := browser_surface_presenter_step(&application.presenter, now_ns)
	if step.status != .Ok {
		return Browser_Application_Step{status=step.status, presentation=presentation}
	}
	application.next_wake_ns = step.next_wake_ns
	if presentation == .Retry_Later {
		retry_ns := now_ns + 16_666_667
		if application.next_wake_ns == 0 || retry_ns < application.next_wake_ns {
			application.next_wake_ns = retry_ns
		}
	}
	browser_input_update_text_input_area(&application.input)
	return Browser_Application_Step{
		status=.Ok,
		presentation=presentation,
		has_more_work=step.has_more_work,
		next_wake_ns=application.next_wake_ns,
	}
}

// Destroy is nonblocking. Input detaches immediately; return false while GPU
// submissions remain in flight, and call again after the completion wake.
browser_application_destroy :: proc(application: ^Browser_Application) -> bool {
	if application == nil { return false }
	if !application.initialized { return true }
	if !application.input_detached {
		browser_input_detach(&application.input)
		application.input_detached = true
	}
	if !browser_surface_presenter_destroy(&application.presenter) { return false }
	if alicorn.hosted_runtime_destroy(&application.hosted) != .Ok { return false }
	application^ = {}
	return true
}
