#+build !js
package ui

import alicorn "alicorn:runtime"
import sdl3_clipboard "alicorn:host/sdl3/clipboard"
import host "alicorn:native/sdl_gpu"

@(private)
run_application :: proc(run_state: ^Hosted_Run_State($T), title: string, width, height: int) -> host.Application {
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
		state.host_services.dialogs = services.dialogs
		state.host_services.quit = services.quit
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
	on_scheduled_wake :: proc(data: rawptr, rt: ^alicorn.Runtime, _class: host.Scheduled_Wake_Class) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_scheduled_wake != nil { state.on_scheduled_wake(state.app, rt) }
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
		interaction_update_policy=.Correct_After_Interaction,
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
	on_scheduled_wake: proc(^T, ^alicorn.Runtime) = nil,
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
		on_initialize=on_initialize, on_start=on_start, on_wake=on_wake, on_stop=on_stop,
		on_key=on_key, on_text_change=on_text_change, on_pointer=on_pointer,
		on_text_key=on_text_key,
		on_services=on_services,
		on_drag=on_drag, on_scroll_capture=on_scroll_capture, on_scroll=on_scroll,
		on_text_input=on_text_input, on_scheduled_wake=on_scheduled_wake,
		on_menu_command=on_menu_command, on_close_requested=on_close_requested,
		on_dialog=on_dialog,
	}
	clipboard_backend: sdl3_clipboard.UI_Clipboard_Backend
	run_state.host_services.clipboard = sdl3_clipboard.UI_Clipboard_Service(&clipboard_backend)
	host.Run(run_application(&run_state, title, width, height), smoke=smoke)
}
