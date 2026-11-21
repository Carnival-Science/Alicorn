#+build !js
package alicorn

import "core:testing"

@(test)
test_motion_direct_manipulation_tracks_pointer_exactly_and_hands_off_at_release :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	split, divider := motion_acceptance_build_split(&rt)
	if split.id == 0 || divider == 0 {
		testing.expect(t, false, "the direct-manipulation split fixture should build")
		return
	}
	handle, handle_status := motion_owner_begin(&rt, divider)
	if handle_status != .Ok {
		testing.expect(t, false, "the split divider should acquire a motion owner")
		return
	}
	config := Motion_Config{omega=16, position_tolerance=0.001, velocity_tolerance=0.02}
	before_position := rt.nodes[split.id].split_position
	logical := rt.nodes[divider].hit_bounds
	press_x, press_y := logical.x+logical.w*0.5, logical.y+logical.h*0.5
	target := process_pointer(&rt, Pointer_Event{kind=.Down, x=press_x, y=press_y, button=POINTER_BUTTON_PRIMARY})
	testing.expect(t, target == divider && rt.captured_node == divider,
		"pointer-down on the split divider should latch capture to the divider")

	sample_ns := i64(10_000_000)
	moved := false
	for step in 1..=5 {
		delta := f32(step*12)
		x := press_x+delta
		_ = process_pointer(&rt, Pointer_Event{kind=.Move, x=x, y=press_y, button=POINTER_BUTTON_PRIMARY})
		status := motion_target_translation(&rt, handle, Motion_Vector2{f64(delta), 0}, config, .Direct, Motion_Time(sample_ns))
		presentation := motion_presentation(&rt, handle)
		owner := rt.motion_owners[divider]
		residual := motion_translation_sample(owner.translation, Motion_Time(sample_ns))
		testing.expectf(t, status == .Ok && presentation.presented_translation == [2]f32{delta, 0},
			"Direct presented translation at step %d should equal its pointer target exactly", step)
		testing.expectf(t, residual.status == .Ok && residual.value.x == f64(delta) && residual.velocity.x == 0,
			"Direct mode should keep zero residual and zero residual velocity at step %d", step)
		testing.expectf(t, !presentation.active,
			"Direct manipulation should not start a settling response before release (step %d)", step)
		testing.expectf(t, rt.nodes[split.id].split_position == before_position+delta,
			"the split divider should track the same pointer delta exactly at step %d", step)
		moved = true
		sample_ns += 8_000_000
	}
	testing.expect(t, moved, "the direct-manipulation loop should produce pointer move samples")

	release_time := Motion_Time(sample_ns)
	state_before := rt.motion_owners[divider]
	sample_before := motion_translation_sample(state_before.translation, release_time)
	_ = process_pointer(&rt, Pointer_Event{kind=.Up, x=press_x+60, y=press_y, button=POINTER_BUTTON_PRIMARY})
	release_status := motion_target_translation(&rt, handle, Motion_Vector2{0, 0}, config, .Settle, release_time)
	state_after := rt.motion_owners[divider]
	sample_after := motion_translation_sample(state_after.translation, release_time)
	presented := motion_presentation(&rt, handle)
	testing.expect(t, release_status == .Ok && sample_before.status == .Ok && sample_after.status == .Ok &&
		sample_before.value == sample_after.value && sample_before.velocity == sample_after.velocity,
		"the Direct-to-Settle switch at release must preserve presented position and velocity")
	testing.expect(t, presented.active && presented.presented_translation == [2]f32{f32(sample_before.value.x), f32(sample_before.value.y)} &&
		presented.target_translation == Motion_Vector2{0, 0},
		"settling should begin only at release, from the last Direct presentation without a jump")

	deadline := rt.motion_owners[divider].translation.x.settle_after_ns
	deadline_at := Motion_Time(i64(release_time)+i64(deadline))
	settled := motion_tick(&rt, deadline_at)
	settled_presentation := motion_presentation(&rt, handle)
	testing.expect(t, settled.status == .Ok && !settled_presentation.active &&
		settled_presentation.presented_translation == [2]f32{0, 0},
		"release settling should retire at its certified deadline on the exact target")
	ui, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&ui) }
	frame_submission_succeeded(&rt)
	for opportunity in 1..=4 {
		at := Motion_Time(i64(deadline_at)+i64(opportunity)*100_000_000)
		after := motion_tick(&rt, at)
		_, ready := begin_presentation_frame(&rt)
		testing.expectf(t, after.status == .Ok && after.changed_owners == 0 && after.active_owners == 0 &&
			!ready && !rt.presentation_pending,
			"after Direct release settlement there should be no wake at opportunity %d", opportunity)
	}
}
