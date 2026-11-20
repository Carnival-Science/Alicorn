#+build !js

package alicorn

import "core:testing"
import "core:thread"
import "core:strings"

Hosted_Test_App :: struct {
	descriptions, wakes, scheduled, stops, posts, pointer_cancels, scroll_events: int,
	host_services, starts: int,
	host_services_before_start: bool,
	button, field, generic_text_target, scroll: Node_ID,
	waker: Hosted_Waker,
	worker_notified, worker_coalesced: bool,
	worker_status, worker_step_status, worker_destroy_status: Hosted_Runtime_Status,
	post_fails: bool,
	text_changes: int,
	committed_text: bool,
	semantic_value_received: bool,
	semantic_value_id: Semantic_ID,
	key_events: int,
	last_key: Application_Key,
	text_key_events: int,
	last_text_key: Application_Text_Navigation_Key,
	host: ^Hosted_Runtime,
}

hosted_test_render :: proc(data: rawptr, ui: ^UI, width, height: int, dpi: f32) {
	app := (^Hosted_Test_App)(data)
	app.descriptions += 1
	app.button, _ = button_ex(ui, "Source", key="hosted-source", style=layout_style(width=100, height=36))
	_ = drag_source(ui, DRAG_TEST_TYPE, DRAG_SCROLL_SOURCE)
	app.field = text_field(ui, "seed", key="hosted-field", style=layout_style(width=180, height=36))
	app.generic_text_target, _ = button_ex(
		ui, "Editor", key="hosted-editor", explicit_key=true, style=layout_style(width=180, height=36),
	)
	_ = text_input_target(ui, app.generic_text_target)
	region := scroll_region_begin(ui, key=key_string("hosted-scroll"), viewport_height=120, content_height=900,
		style=layout_style(.Column, width=240, height=120), label="hosted-scroll")
	app.scroll = region.id
	button(ui, "Target", key="hosted-target", style=layout_style(width=180, height=36))
	_ = drop_target(ui, DRAG_TEST_TYPE, DRAG_SCROLL_TARGET, .On)
	scroll_region_end(ui)
}

hosted_test_post :: proc(data: rawptr) -> bool {
	app := (^Hosted_Test_App)(data)
	app.posts += 1
	return !app.post_fails
}

hosted_test_init :: proc(data: rawptr, rt: ^Runtime) {
	_ = text_engine_load_default_fonts(rt)
}

hosted_test_start :: proc(data: rawptr, waker: Hosted_Waker) {
	app := (^Hosted_Test_App)(data)
	app.starts += 1
	app.waker, _ = hosted_waker_clone(waker)
}

hosted_test_services :: proc(data: rawptr, services: Hosted_Host_Services) {
	app := (^Hosted_Test_App)(data)
	app.host_services += 1
	app.host_services_before_start = app.starts == 0
}

hosted_test_wake :: proc(data: rawptr, rt: ^Runtime) {
	app := (^Hosted_Test_App)(data)
	app.wakes += 1
	for {
		event, found := semantic_request_pop(rt)
		if !found { break }
		if event.kind == .Perform && event.action == .Set_Value && event.text_value == "accessible value" {
			app.semantic_value_received = true
			app.semantic_value_id = event.id
		}
		semantic_request_event_destroy(rt, &event)
	}
	invalidate_root(rt, "hosted worker wake")
}

hosted_test_scheduled :: proc(data: rawptr, rt: ^Runtime) {
	app := (^Hosted_Test_App)(data)
	app.scheduled += 1
}

hosted_test_stop :: proc(data: rawptr) {
	app := (^Hosted_Test_App)(data)
	app.stops += 1
}

hosted_test_pointer :: proc(data: rawptr, rt: ^Runtime, event: Pointer_Event, target: Node_ID) {
	app := (^Hosted_Test_App)(data)
	if event.kind == .Cancel { app.pointer_cancels += 1 }
}

hosted_test_scroll :: proc(data: rawptr, rt: ^Runtime, event: Scroll_Event) {
	app := (^Hosted_Test_App)(data)
	app.scroll_events += 1
}

hosted_test_text_change :: proc(data: rawptr, rt: ^Runtime, change: Text_Change) {
	app := (^Hosted_Test_App)(data)
	if change.changed {
		app.text_changes += 1
		app.committed_text = strings.contains(change.text, "é")
	}
}

hosted_test_key :: proc(data: rawptr, _rt: ^Runtime, _owner: Node_ID, event: Hosted_Key_Event) -> bool {
	app := (^Hosted_Test_App)(data)
	if !event.pressed || event.key_code > u32(Application_Key.Return) { return false }
	app.key_events += 1
	app.last_key = Application_Key(event.key_code)
	return true
}

// Hosted_Key_Route_Test_State isolates the opaque-versus-typed key contract.
// It owns one focusable descendant of an interaction scope that registers Find,
// so a numeric key_code collision would be observable as queued scope input.
Hosted_Key_Route_Test_State :: struct {
	scope_owner: Node_ID,
	button:      Node_ID,
	key_events:  int,
	last_code:   u32,
}

hosted_key_route_init :: proc(_data: rawptr, rt: ^Runtime) {
	_ = text_engine_load_default_fonts(rt)
}

hosted_key_route_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_key_route_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	state := (^Hosted_Key_Route_Test_State)(data)
	state.scope_owner = container_begin(
		ui,
		.Container,
		label="hosted-key-scope",
		key="hosted-key-scope",
		style=layout_style(.Column),
	)
	state.button, _ = button_ex(
		ui,
		"Target",
		key="hosted-key-target",
		style=layout_style(width=120, height=30),
	)
	container_end(ui)
	_ = interaction_scope_register(
		ui.runtime,
		state.scope_owner,
		rawptr(state),
		Interaction_Scope_Options{keys={.Find}},
	)
}

hosted_key_route_key :: proc(data: rawptr, _rt: ^Runtime, _owner: Node_ID, event: Hosted_Key_Event) -> bool {
	state := (^Hosted_Key_Route_Test_State)(data)
	state.key_events += 1
	state.last_code = event.key_code
	return false
}

hosted_key_route_open :: proc(
	host: ^Hosted_Runtime,
	state: ^Hosted_Key_Route_Test_State,
) -> Hosted_Runtime_Status {
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(state),
		logical_width=240,
		logical_height=240,
		pixel_width=480,
		pixel_height=480,
		dpi_scale=2,
		post_wake_data=rawptr(state),
		post_wake=hosted_key_route_post,
		render=hosted_key_route_render,
		on_initialize=hosted_key_route_init,
		on_key=hosted_key_route_key,
	})
}

hosted_test_text_key :: proc(
	data: rawptr,
	_rt: ^Runtime,
	_owner: Node_ID,
	event: Application_Text_Key_Event,
) -> bool {
	app := (^Hosted_Test_App)(data)
	app.text_key_events += 1
	app.last_text_key = event.key
	return true
}

hosted_test_open :: proc(host: ^Hosted_Runtime, app: ^Hosted_Test_App) -> Hosted_Runtime_Status {
	app.host = host
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app), logical_width=240, logical_height=240,
		pixel_width=480, pixel_height=480, dpi_scale=2,
		post_wake_data=rawptr(app), post_wake=hosted_test_post, render=hosted_test_render,
		on_initialize=hosted_test_init, on_host_services=hosted_test_services,
		on_start=hosted_test_start, on_wake=hosted_test_wake,
		on_scheduled_wake=hosted_test_scheduled, on_stop=hosted_test_stop, on_pointer=hosted_test_pointer,
		on_text_change=hosted_test_text_change, on_text_key=hosted_test_text_key,
		on_scroll=hosted_test_scroll, on_key=hosted_test_key,
	})
}

@(test)
test_hosted_runtime_delivers_host_services_before_start :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	testing.expect(t, app.host_services == 1 && app.starts == 1 && app.host_services_before_start,
		"optional host services are delivered during initialization before the app starts")
}

Hosted_Window_Service_Test_State :: struct {
	opened, closed, topped, titled: int,
	last_topmost: bool,
	last_title: string,
}

hosted_test_window_open :: proc(data: rawptr, description: Hosted_Window_Description) -> bool {
	state := cast(^Hosted_Window_Service_Test_State)data
	state.opened += 1
	return description.title == "child"
}

hosted_test_window_close :: proc(data: rawptr) {
	state := cast(^Hosted_Window_Service_Test_State)data
	state.closed += 1
}

hosted_test_window_topmost :: proc(data: rawptr, value: bool) -> bool {
	state := cast(^Hosted_Window_Service_Test_State)data
	state.topped += 1
	state.last_topmost = value
	return true
}

hosted_test_window_title :: proc(data: rawptr, value: string) -> bool {
	state := cast(^Hosted_Window_Service_Test_State)data
	state.titled += 1
	state.last_title = value
	return true
}

@(test)
test_hosted_window_service_optional_and_forwards :: proc(t: ^testing.T) {
	testing.expect(t, !hosted_window_open({}, {}), "an unsupported window service rejects requests")
	state := Hosted_Window_Service_Test_State{}
	service := Hosted_Window_Service{
		data=rawptr(&state), open=hosted_test_window_open, close=hosted_test_window_close,
		set_always_on_top=hosted_test_window_topmost, set_title=hosted_test_window_title,
	}
	description := Hosted_Window_Description{title="child"}
	testing.expect(t, hosted_window_open(service, description) && state.opened == 1,
		"the service forwards an accepted child-window description")
	testing.expect(t, hosted_window_set_always_on_top(service, true) && state.topped == 1 && state.last_topmost,
		"the service forwards always-on-top changes")
	testing.expect(t, hosted_window_set_title(service, "renamed") && state.titled == 1 && state.last_title == "renamed",
		"the service forwards title changes")
	hosted_window_close(service)
	testing.expect(t, state.closed == 1, "the service forwards close requests")
}

@(test)
test_hosted_runtime_application_key_respects_text_and_composition_precedence :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	rt, _ := hosted_runtime_borrow(&host)
	_ = focus(rt, app.field)

	handled, status := hosted_runtime_application_key(&host, .Left, Hosted_Key_Event{
		key_code=u32(Application_Key.Left), pressed=true, text_input_focused=true,
	})
	testing.expect(t, status == .Ok && !handled && app.key_events == 0,
		"ordinary navigation remains with a focused text field")
	handled, status = hosted_runtime_application_key(&host, .Find, Hosted_Key_Event{
		key_code=u32(Application_Key.Find), pressed=true, text_input_focused=true,
	})
	testing.expect(t, status == .Ok && handled && app.key_events == 1 && app.last_key == .Find,
		"an explicit application shortcut can preempt text focus")
	handled, status = hosted_runtime_application_key(&host, .Escape, Hosted_Key_Event{
		key_code=u32(Application_Key.Escape), pressed=true,
		text_input_focused=true, composition_active=true,
	})
	testing.expect(t, status == .Ok && !handled && app.key_events == 1,
		"Escape stays with IME while composition is active")
}

@(test)
test_hosted_runtime_opaque_key_code_never_preempts_application_keys :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	state: Hosted_Key_Route_Test_State
	if hosted_key_route_open(&host, &state) != .Ok {
		testing.expect(t, false, "open failed")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	rt, _ := hosted_runtime_borrow(&host)
	testing.expect(t, focus(rt, state.button),
		"the interaction-scope target should accept focus")

	// An external host's own numeric key codes are opaque. Even a value that
	// happens to equal a real Application_Key ordinal must not reach the
	// focused scope's Find registration.
	for external_code in ([]u32{0x000F_0000, u32(Application_Key.Find)}) {
		handled, status := hosted_runtime_key(&host, Hosted_Key_Event{
			key_code=external_code, pressed=true,
		})
		testing.expect(t, status == .Ok && !handled,
			"an opaque key is only offered to the application callback")
		testing.expect(t, len(rt.interaction_events) == 0,
			"an opaque numeric key must not preempt an interaction scope")
	}
	testing.expect(t, state.key_events == 2 && state.last_code == u32(Application_Key.Find),
		"both opaque events should still reach the application key callback")

	handled, status := hosted_runtime_application_key(&host, .Find, Hosted_Key_Event{
		key_code=0x000F_0000, pressed=true,
	})
	testing.expect(t, status == .Ok && handled,
		"the typed application-key route should consume the registered key")
	testing.expect(t, len(rt.interaction_events) == 1 &&
		rt.interaction_events[0].event.key == .Find,
		"the typed route should queue the key for the focused scope")
	testing.expect(t, state.key_events == 2,
		"a consumed scope key should not also reach the application callback")
}

@(test)
test_hosted_runtime_scroll_fallback_reports_delivery :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_, status := hosted_runtime_scroll(&host, Scroll_Event{delta_y=-1, x=-1, y=-1})
	testing.expect(t, status == .Ok && app.scroll_events == 1,
		"application scroll fallback must be delivered and reported handled")
}

@(test)
test_hosted_runtime_step_resize_and_idle :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	first := hosted_runtime_step(&host, 1)
	testing.expect(t, first.status == .Ok && first.description_built && first.render_required && app.descriptions == 1)
	commands, status := hosted_runtime_display_commands(&host)
	testing.expect(t, status == .Ok && len(commands) > 0)
	_ = hosted_runtime_frame_submission_succeeded(&host)
	// Virtualized scroll geometry can require another description after layout.
	// The host services that finite workload before asserting genuine idle.
	idle := hosted_runtime_step(&host, 2)
	for turn in 3..<8 {
		if !idle.has_more_work && !idle.render_required { break }
		if idle.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }
		idle = hosted_runtime_step(&host, u64(turn))
	}
	testing.expect(t, !idle.description_built && !idle.render_required && !idle.has_more_work && idle.next_wake_ns == 0)
	_ = hosted_runtime_set_deadline(&host, 10)
	early := hosted_runtime_step(&host, 9)
	testing.expect(t, early.next_wake_ns == 10 && app.scheduled == 0)
	due := hosted_runtime_step(&host, 10)
	testing.expect(t, due.next_wake_ns == 0 && app.scheduled == 1 && !due.description_built)
	testing.expect(t, hosted_runtime_step(&host, 9).status == .Time_Rewound)
	_ = hosted_runtime_resize(&host, 300, 200, 450, 400, 1.5)
	resized := hosted_runtime_step(&host, 11)
	rt, _ := hosted_runtime_borrow(&host)
	testing.expect(t, resized.description_built && resized.render_required && viewport_bounds(rt) == Rect{0, 0, 300, 200})
	testing.expect(t, rt.presentation_scale_x == 1.5 && rt.presentation_scale_y == 2)
	_ = hosted_runtime_frame_submission_succeeded(&host)
	_ = hosted_runtime_set_renderable(&host, false)
	_ = hosted_runtime_set_deadline(&host, 20)
	request_presentation(rt)
	hidden := hosted_runtime_step(&host, 20)
	testing.expect(t, app.scheduled == 2 && !hidden.render_required && hidden.next_wake_ns == 0)
	_ = hosted_runtime_set_renderable(&host, true)
	restored := hosted_runtime_step(&host, 21)
	testing.expect(t, restored.render_required && !restored.description_built)
}

@(test)
test_hosted_runtime_host_presentation_request_reuses_description :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	step := hosted_runtime_step(&host, 1)
	if step.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }
	for turn in 2..<8 {
		step = hosted_runtime_step(&host, u64(turn))
		if step.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }
		if !step.has_more_work && !step.render_required { break }
	}
	descriptions_before := app.descriptions
	testing.expect(t, hosted_runtime_request_presentation(&host, "test presenter reattached") == .Ok)
	requested := hosted_runtime_step(&host, 8)
	testing.expect(t, requested.status == .Ok && requested.render_required && !requested.description_built)
	testing.expect(t, app.descriptions == descriptions_before,
		"replacing a presenter requests paint without rebuilding the application description")
}

@(test)
test_hosted_runtime_text_and_semantic_delivery :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	rt, _ := hosted_runtime_borrow(&host)
	if app.field == 0 || app.button == 0 { testing.expect(t, false, "missing nodes"); return }
	_ = focus(rt, app.field)
	testing.expect(t, hosted_runtime_text_input(&host, app.field, .Preedit, "é字", 1, 1) == .Ok)
	testing.expect(t, rt.nodes[app.field].composition.active && rt.nodes[app.field].composition.selection_start == 2 &&
		rt.nodes[app.field].composition.selection_end == 5)
	_ = hosted_runtime_focus_changed(&host, false)
	testing.expect(t, !rt.nodes[app.field].composition.active && app.text_changes == 0)
	_ = hosted_runtime_focus_changed(&host, true, true)
	_ = hosted_runtime_text_input(&host, app.field, .Preedit, "é", 1, 0)
	testing.expect(t, hosted_runtime_text_input(&host, app.field, .Commit, "é") == .Ok && app.text_changes == 1 && app.committed_text)
	testing.expect(t, !rt.nodes[app.field].composition.active)
	_ = hosted_runtime_step(&host, 2)
	snapshot, status := hosted_runtime_semantic_snapshot(&host)
	defer semantic_snapshot_destroy(&snapshot)
	testing.expect(t, status == .Ok && len(snapshot.nodes) >= 2)
	button_id := rt.nodes[app.button].semantic_id
	handled, action_status := hosted_runtime_accessibility_action(&host, button_id, .Press)
	testing.expect(t, action_status == .Ok && handled && app.wakes == 0,
		"realized activation stays runtime-owned and does not call the application semantic-event callback")
	field_id := rt.nodes[app.field].semantic_id
	handled, action_status = hosted_runtime_accessibility_action(
		&host, field_id, .Set_Value, text_value="accessible value",
	)
	testing.expect(t, action_status == .Ok && handled && app.wakes == 1 &&
		app.semantic_value_received && app.semantic_value_id == field_id,
		"queued accessibility values reach on_wake for application-owned adoption")
	queued := semantic_action_request(rt, field_id, .Set_Value, text_value="accessible value")
	delivery_status := hosted_runtime_deliver_semantic_requests(&host)
	testing.expect(t, queued && delivery_status == .Ok && app.wakes == 2 &&
		app.semantic_value_received && app.semantic_value_id == field_id,
		"host-drained native semantic actions can notify the application before the next description")
}

@(test)
test_hosted_runtime_text_key_routes_selection_and_edit_callbacks :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	rt, _ := hosted_runtime_borrow(&host)
	_ = focus(rt, app.generic_text_target)
	result, status := hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Word_Left})
	testing.expect(t, status == .Ok && result == .Navigation && app.text_key_events == 1 &&
		app.last_text_key == .Word_Left,
		"hosted text-key routing delivers editor navigation to the active application-owned text target")
	result, status = hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Delete}, composition_active=true)
	testing.expect(t, status == .Ok && result == .Unhandled && app.text_key_events == 1,
		"active IME composition retains keys instead of dispatching editor navigation")

	if app.field == 0 { testing.expect(t, false, "missing text field"); return }
	_ = focus(rt, app.field)
	result, status = hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Left, shift=true})
	interaction, interaction_ok := text_field_interaction(rt, app.field)
	testing.expect(t, status == .Ok && result == .Navigation && interaction_ok && interaction.has_selection)
	result, status = hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Backspace})
	value, value_ok := text_field_value(rt, app.field)
	testing.expect(t, status == .Ok && result == .Edit && value_ok && len(value) < len("seed") && app.text_changes == 1)
	_ = hosted_runtime_text_input(&host, app.field, .Preedit, "字", 0, 1)
	result, status = hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Left})
	testing.expect(t, status == .Ok && result == .Unhandled, "text key must not preempt active composition")
}

@(test)
test_hosted_runtime_hidden_motion_and_drag_deadlines :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 0)
	rt, _ := hosted_runtime_borrow(&host)
	handle, owner_status := motion_owner_begin(rt, app.button)
	if owner_status != .Ok { testing.expect(t, false, "motion owner failed"); return }
	config := Motion_Config{omega=18, position_tolerance=0.001, velocity_tolerance=0.001}
	_ = motion_target_opacity(rt, handle, 0.5, config, .Settle, Motion_Time(0))
	before := hosted_runtime_step(&host, 100_000_000)
	testing.expect(t, before.next_wake_ns > 100_000_000)
	pose := motion_presentation(rt, handle)
	_ = hosted_runtime_set_renderable(&host, false)
	_ = hosted_runtime_step(&host, 1_000_000_000)
	testing.expect(t, motion_presentation(rt, handle).presented_opacity == pose.presented_opacity)
	_ = hosted_runtime_set_renderable(&host, true)
	restored := hosted_runtime_step(&host, 5_000_000_000)
	testing.expect(t, restored.render_required && restored.next_wake_ns == 0 && !motion_presentation(rt, handle).active)
	button_bounds := rt.nodes[app.button].bounds
	viewport := scroll_region_state(rt, app.scroll).viewport_bounds
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Down, x=button_bounds.x+button_bounds.w/2,
		y=button_bounds.y+button_bounds.h/2, button=POINTER_BUTTON_PRIMARY})
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=viewport.x+viewport.w/2, y=viewport.y+viewport.h-2})
	testing.expect(t, drag_autoscroll_can_step(rt))
	start := u64(5_000_000_001)
	armed := hosted_runtime_step(&host, start)
	testing.expect(t, armed.next_wake_ns == start+HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS)
	offset := scroll_region_offset(rt, app.scroll)
	_ = hosted_runtime_step(&host, armed.next_wake_ns)
	testing.expect(t, scroll_region_offset(rt, app.scroll) > offset)
	_ = hosted_runtime_focus_changed(&host, false)
	testing.expect(t, rt.captured_node == 0 && !drag_autoscroll_can_step(rt) && app.pointer_cancels == 1)
	settled := hosted_runtime_step(&host, armed.next_wake_ns+1)
	testing.expect(t, settled.next_wake_ns == 0)
}

hosted_test_worker :: proc(worker: ^thread.Thread) {
	app := (^Hosted_Test_App)(worker.data)
	_, app.worker_status = hosted_runtime_borrow(app.host)
	app.worker_step_status = hosted_runtime_step(app.host, 0).status
	app.worker_destroy_status = hosted_runtime_destroy(app.host)
	app.worker_notified = hosted_waker_notify(app.waker)
	app.worker_coalesced = hosted_waker_notify(app.waker)
}

@(test)
test_hosted_runtime_worker_wakes_and_teardown :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	worker := thread.create(hosted_test_worker)
	if worker == nil { testing.expect(t, false, "worker creation failed"); return }
	defer thread.destroy(worker)
	worker.data = rawptr(&app)
	thread.start(worker)
	thread.join(worker)
	testing.expect(t, app.worker_status == .Wrong_Thread && app.worker_step_status == .Wrong_Thread &&
		app.worker_destroy_status == .Wrong_Thread && app.worker_notified && app.worker_coalesced)
	testing.expect(t, app.posts == 1 && app.wakes == 0)
	_ = hosted_runtime_deliver_wake(&host)
	_ = hosted_runtime_deliver_wake(&host)
	testing.expect(t, app.wakes == 1)
	app.post_fails = true
	testing.expect(t, !hosted_waker_notify(app.waker) && app.posts == 2)
	app.post_fails = false
	testing.expect(t, hosted_waker_notify(app.waker) && app.posts == 3)
	testing.expect(t, hosted_runtime_destroy(&host) == .Ok && app.stops == 1)
	testing.expect(t, !hosted_waker_notify(app.waker) && hosted_runtime_deliver_wake(&host) == .Closed && app.wakes == 1)
	testing.expect(t, hosted_runtime_destroy(&host) == .Ok && app.stops == 1)
}
