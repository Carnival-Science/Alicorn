#+build !js

package alicorn

import "core:testing"

// Hosted_Motion_Test_App describes a retained marker whose opacity is driven by
// the declarative `ui.motion` path, which is how applications author retained
// animation. The fixture also records tick callbacks so an idle assertion can
// prove that host-loop turns never become frame requests.
Hosted_Motion_Test_App :: struct {
	descriptions, ticks: int,
	root, marker: Node_ID,
	declare: bool,
	opacity: f64,
}

hosted_motion_test_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_motion_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := (^Hosted_Motion_Test_App)(data)
	app.descriptions += 1
	app.root = container_begin(
		ui,
		.Root,
		label="hosted-motion-root",
		key="hosted-motion-root",
		style=layout_style(.Column, grow=1, padding=8),
	)
	if app.root == 0 { return }
	app.marker = container_begin(
		ui,
		.Container,
		label="hosted-motion-marker",
		key="hosted-motion-marker",
		style=layout_style(.Row, width=120, height=40),
	)
	if app.marker != 0 {
		text(ui, "marker", key="hosted-motion-text")
		if app.declare {
			_ = motion_intent_queue(
				ui.runtime,
				app.marker,
				Motion_Target{has_opacity=true, opacity=app.opacity},
			)
		}
		container_end(ui)
	}
	container_end(ui)
}

hosted_motion_test_init :: proc(_data: rawptr, rt: ^Runtime) {
	_ = text_engine_load_default_fonts(rt)
}

hosted_motion_test_tick :: proc(data: rawptr, _rt: ^Runtime) {
	app := (^Hosted_Motion_Test_App)(data)
	app.ticks += 1
}

hosted_motion_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Motion_Test_App,
	tick := false,
) -> Hosted_Runtime_Status {
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app), logical_width=240, logical_height=180,
		pixel_width=240, pixel_height=180, dpi_scale=1,
		post_wake_data=rawptr(app), post_wake=hosted_motion_test_post,
		render=hosted_motion_test_render,
		on_initialize=hosted_motion_test_init,
		on_tick=hosted_motion_test_tick if tick else nil,
	})
}

// Hosted_Motion_Settle is the outcome of one bounded settle run.
Hosted_Motion_Settle :: struct {
	frames: int,
	step:   Hosted_Step_Result,
	at_ns:  u64,
}

// hosted_motion_test_settle runs the host's own loop rule (step at each
// published deadline, acknowledge every submitted frame) until the surface
// reports genuine idle: no pending description, no pending frame, and no wake
// deadline. It returns the frames it presented and the time of the last step, so
// a caller can continue from the same clock. A host with a tick callback never
// reports idle; callers pass a small limit to settle only the description.
hosted_motion_test_settle :: proc(host: ^Hosted_Runtime, now_ns: u64, limit := 400) -> Hosted_Motion_Settle {
	result := Hosted_Motion_Settle{at_ns=now_ns}
	now := now_ns
	for pass in 0..<limit {
		result.step = hosted_runtime_step(host, now)
		result.at_ns = now
		if result.step.render_required {
			result.frames += 1
			_ = hosted_runtime_frame_submission_succeeded(host)
		}
		if !result.step.has_more_work && !result.step.render_required && result.step.next_wake_ns == 0 { return result }
		if result.step.next_wake_ns > now {
			now = result.step.next_wake_ns
		} else {
			now += HOSTED_MOTION_SAMPLE_INTERVAL_NS
		}
	}
	return result
}

@(test)
test_hosted_motion_runs_to_settlement_without_description_changes :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_runtime_destroy(&host)
	settled := hosted_motion_test_settle(&host, 0, limit=8)
	if settled.step.next_wake_ns != 0 {
		testing.expect(t, false, "the initial description did not settle")
		return
	}
	rt, _ := hosted_runtime_borrow(&host)
	settled_descriptions := app.descriptions

	// A description requests a retained opacity change once. Every later frame
	// of the response is presentation-only: the application must not describe
	// again, and the host must keep asking for frames until the response
	// settles on its own.
	app.declare = true
	app.opacity = 0.25
	invalidate_root(rt, "hosted motion fixture retarget")
	start := settled.at_ns+1_000_000
	first := hosted_runtime_step(&host, start)
	testing.expect(t, first.status == .Ok && first.description_built && first.render_required,
		"the retargeting description must be built and presented")
	if first.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }
	testing.expect(t, first.next_wake_ns == start+HOSTED_MOTION_SAMPLE_INTERVAL_NS,
		"an active retained response arms the next sampling deadline")

	frames := 1
	now := first.next_wake_ns
	previous := first
	for guard in 0..<400 {
		step := hosted_runtime_step(&host, now)
		testing.expect(t, step.status == .Ok)
		if step.render_required {
			frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&host)
		}
		testing.expect(t, !step.description_built,
			"retained motion frames must not rebuild the application description")
		if previous.next_wake_ns != 0 && step.next_wake_ns != 0 {
			testing.expect(t, step.next_wake_ns == now+HOSTED_MOTION_SAMPLE_INTERVAL_NS,
				"each sample must re-arm the display-like cadence from its own time")
		}
		previous = step
		if step.next_wake_ns == 0 { break }
		now = step.next_wake_ns
	}
	testing.expectf(t, frames >= 8 && frames <= 120,
		"a single settle response should present a bounded run of frames, got %d", frames)
	state := rt.motion_owners[app.marker]
	pose := motion_presentation(rt, Motion_Owner_Handle{
		runtime_identity=rt.motion_runtime_identity,
		node=app.marker,
		generation=state.generation,
	})
	testing.expect(t, pose.status == .Ok && !pose.active && abs(pose.presented_opacity-0.25) < 0.001,
		"the response must settle exactly on its declared target")
	testing.expect(t, previous.next_wake_ns == 0,
		"a settled response must publish no further wake deadline")
	testing.expect(t, app.descriptions == settled_descriptions+1,
		"motion-only frames must not add descriptions")

	// Idle: a settled surface presents nothing for a full second of host turns.
	idle_frames := 0
	now += HOSTED_MOTION_SAMPLE_INTERVAL_NS
	for i in 0..<60 {
		step := hosted_runtime_step(&host, now+u64(i)*HOSTED_MOTION_SAMPLE_INTERVAL_NS)
		if step.render_required {
			idle_frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&host)
		}
		testing.expect(t, step.next_wake_ns == 0, "a settled surface must not publish a wake deadline")
	}
	testing.expectf(t, idle_frames == 0, "settled surface presented %d idle frames", idle_frames)
	testing.expect(t, app.descriptions == settled_descriptions+1,
		"an idle surface must not describe")
}

@(test)
test_hosted_motion_samples_on_its_cadence_not_on_host_turns :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_runtime_destroy(&host)
	settled := hosted_motion_test_settle(&host, 0)
	rt, _ := hosted_runtime_borrow(&host)
	app.declare = false
	handle, status := motion_owner_begin(rt, app.marker)
	if status != .Ok { testing.expect(t, false, "motion owner failed"); return }
	config := Motion_Config{omega=18, position_tolerance=0.001, velocity_tolerance=0.001}
	start := settled.at_ns+1_000_000
	if motion_target_opacity(rt, handle, 0.0, config, .Settle, Motion_Time(i64(start))) != .Ok {
		testing.expect(t, false, "motion target failed")
		return
	}
	armed := hosted_runtime_step(&host, start)
	testing.expect(t, armed.render_required && armed.next_wake_ns == start+HOSTED_MOTION_SAMPLE_INTERVAL_NS,
		"the imperative route arms the same sampling deadline")
	if armed.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }

	// A pointer storm (or queue-completion wakes) offers a presentation
	// opportunity every millisecond for 250 ms. Only the due samples may
	// present: the reference host's cadence is ~60 Hz, not one frame per turn.
	frames := 0
	now := start
	for i in 0..<250 {
		now += 1_000_000
		step := hosted_runtime_step(&host, now)
		if step.render_required {
			frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&host)
		}
	}
	testing.expectf(t, frames >= 8 && frames <= 24,
		"250 ms of host turns should yield the display cadence, got %d frames", frames)
	// The deadline still drives the response: stepping at it advances and
	// eventually settles, and the total frame count stays at the cadence.
	rest := hosted_motion_test_settle(&host, now)
	pose := motion_presentation(rt, handle)
	testing.expect(t, !pose.active && pose.presented_opacity == 0,
		"the response must complete after the storm")
	testing.expectf(t, frames+rest.frames < 60,
		"the response must terminate instead of animating forever, got %d frames", frames+rest.frames)
}

@(test)
test_hosted_motion_hidden_surface_drops_and_restores_its_deadline :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&host, &app) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_runtime_destroy(&host)
	settled := hosted_motion_test_settle(&host, 0)
	rt, _ := hosted_runtime_borrow(&host)
	app.declare = false
	handle, status := motion_owner_begin(rt, app.marker)
	if status != .Ok { testing.expect(t, false, "motion owner failed"); return }
	config := Motion_Config{omega=6, position_tolerance=0.0001, velocity_tolerance=0.0001}
	start := settled.at_ns+1_000_000
	if motion_target_opacity(rt, handle, 0.0, config, .Settle, Motion_Time(i64(start))) != .Ok {
		testing.expect(t, false, "motion target failed")
		return
	}
	if step := hosted_runtime_step(&host, start); step.render_required {
		_ = hosted_runtime_frame_submission_succeeded(&host)
	}
	pose_before := motion_presentation(rt, handle)
	_ = hosted_runtime_set_renderable(&host, false)
	hidden := hosted_runtime_step(&host, start+1_000_000_000)
	testing.expect(t, hidden.status == .Ok && !hidden.render_required && hidden.next_wake_ns == 0,
		"a hidden surface must publish no frame request or wake")
	testing.expect(t, motion_presentation(rt, handle).presented_opacity == pose_before.presented_opacity,
		"a hidden surface must not advance retained motion")
	_ = hosted_runtime_set_renderable(&host, true)
	restored := hosted_runtime_step(&host, start+2_000_000_000)
	testing.expect(t, restored.render_required,
		"restoring a surface samples once at the current time instead of replaying the gap")
	testing.expect(t, restored.next_wake_ns == start+2_000_000_000+HOSTED_MOTION_SAMPLE_INTERVAL_NS,
		"the restored sample re-arms the cadence")
}

@(test)
test_hosted_tick_turns_do_not_present_settled_frames :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&host, &app, tick=true) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_runtime_destroy(&host)
	settled := hosted_motion_test_settle(&host, 0, limit=8)
	if settled.step.next_wake_ns == 0 { testing.expect(t, false, "expected a tick deadline"); return }
	frames := 0
	now := settled.at_ns
	for i in 0..<120 {
		now += HOSTED_TICK_INTERVAL_NS
		step := hosted_runtime_step(&host, now)
		if step.render_required {
			frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&host)
		}
		testing.expect(t, step.next_wake_ns == now+HOSTED_TICK_INTERVAL_NS,
			"a tick-only surface publishes only its next tick deadline")
	}
	testing.expect(t, app.ticks > 100, "the hosted tick must still run at its bounded cadence")
	testing.expectf(t, frames == 0, "tick turns presented %d settled frames", frames)
	testing.expect(t, app.descriptions == 1,
		"a tick that changes nothing must not describe again")
}

@(test)
test_hosted_motion_windows_schedule_independently :: proc(t: ^testing.T) {
	primary: Hosted_Runtime
	primary_app: Hosted_Motion_Test_App
	child: Hosted_Runtime
	child_app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&primary, &primary_app) != .Ok { testing.expect(t, false, "primary open failed"); return }
	defer hosted_runtime_destroy(&primary)
	if hosted_motion_test_open(&child, &child_app) != .Ok { testing.expect(t, false, "child open failed"); return }
	defer hosted_runtime_destroy(&child)
	primary_settled := hosted_motion_test_settle(&primary, 0)
	_ = hosted_motion_test_settle(&child, 0)
	primary_app.declare = false
	child_app.declare = false

	child_rt, _ := hosted_runtime_borrow(&child)
	child_handle, child_status := motion_owner_begin(child_rt, child_app.marker)
	if child_status != .Ok { testing.expect(t, false, "child motion owner failed"); return }
	config := Motion_Config{omega=12, position_tolerance=0.001, velocity_tolerance=0.001}
	start := primary_settled.at_ns+1_000_000
	if motion_target_opacity(child_rt, child_handle, 0.2, config, .Settle, Motion_Time(i64(start))) != .Ok {
		testing.expect(t, false, "child motion target failed")
		return
	}

	// The shared host loop steps both windows on every turn and merges their
	// earliest deadline, exactly like the reference host. The idle primary must
	// stay idle while the child animates.
	child_frames := 0
	primary_frames := 0
	next_primary := u64(0)
	next_child := u64(0)
	now := start
	for guard in 0..<400 {
		primary_step := hosted_runtime_step(&primary, now)
		if primary_step.render_required {
			primary_frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&primary)
		}
		child_step := hosted_runtime_step(&child, now)
		if child_step.render_required {
			child_frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&child)
		}
		next_primary = primary_step.next_wake_ns
		next_child = child_step.next_wake_ns
		if next_primary == 0 && next_child == 0 { break }
		deadline := next_child
		if deadline == 0 || (next_primary != 0 && next_primary < deadline) { deadline = next_primary }
		if deadline > now { now = deadline } else { now += 1_000_000 }
	}
	testing.expectf(t, child_frames >= 8,
		"the animating child should present a bounded run of frames, got %d", child_frames)
	testing.expectf(t, primary_frames == 0,
		"the settled primary presented %d frames while only the child animated", primary_frames)
	testing.expect(t, next_child == 0 && next_primary == 0,
		"both windows must reach idle once the child response settles")

	// Conversely, a primary animation must not present child frames.
	primary_rt, _ := hosted_runtime_borrow(&primary)
	primary_handle, primary_status := motion_owner_begin(primary_rt, primary_app.marker)
	if primary_status != .Ok { testing.expect(t, false, "primary motion owner failed"); return }
	start = now+16_666_667
	if motion_target_opacity(primary_rt, primary_handle, 0.2, config, .Settle, Motion_Time(i64(start))) != .Ok {
		testing.expect(t, false, "primary motion target failed")
		return
	}
	child_frames = 0
	primary_frames = 0
	now = start
	for guard in 0..<400 {
		primary_step := hosted_runtime_step(&primary, now)
		if primary_step.render_required {
			primary_frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&primary)
		}
		child_step := hosted_runtime_step(&child, now)
		if child_step.render_required {
			child_frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&child)
		}
		next_primary = primary_step.next_wake_ns
		next_child = child_step.next_wake_ns
		if next_primary == 0 && next_child == 0 { break }
		deadline := next_child
		if deadline == 0 || (next_primary != 0 && next_primary < deadline) { deadline = next_primary }
		if deadline > now { now = deadline } else { now += 1_000_000 }
	}
	testing.expectf(t, primary_frames >= 8,
		"the animating primary should present a bounded run of frames, got %d", primary_frames)
	testing.expectf(t, child_frames == 0,
		"the settled child presented %d frames while only the primary animated", child_frames)
}

@(test)
test_hosted_live_step_shares_the_motion_deadline :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Motion_Test_App
	if hosted_motion_test_open(&host, &app, tick=true) != .Ok { testing.expect(t, false, "open failed"); return }
	defer hosted_runtime_destroy(&host)
	settled := hosted_motion_test_settle(&host, 0, limit=8)
	rt, _ := hosted_runtime_borrow(&host)
	app.declare = false
	handle, status := motion_owner_begin(rt, app.marker)
	if status != .Ok { testing.expect(t, false, "motion owner failed"); return }
	config := Motion_Config{omega=18, position_tolerance=0.001, velocity_tolerance=0.001}
	start := settled.at_ns+1_000_000
	if motion_target_opacity(rt, handle, 0.0, config, .Settle, Motion_Time(i64(start))) != .Ok {
		testing.expect(t, false, "motion target failed")
		return
	}
	armed := hosted_runtime_live_step(&host, start)
	testing.expect(t, armed.render_required && armed.next_wake_ns != 0,
		"a modal-loop frame presents and publishes a wake deadline")
	testing.expect(t, host.state.motion_deadline_ns == start+HOSTED_MOTION_SAMPLE_INTERVAL_NS,
		"a modal-loop frame arms the shared sampling deadline")
	if armed.render_required { _ = hosted_runtime_frame_submission_succeeded(&host) }
	ticks_before := app.ticks
	frames := 0
	now := start
	for i in 0..<120 {
		now += 1_000_000
		step := hosted_runtime_live_step(&host, now)
		if step.render_required {
			frames += 1
			_ = hosted_runtime_frame_submission_succeeded(&host)
		}
	}
	testing.expectf(t, frames >= 4 && frames <= 12,
		"live steps honour the cadence too, got %d frames over 120 ms", frames)
	testing.expect(t, app.ticks == ticks_before,
		"live steps must not dispatch application ticks")
	_ = hosted_motion_test_settle(&host, now)
	testing.expect(t, !motion_presentation(rt, handle).active,
		"live steps must keep the response progressing to settlement")
}
