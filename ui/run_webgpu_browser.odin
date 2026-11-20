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
// on_services runs before on_start. Browser clipboard read/write requests use
// the Clipboard API and complete asynchronously after browser permission checks.
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
	on_services: proc(^T, UI_Host_Services) = nil,
	on_drag: proc(^T, ^alicorn.Runtime, alicorn.Drag_Event) = nil,
	on_scroll_capture: proc(^T, ^alicorn.Runtime, alicorn.Scroll_Event, Node_ID) -> bool = nil,
	on_scroll: proc(^T, ^alicorn.Runtime, alicorn.Scroll_Event) = nil,
	on_text_input: proc(^T, ^alicorn.Runtime, Node_ID, alicorn.Hosted_Text_Input_Event) = nil,
	on_scheduled_wake: proc(^T, ^alicorn.Runtime, alicorn.Scheduled_Wake_Class) = nil,
	// Browser hosts can deliver ticks and scheduled wakes. File drops have no
	// canvas event in this slice, so on_file_drop is accepted for compile parity
	// and recorded by the browser policy without being invoked.
	on_file_drop: proc(^T, ^alicorn.Runtime, string) = nil,
	on_tick: proc(^T, ^alicorn.Runtime) = nil,
	interaction_update_policy: alicorn.Interaction_Update_Policy = .Correct_After_Interaction,
	// Native menus are not implemented in the browser host yet; these fields
	// keep the ui.run surface identical so hosted applications compile on both
	// targets. Browser acceleration and menu presentation remain TODO.
	menus: []alicorn.Menu = nil,
	menu_presentation: alicorn.Menu_Presentation = .Labels,
	on_menu_command: proc(^T, ^alicorn.Runtime, alicorn.Action_ID) = nil,
	on_close_requested: proc(^T, ^alicorn.Runtime) -> alicorn.Hosted_Close_Result = nil,
	on_dialog: proc(^T, ^alicorn.Runtime, ^alicorn.File_Dialog_Result) = nil,
	// The browser host records decoration and chrome policy so hosted
	// applications keep one ui.run surface. The canvas has no native chrome
	// band; browser titlebar integration remains outside scope.
	window_decorations: alicorn.Window_Decoration_Mode = .System,
	window_chrome_height: f32 = 0,
	window_chrome_metrics: alicorn.Window_Chrome_Metrics_Proc = nil,
	window_chrome_layout: alicorn.Window_Chrome_Layout_Proc = nil,
	window_chrome_appearance: alicorn.Window_Chrome_Appearance_Proc = nil,
	on_after_frame: proc(^T, ^alicorn.Runtime) = nil,
) {
	_ = title
	_ = smoke
	_ = window_chrome_height
	_ = window_chrome_metrics
	_ = window_chrome_layout
	_ = window_chrome_appearance
	if browser_ui_run.run_state != nil || state == nil || render == nil || width <= 0 || height <= 0 {
		panic("ui.run requires one live application, a valid state pointer, and a render callback")
	}
	js.set_document_title(title)
	run_state := new(Hosted_Run_State(T), allocator=context.allocator)
	if run_state == nil { panic("ui.run could not allocate persistent browser callback state") }
	run_state^ = Hosted_Run_State(T){
		app=state,
		render=render,
		render_overlays=render_overlays,
		menus=menus,
		menu_presentation=menu_presentation,
		window_decorations=window_decorations,
		interaction_update_policy=interaction_update_policy,
		on_initialize=on_initialize,
		on_start=on_start,
		on_wake=on_wake,
		on_stop=on_stop,
		on_key=on_key,
		on_text_change=on_text_change,
		on_text_key=on_text_key,
		on_pointer=on_pointer,
		on_services=on_services,
		on_drag=on_drag, on_scroll_capture=on_scroll_capture, on_scroll=on_scroll,
		on_text_input=on_text_input, on_scheduled_wake=on_scheduled_wake,
		on_file_drop=on_file_drop, on_tick=on_tick,
		on_after_frame=on_after_frame,
		on_menu_command=on_menu_command, on_close_requested=on_close_requested,
		on_dialog=on_dialog,
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
		app := cast(^Hosted_Run_State(T))data
		if app.on_initialize != nil { app.on_initialize(app.app, rt) }
		if !alicorn.text_engine_load_default_fonts(rt) {
			panic("Alicorn's bundled UI fonts could not be initialized in the browser")
		}
	}
	hosted.on_initialize = initialize
	browser_ui_run = Browser_UI_Run{
		run_state=rawptr(run_state),
	}
	start_result := host.browser_webgpu_run_start(
		&browser_ui_run.runner,
		hosted,
		"alicorn-canvas",
		.Other,
		rawptr(&browser_ui_run),
		browser_ui_run_wake,
		"alicorn-text-input",
		"alicorn-accessibility",
	)
	if start_result != .Ok {
		// Instance/surface creation failures are reported through the same
		// browser status channel as asynchronous adapter/device failures.
		if start_result == .Resource_Failure { return }
		panic("ui.run could not start the browser WebGPU host")
	}
	// TODO(issue 211): the browser host has no file-dialog or quit service in
	// this slice. UI_Host_Services.dialogs stays empty so ui_dialog_show_file
	// reports false; add a <input type=file> bridge when browser dialogs are in
	// scope. on_close_requested is also not delivered because the page owns the
	// unload lifecycle.
	run_state.host_services = UI_Host_Services{
		clipboard=host.browser_webgpu_run_clipboard_service(&browser_ui_run.runner),
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
alicorn_browser_failure_code :: proc() -> i32 {
	return i32(host.browser_webgpu_run_failure(&browser_ui_run.runner))
}

@(export)
alicorn_browser_resize :: proc() -> i32 {
	result := host.browser_webgpu_run_resize(&browser_ui_run.runner)
	return i32(result)
}

@(export)
alicorn_browser_clipboard_read_buffer :: proc(token: u32, byte_length: u32) -> u32 {
	return host.browser_webgpu_run_clipboard_read_buffer(&browser_ui_run.runner, token, byte_length)
}

@(export)
alicorn_browser_clipboard_complete :: proc(token: u32, result_code: u32, byte_length: u32) {
	host.browser_webgpu_run_clipboard_complete(&browser_ui_run.runner, token, result_code, byte_length)
}

// Shutdown can return false while initialization callbacks or submitted GPU
// frames remain pending. The scheduler will retry after the host wakes it.
@(export)
alicorn_browser_shutdown :: proc() -> bool {
	if browser_ui_run.run_state == nil { return true }
	browser_ui_run.shutting_down = true
	return browser_ui_run_finish_shutdown()
}
