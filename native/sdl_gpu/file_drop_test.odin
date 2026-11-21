package alicorn_sdl_gpu

// End-to-end SDL file-drop routing for the reference host. The hosted SDL3
// fixture covers the same capability in host/sdl3/application_test.odin; both
// push a real SDL_EVENT_DROP_FILE through SDL's queue and assert the
// application callback receives the exact path.

import "core:sync"
import "core:testing"
import alicorn "../../runtime"
import "vendor:sdl3"

File_Drop_Test_State :: struct {
	drops: int,
	path:  string,
}

file_drop_test_callback :: proc(data: rawptr, _rt: ^alicorn.Runtime, path: string) {
	state := cast(^File_Drop_Test_State)data
	state.drops += 1
	state.path = path
}

@(test)
test_native_drop_file_event_reaches_application_with_the_exact_path :: proc(t: ^testing.T) {
	// SDL's event queue is process-global. Serialize with the other synthetic
	// event tests so one test cannot quit the event subsystem or drain another
	// test's queued wake/drop event while it runs.
	sync.mutex_lock(&native_sdl_event_test_mutex)
	defer sync.mutex_unlock(&native_sdl_event_test_mutex)
	if !sdl3.InitSubSystem(sdl3.INIT_EVENTS) {
		testing.expect(t, false, "SDL event subsystem must initialize for the native file-drop test")
		return
	}
	defer sdl3.QuitSubSystem(sdl3.INIT_EVENTS)

	state: File_Drop_Test_State
	application := Application{state=rawptr(&state), on_file_drop=file_drop_test_callback}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	rt.invalidated = false

	drop_path := "C:/alicorn/native-drop.txt"
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

	quit := false
	logical_resize_events, pixel_resize_events, scale_events: int
	text_input_events, composition_events: int
	app_text := ""
	metrics := Window_Metrics{}
	pump_events(
		nil, &rt, &metrics, &quit,
		&logical_resize_events, &pixel_resize_events, &scale_events,
		&text_input_events, &composition_events, &app_text,
		application=&application,
	)

	testing.expect(t, state.drops == 1 && state.path == drop_path,
		"SDL_EVENT_DROP_FILE pushed through SDL's queue reaches Application.on_file_drop with the exact borrowed path")
	testing.expect(t, rt.invalidated,
		"a native file drop invalidates the retained application description")
}
