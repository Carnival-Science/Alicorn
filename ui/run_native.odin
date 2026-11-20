#+build !js
package ui

import alicorn "alicorn:runtime"
import sdl3_clipboard "alicorn:host/sdl3/clipboard"
import host "alicorn:native/sdl_gpu"

// Run_Native_Window_Service_Context bridges the hosted secondary-window shape
// onto the reference SDL_GPU host. ui.run exposes Hosted_Window_Service; the
// reference host exposes Application_Window_Service. Both values describe the
// same one-child contract, so the adapter keeps one context for the run.
@(private)
Run_Native_Window_Service_Context :: struct {
	windows: host.Application_Window_Service,
}

// Run_Native_Window_Bridge owns the hosted configuration for one native child
// window. The native Application borrows it as state; it is released after the
// application's on_stop, or by on_open_failed when callbacks never started.
@(private)
Run_Native_Window_Bridge :: struct {
	config:          alicorn.Hosted_Runtime_Config,
	on_open_failed:  alicorn.Hosted_Window_Open_Failed_Proc,
	service_context: ^Run_Native_Window_Service_Context,
}

@(private)
run_native_window_build :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	width, height: int,
	dpi: f32,
) -> alicorn.Node_ID {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil || bridge.config.render == nil { return 0 }
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ctx,
		.Root,
		label="ui-root",
		key="alicorn.ui.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root == 0 {
		alicorn.end_frame(&ctx)
		return 0
	}
	bridge.config.render(bridge.config.state, &ctx, width, height, dpi)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return root
}

@(private)
run_native_window_initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_initialize != nil {
		bridge.config.on_initialize(bridge.config.state, rt)
	}
}

@(private)
run_native_window_start :: proc(data: rawptr, _waker: host.Application_Waker) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil || bridge.config.on_start == nil { return }
	// The reference host owns its own wake transport. A hosted child normally
	// receives a Hosted_Waker from the SDL3/WebGPU host; this adapter cannot
	// manufacture one from the SDL_GPU waker, so the hosted callback receives an
	// empty value. The SDL_GPU reference path does not need it.
	bridge.config.on_start(bridge.config.state, {})
}

@(private)
run_native_window_wake :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_wake != nil {
		bridge.config.on_wake(bridge.config.state, rt)
	}
}

@(private)
run_native_window_scheduled_wake :: proc(data: rawptr, rt: ^alicorn.Runtime, class: host.Scheduled_Wake_Class) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_scheduled_wake != nil {
		bridge.config.on_scheduled_wake(bridge.config.state, rt, alicorn.Scheduled_Wake_Class(class))
	}
}

@(private)
run_native_window_stop :: proc(data: rawptr) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil { return }
	if bridge.config.on_stop != nil { bridge.config.on_stop(bridge.config.state) }
	free(bridge)
}

@(private)
run_native_window_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil || bridge.config.on_key == nil { return false }
	return bridge.config.on_key(
		bridge.config.state,
		rt,
		alicorn.focused_node(rt),
		alicorn.Hosted_Key_Event{key_code=u32(key), pressed=true},
	)
}

@(private)
run_native_window_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_text_change != nil {
		bridge.config.on_text_change(bridge.config.state, rt, change)
	}
}

@(private)
run_native_window_text_key :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	owner: Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	bridge := cast(^Run_Native_Window_Bridge)data
	return bridge != nil && bridge.config.on_text_key != nil &&
		bridge.config.on_text_key(bridge.config.state, rt, owner, event)
}

@(private)
run_native_window_pointer :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	event: alicorn.Pointer_Event,
	target: Node_ID,
) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_pointer != nil {
		bridge.config.on_pointer(bridge.config.state, rt, event, target)
	}
}

@(private)
run_native_window_drag :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_drag != nil {
		bridge.config.on_drag(bridge.config.state, rt, event)
	}
}

@(private)
run_native_window_scroll_capture :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	event: alicorn.Scroll_Event,
	target: Node_ID,
) -> bool {
	bridge := cast(^Run_Native_Window_Bridge)data
	return bridge != nil && bridge.config.on_scroll_capture != nil &&
		bridge.config.on_scroll_capture(bridge.config.state, rt, event, target)
}

@(private)
run_native_window_scroll :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_scroll != nil {
		bridge.config.on_scroll(bridge.config.state, rt, event)
	}
}

@(private)
run_native_window_text_input :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	owner: Node_ID,
	event: alicorn.Application_Text_Input_Event,
) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil || bridge.config.on_text_input == nil { return }
	bridge.config.on_text_input(
		bridge.config.state,
		rt,
		owner,
		alicorn.Hosted_Text_Input_Event{
			kind=alicorn.Hosted_Text_Input_Kind(event.kind),
			text=event.text,
			selection_start_byte=event.selection_start_byte,
			selection_end_byte=event.selection_end_byte,
		},
	)
}

@(private)
run_native_window_menu_command :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_menu_command != nil {
		bridge.config.on_menu_command(bridge.config.state, rt, command)
	}
}

@(private)
run_native_window_close_requested :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
) -> alicorn.Hosted_Close_Result {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_close_requested != nil {
		return bridge.config.on_close_requested(bridge.config.state, rt)
	}
	return .Allow
}

@(private)
run_native_window_dialog :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	result: ^alicorn.File_Dialog_Result,
) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_dialog != nil {
		bridge.config.on_dialog(bridge.config.state, rt, result)
	}
}

@(private)
run_native_window_chrome_metrics :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	metrics: alicorn.Window_Chrome_Metrics,
) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.window_chrome_metrics != nil {
		bridge.config.window_chrome_metrics(bridge.config.state, rt, metrics)
	}
}

@(private)
run_native_window_chrome_layout :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
) -> alicorn.Window_Chrome_Layout {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.window_chrome_layout != nil {
		return bridge.config.window_chrome_layout(bridge.config.state, rt)
	}
	return {}
}

@(private)
run_native_window_chrome_appearance :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
) -> alicorn.Window_Chrome_Appearance {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.window_chrome_appearance != nil {
		return bridge.config.window_chrome_appearance(bridge.config.state, rt)
	}
	return {}
}

@(private)
run_native_window_tick :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_tick != nil {
		bridge.config.on_tick(bridge.config.state, rt)
	}
}

@(private)
run_native_window_file_drop :: proc(data: rawptr, rt: ^alicorn.Runtime, path: string) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge != nil && bridge.config.on_file_drop != nil {
		bridge.config.on_file_drop(bridge.config.state, rt, path)
	}
}

@(private)
run_native_window_services :: proc(data: rawptr, services: host.Application_Services) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil || bridge.config.on_host_services == nil { return }
	ctx := bridge.service_context
	if ctx == nil { return }
	bridge.config.on_host_services(
		bridge.config.state,
		alicorn.Hosted_Host_Services{
			windows=alicorn.Hosted_Window_Service{
				data=rawptr(ctx),
				open=run_native_window_open,
				close=run_native_window_close,
				set_always_on_top=run_native_window_set_always_on_top,
				set_title=run_native_window_set_title,
			},
			dialogs=services.dialogs,
			quit=services.quit,
			clipboard=services.clipboard,
			scheduler=services.scheduler,
		},
	)
}

@(private)
run_native_window_open :: proc(data: rawptr, description: alicorn.Hosted_Window_Description) -> bool {
	ctx := cast(^Run_Native_Window_Service_Context)data
	if ctx == nil || ctx.windows.open == nil || description.config.render == nil { return false }
	bridge := new(Run_Native_Window_Bridge)
	if bridge == nil { return false }
	bridge.config = description.config
	bridge.on_open_failed = description.on_open_failed
	bridge.service_context = ctx
	application := host.Application{
		state=rawptr(bridge),
		title=description.title,
		width=description.width,
		height=description.height,
		menus=description.config.menus,
		menu_presentation=host.Application_Menu_Presentation(description.config.menu_presentation),
		window_decorations=host.Window_Decoration_Mode(description.config.window_decorations),
		window_chrome_height=description.config.window_chrome_height,
		window_chrome_metrics=run_native_window_chrome_metrics,
		window_chrome_layout=run_native_window_chrome_layout,
		window_chrome_appearance=run_native_window_chrome_appearance,
		build=run_native_window_build,
		interaction_update_policy=host.Application_Interaction_Update_Policy(description.config.interaction_update_policy),
	}
	if description.config.on_initialize != nil { application.on_initialize = run_native_window_initialize }
	if description.config.on_host_services != nil { application.on_services = run_native_window_services }
	if description.config.on_file_drop != nil { application.on_file_drop = run_native_window_file_drop }
	if description.config.on_tick != nil { application.on_tick = run_native_window_tick }
	if description.config.on_start != nil { application.on_start = run_native_window_start }
	if description.config.on_wake != nil { application.on_wake = run_native_window_wake }
	if description.config.on_scheduled_wake != nil {
		application.on_scheduled_wake = run_native_window_scheduled_wake
	}
	if description.config.on_stop != nil { application.on_stop = run_native_window_stop }
	if description.config.on_key != nil { application.on_key = run_native_window_key }
	if description.config.on_text_change != nil { application.on_text_change = run_native_window_text_change }
	if description.config.on_text_key != nil { application.on_text_key = run_native_window_text_key }
	if description.config.on_pointer != nil { application.on_pointer = run_native_window_pointer }
	if description.config.on_drag != nil { application.on_drag = run_native_window_drag }
	if description.config.on_scroll_capture != nil {
		application.on_scroll_capture = run_native_window_scroll_capture
	}
	if description.config.on_scroll != nil { application.on_scroll = run_native_window_scroll }
	if description.config.on_text_input != nil { application.on_text_input = run_native_window_text_input }
	if description.config.on_menu_command != nil {
		application.on_menu_command = run_native_window_menu_command
	}
	if description.config.on_close_requested != nil {
		application.on_close_requested = run_native_window_close_requested
	}
	if description.config.on_dialog != nil { application.on_dialog = run_native_window_dialog }
	// on_stop is required to release the bridge even when the application does
	// not install one. It is only invoked after callbacks started.
	if application.on_stop == nil { application.on_stop = run_native_window_stop }
	native_description := host.Application_Window_Description{
		application=application,
		width=description.width,
		height=description.height,
		always_on_top=description.always_on_top,
		on_open_failed=run_native_window_open_failed,
	}
	if !host.application_open_window(ctx.windows, native_description) {
		free(bridge)
		return false
	}
	return true
}

@(private)
run_native_window_open_failed :: proc(data: rawptr) {
	bridge := cast(^Run_Native_Window_Bridge)data
	if bridge == nil { return }
	state := bridge.config.state
	failed := bridge.on_open_failed
	free(bridge)
	if failed != nil { failed(state) }
}

@(private)
run_native_window_close :: proc(data: rawptr) {
	ctx := cast(^Run_Native_Window_Service_Context)data
	if ctx != nil && ctx.windows.close != nil { ctx.windows.close(ctx.windows.data) }
}

@(private)
run_native_window_set_always_on_top :: proc(data: rawptr, always_on_top: bool) -> bool {
	ctx := cast(^Run_Native_Window_Service_Context)data
	return ctx != nil && ctx.windows.set_always_on_top != nil &&
		ctx.windows.set_always_on_top(ctx.windows.data, always_on_top)
}

@(private)
run_native_window_set_title :: proc(data: rawptr, title: string) -> bool {
	ctx := cast(^Run_Native_Window_Service_Context)data
	return ctx != nil && ctx.windows.set_title != nil &&
		ctx.windows.set_title(ctx.windows.data, title)
}

@(private)
run_application :: proc(
	run_state: ^Hosted_Run_State($T),
	title: string,
	width, height: int,
) -> host.Application {
	build :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		_logical_width, _logical_height: int,
		_dpi_scale: f32,
	) -> alicorn.Node_ID {
		ctx, should_build := alicorn.begin_frame(rt)
		if !should_build { return 0 }
		root := run_describe(cast(^Hosted_Run_State(T))data, &ctx)
		alicorn.end_frame(&ctx)
		return root
	}
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		state.on_initialize(state.app, rt)
	}
	start :: proc(data: rawptr, waker: host.Application_Waker) {
		state := cast(^Hosted_Run_State(T))data
		state.on_start(state.app, Application_Waker{data=waker.data, wake=waker.wake})
	}
	on_services :: proc(data: rawptr, services: host.Application_Services) {
		state := cast(^Hosted_Run_State(T))data
		backend := cast(^sdl3_clipboard.UI_Clipboard_Backend)state.host_services.clipboard.data
		if backend != nil { backend.service = services.clipboard }
		service_context := cast(^Run_Native_Window_Service_Context)state.host_services.windows.data
		state.host_services.dialogs = services.dialogs
		state.host_services.quit = services.quit
		state.host_services.clipboard_text = services.clipboard
		state.host_services.scheduler = services.scheduler
		if service_context != nil {
			service_context.windows = services.windows
			state.host_services.windows = alicorn.Hosted_Window_Service{
				data=rawptr(service_context),
				open=run_native_window_open,
				close=run_native_window_close,
				set_always_on_top=run_native_window_set_always_on_top,
				set_title=run_native_window_set_title,
			}
		}
		if state.on_services != nil { state.on_services(state.app, state.host_services) }
	}
	woken :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		state.on_wake(state.app, Application_Context(rt))
	}
	stop :: proc(data: rawptr) {
		state := cast(^Hosted_Run_State(T))data
		state.on_stop(state.app)
	}
	on_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
		state := cast(^Hosted_Run_State(T))data
		return run_application_key(state, rt, key)
	}
	on_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_text_change != nil { state.on_text_change(state.app, rt, change) }
	}
	on_text_key :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		owner: Node_ID,
		event: alicorn.Application_Text_Key_Event,
	) -> bool {
		state := cast(^Hosted_Run_State(T))data
		return state.on_text_key != nil && state.on_text_key(state.app, rt, owner, event)
	}
	on_pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: Node_ID) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_pointer != nil { state.on_pointer(state.app, rt, event, target) }
	}
	on_drag :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_drag != nil { state.on_drag(state.app, rt, event) }
	}
	on_scroll_capture :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		event: alicorn.Scroll_Event,
		target: Node_ID,
	) -> bool {
		state := cast(^Hosted_Run_State(T))data
		return state.on_scroll_capture != nil && state.on_scroll_capture(state.app, rt, event, target)
	}
	on_scroll :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_scroll != nil { state.on_scroll(state.app, rt, event) }
	}
	on_text_input :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		owner: Node_ID,
		event: alicorn.Application_Text_Input_Event,
	) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_text_input != nil {
			state.on_text_input(state.app, rt, owner, alicorn.Hosted_Text_Input_Event{
				kind=alicorn.Hosted_Text_Input_Kind(event.kind),
				text=event.text,
				selection_start_byte=event.selection_start_byte,
				selection_end_byte=event.selection_end_byte,
			})
		}
	}
	on_scheduled_wake :: proc(data: rawptr, rt: ^alicorn.Runtime, class: host.Scheduled_Wake_Class) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_scheduled_wake != nil {
			state.on_scheduled_wake(state.app, rt, alicorn.Scheduled_Wake_Class(class))
		}
	}
	on_file_drop :: proc(data: rawptr, rt: ^alicorn.Runtime, path: string) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_file_drop != nil { state.on_file_drop(state.app, rt, path) }
	}
	on_tick :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_tick != nil { state.on_tick(state.app, rt) }
	}
	on_menu_command :: proc(data: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_menu_command != nil { state.on_menu_command(state.app, rt, command) }
	}
	on_close_requested :: proc(data: rawptr, rt: ^alicorn.Runtime) -> host.Application_Close_Result {
		state := cast(^Hosted_Run_State(T))data
		if state.on_close_requested != nil { return host.Application_Close_Result(state.on_close_requested(state.app, rt)) }
		return .Allow
	}
	on_dialog :: proc(data: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_dialog != nil { state.on_dialog(state.app, rt, result) }
	}
	chrome_metrics :: proc(data: rawptr, rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
		state := cast(^Hosted_Run_State(T))data
		if state.window_chrome_metrics != nil { state.window_chrome_metrics(state.app, rt, metrics) }
	}
	chrome_layout :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
		state := cast(^Hosted_Run_State(T))data
		if state.window_chrome_layout != nil { return state.window_chrome_layout(state.app, rt) }
		return {}
	}
	chrome_appearance :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Appearance {
		state := cast(^Hosted_Run_State(T))data
		if state.window_chrome_appearance != nil { return state.window_chrome_appearance(state.app, rt) }
		return {}
	}

	application := host.Application{
		state=rawptr(run_state),
		title=title,
		width=width,
		height=height,
		menus=run_state.menus,
		menu_presentation=host.Application_Menu_Presentation(run_state.menu_presentation),
		window_decorations=host.Window_Decoration_Mode(run_state.window_decorations),
		window_chrome_height=run_state.window_chrome_height,
		window_chrome_metrics=chrome_metrics,
		window_chrome_layout=chrome_layout,
		window_chrome_appearance=chrome_appearance,
		build=build,
		interaction_update_policy=host.Application_Interaction_Update_Policy(run_state.interaction_update_policy),
	}
	if run_state.on_initialize != nil { application.on_initialize = initialize }
	if run_state.on_services != nil { application.on_services = on_services }
	if run_state.on_start != nil { application.on_start = start }
	if run_state.on_wake != nil { application.on_wake = woken }
	if run_state.on_stop != nil { application.on_stop = stop }
	if run_state.on_key != nil { application.on_key = on_key }
	if run_state.on_text_change != nil { application.on_text_change = on_text_change }
	if run_state.on_text_key != nil { application.on_text_key = on_text_key }
	if run_state.on_pointer != nil { application.on_pointer = on_pointer }
	if run_state.on_drag != nil { application.on_drag = on_drag }
	if run_state.on_scroll_capture != nil { application.on_scroll_capture = on_scroll_capture }
	if run_state.on_scroll != nil { application.on_scroll = on_scroll }
	if run_state.on_text_input != nil { application.on_text_input = on_text_input }
	if run_state.on_file_drop != nil { application.on_file_drop = on_file_drop }
	if run_state.on_tick != nil { application.on_tick = on_tick }
	if run_state.on_scheduled_wake != nil { application.on_scheduled_wake = on_scheduled_wake }
	if run_state.on_menu_command != nil { application.on_menu_command = on_menu_command }
	if run_state.on_close_requested != nil { application.on_close_requested = on_close_requested }
	if run_state.on_dialog != nil { application.on_dialog = on_dialog }
	return application
}

// run borrows state until the synchronous native host returns. Optional hooks
// run on the application thread: on_initialize receives the newly created
// Runtime before the first description (for theme and resource registration);
// on_services supplies host capabilities before on_start, which receives the
// borrowed worker waker;
// on_wake adopts results and explicitly invalidates through its context;
// on_stop stops and joins all producers before the host destroys the waker.
// Rendering uses the same bounded corrective-description policy as host.Run.
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
	on_file_drop: proc(^T, ^alicorn.Runtime, string) = nil,
	on_tick: proc(^T, ^alicorn.Runtime) = nil,
	interaction_update_policy: alicorn.Interaction_Update_Policy = .Correct_After_Interaction,
	menus: []alicorn.Menu = nil,
	menu_presentation: alicorn.Menu_Presentation = .Labels,
	on_menu_command: proc(^T, ^alicorn.Runtime, alicorn.Action_ID) = nil,
	on_close_requested: proc(^T, ^alicorn.Runtime) -> alicorn.Hosted_Close_Result = nil,
	on_dialog: proc(^T, ^alicorn.Runtime, ^alicorn.File_Dialog_Result) = nil,
	window_decorations: alicorn.Window_Decoration_Mode = .System,
	window_chrome_height: f32 = 0,
	window_chrome_metrics: alicorn.Window_Chrome_Metrics_Proc = nil,
	window_chrome_layout: alicorn.Window_Chrome_Layout_Proc = nil,
	window_chrome_appearance: alicorn.Window_Chrome_Appearance_Proc = nil,
) {
	run_state := Hosted_Run_State(T){
		app=state, render=render, render_overlays=render_overlays,
		menus=menus, menu_presentation=menu_presentation,
		window_decorations=window_decorations,
		window_chrome_height=window_chrome_height,
		window_chrome_metrics=window_chrome_metrics,
		window_chrome_layout=window_chrome_layout,
		window_chrome_appearance=window_chrome_appearance,
		interaction_update_policy=interaction_update_policy,
		on_initialize=on_initialize, on_start=on_start, on_wake=on_wake, on_stop=on_stop,
		on_key=on_key, on_text_change=on_text_change, on_pointer=on_pointer,
		on_text_key=on_text_key,
		on_services=on_services,
		on_drag=on_drag, on_scroll_capture=on_scroll_capture, on_scroll=on_scroll,
		on_text_input=on_text_input, on_scheduled_wake=on_scheduled_wake,
		on_file_drop=on_file_drop, on_tick=on_tick,
		on_menu_command=on_menu_command, on_close_requested=on_close_requested,
		on_dialog=on_dialog,
	}
	clipboard_backend: sdl3_clipboard.UI_Clipboard_Backend
	run_state.host_services.clipboard = sdl3_clipboard.UI_Clipboard_Service(&clipboard_backend)
	window_service: Run_Native_Window_Service_Context
	run_state.host_services.windows = alicorn.Hosted_Window_Service{data=rawptr(&window_service)}
	host.Run(run_application(&run_state, title, width, height), smoke=smoke)
}
