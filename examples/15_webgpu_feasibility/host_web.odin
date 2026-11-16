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
	application: browser_host_api.Browser_Application,
	app: Browser_Feasibility_App,
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

browser_host_init :: proc() {
	if browser_host_runtime.application.initialized { return }
	if !browser_host_runtime.app.field.initialized {
		field, ok := alicorn.text_field_buffer_init("Type into this retained text field", context.allocator)
		if !ok { fmt.panicf("browser hosted fixture could not allocate text buffer") }
		browser_host_runtime.app.field = field
	}
	host_config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&browser_host_runtime.app),
		render=browser_host_app_render,
		on_initialize=browser_host_app_initialize,
	}
	if result := browser_host_api.browser_application_init(
		&browser_host_runtime.application,
		host_config,
		state.surface,
		state.device,
		state.queue,
		state.config,
		"wgpu-canvas",
		.Other,
		rawptr(&browser_host_runtime),
		browser_host_surface_wake,
		"wgpu-text-input",
	); result != .Ok {
		fmt.panicf("browser Hosted_Runtime application initialization failed: %v", result)
	}
	fmt.println("[webgpu-feasibility] Hosted_Runtime, browser input, and canvas presenter connected")
}

browser_host_resize :: proc() {
	result := browser_host_api.browser_application_resize(&browser_host_runtime.application)
	state.width, state.height = os_get_framebuffer_size()
	state.config.width, state.config.height = max(state.width, 1), max(state.height, 1)
	if result == .Invalid_Input || result == .Resource_Failure || result == .Render_Failure {
		fmt.eprintln("[webgpu-feasibility] browser Hosted_Runtime resize failed:", result)
	}
}

browser_host_step :: proc(now_ns: u64) -> bool {
	step := browser_host_api.browser_application_step(&browser_host_runtime.application, now_ns)
	if step.status != .Ok {
		fmt.eprintln("[webgpu-feasibility] browser Hosted_Runtime step failed:", step.status)
		return false
	}
	if step.presentation == .Invalid_Input || step.presentation == .Resource_Failure ||
	   step.presentation == .Render_Failure || step.presentation == .Surface_Acquire_Failure ||
	   step.presentation == .Present_Failure {
		fmt.eprintln("[webgpu-feasibility] browser canvas presentation failed:", step.presentation)
		return false
	}
	return step.has_more_work
}

@(export)
browser_host_next_wake_ns :: proc() -> u64 {
	context = state.ctx
	return browser_host_runtime.application.next_wake_ns
}

@(export)
browser_host_shutdown :: proc() {
	context = state.ctx
	if browser_host_runtime.application.initialized {
		if !browser_host_api.browser_application_destroy(&browser_host_runtime.application) {
			// Page teardown may stop delivering GPU completion callbacks. Keep the
			// Runtime and presenter state alive until the WASM instance is reclaimed.
			fmt.println("[webgpu-feasibility] page teardown deferred presenter destruction with work in flight")
			return
		}
		alicorn.text_field_buffer_destroy(&browser_host_runtime.app.field)
	}
}

@(private="file", fini)
os_fini :: proc "contextless" () {
	context=runtime.default_context()
	finish()
}
