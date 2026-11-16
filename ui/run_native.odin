#+build !js
package ui

import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"

@(private)
run_application :: proc(run_state: ^Run_State($T), title: string, width, height: int) -> host.Application {
	build :: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		_logical_width, _logical_height: int,
		_dpi_scale: f32,
	) -> alicorn.Node_ID {
		ctx, should_build := alicorn.begin_frame(rt)
		if !should_build { return 0 }
		root := run_describe(cast(^Run_State(T))data, &ctx)
		alicorn.end_frame(&ctx)
		return root
	}
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Run_State(T))data
		state.on_initialize(state.app, rt)
	}
	start :: proc(data: rawptr, waker: host.Application_Waker) {
		state := cast(^Run_State(T))data
		state.on_start(state.app, Application_Waker{data=waker.data, wake=waker.wake})
	}
	woken :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^Run_State(T))data
		state.on_wake(state.app, Application_Context(rt))
	}
	stop :: proc(data: rawptr) {
		state := cast(^Run_State(T))data
		state.on_stop(state.app)
	}
	on_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
		state := cast(^Run_State(T))data
		return state.on_key != nil && state.on_key(state.app, rt, key)
	}
	on_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
		state := cast(^Run_State(T))data
		if state.on_text_change != nil { state.on_text_change(state.app, rt, change) }
	}
	on_pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: Node_ID) {
		state := cast(^Run_State(T))data
		if state.on_pointer != nil { state.on_pointer(state.app, rt, event, target) }
	}

	application := host.Application{
		state=rawptr(run_state),
		title=title,
		width=width,
		height=height,
		build=build,
		interaction_update_policy=.Correct_After_Interaction,
	}
	if run_state.on_initialize != nil { application.on_initialize = initialize }
	if run_state.on_start != nil { application.on_start = start }
	if run_state.on_wake != nil { application.on_wake = woken }
	if run_state.on_stop != nil { application.on_stop = stop }
	if run_state.on_key != nil { application.on_key = on_key }
	if run_state.on_text_change != nil { application.on_text_change = on_text_change }
	if run_state.on_pointer != nil { application.on_pointer = on_pointer }
	return application
}

// run borrows state until the synchronous native host returns. Optional hooks
// run on the application thread: on_initialize receives the newly created
// Runtime before the first description (for theme and resource registration);
// on_start receives the borrowed worker waker;
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
) {
	run_state := Run_State(T){
		app=state, render=render, render_overlays=render_overlays,
		on_initialize=on_initialize, on_start=on_start, on_wake=on_wake, on_stop=on_stop,
		on_key=on_key, on_text_change=on_text_change, on_pointer=on_pointer,
	}
	host.Run(run_application(&run_state, title, width, height), smoke=smoke)
}
