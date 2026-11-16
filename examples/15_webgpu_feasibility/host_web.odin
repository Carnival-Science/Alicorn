#+build js
package webgpu_feasibility

import "base:runtime"
import "core:fmt"
import "core:sys/wasm/js"
import "vendor:wgpu"
import alicorn "../../runtime"
import browser_host_api "../../host/web"

Browser_Feasibility_App :: struct {
	button_active: bool,
	field: alicorn.Text_Field_Buffer,
}

browser_host_runtime: struct {
	hosted: alicorn.Hosted_Runtime,
	presenter: browser_host_api.Browser_Surface_Presenter,
	input: browser_host_api.Browser_Input,
	app: Browser_Feasibility_App,
	initialized: bool,
	next_wake_ns: u64,
}

OS :: struct {}

os_requested_backend :: proc() -> (wgpu.BackendType, bool) { return .Undefined, true }
os_init :: proc() {}
os_run :: proc() {}
os_process_gpu_events :: proc() {}
os_exit_failure :: proc() { panic("WebGPU feasibility readback failed") }

os_get_framebuffer_size :: proc()->(width,height:u32) {
	rect:=js.get_bounding_client_rect("wgpu-canvas")
	dpi:=js.device_pixel_ratio()
	return u32(max(f64(1),rect.width*dpi)),u32(max(f64(1),rect.height*dpi))
}
os_set_surface_size :: proc(width,height:u32) {
	js.set_element_key_f64("wgpu-canvas","width",f64(width))
	js.set_element_key_f64("wgpu-canvas","height",f64(height))
}
os_get_surface :: proc(instance:wgpu.Instance)->wgpu.Surface {
	return wgpu.InstanceCreateSurface(instance,&wgpu.SurfaceDescriptor{
		nextInChain=&wgpu.SurfaceSourceCanvasHTMLSelector{sType=.SurfaceSourceCanvasHTMLSelector,selector="#wgpu-canvas"},
	})
}

// The browser fixture shares the production host-side coordinator, input
// bridge, retained Runtime, and WebGPU presenter. Only adapter/device creation
// and canvas acquisition remain in this example's feasibility harness.
browser_host_app_initialize :: proc(_app_state: rawptr, rt: ^alicorn.Runtime) {
	if !alicorn.text_engine_load_font_role(&rt.text_engine, .UI, FONT_DATA) {
		fmt.panicf("browser hosted fixture could not load the bundled UI font")
	}
}

browser_host_app_render :: proc(app_state: rawptr, ui: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	app := cast(^Browser_Feasibility_App)app_state
	alicorn.text(
		ui, "Shared Alicorn WebGPU host",
		key=alicorn.key_string("browser-host-title"),
		style=alicorn.layout_style(.Row, height=38),
		text_style=alicorn.Text_Style{font_size=26},
	)
	alicorn.text(
		ui, "This surface is described by Hosted_Runtime and presented by the shared WebGPU renderer.",
		key=alicorn.key_string("browser-host-description"),
		style=alicorn.layout_style(.Row, height=52),
		text_style=alicorn.Text_Style{font_size=16, overflow=.Wrap},
	)
	if alicorn.button(
		ui, "Activate retained control",
		key=alicorn.key_string("browser-host-button"),
		style=alicorn.layout_style(.Row, width=240, height=44),
	) {
		app.button_active = !app.button_active
	}
	alicorn.text(
		ui,
		"Button input reached the Hosted_Runtime." if app.button_active else "Click the button or edit the field to exercise browser input.",
		key=alicorn.key_string("browser-host-button-state"),
		style=alicorn.layout_style(.Row, height=30),
	)
	_ = alicorn.text_field_controlled(
		ui, &app.field,
		key=alicorn.key_string("browser-host-text-field"),
		style=alicorn.layout_style(.Row, width=460, height=44, padding=8),
	)
}

browser_host_surface_wake :: proc(_data: rawptr) {
	js.evaluate("window.__alicornDemandScheduler?.wake();")
}

browser_host_post_wake :: proc(data: rawptr) -> bool {
	browser_host_surface_wake(data)
	return true
}

browser_host_init :: proc() {
	if browser_host_runtime.initialized { return }
	rect := js.get_bounding_client_rect("wgpu-canvas")
	dpi := f32(max(js.device_pixel_ratio(), 0.01))
	logical_width := max(1, int(rect.width))
	logical_height := max(1, int(rect.height))
	if !browser_host_runtime.app.field.initialized {
		field, ok := alicorn.text_field_buffer_init("Type into this retained text field", context.allocator)
		if !ok { fmt.panicf("browser hosted fixture could not allocate text buffer") }
		browser_host_runtime.app.field = field
	}
	host_config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&browser_host_runtime.app),
		logical_width=logical_width,
		logical_height=logical_height,
		pixel_width=int(state.config.width),
		pixel_height=int(state.config.height),
		dpi_scale=dpi,
		post_wake=browser_host_post_wake,
		render=browser_host_app_render,
		on_initialize=browser_host_app_initialize,
	}
	if status := alicorn.hosted_runtime_init(&browser_host_runtime.hosted, host_config); status != .Ok {
		fmt.panicf("browser Hosted_Runtime initialization failed: %v", status)
	}
	if result := browser_host_api.browser_surface_presenter_init(
		&browser_host_runtime.presenter,
		&browser_host_runtime.hosted,
		state.surface,
		state.device,
		state.queue,
		state.config,
		logical_width,
		logical_height,
		dpi,
		rawptr(&browser_host_runtime),
		browser_host_surface_wake,
	); result != .Ok {
		fmt.panicf("browser Hosted_Runtime surface presenter initialization failed: %v", result)
	}
	if !browser_host_api.browser_input_install(
		&browser_host_runtime.input,
		&browser_host_runtime.hosted,
		"wgpu-canvas",
		.Other,
		rawptr(&browser_host_runtime),
		browser_host_surface_wake,
		rawptr(&browser_host_runtime.presenter),
		browser_host_api.browser_surface_visibility_changed,
	) {
		fmt.panicf("browser Hosted_Runtime input listener installation failed")
	}
	browser_host_runtime.initialized = true
	fmt.println("[webgpu-feasibility] Hosted_Runtime, browser input, and canvas presenter connected")
}

browser_host_resize :: proc() {
	if !browser_host_runtime.initialized { return }
	rect := js.get_bounding_client_rect("wgpu-canvas")
	dpi := max(js.device_pixel_ratio(), 0.01)
	logical_width := max(0, int(rect.width))
	logical_height := max(0, int(rect.height))
	pixel_width := max(0, int(rect.width*dpi))
	pixel_height := max(0, int(rect.height*dpi))
	state.width, state.height = u32(pixel_width), u32(pixel_height)
	os_set_surface_size(state.width, state.height)
	state.config.width, state.config.height = u32(max(1, pixel_width)), u32(max(1, pixel_height))
	result := browser_host_api.browser_surface_presenter_resize(
		&browser_host_runtime.presenter,
		logical_width,
		logical_height,
		pixel_width,
		pixel_height,
		f32(dpi),
	)
	if result != .Ok && result != .Suspended {
		fmt.eprintln("[webgpu-feasibility] browser Hosted_Runtime resize failed:", result)
	}
}

browser_host_step :: proc(now_ns: u64) -> bool {
	if !browser_host_runtime.initialized { return false }
	step, presentation := browser_host_api.browser_surface_presenter_step(
		&browser_host_runtime.presenter,
		now_ns,
	)
	if step.status != .Ok {
		fmt.eprintln("[webgpu-feasibility] browser Hosted_Runtime step failed:", step.status)
		return false
	}
	browser_host_runtime.next_wake_ns = step.next_wake_ns
	if presentation == .Retry_Later {
		retry_ns := now_ns + 16_666_667
		if browser_host_runtime.next_wake_ns == 0 || retry_ns < browser_host_runtime.next_wake_ns {
			browser_host_runtime.next_wake_ns = retry_ns
		}
	}
	if presentation == .Invalid_Input || presentation == .Resource_Failure ||
	   presentation == .Render_Failure || presentation == .Surface_Acquire_Failure ||
	   presentation == .Present_Failure {
		fmt.eprintln("[webgpu-feasibility] browser canvas presentation failed:", presentation)
		return false
	}
	return step.has_more_work
}

@(export)
browser_host_next_wake_ns :: proc() -> u64 {
	context = state.ctx
	return browser_host_runtime.next_wake_ns
}

@(export)
browser_host_shutdown :: proc() {
	context = state.ctx
	if browser_host_runtime.initialized {
		browser_host_api.browser_input_detach(&browser_host_runtime.input)
		if !browser_host_api.browser_surface_presenter_destroy(&browser_host_runtime.presenter) {
			// Page teardown may stop delivering GPU completion callbacks. Keep the
			// Runtime and presenter state alive until the WASM instance is reclaimed.
			fmt.println("[webgpu-feasibility] page teardown deferred presenter destruction with work in flight")
			return
		}
		_ = alicorn.hosted_runtime_destroy(&browser_host_runtime.hosted)
		alicorn.text_field_buffer_destroy(&browser_host_runtime.app.field)
		browser_host_runtime.initialized = false
	}
}

@(private="file", fini)
os_fini :: proc "contextless" () {
	context=runtime.default_context()
	finish()
}
