#+build !js
package alicorn

import "core:testing"

@(test)
test_motion_composition_applies_three_ancestor_levels_exactly_once :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 160})
	defer destroy_runtime(&rt)
	levels, leaf := motion_acceptance_build_nested(&rt)
	if leaf == 0 { testing.expect(t, false, "the nested composition fixture should build"); return }
	config := Motion_Config{omega=12, position_tolerance=0.001, velocity_tolerance=0.001}
	translations := [3]Motion_Vector2{{10, 5}, {2, 3}, {5, -1}}
	opacities := [3]f64{0.9, 0.8, 0.5}
	for level, index in levels {
		handle, status := motion_owner_begin(&rt, level)
		if status != .Ok {
			testing.expectf(t, false, "ancestor level %d should acquire a motion owner", index)
			return
		}
		testing.expectf(t, motion_target_translation(&rt, handle, translations[index], config, .Snap, Motion_Time(0)) == .Ok &&
			motion_target_opacity(&rt, handle, opacities[index], config, .Snap, Motion_Time(0)) == .Ok,
			"ancestor level %d should commit translation and opacity", index)
	}
	ui, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&ui) }
	command, found := motion_acceptance_find_command(&rt, leaf, true)
	expected_translation := [2]f32{
		f32(translations[0].x+translations[1].x+translations[2].x),
		f32(translations[0].y+translations[1].y+translations[2].y),
	}
	expected_opacity := f32(opacities[0]*opacities[1]*opacities[2])
	testing.expect(t, ready && found && command.translation == expected_translation,
		"a leaf under three motion ancestors must consume the summed translation exactly once")
	testing.expect(t, abs(command.opacity-expected_opacity) <= 1e-6,
		"opacity must multiply through each ancestor exactly once")
	testing.expect(t, command.translation != [2]f32{expected_translation.x*2, expected_translation.y*2},
		"the result must not look like a per-level re-application of the composed transform")
}

@(test)
test_motion_follow_visual_inside_scrolled_clip_translates_clip_once :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&rt)
	scroll, moving, leaf := motion_acceptance_build_scrolled(&rt)
	if scroll == 0 || moving == 0 || leaf == 0 {
		testing.expect(t, false, "the scrolled-clip fixture should build")
		return
	}
	// Offset the scroll region, then describe once more so layout bakes the
	// offset into the moving row's logical bounds.
	testing.expect(t, scroll_region_set_offset(&rt, scroll, 40, "motion acceptance scroll offset"),
		"the scroll fixture should accept its logical offset")
	invalidate_root(&rt, "apply motion acceptance scroll offset")
	scroll, moving, leaf = motion_acceptance_build_scrolled(&rt)
	viewport := rt.nodes[scroll].scroll_viewport_bounds
	moving_bounds := rt.nodes[moving].bounds
	moving_clip := rt.nodes[moving].clip
	hit_before := rt.nodes[leaf].hit_bounds
	testing.expect(t, moving_bounds.y == 0 && viewport.y == 0 && rt.nodes[scroll].scroll_offset_y == 40,
		"the fixture should place the scrolled moving row from its offset exactly once")

	handle, status := motion_owner_begin(&rt, moving)
	config := Motion_Config{omega=12, position_tolerance=0.001, velocity_tolerance=0.001}
	_ = motion_clock_set_time(&rt, Motion_Time(0))
	target := Motion_Target{translation=Motion_Vector2{24, 8}, has_translation=true, clip_policy=.Follow_Visual}
	testing.expect(t, status == .Ok && motion_apply_intent(&rt, moving, target, .Snap) == .Ok,
		"the scrolled moving row should accept Follow_Visual translation")
	_ = handle
	ui, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&ui) }
	command, found := motion_acceptance_find_command(&rt, leaf, true)
	expected_clip := rect_intersection(viewport, Rect{
		moving_bounds.x+24, moving_bounds.y+8, moving_bounds.w, moving_bounds.h,
	})
	testing.expect(t, ready && found && command.translation == [2]f32{24, 8},
		"the leaf command should receive the Follow_Visual translation")
	testing.expect(t, command.clip == expected_clip && command.clip.y == moving_bounds.y+8,
		"the moved clip should be translated once against the stationary scroll viewport")
	testing.expect(t, command.clip.y != moving_bounds.y+16 &&
		moving_bounds.y == 0 && rt.nodes[scroll].scroll_offset_y == 40,
		"neither the motion clip translation nor the scroll offset may be applied twice")
	testing.expect(t, rt.nodes[moving].clip == moving_clip && rt.nodes[leaf].hit_bounds == hit_before,
		"Follow_Visual is paint-only; retained logical clips and hit geometry must stay fixed")
}

