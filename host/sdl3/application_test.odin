#+build !js

package sdl3_host

import "core:testing"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

SDL3_WebGPU_Application_Wake_Test_State :: struct {
	waker: alicorn.Hosted_Waker,
	wake_count: int,
	close_requests: int,
	close_result: alicorn.Hosted_Close_Result,
}

sdl3_webgpu_application_wake_test_close :: proc(
	data: rawptr,
	_rt: ^alicorn.Runtime,
) -> alicorn.Hosted_Close_Result {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.close_requests += 1
	return state.close_result
}

sdl3_webgpu_application_wake_test_render :: proc(
	_data: rawptr,
	_ui: ^alicorn.UI,
	_width, _height: int,
	_dpi: f32,
) {}

sdl3_webgpu_application_wake_test_start :: proc(data: rawptr, waker: alicorn.Hosted_Waker) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.waker, _ = alicorn.hosted_waker_clone(waker)
}

sdl3_webgpu_application_wake_test_on_wake :: proc(data: rawptr, _rt: ^alicorn.Runtime) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.wake_count += 1
}

@(test)
test_sdl3_webgpu_application_delivers_posted_wake_on_registered_event :: proc(t: ^testing.T) {
	if !sdl3.InitSubSystem(sdl3.INIT_EVENTS) {
		testing.expect(t, false, "SDL event subsystem must initialize for the native wake event test")
		return
	}
	defer sdl3.QuitSubSystem(sdl3.INIT_EVENTS)

	wake_event := sdl3.EventType(sdl3.RegisterEvents(1))
	if wake_event == {} {
		testing.expect(t, false, "SDL must register a user event for Hosted_Waker delivery")
		return
	}
	application := SDL3_WebGPU_Application{
		wake_event_type=wake_event,
		initialized=true,
	}
	state: SDL3_WebGPU_Application_Wake_Test_State
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&state),
		logical_width=160,
		logical_height=100,
		pixel_width=160,
		pixel_height=100,
		dpi_scale=1,
		post_wake_data=rawptr(&application),
		post_wake=sdl3_webgpu_application_post_wake,
		render=sdl3_webgpu_application_wake_test_render,
		on_start=sdl3_webgpu_application_wake_test_start,
		on_wake=sdl3_webgpu_application_wake_test_on_wake,
	}
	if status := alicorn.hosted_runtime_init(&application.hosted, config); status != .Ok {
		testing.expect(t, false, "Hosted_Runtime must initialize before the event is posted")
		return
	}
	defer alicorn.hosted_runtime_destroy(&application.hosted)
	defer alicorn.hosted_waker_release(&state.waker)

	posted := alicorn.hosted_waker_notify(state.waker)
	delivery: SDL3_WebGPU_Application_Event_Result
	event: sdl3.Event
	observed := sdl3.PeepEvents(&event, 1, .GETEVENT, wake_event, wake_event) == 1
	if observed {
		delivery = sdl3_webgpu_application_handle_event(&application, event)
	}
	testing.expect(t, posted && observed && delivery == .Wake && state.wake_count == 1,
		"SDL3 consumes the queued Hosted_Waker event and delivers on_wake on the owner thread")
}


@(test)
test_sdl3_webgpu_application_defers_and_allows_window_close :: proc(t: ^testing.T) {
	wake_event := sdl3.EventType(sdl3.RegisterEvents(1))
	if wake_event == {} {
		testing.expect(t, false, "SDL must register a user event for the close-deferral test")
		return
	}
	application := SDL3_WebGPU_Application{
		wake_event_type=wake_event,
		window_id=sdl3.WindowID(77),
		initialized=true,
	}
	state := SDL3_WebGPU_Application_Wake_Test_State{close_result=.Defer}
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&state),
		logical_width=160,
		logical_height=100,
		pixel_width=160,
		pixel_height=100,
		dpi_scale=1,
		post_wake_data=rawptr(&application),
		post_wake=sdl3_webgpu_application_post_wake,
		render=sdl3_webgpu_application_wake_test_render,
		on_close_requested=sdl3_webgpu_application_wake_test_close,
	}
	if status := alicorn.hosted_runtime_init(&application.hosted, config); status != .Ok {
		testing.expect(t, false, "Hosted_Runtime must initialize before the close event")
		return
	}
	defer alicorn.hosted_runtime_destroy(&application.hosted)

	close_event: sdl3.Event
	close_event.type = .WINDOW_CLOSE_REQUESTED
	close_event.window.windowID = sdl3.WindowID(77)
	result := sdl3_webgpu_application_handle_event(&application, close_event)
	testing.expect(t, result == .Close_Deferred && state.close_requests == 1,
		"a deferred close request must not produce Close_Requested")

	state.close_result = .Allow
	result = sdl3_webgpu_application_handle_event(&application, close_event)
	testing.expect(t, result == .Close_Requested && state.close_requests == 2,
		"allowing the second close request must produce Close_Requested")
}