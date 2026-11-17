#+build js wasm32

package ui

import "core:sys/wasm/js"
import alicorn "alicorn:runtime"
import host "alicorn:host/web"

@(private)
Browser_UI_Run :: struct {
	runner: host.Browser_WebGPU_Run,
	run_state: rawptr,
	shutting_down: bool,
}

@(private)
browser_ui_run: Browser_UI_Run

// run starts the shared WebGPU browser host and returns while WebGPU device
// setup continues asynchronously. The page must provide a canvas with id
// "alicorn-canvas", a textarea with id "alicorn-text-input", and an optional
// accessibility root with id "alicorn-accessibility". The application state
// pointer must remain valid until alicorn_browser_shutdown reports completion;
// browser applications normally keep it in package-global storage.
run :: proc(
	state: ^$T,
	render: proc(^T, ^UI),
	title: string = "Alicorn",
	width: int = 720,
	height: int = 480,
	render_overlays: proc(^T, ^UI) = nil,
	on_start: proc(^T, Application_Waker) = nil,
	on_wake: proc(^T, Application_Context) = nil,
	on_stop: proc(^T) = nil,
	smoke: bool = false,
	on_initialize: proc(^T, ^alicorn.Runtime) = nil,
	on_key: proc(^T, ^alicorn.Runtime, alicorn.Application_Key) -> bool = nil,
	on_text_change: proc(^T, ^alicorn.Runtime, alicorn.Text_Change) = nil,
	on_pointer: proc(^T, ^alicorn.Runtime, alicorn.Pointer_Event, Node_ID) = nil,
	on_text_key: proc(^T, ^alicorn.Runtime, Node_ID, alicorn.Application_Text_Key_Event) -> bool = nil,
) {
	_ = title
	_ = smoke
	if browser_ui_run.run_state != nil || state == nil || render == nil || width <= 0 || height <= 0 {
		panic("ui.run requires one live application, a valid state pointer, and a render callback")
	}
	js.set_document_title(title)
	run_state := new(Run_State(T), allocator=context.allocator)
	if run_state == nil { panic("ui.run could not allocate persistent browser callback state") }
	run_state^ = Run_State(T){
		app=state,
		render=render,
		render_overlays=render_overlays,
		on_initialize=on_initialize,
		on_start=on_start,
		on_wake=on_wake,
		on_stop=on_stop,
		on_key=on_key,
		on_text_change=on_text_change,
		on_text_key=on_text_key,
		on_pointer=on_pointer,
	}
	hosted := run_hosted_config(
		run_state,
		width,
		height,
		width,
		height,
		1,
		rawptr(run_state),
		run_hosted_unused_post_wake,
	)
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		app := cast(^Run_State(T))data
		if app.on_initialize != nil { app.on_initialize(app.app, rt) }
		if !alicorn.text_engine_load_default_fonts(rt) {
			panic("Alicorn's bundled UI fonts could not be initialized in the browser")
		}
	}
	hosted.on_initialize = initialize
	browser_ui_run = Browser_UI_Run{
		run_state=rawptr(run_state),
	}
	if result := host.browser_webgpu_run_start(
		&browser_ui_run.runner,
		hosted,
		"alicorn-canvas",
		.Other,
		rawptr(&browser_ui_run),
		browser_ui_run_wake,
		"alicorn-text-input",
		"alicorn-accessibility",
	); result != .Ok {
		panic("ui.run could not start the browser WebGPU host")
	}
}

@(private)
browser_ui_run_wake :: proc(_data: rawptr) {
	js.evaluate("window.__alicornDemandScheduler?.wake();")
}

@(private)
browser_ui_run_finish_shutdown :: proc() -> bool {
	if !host.browser_webgpu_run_destroy(&browser_ui_run.runner) { return false }
	return true
}

// alicorn_browser_frame is called by the host page's one-shot frame scheduler.
// It returns true only when another frame is required for active runtime work.
@(export)
alicorn_browser_frame :: proc(now_ns: u64) -> bool {
	if browser_ui_run.run_state == nil { return false }
	if browser_ui_run.shutting_down {
		_ = browser_ui_run_finish_shutdown()
		return false
	}
	status := host.browser_webgpu_run_status(&browser_ui_run.runner)
	if status == .Recovery_Draining || status == .Recovery_Waiting {
		return host.browser_webgpu_run_recovery_step(&browser_ui_run.runner, now_ns)
	}
	if status != .Ready { return false }
	step := host.browser_webgpu_run_step(&browser_ui_run.runner, now_ns)
	return step.status == .Ok && step.has_more_work
}

@(export)
alicorn_browser_next_wake_ns :: proc() -> u64 {
	return host.browser_webgpu_run_next_wake_ns(&browser_ui_run.runner)
}

// 0 = initializing, 1 = ready, 2 = non-recoverable/intentional device loss,
// 3 = shutdown pending, 4 = recovering, -1 = initialization failure,
// -2 = shutdown complete, -3 = bounded recovery exhausted.
@(export)
alicorn_browser_status :: proc() -> i32 {
	switch host.browser_webgpu_run_status(&browser_ui_run.runner) {
	case .Ready:
		return 1
	case .Device_Lost:
		return 2
	case .Recovery_Draining, .Recovery_Waiting, .Recovery_Adapter_Pending, .Recovery_Device_Pending:
		return 4
	case .Recovery_Failed:
		return -3
	case .Failed:
		return -1
	case .Destroying:
		return 3
	case .Destroyed:
		return -2
	case .Uninitialized, .Adapter_Pending, .Device_Pending:
		return 0
	}
	return 0
}

@(export)
alicorn_browser_resize :: proc() -> i32 {
	result := host.browser_webgpu_run_resize(&browser_ui_run.runner)
	return i32(result)
}

// Shutdown can return false while initialization callbacks or submitted GPU
// frames remain pending. The scheduler will retry after the host wakes it.
@(export)
alicorn_browser_shutdown :: proc() -> bool {
	if browser_ui_run.run_state == nil { return true }
	browser_ui_run.shutting_down = true
	return browser_ui_run_finish_shutdown()
}
