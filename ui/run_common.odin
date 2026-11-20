package ui

import alicorn "alicorn:runtime"

// Hosted_Run_State contains the application description shared by platform
// hosts. Keeping this independent of native/sdl_gpu lets compile-time host
// adapters reuse the exact same root and overlay composition. Opt-in host
// packages such as alicorn:ui/webgpu construct this value directly so the
// default SDL_GPU path never imports their WebGPU code.
Hosted_Run_State :: struct($T: typeid) {
	app: ^T,
	render: proc(^T, ^UI),
	render_overlays: proc(^T, ^UI),
	on_initialize: proc(^T, ^alicorn.Runtime),
	on_services: proc(^T, UI_Host_Services),
	host_services: UI_Host_Services,
	on_start: proc(^T, Application_Waker),
	on_wake: proc(^T, Application_Context),
	on_stop: proc(^T),
	on_key: proc(^T, ^alicorn.Runtime, alicorn.Application_Key) -> bool,
	on_text_change: proc(^T, ^alicorn.Runtime, alicorn.Text_Change),
	on_text_key: proc(^T, ^alicorn.Runtime, Node_ID, alicorn.Application_Text_Key_Event) -> bool,
	on_pointer: proc(^T, ^alicorn.Runtime, alicorn.Pointer_Event, Node_ID),
	on_drag: proc(^T, ^alicorn.Runtime, alicorn.Drag_Event),
	on_scroll_capture: proc(^T, ^alicorn.Runtime, alicorn.Scroll_Event, Node_ID) -> bool,
	on_scroll: proc(^T, ^alicorn.Runtime, alicorn.Scroll_Event),
	on_text_input: proc(^T, ^alicorn.Runtime, Node_ID, alicorn.Hosted_Text_Input_Event),
	on_scheduled_wake: proc(^T, ^alicorn.Runtime),
	on_menu_command: proc(^T, ^alicorn.Runtime, alicorn.Action_ID),
	on_close_requested: proc(^T, ^alicorn.Runtime) -> alicorn.Hosted_Close_Result,
	on_dialog: proc(^T, ^alicorn.Runtime, ^alicorn.File_Dialog_Result),
	hosted_waker: alicorn.Hosted_Waker,
}

@(private)
run_describe :: proc(state: ^Hosted_Run_State($T), ctx: ^UI) -> alicorn.Node_ID {
	root := alicorn.container_begin(
		ctx,
		.Root,
		label="ui-root",
		key="alicorn.ui.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root == 0 { return 0 }
	state.render(state.app, ctx)
	alicorn.container_end(ctx)
	if state.render_overlays != nil { state.render_overlays(state.app, ctx) }
	return root
}

@(private)
run_application_key :: proc(state: ^Hosted_Run_State($T), rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	return state != nil && state.on_key != nil && state.on_key(state.app, rt, key)
}

@(private)
run_hosted_wake :: proc(data: rawptr) {
	if data == nil { return }
	waker := cast(^alicorn.Hosted_Waker)data
	alicorn.hosted_waker_notify(waker^)
}

@(private)
run_hosted_unused_post_wake :: proc(_data: rawptr) -> bool {
	// The native coordinator replaces this callback with an SDL user event.
	return true
}

// run_hosted_config adapts the target-neutral ui.run description and lifecycle
// hooks to an embedding host's Hosted_Runtime. The caller owns both the config
// inputs and Hosted_Run_State lifetime; Hosted_Run_State must remain valid until
// hosted_runtime_destroy returns. A host that translates an event into
// Alicorn's key vocabulary calls hosted_runtime_application_key; this adapter
// then receives the opaque Hosted_Key_Event and converts the built-in host's
// ordinal key_code for the ui.run on_key callback.
run_hosted_config :: proc(
	run_state: ^Hosted_Run_State($T),
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
	post_wake_data: rawptr,
	post_wake: alicorn.Hosted_Post_Wake_Proc,
	runtime_config: alicorn.Runtime_Config = {},
) -> alicorn.Hosted_Runtime_Config {
	if run_state == nil || run_state.render == nil || post_wake == nil { return {} }

	describe :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
		state := cast(^Hosted_Run_State(T))data
		state.render(state.app, ctx)
	}
	describe_overlays :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
		state := cast(^Hosted_Run_State(T))data
		if state.render_overlays != nil { state.render_overlays(state.app, ctx) }
	}
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_initialize != nil { state.on_initialize(state.app, rt) }
	}
	start :: proc(data: rawptr, waker: alicorn.Hosted_Waker) {
		state := cast(^Hosted_Run_State(T))data
		state.hosted_waker = waker
		if state.on_services != nil { state.on_services(state.app, state.host_services) }
		if state.on_start != nil {
			state.on_start(state.app, Application_Waker{data=rawptr(&state.hosted_waker), wake=run_hosted_wake})
		}
	}
	wake :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_wake != nil { state.on_wake(state.app, Application_Context(rt)) }
	}
	stop :: proc(data: rawptr) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_stop != nil { state.on_stop(state.app) }
	}
	key :: proc(data: rawptr, rt: ^alicorn.Runtime, _owner: Node_ID, event: alicorn.Hosted_Key_Event) -> bool {
		// The built-in native host maps each Application_Key to its ordinal
		// before the typed hosted_runtime_application_key call. External hosts
		// keep key_code opaque and dispatch it through their own on_key policy.
		if !event.pressed || event.key_code > u32(alicorn.Application_Key.Return) { return false }
		return run_application_key(cast(^Hosted_Run_State(T))data, rt, alicorn.Application_Key(event.key_code))
	}
	text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_text_change != nil { state.on_text_change(state.app, rt, change) }
	}
	text_key :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		owner: alicorn.Node_ID,
		event: alicorn.Application_Text_Key_Event,
	) -> bool {
		state := cast(^Hosted_Run_State(T))data
		return state.on_text_key != nil && state.on_text_key(state.app, rt, owner, event)
	}
	pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: Node_ID) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_pointer != nil { state.on_pointer(state.app, rt, event, target) }
	}
	drag :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_drag != nil { state.on_drag(state.app, rt, event) }
	}
	scroll_capture :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		event: alicorn.Scroll_Event,
		target: Node_ID,
	) -> bool {
		state := cast(^Hosted_Run_State(T))data
		return state.on_scroll_capture != nil && state.on_scroll_capture(state.app, rt, event, target)
	}
	scroll :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_scroll != nil { state.on_scroll(state.app, rt, event) }
	}
	text_input :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		owner: Node_ID,
		event: alicorn.Hosted_Text_Input_Event,
	) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_text_input != nil { state.on_text_input(state.app, rt, owner, event) }
	}
	scheduled_wake :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_scheduled_wake != nil { state.on_scheduled_wake(state.app, rt) }
	}
	menu_command :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_menu_command != nil { state.on_menu_command(state.app, rt, command) }
	}
	close_requested :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result {
		state := cast(^Hosted_Run_State(T))data
		if state.on_close_requested != nil { return state.on_close_requested(state.app, rt) }
		return .Allow
	}
	dialog :: proc(data: rawptr, rt: ^alicorn.Runtime, result: ^alicorn.File_Dialog_Result) {
		state := cast(^Hosted_Run_State(T))data
		if state.on_dialog != nil { state.on_dialog(state.app, rt, result) }
	}
	host_services :: proc(data: rawptr, services: alicorn.Hosted_Host_Services) {
		state := cast(^Hosted_Run_State(T))data
		state.host_services.windows = services.windows
		state.host_services.dialogs = services.dialogs
		state.host_services.quit = services.quit
	}

	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(run_state),
		logical_width=logical_width,
		logical_height=logical_height,
		pixel_width=pixel_width,
		pixel_height=pixel_height,
		dpi_scale=dpi_scale,
		runtime=runtime_config,
		on_host_services=host_services,
		post_wake_data=post_wake_data,
		post_wake=post_wake,
		render=describe,
	}
	if run_state.on_initialize != nil { config.on_initialize = initialize }
	if run_state.on_services != nil || run_state.on_start != nil { config.on_start = start }
	if run_state.on_wake != nil { config.on_wake = wake }
	if run_state.on_stop != nil { config.on_stop = stop }
	if run_state.on_key != nil { config.on_key = key }
	if run_state.on_text_change != nil { config.on_text_change = text_change }
	if run_state.on_text_key != nil { config.on_text_key = text_key }
	if run_state.on_pointer != nil { config.on_pointer = pointer }
	if run_state.on_drag != nil { config.on_drag = drag }
	if run_state.on_scroll_capture != nil { config.on_scroll_capture = scroll_capture }
	if run_state.on_scroll != nil { config.on_scroll = scroll }
	if run_state.on_text_input != nil { config.on_text_input = text_input }
	if run_state.on_scheduled_wake != nil { config.on_scheduled_wake = scheduled_wake }
	if run_state.on_menu_command != nil { config.on_menu_command = menu_command }
	if run_state.on_close_requested != nil { config.on_close_requested = close_requested }
	if run_state.on_dialog != nil { config.on_dialog = dialog }
	if run_state.render_overlays != nil { config.render_overlays = describe_overlays }
	return config
}
