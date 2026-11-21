#+build !js
package alicorn

import "core:testing"

@(test)
test_motion_high_contrast_and_presentation_scales_preserve_logical_presentation :: proc(t: ^testing.T) {
	normal := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&normal)
	contrast := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&contrast)

	build := proc(rt: ^Runtime, environment: Style_Environment) -> (outer, child: Node_ID) {
		ui, ready := begin_frame(rt)
		if !ready { return }
		container_begin_simple(&ui, .Root, key="motion-appearance-root", style=layout_style(.Column, width=240, height=120))
		scope := style_environment_push(&ui, environment)
		outer = surface_begin(
			&ui, surface_core_color_role(.Surface), key="motion-appearance-outer",
			style=layout_style(.Column, width=180, height=80), fill=Color{0.2, 0.2, 0.2, 1},
		)
		child, _ = button_begin(
			&ui, "M", key=key_string("motion-appearance-child"),
			style=layout_style(.Row, width=60, height=30),
		)
		button_end(&ui)
		surface_end(&ui)
		style_environment_pop(&ui, scope)
		container_end(&ui)
		end_frame(&ui)
		return
	}
	high_contrast := Style_Environment{
		accessibility=Accessibility_Appearance_Preferences{increased_contrast=true},
		accessibility_set=true,
	}
	normal_outer, normal_child := build(&normal, {})
	contrast_outer, contrast_child := build(&contrast, high_contrast)
	_ = normal_outer
	_ = contrast_outer
	if normal_child == 0 || contrast_child == 0 {
		testing.expect(t, false, "both appearance fixtures should build")
		return
	}
	normal_handle, normal_status := motion_owner_begin(&normal, normal_child)
	contrast_handle, contrast_status := motion_owner_begin(&contrast, contrast_child)
	config := Motion_Config{omega=14, position_tolerance=0.001, velocity_tolerance=0.001}
	_ = config
	_ = motion_clock_set_time(&normal, Motion_Time(0))
	_ = motion_clock_set_time(&contrast, Motion_Time(0))
	target := Motion_Target{
		translation=Motion_Vector2{28, -6},
		opacity=0.55,
		has_translation=true,
		has_opacity=true,
		clip_policy=.Follow_Visual,
	}
	normal_target := motion_apply_intent(&normal, normal_child, target, .Snap)
	contrast_target := motion_apply_intent(&contrast, contrast_child, target, .Snap)
	_ = normal_handle
	_ = contrast_handle
	normal_ui, normal_ready := begin_presentation_frame(&normal)
	if normal_ready { end_presentation_frame(&normal_ui) }
	contrast_ui, contrast_ready := begin_presentation_frame(&contrast)
	if contrast_ready { end_presentation_frame(&contrast_ui) }
	normal_command, normal_found := motion_acceptance_find_command(&normal, normal_child, true)
	contrast_command, contrast_found := motion_acceptance_find_command(&contrast, contrast_child, true)
	testing.expect(t, normal_status == .Ok && contrast_status == .Ok &&
		normal_target == .Ok && contrast_target == .Ok && normal_ready && contrast_ready &&
		normal_found && contrast_found,
		"both normal and high-contrast motion fixtures should present")
	testing.expect(t, normal_command.translation == contrast_command.translation &&
		normal_command.opacity == contrast_command.opacity &&
		normal_command.translation == [2]f32{28, -6} && normal_command.opacity == 0.55,
		"high-contrast appearance must not change motion translation or opacity presentation")
	testing.expect(t, normal.nodes[normal_child].hit_bounds == contrast.nodes[contrast_child].hit_bounds,
		"high-contrast appearance must not move logical hit geometry")
	_ = config

	// Device scales finalize paint bounds only. The logical translation and
	// opacity, the retained target bounds, and hit testing stay invariant.
	logical_bounds := contrast.nodes[contrast_child].bounds
	hit_bounds_before := contrast.nodes[contrast_child].hit_bounds
	baseline_target, _ := motion_acceptance_find_command(&contrast, contrast_child, true)
	for scale in ([3]f32{1.25, 1.5, 1.75}) {
		changed := set_presentation_scale(&contrast, scale, scale)
		ui, ready := begin_presentation_frame(&contrast)
		if ready { end_presentation_frame(&ui) }
		frame_submission_succeeded(&contrast)
		target_command, found := motion_acceptance_find_command(&contrast, contrast_child, true)
		display_command, display_found := motion_acceptance_find_command(&contrast, contrast_child)
		_ = display_command
		finalized := layout_node_finalized_geometry(&contrast, contrast_child)
		testing.expectf(t, changed && ready && found && display_found,
			"a presentation scale change to %.2f should request and finalize one frame", scale)
		testing.expectf(t, target_command.translation == baseline_target.translation &&
			target_command.translation == [2]f32{28, -6} && target_command.opacity == 0.55,
			"logical motion presentation must stay invariant at scale %.2f", scale)
		testing.expectf(t, contrast.presentation_scale_x == scale && contrast.presentation_scale_y == scale,
			"presentation scale should report %.2f", scale)
		testing.expectf(t, abs(finalized.bounds.x-logical_bounds.x) <= 1/scale &&
			abs(finalized.bounds.w-logical_bounds.w) <= 1/scale,
			"device pixel snapping at %.2f should stay within one device pixel of logical bounds", scale)
		if scale != 1.5 {
			testing.expectf(t, abs(finalized.bounds.h-logical_bounds.h) > 1e-4,
				"scale %.2f should demonstrate device-pixel quantization of the presentation geometry", scale)
		}
		testing.expectf(t, contrast.nodes[contrast_child].hit_bounds == hit_bounds_before &&
			hit_test(&contrast, logical_bounds.x+logical_bounds.w*0.5,
				logical_bounds.y+logical_bounds.h*0.5) == contrast_child,
			"hit testing must remain in logical coordinates at scale %.2f", scale)
	}
}

