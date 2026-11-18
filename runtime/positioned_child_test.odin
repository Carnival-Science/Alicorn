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
