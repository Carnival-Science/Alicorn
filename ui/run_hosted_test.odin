#+build !js
package ui

import "core:mem"
import "core:testing"
import alicorn "alicorn:runtime"
import clipboard "alicorn:host/clipboard"

Run_Hosted_Config_Test_App :: struct {
	waker: Application_Waker,
	renders, initializations, starts, wakes, stops, keys, pointers: int,
	service_calls: int,
	service_available_before_start: bool,
	service_read_available: bool,
	text_key_events: int,
	last_text_key: alicorn.Application_Text_Navigation_Key,
	generic_text_target: Node_ID,
	drag_events, scroll_captures, scroll_events, text_inputs, scheduled, menu_commands: int,
	dialogs, close_requests: int,
	last_menu_command: alicorn.Action_ID,
	last_dialog_status: alicorn.Dialog_Status,
	close_result: alicorn.Hosted_Close_Result,
	scheduler_available: bool,
	clipboard_text_available: bool,
	file_drops: int,
	ticks: int,
}

run_hosted_config_test_render :: proc(app: ^Run_Hosted_Config_Test_App, ctx: ^UI) {
	app.renders += 1
	_ = text(ctx, "Hosted ui.run")
	if app.renders % 2 == 1 {
		app.generic_text_target, _ = alicorn.button_ex(
			ctx, "Editor", key="run-hosted-editor", explicit_key=true,
		)
		_ = alicorn.text_input_target(ctx, app.generic_text_target)
	}
}

run_hosted_config_test_initialize :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime) {
	app.initializations += 1
}

run_hosted_config_test_start :: proc(app: ^Run_Hosted_Config_Test_App, waker: Application_Waker) {
	app.starts += 1
	app.service_available_before_start = app.service_calls == 1
	app.waker = waker
}

run_hosted_config_test_services :: proc(app: ^Run_Hosted_Config_Test_App, services: UI_Host_Services) {
	app.service_calls += 1
	app.service_read_available = services.clipboard.read_text != nil
	app.scheduler_available = services.scheduler.schedule != nil && services.scheduler.cancel != nil
	app.clipboard_text_available = services.clipboard_text.get_text != nil
}

run_hosted_config_test_file_drop :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, _path: string) {
	app.file_drops += 1
}

run_hosted_config_test_tick :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime) {
	app.ticks += 1
}

run_hosted_config_test_clipboard_text_get :: proc(_data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	return "", true
}

run_hosted_config_test_clipboard_text_set :: proc(_data: rawptr, _text: string) -> bool {
	return true
}

run_hosted_config_test_clipboard_read :: proc(	_data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	completion(completion_data, request_id, .Unsupported, "")
	return true
}

run_hosted_config_test_wake :: proc(app: ^Run_Hosted_Config_Test_App, ctx: Application_Context) {
	app.wakes += 1
	invalidate(ctx, "hosted runner test wake")
}

run_hosted_config_test_stop :: proc(app: ^Run_Hosted_Config_Test_App) {
	app.stops += 1
}

run_hosted_config_test_key :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app.keys += 1
	return key == .Find
}

run_hosted_config_test_text_key :: proc(
	app: ^Run_Hosted_Config_Test_App,
	_rt: ^alicorn.Runtime,
	_owner: Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app.text_key_events += 1
	app.last_text_key = event.key
	return true
}

run_hosted_config_test_pointer :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, _event: alicorn.Pointer_Event, _target: Node_ID) {
	app.pointers += 1
}

run_hosted_config_test_drag :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, _event: alicorn.Drag_Event) {
	app.drag_events += 1
}

run_hosted_config_test_scroll_capture :: proc(
	app: ^Run_Hosted_Config_Test_App,
	_rt: ^alicorn.Runtime,
	_event: alicorn.Scroll_Event,
	_target: Node_ID,
) -> bool {
	app.scroll_captures += 1
	return false
}

run_hosted_config_test_scroll :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, _event: alicorn.Scroll_Event) {
	app.scroll_events += 1
}

run_hosted_config_test_text_input :: proc(
	app: ^Run_Hosted_Config_Test_App,
	_rt: ^alicorn.Runtime,
	_owner: Node_ID,
	_event: alicorn.Hosted_Text_Input_Event,
) {
	app.text_inputs += 1
}

run_hosted_config_test_scheduled :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, _class: alicorn.Scheduled_Wake_Class) {
	app.scheduled += 1
}

run_hosted_config_test_menu_command :: proc(app: ^Run_Hosted_Config_Test_App, _rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	app.menu_commands += 1
	app.last_menu_command = command
}

run_hosted_config_test_close_requested :: proc(
	app: ^Run_Hosted_Config_Test_App,
	_rt: ^alicorn.Runtime,
) -> alicorn.Hosted_Close_Result {
	app.close_requests += 1
	return app.close_result
}

run_hosted_config_test_dialog :: proc(
	app: ^Run_Hosted_Config_Test_App,
	_rt: ^alicorn.Runtime,
	result: ^alicorn.File_Dialog_Result,
) {
	app.dialogs += 1
	app.last_dialog_status = result.status
}

Run_Hosted_Config_Test_Wake_Queue :: struct { count: int }

run_hosted_config_test_post_wake :: proc(data: rawptr) -> bool {
	queue := cast(^Run_Hosted_Config_Test_Wake_Queue)data
	queue.count += 1
	return true
}

@(test)
test_shared_ui_run_adapts_to_hosted_runtime :: proc(t: ^testing.T) {
	app := Run_Hosted_Config_Test_App{}
	state := Hosted_Run_State(Run_Hosted_Config_Test_App){
		app=&app,
		render=run_hosted_config_test_render,
		render_overlays=run_hosted_config_test_render,
		on_initialize=run_hosted_config_test_initialize,
		on_services=run_hosted_config_test_services,
		host_services=UI_Host_Services{clipboard=clipboard.Clipboard_Service{read_text=run_hosted_config_test_clipboard_read}},
		on_start=run_hosted_config_test_start,
		on_wake=run_hosted_config_test_wake,
		on_stop=run_hosted_config_test_stop,
		on_key=run_hosted_config_test_key,
		on_text_key=run_hosted_config_test_text_key,
		on_pointer=run_hosted_config_test_pointer,
		on_drag=run_hosted_config_test_drag,
		on_scroll_capture=run_hosted_config_test_scroll_capture,
		on_scroll=run_hosted_config_test_scroll,
		on_text_input=run_hosted_config_test_text_input,
		on_scheduled_wake=run_hosted_config_test_scheduled,
		on_file_drop=run_hosted_config_test_file_drop,
		on_tick=run_hosted_config_test_tick,
		interaction_update_policy=.Correct_After_Interaction,
		on_menu_command=run_hosted_config_test_menu_command,
		on_close_requested=run_hosted_config_test_close_requested,
		on_dialog=run_hosted_config_test_dialog,
	}
	queue := Run_Hosted_Config_Test_Wake_Queue{}
	config := run_hosted_config(&state, 240, 120, 480, 240, 2, rawptr(&queue), run_hosted_config_test_post_wake)
	config.host_services.clipboard = alicorn.Clipboard_Service{
		get_text=run_hosted_config_test_clipboard_text_get,
		set_text=run_hosted_config_test_clipboard_text_set,
	}
	testing.expect(t,
		config.on_drag != nil && config.on_scroll_capture != nil && config.on_scroll != nil &&
		config.on_text_input != nil && config.on_scheduled_wake != nil &&
		config.on_file_drop != nil && config.on_tick != nil &&
		config.interaction_update_policy == .Correct_After_Interaction &&
		config.on_menu_command != nil && config.on_close_requested != nil && config.on_dialog != nil,
		"the shared ui.run adapter should expose every optional hosted callback")
	session: alicorn.Hosted_Runtime
	testing.expect(t, alicorn.hosted_runtime_init(&session, config) == .Ok,
		"the common ui.run state should initialize through the embedding-host Runtime contract")
	defer alicorn.hosted_runtime_destroy(&session)
	testing.expect(t, app.initializations == 1 && app.starts == 1 && app.service_calls == 1 &&
		app.service_read_available && app.service_available_before_start,
		"host services should be delivered after initialization and before the app start hook")
	testing.expect(t, app.scheduler_available && app.clipboard_text_available,
		"UI_Host_Services should publish the native-shaped scheduler and synchronous clipboard")

	first := alicorn.hosted_runtime_step(&session, 1)
	testing.expect(t, first.status == .Ok && first.description_built && first.render_required && app.renders == 2,
		"the hosted adapter should describe the shared root and overlay callbacks once each")
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)
	rt, borrow_status := alicorn.hosted_runtime_borrow(&session)
	testing.expect(t, borrow_status == .Ok && alicorn.focus(rt, app.generic_text_target))
	text_result, text_status := alicorn.hosted_runtime_text_key(
		&session,
		alicorn.Application_Text_Key_Event{key=.Document_End, shift=true},
	)
	testing.expect(t, text_status == .Ok && text_result == .Navigation &&
		app.text_key_events == 1 && app.last_text_key == .Document_End,
		"the shared ui.run adapter must forward application-owned editor key events")
	_ = alicorn.hosted_runtime_set_deadline(&session, 2)
	_ = alicorn.hosted_runtime_step(&session, 4)
	testing.expect(t, app.scheduled == 1,
		"a hosted application deadline should reach the shared ui.run scheduled-wake hook")
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	wake(app.waker)
	testing.expect(t, queue.count == 1, "the application waker should post through Hosted_Waker")
	_ = alicorn.hosted_runtime_deliver_wake(&session)
	second := alicorn.hosted_runtime_step(&session, 5)
	testing.expect(t, second.status == .Ok && second.description_built && app.wakes == 1,
		"a delivered wake should reach the application and explicitly invalidate the shared description")
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	handled, key_status := alicorn.hosted_runtime_application_key(&session, alicorn.Application_Key.Find, alicorn.Hosted_Key_Event{
		key_code=u32(alicorn.Application_Key.Find),
		pressed=true,
	})
	testing.expect(t, key_status == .Ok && handled && app.keys == 1,
		"host-mapped Application_Key values should reach the existing ui.run callback")
	third := alicorn.hosted_runtime_step(&session, 6)
	testing.expect(t, third.status == .Ok && third.description_built)
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	_, pointer_status := alicorn.hosted_runtime_pointer(&session, alicorn.Pointer_Event{kind=.Move, x=8, y=8})
	testing.expect(t, pointer_status == .Ok && app.pointers == 1,
		"pointer callbacks should remain attached to the same Hosted_Runtime event lane")

	config.on_drag(rawptr(&state), rt, alicorn.Drag_Event{})
	testing.expect(t, app.drag_events == 1, "the shared ui.run drag hook should receive hosted drag events")

	_, scroll_status := alicorn.hosted_runtime_scroll(&session, alicorn.Scroll_Event{delta_y=-1, x=-1, y=-1})
	testing.expect(t, scroll_status == .Ok && app.scroll_events == 1,
		"the shared ui.run scroll fallback should receive unclaimed hosted scroll events")

	_ = alicorn.focus(rt, app.generic_text_target)
	testing.expect(t,
		alicorn.hosted_runtime_text_input(&session, app.generic_text_target, .Commit, "text") == .Ok &&
		app.text_inputs == 1,
		"the shared ui.run text-input hook should receive application-owned text events")

	_ = alicorn.hosted_runtime_menu_command(&session, alicorn.Action_ID(17))
	testing.expect(t, app.menu_commands == 1 && app.last_menu_command == alicorn.Action_ID(17),
		"the shared ui.run menu hook should receive hosted native commands")

	dialog_result := alicorn.File_Dialog_Result{id=alicorn.Dialog_ID(3), status=.Accepted}
	_ = alicorn.hosted_runtime_dialog(&session, &dialog_result)
	testing.expect(t, app.dialogs == 1 && app.last_dialog_status == .Accepted,
		"the shared ui.run dialog hook should receive hosted completions")

	app.close_result = .Defer
	close_result, close_status := alicorn.hosted_runtime_request_close(&session)
	testing.expect(t, close_status == .Ok && close_result == .Defer && app.close_requests == 1,
		"the shared ui.run close hook should be able to defer a host close request")

	_ = alicorn.hosted_runtime_destroy(&session)
	testing.expect(t, app.stops == 1, "hosted teardown should call the existing ui.run stop hook")
}
