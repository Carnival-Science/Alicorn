#+build !js

package alicorn

import "core:math"
import "core:testing"

// Issue #207: ruler-style labels need to sit at explicit surface-local
// coordinates without a fixed-width spacer row. These fixtures pin the
// renderer-neutral placement seam: positioned children are ordinary retained
// nodes that reuse measurement, shaping, paint, clipping, and semantics.

POSITIONED_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

positioned_test_close :: proc(a, b: f32) -> bool {
	return math.abs(a-b) <= 0.02
}

positioned_test_render :: proc(
	rt: ^Runtime,
	x, y: f32,
	horizontal := Positioned_Horizontal.Start,
	vertical := Positioned_Vertical.Top,
	clip := false,
	opacity: f32 = 1,
	value := "0:00",
	include_surface := false,
	flow_height: f32 = -1,
	semantic := false,
	owner_height: f32 = 120,
) -> (owner, label, surface: Node_ID) {
	invalidate_root(rt, "positioned child fixture")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, key=key_string("positioned-root"), style=layout_style(.Column, width=400, height=200))
	owner = container_begin(&ui, .Container, key=key_string("positioned-owner"), style=layout_style(.Column, width=300, height=owner_height, padding=8))
	if include_surface {
		surface = gpu_geometry_surface(&ui, "positioned-ticks", layout_style(width=-1, height=20), 1)
	}
	if flow_height >= 0 {
		flow := container_begin(&ui, .Container, key=key_string("positioned-flow"), style=layout_style(.Column, width=40, height=flow_height))
		container_end(&ui)
	}
	label = text(&ui, value, key=key_string("positioned-label"))
	_ = position_child(&ui, label, positioned(x, y, horizontal=horizontal, vertical=vertical, clip=clip, opacity=opacity))
	if semantic { _ = semantic_static_text(&ui) }
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return
}

positioned_test_anchor :: proc(owner: ^Node, x, y: f32) -> (f32, f32) {
	inner_x := owner.bounds.x+owner.style.padding
	inner_y := owner.bounds.y+owner.style.padding
	return layout_unit_to_f32(layout_unit_position(inner_x)+layout_unit_position(x)),
		layout_unit_to_f32(layout_unit_position(inner_y)+layout_unit_position(y))
}

positioned_test_render_decoration :: proc(
	rt: ^Runtime,
	width, height: f32,
	shape: Surface_Shape,
	stroke_width: f32 = 0,
	width_mode: Positioned_Width_Mode = .Authored,
	owner_width: f32 = 200,
) -> (owner, decoration: Node_ID) {
	invalidate_root(rt, "positioned decoration extent fixture")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, key=key_string("positioned-decoration-root"), style=layout_style(.Column, width=400, height=200))
	owner, _ = button_begin(&ui, "Owner", key=key_string("positioned-decoration-owner"),
		style=layout_style(.Row, width=owner_width, height=64), presentation=.Custom)
	decoration = surface_begin(
		&ui,
		surface_core_color_role(.Accent),
		key=key_string("positioned-decoration"),
		style=layout_style(.Row, width=width, height=height),
		shape=shape,
		fill=Color{0.2, 0.3, 0.4, 1},
		stroke=Paint_Stroke{color=Color{0.9, 0.9, 0.9, 1}, width=stroke_width},
		stroke_placement=.Inside,
	)
	surface_end(&ui)
	_ = position_child(&ui, decoration, positioned(0, 0, width_mode=width_mode))
	_ = visual_part_attach(&ui, decoration, owner,
		visual_part_extension_id("alicorn.test", "positioned-decoration"))
	button_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return
}

@(test)
test_positioned_child_can_fill_owner_content_width :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	owner, decoration := positioned_test_render_decoration(
		&rt,
		-1,
		6,
		surface_shape_uniform_corner_radius(2),
		width_mode=.Fill_Available,
	)
	if !testing.expect(t, owner != 0 && decoration != 0, "the positioned surface should be retained") { return }
	owner_bounds := rt.nodes[owner].bounds
	decoration_bounds := rt.nodes[decoration].bounds
	expected_width := maxf(owner_bounds.w-2*rt.nodes[owner].style.padding, 0)
	command, _, command_ok := positioned_test_surface_command(&rt, decoration)
	testing.expect(t, positioned_test_close(decoration_bounds.x, owner_bounds.x+rt.nodes[owner].style.padding) &&
		positioned_test_close(decoration_bounds.w, expected_width) &&
		command_ok && positioned_test_close(command.bounds.w, expected_width),
		"Fill_Available should resolve a positioned visual to the owner's current content width")
	before_measurements := rt.stats.measure_nodes_executed
	owner_after, decoration_after := positioned_test_render_decoration(
		&rt,
		-1,
		6,
		surface_shape_uniform_corner_radius(2),
		width_mode=.Fill_Available,
		owner_width=240,
	)
	updated := rt.nodes[decoration_after]
	testing.expect(t, owner_after == owner && decoration_after == decoration &&
		positioned_test_close(updated.bounds.w, 240-2*rt.nodes[owner].style.padding) &&
		rt.stats.measure_nodes_executed > before_measurements,
		"Fill_Available should remeasure the same child when its owner's content width changes")
}

positioned_test_surface_command :: proc(rt: ^Runtime, node_id: Node_ID) -> (command: Paint_Command, surface: Surface_Paint, found: bool) {
	for candidate in rt.display {
		if candidate.owner != node_id { continue }
		if payload, is_surface := candidate.payload.(Surface_Paint); is_surface { return candidate, payload, true }
	}
	return
}

@(test)
test_positioned_decoration_extent_updates_with_stable_identity :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	bar_shape := surface_shape_uniform_corner_radius(1)
	dot_shape := surface_shape_uniform_corner_radius(3)
	owner, decoration := positioned_test_render_decoration(&rt, 3, 16, bar_shape)
	if !testing.expect(t, owner != 0 && decoration != 0, "the positioned visual part should be retained") { return }
	first_bounds := rt.nodes[decoration].bounds
	first_finalized, first_finalized_ok := rt.finalized_geometry[decoration]
	first_command, first_surface, first_command_ok := positioned_test_surface_command(&rt, decoration)
	if !testing.expect(t, first_finalized_ok && first_command_ok &&
		positioned_test_close(first_bounds.w, 3) && positioned_test_close(first_bounds.h, 16) &&
		positioned_test_close(first_finalized.bounds.w, 3) && positioned_test_close(first_finalized.bounds.h, 16) &&
		positioned_test_close(first_command.bounds.w, 3) && positioned_test_close(first_command.bounds.h, 16) &&
		first_surface.shape.corner_radius == 1,
		"the initial bar should have 3-by-16 retained, finalized and painted bounds") {
		return
	}

	before_measurements := rt.stats.measure_nodes_executed
	owner_after, decoration_after := positioned_test_render_decoration(&rt, 6, 6, dot_shape)
	retained := rt.nodes[decoration_after]
	finalized, finalized_ok := rt.finalized_geometry[decoration_after]
	dot_command, dot_surface, dot_command_ok := positioned_test_surface_command(&rt, decoration_after)
	testing.expect(t, owner_after == owner && decoration_after == decoration,
		"changing a bar into a dot should preserve the Button owner and positioned visual-part identity")
	final_part, part_found := rt.visual_parts[decoration_after]
	testing.expect(t, final_part.owner == owner && part_found,
		"the positioned decoration should remain attached to its original Button owner")
	testing.expect(t, retained != nil && positioned_test_close(retained.bounds.w, 6) && positioned_test_close(retained.bounds.h, 6) &&
		finalized_ok && positioned_test_close(finalized.bounds.w, 6) && positioned_test_close(finalized.bounds.h, 6) &&
		dot_command_ok && positioned_test_close(dot_command.bounds.w, 6) && positioned_test_close(dot_command.bounds.h, 6) &&
		dot_surface.shape.corner_radius == 3 && rt.stats.measure_nodes_executed > before_measurements,
		"bar-to-dot sizing should refresh retained, finalized and painted bounds without replacing the node")

	layout_visits := rt.stats.layout_nodes_visited
	owner_after, decoration_after = positioned_test_render_decoration(&rt, 6, 6, surface_shape_uniform_corner_radius(5))
	_, radius_surface, radius_command_ok := positioned_test_surface_command(&rt, decoration_after)
	testing.expect(t, owner_after == owner && decoration_after == decoration && radius_command_ok &&
		radius_surface.shape.corner_radius == 5 && rt.stats.layout_nodes_visited == layout_visits,
		"changing only the radius should repaint the same node without layout work")

	owner_after, decoration_after = positioned_test_render_decoration(&rt, 6, 6,
		surface_shape_uniform_corner_radius(5), stroke_width=2)
	stroke_command, stroke_surface, stroke_command_ok := positioned_test_surface_command(&rt, decoration_after)
	owner_clip := rt.nodes[owner].clip
	testing.expect(t, owner_after == owner && decoration_after == decoration && stroke_command_ok &&
		stroke_surface.stroke.width == 2 && stroke_command.stroke_placement == .Inside &&
		stroke_command.bounds.w == 6 && stroke_command.bounds.h == 6 && stroke_command.clip == owner_clip,
		"a stroke-width change should update paint while retaining the owner's clipping bounds")

	owner_after, decoration_after = positioned_test_render_decoration(&rt, 3, 16, bar_shape)
	returned, returned_surface, returned_ok := positioned_test_surface_command(&rt, decoration_after)
	returned_geometry, returned_geometry_ok := rt.finalized_geometry[decoration_after]
	fresh := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&fresh)
	fresh_owner, fresh_decoration := positioned_test_render_decoration(&fresh, 3, 16, bar_shape)
	fresh_command, fresh_surface, fresh_ok := positioned_test_surface_command(&fresh, fresh_decoration)
	fresh_geometry, fresh_geometry_ok := fresh.finalized_geometry[fresh_decoration]
	testing.expect(t, owner_after == owner && decoration_after == decoration && returned_ok && fresh_owner != 0 && fresh_ok &&
		returned.bounds == fresh_command.bounds && returned.clip == fresh_command.clip &&
		returned_surface == fresh_surface && returned_geometry_ok && fresh_geometry_ok &&
		returned_geometry.bounds == fresh_geometry.bounds && returned_geometry.clip == fresh_geometry.clip,
		"changing back to the original bar should match a fresh runtime's paint and finalized geometry")

	_ = motion_clock_set_time(&rt, Motion_Time(0))
	handle, handle_status := motion_owner_begin(&rt, decoration)
	motion_status := motion_apply_intent(&rt, decoration,
		Motion_Target{translation=Motion_Vector2{12, 0}, has_translation=true}, .Settle)
	_ = motion_tick(&rt, Motion_Time(50_000_000))
	ui, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&ui) }
	active_motion := motion_presentation(&rt, handle)
	owner_after, decoration_after = positioned_test_render_decoration(&rt, 6, 6, dot_shape)
	animated_command, animated_surface, animated_command_ok := positioned_test_surface_command(&rt, decoration_after)
	active_after_shape_change := motion_presentation(&rt, handle)
	testing.expect(t, handle_status == .Ok && motion_status == .Ok && ready && active_motion.active &&
		owner_after == owner && decoration_after == decoration && active_after_shape_change.active &&
		positioned_test_close(rt.nodes[decoration].bounds.w, 6) && positioned_test_close(rt.nodes[decoration].bounds.h, 6) &&
		animated_command_ok && animated_surface.shape.corner_radius == 3 && animated_command.translation[0] > 0,
		"a shape and extent change during motion should preserve motion state and publish the new geometry")
}

positioned_test_render_content_height :: proc(rt: ^Runtime, height: f32) -> (decoration: Node_ID) {
	invalidate_root(rt, "positioned content-height fixture")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, key=key_string("positioned-content-height-root"), style=layout_style(.Column, width=400, height=200))
	container_begin(&ui, .Container, key=key_string("positioned-content-height-owner"), style=layout_style(.Column, width=200, height=100))
	decoration = container_begin(&ui, .Container, key=key_string("positioned-content-height-decoration"),
		style=layout_style(.Column, width=80, height=height))
	container_begin(&ui, .Container, key=key_string("positioned-content-height-child"),
		style=layout_style(.Column, width=80, height=40))
	container_end(&ui)
	container_end(&ui)
	_ = position_child(&ui, decoration, positioned(0, 0))
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return
}

@(test)
test_positioned_child_height_change_updates_same_decoration_bounds :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	shape := surface_shape_uniform_corner_radius(4)
	owner, decoration := positioned_test_render_decoration(&rt, 120, 44, shape)
	if !testing.expect(t, owner != 0 && decoration != 0, "the positioned outline should be retained") { return }
	before_measurements := rt.stats.measure_nodes_executed
	owner_after, decoration_after := positioned_test_render_decoration(&rt, 120, 50, shape)
	command, _, command_ok := positioned_test_surface_command(&rt, decoration_after)
	finalized, finalized_ok := rt.finalized_geometry[decoration_after]
	testing.expect(t, owner_after == owner && decoration_after == decoration &&
		positioned_test_close(rt.nodes[decoration].bounds.h, 50) &&
		finalized_ok && positioned_test_close(finalized.bounds.h, 50) &&
		command_ok && positioned_test_close(command.bounds.h, 50) &&
		rt.stats.measure_nodes_executed > before_measurements,
		"a 44-to-50 height edit should update the same retained decoration and its paint bounds")
}

@(test)
test_positioned_child_content_height_mode_invalidates_measurement :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	decoration := positioned_test_render_content_height(&rt, -1)
	if !testing.expect(t, decoration != 0 && positioned_test_close(rt.nodes[decoration].bounds.h, 24),
		"an unconstrained positioned container should begin with its intrinsic 24-unit height") {
		return
	}
	updated := positioned_test_render_content_height(&rt, LAYOUT_SIZE_FIT_CONTENT)
	testing.expect(t, updated == decoration && positioned_test_close(rt.nodes[updated].bounds.h, 40),
		"changing the same positioned container to fit-content should measure its 40-unit child")
}

@(test)
test_positioned_child_horizontal_and_vertical_alignment :: proc(t: ^testing.T) {
	for horizontal in Positioned_Horizontal {
		for vertical in Positioned_Vertical {
			rt := new_runtime(Rect{0, 0, 400, 200})
			if !text_engine_load_font(&rt.text_engine, POSITIONED_TEST_FONT) {
				testing.expect(t, false, "positioned alignment fixture font should load")
				destroy_runtime(&rt)
				return
			}
			owner_id, label_id, _ := positioned_test_render(&rt, 40, 30, horizontal, vertical)
			owner := rt.nodes[owner_id]
			label := rt.nodes[label_id]
			if owner == nil || label == nil || !label.text_run_valid {
				testing.expect(t, false, "alignment fixture should retain owner and shaped label")
				destroy_runtime(&rt)
				continue
			}
			anchor_x, anchor_y := positioned_test_anchor(owner, 40, 30)
			left := label.bounds.x
			right := label.bounds.x+label.bounds.w
			top := label.bounds.y
			bottom := label.bounds.y+label.bounds.h
			horizontal_ok := true
			switch horizontal {
			case .Start: horizontal_ok = positioned_test_close(left, anchor_x)
			case .Center: horizontal_ok = positioned_test_close(left+label.bounds.w*0.5, anchor_x)
			case .End: horizontal_ok = positioned_test_close(right, anchor_x)
			}
			vertical_ok := true
			switch vertical {
			case .Top: vertical_ok = positioned_test_close(top, anchor_y)
			case .Middle: vertical_ok = positioned_test_close(top+label.bounds.h*0.5, anchor_y)
			case .Bottom: vertical_ok = positioned_test_close(bottom, anchor_y)
			case .Baseline:
				vertical_ok = positioned_test_close(top+label.text_run.lines[0].baseline, anchor_y)
			}
			testing.expectf(t, horizontal_ok, "%v alignment should place the label relative to the owner content box", horizontal)
			testing.expectf(t, vertical_ok, "%v alignment should place the label relative to the owner content box", vertical)
			testing.expectf(t, positioned_test_close(owner.bounds.h, 120),
				"an explicitly sized owner should keep its authored rectangle")
			destroy_runtime(&rt)
		}
	}
}

@(test)
test_positioned_child_clipping_and_opacity_are_explicit :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	if !text_engine_load_font(&rt.text_engine, POSITIONED_TEST_FONT) {
		testing.expect(t, false, "positioned clip fixture font should load")
		return
	}
	owner_id, label_id, _ := positioned_test_render(&rt, 280, 100, clip=true, opacity=0.5)
	owner := rt.nodes[owner_id]
	label := rt.nodes[label_id]
	if owner == nil || label == nil {
		testing.expect(t, false, "clip fixture should retain its nodes")
		return
	}
	testing.expect(t, label.clip == rect_intersection(owner.clip, owner.bounds),
		"clip=true should clip the label to its owner bounds")
	testing.expect(t, label.clip == owner.bounds,
		"the owner clip is the viewport, so its bounds are the effective label clip")
	testing.expect(t, len(label.paint) > 0, "the positioned label should emit retained paint")
	for command in label.paint {
		testing.expectf(t, command.opacity == 0.5,
			"placement opacity should scale every emitted command, got %.3f", command.opacity)
	}

	_, unbounded_id, _ := positioned_test_render(&rt, 280, 100, clip=false)
	unbounded := rt.nodes[unbounded_id]
	testing.expect(t, unbounded.clip == rt.nodes[owner_id].clip,
		"clip=false should inherit the owner clip instead of the owner bounds")
}

@(test)
test_positioned_child_semantics_and_input_are_not_implied :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	if !text_engine_load_font(&rt.text_engine, POSITIONED_TEST_FONT) {
		testing.expect(t, false, "positioned semantic fixture font should load")
		return
	}
	_, decorative_id, _ := positioned_test_render(&rt, 20, 20)
	decorative := rt.nodes[decorative_id]
	testing.expect(t, decorative != nil && !decorative.focusable && !decorative.text_input_target,
		"a decorative positioned label should not enter focus traversal or text input")
	_, found := rt.semantic_entities[semantic_visual_id(decorative_id)]
	testing.expect(t, !found, "a decorative positioned label should not invent a semantic entity")
	center := Rect{decorative.bounds.x+decorative.bounds.w*0.5, decorative.bounds.y+decorative.bounds.h*0.5, 0, 0}
	testing.expect(t, hit_test(&rt, center.x, center.y) == 0,
		"a decorative positioned label must not intercept pointer gestures")

	_, meaningful_id, _ := positioned_test_render(&rt, 20, 20, semantic=true)
	entity, entity_found := rt.semantic_entities[semantic_visual_id(meaningful_id)]
	testing.expect(t, entity_found && entity.node.role == .Static_Text && entity.node.has_bounds,
		"semantic_static_text should export a positioned label as meaningful static text")
	finalized, finalized_ok := rt.finalized_geometry[meaningful_id]
	testing.expect(t, entity_found && finalized_ok && entity.node.bounds == finalized.bounds,
		"the exported semantic bounds should follow the positioned label's finalized bounds")
}

@(test)
test_positioned_children_do_not_contribute_to_fit_content_owner :: proc(t: ^testing.T) {
	fixture := proc(t: ^testing.T, flow_height: f32, want_height: f32) {
		rt := new_runtime(Rect{0, 0, 400, 200})
		defer destroy_runtime(&rt)
		if !text_engine_load_font(&rt.text_engine, POSITIONED_TEST_FONT) {
			testing.expect(t, false, "fit-content positioned fixture font should load")
			return
		}
		owner_id, label_id, _ := positioned_test_render(
			&rt, 20, 20, flow_height=flow_height, owner_height=LAYOUT_SIZE_FIT_CONTENT,
		)
		owner := rt.nodes[owner_id]
		label := rt.nodes[label_id]
		if owner == nil || label == nil {
			testing.expect(t, false, "fit-content positioned fixture should retain its nodes")
			return
		}
		testing.expectf(t, positioned_test_close(owner.bounds.h, want_height),
			"positioned children should not size the owner: want %.3f, got %.3f", want_height, owner.bounds.h)
		testing.expectf(t, positioned_test_close(label.bounds.y, owner.bounds.y+owner.style.padding+20),
			"the label should keep its explicit y even when the owner measures only flow content")
	}
	// Each label measures; only the padded fit-content owner and its one flow
	// child contribute to the owner height.
	fixture(t, -1, 2*8)
	fixture(t, 30, 30+2*8)
}

@(test)
test_positioned_label_moves_reuse_shaping_and_keep_geometry_payload :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 400, 200})
	defer destroy_runtime(&rt)
	if !text_engine_load_font(&rt.text_engine, POSITIONED_TEST_FONT) {
		testing.expect(t, false, "positioned shaping fixture font should load")
		return
	}
	_, first_label, surface := positioned_test_render(&rt, 20, 20, value="0:00", include_surface=true)
	if !gpu_surface_update_geometry(&rt, surface, nil, nil) {
		testing.expect(t, false, "the retained ticks surface should accept a geometry payload")
		return
	}
	revision := u64(rt.nodes[surface].surface_payload_revision)
	testing.expect(t, revision == 1, "explicit geometry updates should own the payload revision")

	shapes_before := rt.stats.text_shape_requests
	_, moved_label, _ := positioned_test_render(&rt, 120, 20, value="0:00", include_surface=true)
	testing.expect(t, moved_label == first_label, "a move-only description should retain the label node")
	testing.expectf(t, positioned_test_close(rt.nodes[moved_label].bounds.x, 8+120),
		"the moved label should place at its new surface-local x")
	testing.expect(t, rt.stats.text_shape_requests == shapes_before,
		"a position-only update must reuse the retained shaped run")
	testing.expect(t, u64(rt.nodes[surface].surface_payload_revision) == revision,
		"moving a label must not invalidate retained geometry")

	_, edited_label, _ := positioned_test_render(&rt, 120, 20, value="0:01", include_surface=true)
	testing.expect(t, edited_label == first_label, "a text-only update should retain the label node")
	testing.expect(t, rt.stats.text_shape_requests > shapes_before,
		"changing label text should request exactly the required new shaping work")
	testing.expect(t, u64(rt.nodes[surface].surface_payload_revision) == revision,
		"a label text update must not invalidate retained geometry")
}
