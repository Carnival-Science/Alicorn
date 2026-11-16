#+build !js

package alicorn

import "core:testing"
import "core:thread"
import "core:strings"

Hosted_Test_App :: struct {
	descriptions, wakes, scheduled, stops, posts, pointer_cancels, scroll_events: int,
	button, field, scroll: Node_ID,
	waker: Hosted_Waker,
	worker_notified, worker_coalesced: bool,
	worker_status, worker_step_status, worker_destroy_status: Hosted_Runtime_Status,
	post_fails: bool,
	text_changes: int,
	committed_text: bool,
	key_events: int,
	last_key: Application_Key,
	host: ^Hosted_Runtime,
}

hosted_test_render :: proc(data: rawptr, ui: ^UI, width, height: int, dpi: f32) {
	app := (^Hosted_Test_App)(data)
	app.descriptions += 1
	app.button, _ = button_ex(ui, "Source", key="hosted-source", style=layout_style(width=100, height=36))
	_ = drag_source(ui, DRAG_TEST_TYPE, DRAG_SCROLL_SOURCE)
	app.field = text_field(ui, "seed", key="hosted-field", style=layout_style(width=180, height=36))
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
	app.waker, _ = hosted_waker_clone(waker)
}

hosted_test_wake :: proc(data: rawptr, rt: ^Runtime) {
	app := (^Hosted_Test_App)(data)
	app.wakes += 1
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

hosted_test_open :: proc(host: ^Hosted_Runtime, app: ^Hosted_Test_App) -> Hosted_Runtime_Status {
	app.host = host
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app), logical_width=240, logical_height=240,
		pixel_width=480, pixel_height=480, dpi_scale=2,
		post_wake_data=rawptr(app), post_wake=hosted_test_post, render=hosted_test_render,
		on_initialize=hosted_test_init, on_start=hosted_test_start, on_wake=hosted_test_wake,
		on_scheduled_wake=hosted_test_scheduled, on_stop=hosted_test_stop, on_pointer=hosted_test_pointer,
		on_text_change=hosted_test_text_change, on_scroll=hosted_test_scroll, on_key=hosted_test_key,
	})
}

@(test)
test_hosted_runtime_key_respects_text_and_composition_precedence :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Test_App
	if hosted_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_waker_release(&app.waker)
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	rt, _ := hosted_runtime_borrow(&host)
	_ = focus(rt, app.field)

	handled, status := hosted_runtime_key(&host, Hosted_Key_Event{
		key_code=u32(Application_Key.Left), pressed=true, text_input_focused=true,
	})
	testing.expect(t, status == .Ok && !handled && app.key_events == 0,
		"ordinary navigation remains with a focused text field")
	handled, status = hosted_runtime_key(&host, Hosted_Key_Event{
		key_code=u32(Application_Key.Find), pressed=true, text_input_focused=true,
	})
	testing.expect(t, status == .Ok && handled && app.key_events == 1 && app.last_key == .Find,
		"an explicit application shortcut can preempt text focus")
	handled, status = hosted_runtime_key(&host, Hosted_Key_Event{
		key_code=u32(Application_Key.Escape), pressed=true,
		text_input_focused=true, composition_active=true,
	})
	testing.expect(t, status == .Ok && !handled && app.key_events == 1,
		"Escape stays with IME while composition is active")
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
	testing.expect(t, action_status == .Ok && handled)
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
	if app.field == 0 { testing.expect(t, false, "missing text field"); return }
	_ = focus(rt, app.field)
	result, status := hosted_runtime_text_key(&host, Application_Text_Key_Event{key=.Left, shift=true})
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
