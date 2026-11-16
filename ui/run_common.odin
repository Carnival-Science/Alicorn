package ui

import alicorn "alicorn:runtime"

// Run_State contains the application description shared by platform hosts.
// Keeping this independent of native/sdl_gpu lets compile-time host adapters
// reuse the exact same root and overlay composition.
@(private)
Run_State :: struct($T: typeid) {
	app: ^T,
	render: proc(^T, ^UI),
	render_overlays: proc(^T, ^UI),
	on_initialize: proc(^T, ^alicorn.Runtime),
	on_start: proc(^T, Application_Waker),
	on_wake: proc(^T, Application_Context),
	on_stop: proc(^T),
	on_key: proc(^T, ^alicorn.Runtime, alicorn.Application_Key) -> bool,
	on_text_change: proc(^T, ^alicorn.Runtime, alicorn.Text_Change),
	on_pointer: proc(^T, ^alicorn.Runtime, alicorn.Pointer_Event, Node_ID),
	hosted_waker: alicorn.Hosted_Waker,
}

@(private)
run_describe :: proc(state: ^Run_State($T), ctx: ^UI) -> alicorn.Node_ID {
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
run_application_key :: proc(state: ^Run_State($T), rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	return state != nil && state.on_key != nil && state.on_key(state.app, rt, key)
}

@(private)
run_hosted_wake :: proc(data: rawptr) {
	if data == nil { return }
	waker := cast(^alicorn.Hosted_Waker)data
	alicorn.hosted_waker_notify(waker^)
}

// run_hosted_config adapts the target-neutral ui.run description and lifecycle
// hooks to an embedding host's Hosted_Runtime. The caller owns both the config
// inputs and Run_State lifetime; Run_State must remain valid until
// hosted_runtime_destroy returns. A host maps only its application-level keys
// into Application_Key ordinals before calling hosted_runtime_key.
run_hosted_config :: proc(
	run_state: ^Run_State($T),
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
	post_wake_data: rawptr,
	post_wake: alicorn.Hosted_Post_Wake_Proc,
	runtime_config: alicorn.Runtime_Config = {},
) -> alicorn.Hosted_Runtime_Config {
	if run_state == nil || run_state.render == nil || post_wake == nil { return {} }

	describe :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
		state := cast(^Run_State(T))data
		state.render(state.app, ctx)
	}
	describe_overlays :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
		state := cast(^Run_State(T))data
		if state.render_overlays != nil { state.render_overlays(state.app, ctx) }
	}
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Run_State(T))data
		if state.on_initialize != nil { state.on_initialize(state.app, rt) }
	}
	start :: proc(data: rawptr, waker: alicorn.Hosted_Waker) {
		state := cast(^Run_State(T))data
		state.hosted_waker = waker
		if state.on_start != nil {
			state.on_start(state.app, Application_Waker{data=rawptr(&state.hosted_waker), wake=run_hosted_wake})
		}
	}
	wake :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Run_State(T))data
		if state.on_wake != nil { state.on_wake(state.app, Application_Context(rt)) }
	}
	stop :: proc(data: rawptr) {
		state := cast(^Run_State(T))data
		if state.on_stop != nil { state.on_stop(state.app) }
	}
	key :: proc(data: rawptr, rt: ^alicorn.Runtime, _owner: Node_ID, event: alicorn.Hosted_Key_Event) -> bool {
		if !event.pressed || event.key_code > u32(alicorn.Application_Key.Return) { return false }
		return run_application_key(cast(^Run_State(T))data, rt, alicorn.Application_Key(event.key_code))
	}
	text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
		state := cast(^Run_State(T))data
		if state.on_text_change != nil { state.on_text_change(state.app, rt, change) }
	}
	pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: Node_ID) {
		state := cast(^Run_State(T))data
		if state.on_pointer != nil { state.on_pointer(state.app, rt, event, target) }
	}

	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(run_state),
		logical_width=logical_width,
		logical_height=logical_height,
		pixel_width=pixel_width,
		pixel_height=pixel_height,
		dpi_scale=dpi_scale,
		runtime=runtime_config,
		post_wake_data=post_wake_data,
		post_wake=post_wake,
		render=describe,
	}
	if run_state.on_initialize != nil { config.on_initialize = initialize }
	if run_state.on_start != nil { config.on_start = start }
	if run_state.on_wake != nil { config.on_wake = wake }
	if run_state.on_stop != nil { config.on_stop = stop }
	if run_state.on_key != nil { config.on_key = key }
	if run_state.on_text_change != nil { config.on_text_change = text_change }
	if run_state.on_pointer != nil { config.on_pointer = pointer }
	if run_state.render_overlays != nil { config.render_overlays = describe_overlays }
	return config
}
