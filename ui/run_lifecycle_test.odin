#+build !js
package ui

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:testing"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import clipboard "alicorn:host/clipboard"

Run_Wake_Test_Queue :: struct {
	available: sync.Sema,
	live: bool,
	woke_while_live: bool,
	count: int,
}

run_test_enqueue_wake :: proc(data: rawptr) {
	queue := cast(^Run_Wake_Test_Queue)data
	queue.woke_while_live = queue.live
	queue.count += 1
	sync.sema_post(&queue.available)
}

Run_Lifecycle_Test_App :: struct {
	worker: ^thread.Thread,
	release_worker: sync.Sema,
	mutex: sync.Mutex,
	waker: Application_Waker,
	ready: bool,
	result, adopted: int,
	starts, wakes, stops, renders: int,
	initializations: int,
	initialized: bool,
	joined: bool,
	text: Node_ID,
	text_key_events: int,
	text_key_owner: Node_ID,
	last_text_key: alicorn.Application_Text_Navigation_Key,
	host_services: UI_Host_Services,
	service_callbacks: int,
	last_clipboard_request: clipboard.Clipboard_Request_ID,
	clipboard_result: clipboard.Clipboard_Result,
	clipboard_text_matches: bool,
}

Run_Clipboard_Integration_Backend :: struct {
	text: string,
	reads, writes: int,
}

run_clipboard_integration_get :: proc(data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	backend := cast(^Run_Clipboard_Integration_Backend)data
	backend.reads += 1
	cloned, err := strings.clone(backend.text, allocator)
	return cloned, err == nil
}

run_clipboard_integration_set :: proc(data: rawptr, text: string) -> bool {
	backend := cast(^Run_Clipboard_Integration_Backend)data
	backend.writes += 1
	backend.text = text
	return true
}

run_lifecycle_test_services :: proc(app: ^Run_Lifecycle_Test_App, services: UI_Host_Services) {
	app.service_callbacks += 1
	app.host_services = services
}

run_lifecycle_test_clipboard_completion :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	result: clipboard.Clipboard_Result,
	text: string,
) {
	app := cast(^Run_Lifecycle_Test_App)data
	app.last_clipboard_request = request_id
	app.clipboard_result = result
	app.clipboard_text_matches = text == "copied from SDL3"
}

run_lifecycle_test_worker :: proc(data: rawptr) {
	app := cast(^Run_Lifecycle_Test_App)data
	sync.sema_wait(&app.release_worker)
	sync.mutex_lock(&app.mutex)
	app.result = 42
	app.ready = true
	sync.mutex_unlock(&app.mutex)
	wake(app.waker)
}

run_lifecycle_test_start :: proc(app: ^Run_Lifecycle_Test_App, waker: Application_Waker) {
	app.starts += 1
	app.waker = waker
	app.worker = thread.create_and_start_with_data(rawptr(app), run_lifecycle_test_worker)
}

run_lifecycle_test_wake :: proc(app: ^Run_Lifecycle_Test_App, ctx: Application_Context) {
	app.wakes += 1
	sync.mutex_lock(&app.mutex)
	ready, result := app.ready, app.result
	sync.mutex_unlock(&app.mutex)
	if ready && app.adopted != result {
		app.adopted = result
		invalidate(ctx, "adopt test worker completion")
	}
}

run_lifecycle_test_stop :: proc(app: ^Run_Lifecycle_Test_App) {
	app.stops += 1
	if app.worker != nil {
		sync.sema_post(&app.release_worker)
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
		app.joined = true
	}
}

run_lifecycle_test_render :: proc(app: ^Run_Lifecycle_Test_App, ctx: ^UI) {
	app.renders += 1
	app.text = text(ctx, fmt.tprintf("Result: %d", app.adopted))
}

run_lifecycle_test_initialize :: proc(app: ^Run_Lifecycle_Test_App, _rt: ^alicorn.Runtime) {
	app.initializations += 1
	app.initialized = true
}

run_lifecycle_test_text_key :: proc(
	app: ^Run_Lifecycle_Test_App,
	_rt: ^alicorn.Runtime,
	owner: Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app.text_key_events += 1
	app.text_key_owner = owner
	app.last_text_key = event.key
	return event.key == .Line_Start
}

@(test)
test_typed_wake_adopts_result_with_explicit_invalidation_and_returns_to_idle :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 240, 120})
	defer alicorn.destroy_runtime(&rt)
	app := Run_Lifecycle_Test_App{}
	state := Run_State(Run_Lifecycle_Test_App){app=&app, render=run_lifecycle_test_render,
		on_initialize=run_lifecycle_test_initialize,
		on_start=run_lifecycle_test_start, on_wake=run_lifecycle_test_wake, on_stop=run_lifecycle_test_stop}
	application := run_application(&state, "Async test", 240, 120)
	queue := Run_Wake_Test_Queue{live=true}
	testing.expect(t, application.on_initialize != nil,
		"ui.run should forward its typed initialization callback to the native host")
	application.on_initialize(application.state, &rt)
	testing.expect(t, app.initializations == 1 && app.initialized,
		"initialization should run once on the created Runtime before the first description")
	application.on_start(application.state, host.Application_Waker{data=rawptr(&queue), wake=run_test_enqueue_wake})
	defer application.on_stop(application.state)
	if app.worker == nil { testing.expect(t, false, "the app-owned worker must start"); return }
	testing.expect(t, application.build(application.state, &rt, 240, 120, 1) != 0 && app.renders == 1 && app.starts == 1 && app.initialized)
	application.on_wake(application.state, &rt)
	testing.expect(t, application.build(application.state, &rt, 240, 120, 1) == 0 && app.renders == 1,
		"a wake without adopted data must not implicitly invalidate or describe the app")
	sync.sema_post(&app.release_worker)
	if !sync.sema_wait_with_timeout(&queue.available, 5*time.Second) {
		testing.expect(t, false, "the worker must publish and request one host event"); return
	}
	wake_cause := alicorn.cause_begin(&rt, .Async_Wake, "application wake event")
	application.on_wake(application.state, &rt)
	alicorn.cause_end(&rt, wake_cause)
	testing.expect(t, rt.pending_work_cause.id == wake_cause.cause.id,
		"explicit invalidation through the typed context must retain the native wake's causal attribution")
	testing.expect(t, application.build(application.state, &rt, 240, 120, 1) != 0 && app.adopted == 42 && app.renders == 2 && queue.count == 1)
	value, found := alicorn.node_info(&rt, app.text)
	testing.expect(t, found && value.active && rt.nodes[app.text].text == "Result: 42",
		"the first adopted description must contain the worker's completed result")
	before := rt.allocation_stats^
	for _ in 0..<10 {
		testing.expect(t, application.build(application.state, &rt, 240, 120, 1) == 0)
	}
	testing.expect(t, app.renders == 2 && rt.allocation_stats.persistent_alloc_calls == before.persistent_alloc_calls &&
		rt.allocation_stats.scratch_alloc_calls == before.scratch_alloc_calls,
		"after result adoption the bridge must perform no descriptions or allocations while idle")
}

@(test)
test_typed_stop_joins_a_worker_that_wakes_during_shutdown :: proc(t: ^testing.T) {
	app := Run_Lifecycle_Test_App{}
	state := Run_State(Run_Lifecycle_Test_App){app=&app, render=run_lifecycle_test_render,
		on_start=run_lifecycle_test_start, on_stop=run_lifecycle_test_stop}
	application := run_application(&state, "Shutdown test", 240, 120)
	queue := Run_Wake_Test_Queue{live=true}
	application.on_start(application.state, host.Application_Waker{data=rawptr(&queue), wake=run_test_enqueue_wake})
	application.on_stop(application.state)
	queue.live = false // The host retires the borrowed backing state only now.
	testing.expect(t, app.starts == 1 && app.stops == 1 && app.joined && app.worker == nil && queue.count == 1 && queue.woke_while_live,
		"typed shutdown must finish the app-owned join while late producer wakes remain valid")
}

@(test)
test_runner_keeps_optional_hooks_absent_and_preserves_simple_app_policy :: proc(t: ^testing.T) {
	app := Run_Lifecycle_Test_App{}
	state := Run_State(Run_Lifecycle_Test_App){app=&app, render=run_lifecycle_test_render}
	application := run_application(&state, "Simple test", 240, 120)
	testing.expect(t, application.on_initialize == nil && application.on_start == nil && application.on_wake == nil && application.on_stop == nil && application.on_tick == nil && application.on_text_key == nil &&
		application.interaction_update_policy == .Correct_After_Interaction,
		"ordinary ui.run users must retain the existing policy and no polling or synthetic lifecycle callbacks")
	wake(Application_Waker{})
	invalidate(Application_Context(nil))
}

@(test)
test_native_ui_run_forwards_application_owned_text_keys :: proc(t: ^testing.T) {
	app := Run_Lifecycle_Test_App{}
	state := Run_State(Run_Lifecycle_Test_App){app=&app, render=run_lifecycle_test_render,
		on_text_key=run_lifecycle_test_text_key}
	application := run_application(&state, "Editor test", 240, 120)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 240, 120})
	defer alicorn.destroy_runtime(&rt)
	event := alicorn.Application_Text_Key_Event{key=.Line_Start, shift=true}
	handled := application.on_text_key(application.state, &rt, Node_ID(42), event)
	testing.expect(t, application.on_text_key != nil && handled && app.text_key_events == 1 &&
		app.text_key_owner == Node_ID(42) && app.last_text_key == .Line_Start,
		"native ui.run must forward the focused owner and normalized text-key event to app state")
}

@(test)
test_native_ui_run_injects_sdl3_clipboard_service_before_use :: proc(t: ^testing.T) {
	app := Run_Lifecycle_Test_App{}
	backend := Run_Clipboard_Integration_Backend{text="copied from SDL3"}
	sdl3_clipboard: Run_SDL3_Clipboard_Backend
	state := Run_State(Run_Lifecycle_Test_App){
		app=&app,
		render=run_lifecycle_test_render,
		on_services=run_lifecycle_test_services,
		host_services=UI_Host_Services{clipboard=run_sdl3_clipboard_service(&sdl3_clipboard)},
	}
	application := run_application(&state, "Clipboard service test", 240, 120)
	native_services := host.Application_Services{
		clipboard=host.Clipboard_Service{
			data=rawptr(&backend),
			get_text=run_clipboard_integration_get,
			set_text=run_clipboard_integration_set,
		},
	}
	application.on_services(application.state, native_services)
	testing.expect(t, app.service_callbacks == 1 && app.host_services.clipboard.read_text != nil &&
		app.host_services.clipboard.write_text != nil,
		"the native ui.run service callback must expose the SDL3 clipboard capability")
	read_accepted := ui_clipboard_read_text(
		app.host_services.clipboard,
		clipboard.Clipboard_Request_ID(17),
		rawptr(&app),
		run_lifecycle_test_clipboard_completion,
	)
	testing.expect(t, read_accepted && backend.reads == 1 && app.clipboard_result == .Success &&
		app.last_clipboard_request == clipboard.Clipboard_Request_ID(17) && app.clipboard_text_matches,
		"clipboard reads should complete on the owner thread with the request ID and borrowed UTF-8 text")
	write_accepted := ui_clipboard_write_text(
		app.host_services.clipboard,
		clipboard.Clipboard_Request_ID(18),
		"written through ui.run",
		rawptr(&app),
		run_lifecycle_test_clipboard_completion,
	)
	testing.expect(t, write_accepted && backend.writes == 1 && backend.text == "written through ui.run" &&
		app.clipboard_result == .Success && app.last_clipboard_request == clipboard.Clipboard_Request_ID(18),
		"clipboard writes should preserve the app request ID and report synchronous native success")
}
