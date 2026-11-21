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
	file_drops: int,
	drop_path: string,
	last_dpi: f32,
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
	data: rawptr,
	_ui: ^alicorn.UI,
	_width, _height: int,
	dpi: f32,
) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	if state != nil { state.last_dpi = dpi }
}

sdl3_webgpu_application_wake_test_start :: proc(data: rawptr, waker: alicorn.Hosted_Waker) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.waker, _ = alicorn.hosted_waker_clone(waker)
}

sdl3_webgpu_application_wake_test_on_wake :: proc(data: rawptr, _rt: ^alicorn.Runtime) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.wake_count += 1
}

sdl3_webgpu_application_wake_test_file_drop :: proc(data: rawptr, _rt: ^alicorn.Runtime, path: string) {
	state := cast(^SDL3_WebGPU_Application_Wake_Test_State)data
	state.file_drops += 1
	state.drop_path = path
}

@(test)
test_sdl3_webgpu_application_routes_drop_file_events :: proc(t: ^testing.T) {
	if !sdl3.InitSubSystem(sdl3.INIT_EVENTS) {
		testing.expect(t, false, "SDL event subsystem must initialize for the file-drop test")
		return
	}
	defer sdl3.QuitSubSystem(sdl3.INIT_EVENTS)
	wake_event := sdl3.EventType(sdl3.RegisterEvents(1))
	if wake_event == {} {
		testing.expect(t, false, "SDL must register the hosted wake event")
		return
	}
	application := SDL3_WebGPU_Application{
		wake_event_type=wake_event,
		initialized=true,
	}
	state := SDL3_WebGPU_Application_Wake_Test_State{}
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
		on_file_drop=sdl3_webgpu_application_wake_test_file_drop,
	}
	if status := alicorn.hosted_runtime_init(&application.hosted, config); status != .Ok {
		testing.expect(t, false, "Hosted_Runtime must initialize before the drop event")
		return
	}
	defer alicorn.hosted_runtime_destroy(&application.hosted)

	drop_path := "C:/alicorn/host-drop.txt"
	path_buffer: [64]u8
	copy(path_buffer[:], drop_path)
	path_buffer[len(drop_path)] = 0
	drop_event: sdl3.Event
	drop_event.type = .DROP_FILE
	drop_event.drop.commonEvent.type = .DROP_FILE
	drop_event.drop.windowID = 0
	drop_event.drop.data = cstring(rawptr(&path_buffer[0]))
	if !sdl3.PushEvent(&drop_event) {
		testing.expect(t, false, "the synthetic SDL drop event must enqueue")
		return
	}
	queued: sdl3.Event
	observed := sdl3.PeepEvents(&queued, 1, .GETEVENT, .DROP_FILE, .DROP_FILE) == 1
	result: SDL3_WebGPU_Application_Event_Result
	if observed {
		result = sdl3_webgpu_application_handle_event(&application, queued)
	}
	step := alicorn.hosted_runtime_step(&application.hosted, 1)
	testing.expect(t, observed && result == .Handled && state.file_drops == 1 &&
		state.drop_path == drop_path,
		"SDL_EVENT_DROP_FILE pushed through SDL's queue reaches the hosted application callback with the exact path")
	testing.expect(t, step.description_built,
		"a routed drop invalidates the hosted application description")
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

// sdl3_webgpu_application_apply_metrics is the measurement adoption that a real
// SDL window event (and a synthetic WM_DPICHANGED harness) feeds. It must keep
// the application-facing display scale separate from the drawable ratio and
// publish both to the presenter/runtime coherently.
@(test)
test_sdl3_webgpu_application_apply_metrics_separates_display_scale_from_drawable_ratio :: proc(t: ^testing.T) {
	application := SDL3_WebGPU_Application{initialized=true, visible=true}
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
	}
	if status := alicorn.hosted_runtime_init(&application.hosted, config); status != .Ok {
		testing.expect(t, false, "Hosted_Runtime must initialize before metric adoption")
		return
	}
	defer alicorn.hosted_runtime_destroy(&application.hosted)

	fallback_density, fallback_scale := sdl3_webgpu_application_window_scales(nil, 0, 0)
	testing.expect(t, fallback_density == 1 && fallback_scale == 1,
		"a windowless test application must fall back to a coherent unit scale")

	result := sdl3_webgpu_application_apply_metrics(&application, 160, 100, 240, 150, 1.5, 1.5)
	testing.expect(t, result == .Ok, "a per-monitor measurement must be accepted")
	testing.expect(t, application.pixel_density == 1.5 && application.display_scale == 1.5 &&
		application.dpi_scale == 1.5,
		"drawable ratio and display scale must both be published when they agree")
	testing.expect(t, application.last_logical_width == 160 && application.last_pixel_width == 240 &&
		application.last_pixel_height == 150,
		"the adopted measurement must be retained for diagnostics")
	_ = alicorn.hosted_runtime_step(&application.hosted, 1)
	rt, _ := alicorn.hosted_runtime_borrow(&application.hosted)
	testing.expect(t, state.last_dpi == 1.5 &&
		rt.presentation_scale_x == 1.5 && rt.presentation_scale_y == 1.5,
		"the application must receive display scale while presentation follows the drawable")

	// A content-scale change without a drawable change is still a description
	// trigger, but the device grid keeps using the drawable ratio.
	result = sdl3_webgpu_application_apply_metrics(&application, 160, 100, 240, 150, 1.5, 1.25)
	testing.expect(t, result == .Ok, "a metadata-only scale change must be accepted")
	testing.expect(t, application.pixel_density == 1.5 && application.display_scale == 1.25,
		"display scale must update independently of the drawable ratio")
	step := alicorn.hosted_runtime_step(&application.hosted, 2)
	rt, _ = alicorn.hosted_runtime_borrow(&application.hosted)
	testing.expect(t, step.description_built && state.last_dpi == 1.25,
		"metadata scale changes must rebuild the description with the new display scale")
	testing.expect(t, rt.presentation_scale_x == 1.5 && rt.presentation_scale_y == 1.5,
		"the presentation scale must not adopt the display value when the drawable ratio differs")

	// Invalid platform values fall back to the drawable ratio rather than
	// publishing a zero or NaN scale into the application description.
	result = sdl3_webgpu_application_apply_metrics(&application, 160, 100, 320, 200, 0, 0)
	testing.expect(t, result == .Ok && application.pixel_density == 2 && application.display_scale == 2,
		"zero platform scales must fall back to the drawable ratio")
}
