#+build !js
package ui

import "core:testing"
import alicorn "alicorn:runtime"

Run_Hosted_Config_Test_App :: struct {
	waker: Application_Waker,
	renders, initializations, starts, wakes, stops, keys, pointers: int,
	text_key_events: int,
	last_text_key: alicorn.Application_Text_Navigation_Key,
	generic_text_target: Node_ID,
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
	app.waker = waker
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

Run_Hosted_Config_Test_Wake_Queue :: struct { count: int }

run_hosted_config_test_post_wake :: proc(data: rawptr) -> bool {
	queue := cast(^Run_Hosted_Config_Test_Wake_Queue)data
	queue.count += 1
	return true
}

@(test)
test_shared_ui_run_adapts_to_hosted_runtime :: proc(t: ^testing.T) {
	app := Run_Hosted_Config_Test_App{}
	state := Run_State(Run_Hosted_Config_Test_App){
		app=&app,
		render=run_hosted_config_test_render,
		render_overlays=run_hosted_config_test_render,
		on_initialize=run_hosted_config_test_initialize,
		on_start=run_hosted_config_test_start,
		on_wake=run_hosted_config_test_wake,
		on_stop=run_hosted_config_test_stop,
		on_key=run_hosted_config_test_key,
		on_text_key=run_hosted_config_test_text_key,
		on_pointer=run_hosted_config_test_pointer,
	}
	queue := Run_Hosted_Config_Test_Wake_Queue{}
	config := run_hosted_config(&state, 240, 120, 480, 240, 2, rawptr(&queue), run_hosted_config_test_post_wake)
	session: alicorn.Hosted_Runtime
	testing.expect(t, alicorn.hosted_runtime_init(&session, config) == .Ok,
		"the common ui.run state should initialize through the embedding-host Runtime contract")
	defer alicorn.hosted_runtime_destroy(&session)
	testing.expect(t, app.initializations == 1 && app.starts == 1,
		"initialization and start hooks should keep their ui.run ordering")

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
	_ = alicorn.hosted_runtime_step(&session, 4)
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	wake(app.waker)
	testing.expect(t, queue.count == 1, "the application waker should post through Hosted_Waker")
	_ = alicorn.hosted_runtime_deliver_wake(&session)
	second := alicorn.hosted_runtime_step(&session, 5)
	testing.expect(t, second.status == .Ok && second.description_built && app.wakes == 1,
		"a delivered wake should reach the application and explicitly invalidate the shared description")
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	handled, key_status := alicorn.hosted_runtime_key(&session, alicorn.Hosted_Key_Event{
		key_code=u32(alicorn.Application_Key.Find),
		pressed=true,
	})
	testing.expect(t, key_status == .Ok && handled && app.keys == 1,
		"host-mapped Application_Key ordinals should reach the existing ui.run callback")
	third := alicorn.hosted_runtime_step(&session, 6)
	testing.expect(t, third.status == .Ok && third.description_built)
	_ = alicorn.hosted_runtime_frame_submission_succeeded(&session)

	_, pointer_status := alicorn.hosted_runtime_pointer(&session, alicorn.Pointer_Event{kind=.Move, x=8, y=8})
	testing.expect(t, pointer_status == .Ok && app.pointers == 1,
		"pointer callbacks should remain attached to the same Hosted_Runtime event lane")
	_ = alicorn.hosted_runtime_destroy(&session)
	testing.expect(t, app.stops == 1, "hosted teardown should call the existing ui.run stop hook")
}
