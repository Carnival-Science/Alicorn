#+build !js

package ui

import "core:math"
import "core:testing"
import alicorn "alicorn:runtime"

// Issue #158 production-validation fixtures for definite-parent percentage
// width. These use realistic compositions (nested percentage columns,
// percentage children inside rows, panels and scroll regions, positioned
// children, cached regions, theme/text-scale changes and presentation scale)
// and compare retained updates with a fresh runtime at the same inputs.

UI_PERCENT_VALIDATION_EPSILON :: f32(0.05)
UI_PERCENT_VALIDATION_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

ui_percent_validation_close :: proc(a, b: f32) -> bool {
	return math.abs(a-b) <= UI_PERCENT_VALIDATION_EPSILON
}

ui_percent_validation_last_id :: proc(ui: ^UI) -> alicorn.Node_ID {
	if ui == nil || ui.runtime == nil || len(ui.runtime.pending) == 0 { return 0 }
	return ui.runtime.pending[len(ui.runtime.pending)-1].description.id
}

// Retained measurement constraints are stored in canonical Layout_Units.
ui_percent_validation_text_max_width :: proc(rt: ^alicorn.Runtime, id: alicorn.Node_ID) -> f32 {
	max := rt.measure_states[id].cache_key.constraints.width.max
	return f32(i64(max))/alicorn.LAYOUT_UNIT_SCALE
}

// Retained-only resize: no application description is emitted, so percentage
// dependencies must follow the host viewport through layout alone.
ui_percent_validation_retained_resize :: proc(rt: ^alicorn.Runtime, width: f32) {
	rt.viewport = alicorn.Rect{0, 0, width, 480}
	rt.layout_pending = true
	rt.frame_open = true
	ctx := alicorn.UI{runtime=rt}
	alicorn.end_presentation_frame(&ctx)
}

UI_Percent_Validation_Nested :: struct {
	root, outer, inner, body: alicorn.Node_ID,
}

ui_percent_validation_nested_frame :: proc(rt: ^alicorn.Runtime, viewport_width: f32) -> (nodes: UI_Percent_Validation_Nested) {
	rt.viewport = alicorn.Rect{0, 0, viewport_width, 480}
	alicorn.invalidate_root(rt, "percentage validation nested fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	nodes.root = alicorn.container_begin(&ctx, .Root, key="pct-validation-nested-root",
		style=alicorn.layout_style(.Column, padding=20, gap=8))
	if layout_sized(&ctx, alicorn.layout_style(.Column, height=320, padding=12, gap=4),
		sizing(width=percent(0.5)), key="pct-validation-outer", label="nested outer percent") {
		nodes.outer = ui_percent_validation_last_id(&ctx)
		if layout_sized(&ctx, alicorn.layout_style(.Column, height=200, padding=8),
			sizing(width=percent(0.5)), key="pct-validation-inner", label="nested inner percent") {
			nodes.inner = ui_percent_validation_last_id(&ctx)
			nodes.body = text(&ctx,
				"Nested percentage width must resolve the outer basis before the inner one while wrapped text measurement follows the new constraint.",
				key="pct-validation-nested-body",
				text_style=alicorn.Text_Style{overflow=.Wrap})
		}
	}
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

ui_percent_validation_expect_nested_basis :: proc(
	t: ^testing.T,
	rt: ^alicorn.Runtime,
	nodes: UI_Percent_Validation_Nested,
	outer_width, inner_width: f32,
	message: string,
) {
	outer, outer_found := rt.nodes[nodes.outer]
	inner, inner_found := rt.nodes[nodes.inner]
	testing.expect(t, outer_found && inner_found && ui_percent_validation_close(outer.bounds.w, outer_width) &&
		ui_percent_validation_close(inner.bounds.w, inner_width),
		message)
}

@(test)
test_nested_percentage_width_matches_fresh_geometry_across_retained_resize :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 480})
	defer alicorn.destroy_runtime(&rt)
	nodes := ui_percent_validation_nested_frame(&rt, 800)
	if nodes.outer == 0 || nodes.inner == 0 || nodes.body == 0 {
		testing.expect(t, false, "the nested percentage fixture should describe both levels and wrapped text")
		return
	}
	// Root padding 20: 760 inner. Outer 50% = 380; its padding 12 leaves 356.
	// Inner 50% of 356 = 178; its padding 8 leaves 162 for the text.
	ui_percent_validation_expect_nested_basis(t, &rt, nodes, 380, 178,
		"the first description must resolve both nested percentage levels against the current parent basis")
	testing.expect(t, ui_percent_validation_close(ui_percent_validation_text_max_width(&rt, nodes.body), 162),
		"the wrapped body should measure against the inner percentage content width")

	outer_id, inner_id, body_id := nodes.outer, nodes.inner, nodes.body
	outer_description_hash := rt.nodes[nodes.outer].description_hash
	measure_misses_before := rt.stats.measure_cache_misses

	widths := [4]f32{1000, 640, 1200, 800}
	for width in widths {
		ui_percent_validation_retained_resize(&rt, width)
		expected_outer := (width-40)*0.5
		expected_inner := (expected_outer-24)*0.5
		ui_percent_validation_expect_nested_basis(t, &rt, nodes,
			expected_outer, expected_inner,
			"a retained-only resize must resolve the outer percentage before the inner one")
		testing.expect(t, nodes.outer == outer_id && nodes.inner == inner_id && nodes.body == body_id &&
			rt.nodes[nodes.outer].description_hash == outer_description_hash,
			"nested percentage updates must preserve Node_IDs and description identity")
		testing.expect(t, ui_percent_validation_close(ui_percent_validation_text_max_width(&rt, nodes.body),
			expected_inner-16),
			"the wrapped body constraint must follow the inner percentage width after retained resize")

		fresh := alicorn.new_runtime(alicorn.Rect{0, 0, width, 480})
		fresh_nodes := ui_percent_validation_nested_frame(&fresh, width)
		testing.expect(t, fresh_nodes.outer != 0 && fresh_nodes.inner != 0 &&
			rt.nodes[nodes.outer].bounds == fresh.nodes[fresh_nodes.outer].bounds &&
			rt.nodes[nodes.inner].bounds == fresh.nodes[fresh_nodes.inner].bounds &&
			rt.nodes[nodes.body].bounds == fresh.nodes[fresh_nodes.body].bounds,
			"retained nested percentage geometry must equal a fresh runtime at the same viewport")
		alicorn.destroy_runtime(&fresh)
	}
	testing.expect(t, rt.stats.measure_cache_misses > measure_misses_before,
		"retained percentage basis changes must invalidate the wrapped text measurement")
}

UI_Percent_Validation_Cached :: struct {
	parent, outer, inner, body: alicorn.Node_ID,
}

ui_percent_validation_cached_frame :: proc(
	rt: ^alicorn.Runtime,
	parent_width: f32,
	revision: u64,
) -> (nodes: UI_Percent_Validation_Cached) {
	rt.viewport = alicorn.Rect{0, 0, 800, 400}
	alicorn.invalidate_root(rt, "percentage validation cached fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ctx, .Root, key="pct-validation-cached-root", style=alicorn.layout_style(.Column))
	parent_id, reused := alicorn.region_begin(&ctx, "pct-validation-cached-parent", revision,
		style=alicorn.layout_style(.Column, width=parent_width, height=240))
	nodes.parent = parent_id
	if !reused {
		if layout_sized(&ctx, alicorn.layout_style(.Column, height=200, padding=12),
			sizing(width=percent(0.5)), key="pct-validation-cached-outer", label="cached outer percent") {
			nodes.outer = ui_percent_validation_last_id(&ctx)
			if layout_sized(&ctx, alicorn.layout_style(.Column, height=140, padding=8),
				sizing(width=percent(0.5)), key="pct-validation-cached-inner", label="cached inner percent") {
				nodes.inner = ui_percent_validation_last_id(&ctx)
				nodes.body = text(&ctx,
					"Cached-region percentage children must resolve their nested bases in parent order and update wrapped text.",
					key="pct-validation-cached-body",
					text_style=alicorn.Text_Style{overflow=.Wrap})
			}
		}
		alicorn.region_end(&ctx, nodes.parent, reused, 0)
	}
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

@(test)
test_nested_percentage_width_inside_cached_region_matches_fresh_parent_basis :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 400})
	defer alicorn.destroy_runtime(&rt)
	first := ui_percent_validation_cached_frame(&rt, 400, 1)
	if first.parent == 0 { testing.expect(t, false, "the cached percentage fixture should describe"); return }
	outer, outer_found := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-outer"), .Container)
	inner, inner_found := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-inner"), .Container)
	body, body_found := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-body"), .Text)
	if !outer_found || !inner_found || !body_found {
		testing.expect(t, false, "the cached fixture should create both percentage levels and body text")
		return
	}
	testing.expect(t, ui_percent_validation_close(rt.nodes[outer].bounds.w, 200) &&
		ui_percent_validation_close(rt.nodes[inner].bounds.w, 88),
		"the cached parent's 400-unit width should resolve 50% then 50% of the padded inner width")
	outer_description_hash := rt.nodes[outer].description_hash
	outer_layout_hash := rt.nodes[outer].layout_hash
	body_constraint_before := rt.measure_states[body].cache_key.constraints.width.max
	visited_before := rt.stats.reconcile_nodes_visited
	skipped_before := rt.stats.regions_skipped

	// The parent basis changes while the region revision and its application
	// content stay unchanged. The retained sidecar must replay parent-first.
	second := ui_percent_validation_cached_frame(&rt, 600, 1)
	outer_after, _ := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-outer"), .Container)
	inner_after, _ := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-inner"), .Container)
	body_after, _ := alicorn.node_by_key(&rt, alicorn.key_string("pct-validation-cached-body"), .Text)
	testing.expect(t, second.parent == first.parent && outer_after == outer && inner_after == inner && body_after == body,
		"a reused region must preserve every nested percentage identity")
	testing.expectf(t, rt.stats.regions_skipped-skipped_before == 1 && rt.stats.reconcile_nodes_visited-visited_before == 2,
		"the parent basis change should update retained descendants without rebuilding the region body: skipped=%d visited=%d",
		rt.stats.regions_skipped-skipped_before, rt.stats.reconcile_nodes_visited-visited_before)
	testing.expect(t, ui_percent_validation_close(rt.nodes[outer].bounds.w, 300) &&
		ui_percent_validation_close(rt.nodes[inner].bounds.w, 138),
		"nested cached percentages must follow the new parent width in parent-first order")
	testing.expect(t, rt.nodes[outer].description_hash == outer_description_hash &&
		rt.nodes[outer].layout_hash != outer_layout_hash,
		"the cached percentage update should change layout inputs without changing description identity")
	testing.expect(t, rt.measure_states[body].cache_key.constraints.width.max != body_constraint_before,
		"the nested text constraint must follow the changed inner percentage width")

	fresh := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 400})
	defer alicorn.destroy_runtime(&fresh)
	fresh_nodes := ui_percent_validation_cached_frame(&fresh, 600, 1)
	if fresh_nodes.outer == 0 || fresh_nodes.inner == 0 || fresh_nodes.body == 0 {
		testing.expect(t, false, "the fresh comparison fixture should describe")
		return
	}
	testing.expect(t, rt.nodes[outer].bounds == fresh.nodes[fresh_nodes.outer].bounds &&
		rt.nodes[inner].bounds == fresh.nodes[fresh_nodes.inner].bounds &&
		rt.nodes[body].bounds == fresh.nodes[fresh_nodes.body].bounds &&
		rt.measure_states[body].cache_key.constraints.width.max ==
			fresh.measure_states[fresh_nodes.body].cache_key.constraints.width.max,
		"cached nested percentage geometry and text constraints must equal a fresh runtime")
}

UI_Percent_Validation_Composition :: struct {
	root, row, left, right, scroll, button: alicorn.Node_ID,
}

// A virtualized scroll region reserves its vertical scrollbar lane from the
// content viewport. Read that lane from the retained node instead of baking a
// theme metric into the percentage-width fixture.
ui_percent_validation_scroll_content_width :: proc(rt: ^alicorn.Runtime, id: alicorn.Node_ID) -> f32 {
	node := rt.nodes[id]
	lane := f32(0)
	if node.scrollbar_vertical_visible { lane = node.scrollbar_vertical_track.w }
	return node.bounds.w-lane
}

// Scroll geometry requests one follow-up description after it first resolves.
// Settle those non-percentage follow-ups before measuring retained-only updates.
ui_percent_validation_settle :: proc(rt: ^alicorn.Runtime, describe: proc(rt: ^alicorn.Runtime, viewport_width: f32) -> UI_Percent_Validation_Composition, viewport_width: f32) {
	for _ in 0..<3 {
		if !rt.invalidated { break }
		_ = describe(rt, viewport_width)
	}
}

ui_percent_validation_composition_frame :: proc(rt: ^alicorn.Runtime, viewport_width: f32) -> (nodes: UI_Percent_Validation_Composition) {
	rt.viewport = alicorn.Rect{0, 0, viewport_width, 420}
	alicorn.invalidate_root(rt, "percentage validation composition fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	nodes.root = alicorn.container_begin(&ctx, .Root, key="pct-validation-composition-root",
		style=alicorn.layout_style(.Column, padding=16, gap=8))
	if layout_sized(&ctx, alicorn.layout_style(.Row, height=280, padding=8, gap=8),
		sizing(width=percent(1)), key="pct-validation-composition-row", label="percentage row") {
		nodes.row = ui_percent_validation_last_id(&ctx)
		if layout_sized(&ctx, alicorn.layout_style(.Column, height=240),
			sizing(width=percent(0.5)), key="pct-validation-composition-left", label="percentage scroll column") {
			nodes.left = ui_percent_validation_last_id(&ctx)
			region := alicorn.scroll_region_begin(&ctx, key=alicorn.key_string("pct-validation-scroll"),
				viewport_height=120, content_height=600,
				style=alicorn.layout_style(.Column, width=-1, height=120),
				label="percentage scroll region")
			nodes.scroll = region.id
			if button(&ctx, "Scrollable action", key="pct-validation-scroll-button", height=32) {
				nodes.button = ui_percent_validation_last_id(&ctx)
			}
			alicorn.scroll_region_end(&ctx)
		}
		if panel(&ctx,
			key="pct-validation-composition-right",
			height=240,
			padding=12,
			sizing=sizing(width=percent(0.5), max_width=logical(240)),
			label="percentage capped panel",
		) {
			nodes.right = ui_percent_validation_last_id(&ctx)
			_ = text(&ctx, "Capped panel", key="pct-validation-panel-text")
		}
	}
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

@(test)
test_percentage_width_composes_with_row_panel_and_scroll_parents :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 420})
	defer alicorn.destroy_runtime(&rt)
	nodes := ui_percent_validation_composition_frame(&rt, 800)
	if nodes.row == 0 || nodes.left == 0 || nodes.right == 0 || nodes.scroll == 0 {
		testing.expect(t, false, "the percentage composition fixture should describe a row, panel and scroll region")
		return
	}
	ui_percent_validation_settle(&rt, ui_percent_validation_composition_frame, 800)
	// Root padding 16: 768. Row padding 8: 752. Two 50% requests are 376 each;
	// the right panel's 240 cap wins without renormalizing the left column.
	testing.expect(t, ui_percent_validation_close(rt.nodes[nodes.left].bounds.w, 376) &&
		ui_percent_validation_close(rt.nodes[nodes.right].bounds.w, 240),
		"percentage siblings must keep their preferred widths and independent max-width caps")
	scroll_state := alicorn.scroll_region_state(&rt, nodes.scroll)
	testing.expectf(t, ui_percent_validation_close(scroll_state.viewport_bounds.w,
		ui_percent_validation_scroll_content_width(&rt, nodes.scroll)),
		"a scroll region inside a percentage column should fill that resolved width: left=%f scroll=%f viewport=%v",
		rt.nodes[nodes.left].bounds.w, rt.nodes[nodes.scroll].bounds.w, scroll_state.viewport_bounds)

	left_id, right_id, scroll_id := nodes.left, nodes.right, nodes.scroll
	ui_percent_validation_retained_resize(&rt, 1000)
	testing.expectf(t, ui_percent_validation_close(rt.nodes[nodes.left].bounds.w, 476) &&
		ui_percent_validation_close(rt.nodes[nodes.right].bounds.w, 240),
		"retained resize must widen the uncapped percentage column while the panel stays capped: left=%f right=%f",
		rt.nodes[nodes.left].bounds.w, rt.nodes[nodes.right].bounds.w)
	scroll_state = alicorn.scroll_region_state(&rt, nodes.scroll)
	testing.expectf(t, ui_percent_validation_close(scroll_state.viewport_bounds.w,
		ui_percent_validation_scroll_content_width(&rt, nodes.scroll)),
		"the nested scroll viewport should follow its percentage column on retained resize: left=%f scroll=%f viewport=%v",
		rt.nodes[nodes.left].bounds.w, rt.nodes[nodes.scroll].bounds.w, scroll_state.viewport_bounds)
	testing.expect(t, nodes.left == left_id && nodes.right == right_id && nodes.scroll == scroll_id,
		"composition identities must survive a retained percentage resize")

	fresh := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 420})
	defer alicorn.destroy_runtime(&fresh)
	fresh_nodes := ui_percent_validation_composition_frame(&fresh, 1000)
	ui_percent_validation_settle(&fresh, ui_percent_validation_composition_frame, 1000)
	testing.expectf(t, fresh_nodes.scroll != 0 &&
		rt.nodes[nodes.left].bounds == fresh.nodes[fresh_nodes.left].bounds &&
		rt.nodes[nodes.right].bounds == fresh.nodes[fresh_nodes.right].bounds &&
		rt.nodes[nodes.scroll].bounds == fresh.nodes[fresh_nodes.scroll].bounds &&
		alicorn.scroll_region_state(&rt, nodes.scroll).viewport_bounds ==
			alicorn.scroll_region_state(&fresh, fresh_nodes.scroll).viewport_bounds,
		"retained row/panel/scroll percentage composition must equal a fresh runtime: retained=%v fresh=%v retained_viewport=%v fresh_viewport=%v",
		rt.nodes[nodes.scroll].bounds, fresh.nodes[fresh_nodes.scroll].bounds,
		alicorn.scroll_region_state(&rt, nodes.scroll).viewport_bounds,
		alicorn.scroll_region_state(&fresh, fresh_nodes.scroll).viewport_bounds)
}

UI_Percent_Validation_Positioned :: struct {
	first, second, badge: alicorn.Node_ID,
}

ui_percent_validation_positioned_frame :: proc(rt: ^alicorn.Runtime, viewport_width: f32) -> (nodes: UI_Percent_Validation_Positioned) {
	rt.viewport = alicorn.Rect{0, 0, viewport_width, 300}
	alicorn.invalidate_root(rt, "percentage validation positioned fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ctx, .Root, key="pct-validation-positioned-root",
		style=alicorn.layout_style(.Row, padding=20, gap=8))
	if layout_sized(&ctx, alicorn.layout_style(.Column, height=200),
		sizing(width=percent(0.5)), key="pct-validation-positioned-first", label="positioned first percent") {
		nodes.first = ui_percent_validation_last_id(&ctx)
	}
	if layout_sized(&ctx, alicorn.layout_style(.Column, height=200),
		sizing(width=percent(0.5)), key="pct-validation-positioned-second", label="positioned second percent") {
		nodes.second = ui_percent_validation_last_id(&ctx)
		nodes.badge = box(&ctx, key="pct-validation-positioned-badge", size=24)
		_ = alicorn.position_child(&ctx, nodes.badge, alicorn.positioned(4, 4))
	}
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

@(test)
test_positioned_child_tracks_percentage_owner_across_resize_and_presentation_scale :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 300})
	defer alicorn.destroy_runtime(&rt)
	nodes := ui_percent_validation_positioned_frame(&rt, 800)
	if nodes.first == 0 || nodes.second == 0 || nodes.badge == 0 {
		testing.expect(t, false, "the positioned percentage fixture should describe both columns and a badge")
		return
	}
	second_before := rt.nodes[nodes.second]
	badge_before := rt.nodes[nodes.badge]
	testing.expect(t, ui_percent_validation_close(second_before.bounds.w, 380) &&
		ui_percent_validation_close(badge_before.bounds.x, second_before.bounds.x+4),
		"a positioned child should anchor to its percentage owner's current origin")

	ui_percent_validation_retained_resize(&rt, 1000)
	second_after := rt.nodes[nodes.second]
	badge_after := rt.nodes[nodes.badge]
	testing.expect(t, ui_percent_validation_close(second_after.bounds.w, 480) &&
		ui_percent_validation_close(badge_after.bounds.x, second_after.bounds.x+4) &&
		ui_percent_validation_close(badge_after.bounds.y, second_after.bounds.y+4),
		"a positioned child must re-anchor when a preceding percentage sibling changes width")

	// Presentation scale finalizes device geometry only. The logical percentage
	// basis and owner-relative placement must not be recomputed or rescaled twice.
	logical_before := rt.nodes[nodes.second].bounds
	testing.expect(t, alicorn.set_presentation_scale(&rt, 1.25, 1.5),
		"presentation scale should accept a finite positive device scale")
	info, info_ok := alicorn.node_info(&rt, nodes.second)
	badge_info, badge_info_ok := alicorn.node_info(&rt, nodes.badge)
	// Finalized bounds are logical coordinates snapped to the device grid, not
	// a second geometry multiply. Device pixels are the renderer's conversion.
	testing.expectf(t, info_ok && badge_info_ok && rt.nodes[nodes.second].bounds == logical_before &&
		ui_percent_validation_close(info.bounds.w, logical_before.w) &&
		ui_percent_validation_close(badge_info.bounds.x, info.bounds.x+4) &&
		ui_percent_validation_close(info.bounds.w*1.25, math.round(info.bounds.w*1.25)),
		"presentation scale must snap device geometry without changing the logical percentage basis: logical=%v info=%v badge=%v",
		rt.nodes[nodes.second].bounds, info.bounds, badge_info.bounds)
}

@(test)
test_percentage_width_survives_theme_switch_and_text_scale_change :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 480})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, UI_PERCENT_VALIDATION_FONT) {
		testing.expect(t, false, "the percentage theme fixture should load a shaped text font")
		return
	}
	other_theme := alicorn.DEFAULT_STYLE_THEME
	other_theme.colors[0] = alicorn.Color{0.2, 0.1, 0.05, 1}
	alternate_theme := alicorn.style_theme_register(&rt, other_theme)

	describe := proc(rt: ^alicorn.Runtime, theme: alicorn.Style_Theme_ID) -> (UI_Percent_Validation_Nested, alicorn.Node_ID) {
		rt.viewport = alicorn.Rect{0, 0, 800, 480}
		alicorn.invalidate_root(rt, "percentage validation theme fixture")
		ctx, build := alicorn.begin_frame(rt)
		if !build { return {}, 0 }
		alicorn.container_begin(&ctx, .Root, key="pct-validation-nested-root",
			style=alicorn.layout_style(.Column, padding=20, gap=8))
		scope: alicorn.Style_Environment_Scope
		if theme != 0 { scope = alicorn.style_environment_push(&ctx, alicorn.Style_Environment{theme=theme}) }
		nodes: UI_Percent_Validation_Nested
		if layout_sized(&ctx, alicorn.layout_style(.Column, height=320, padding=12, gap=4),
			sizing(width=percent(0.5)), key="pct-validation-outer", label="nested outer percent") {
			nodes.outer = ui_percent_validation_last_id(&ctx)
			if layout_sized(&ctx, alicorn.layout_style(.Column, height=200, padding=8),
				sizing(width=percent(0.5)), key="pct-validation-inner", label="nested inner percent") {
				nodes.inner = ui_percent_validation_last_id(&ctx)
				nodes.body = text(&ctx,
					"Theme and text-scale changes must not change the resolved percentage basis or identity.",
					key="pct-validation-nested-body",
					text_style=alicorn.Text_Style{overflow=.Wrap})
			}
		}
		if theme != 0 { alicorn.style_environment_pop(&ctx, scope) }
		alicorn.container_end(&ctx)
		alicorn.end_frame(&ctx)
		return nodes, nodes.body
	}

	base, body := describe(&rt, 0)
	if base.outer == 0 || base.inner == 0 || body == 0 {
		testing.expect(t, false, "the theme percentage fixture should describe")
		return
	}
	base_outer_bounds := rt.nodes[base.outer].bounds
	base_inner_bounds := rt.nodes[base.inner].bounds
	base_body_height := rt.nodes[body].bounds.h
	base_layout_hash := rt.nodes[base.outer].layout_hash

	switched, switched_body := describe(&rt, alternate_theme)
	testing.expect(t, switched.outer == base.outer && switched.inner == base.inner && switched_body == body &&
		rt.nodes[switched.outer].bounds == base_outer_bounds &&
		rt.nodes[switched.inner].bounds == base_inner_bounds &&
		rt.nodes[switched.outer].layout_hash == base_layout_hash,
		"a palette-only theme switch must preserve percentage identities, basis and layout inputs")

	rt.root_text_scale = 1.5
	scaled, scaled_body := describe(&rt, 0)
	testing.expect(t, scaled.outer == base.outer && scaled.inner == base.inner && scaled_body == body &&
		ui_percent_validation_close(rt.nodes[scaled.outer].bounds.w, 380) &&
		ui_percent_validation_close(rt.nodes[scaled.inner].bounds.w, 178),
		"text scale must not change the logical percentage-width basis")
	testing.expectf(t, rt.nodes[scaled_body].bounds.h > base_body_height,
		"larger text scale should remeasure and grow the wrapped body instead of reusing the old text run: before=%f after=%f run_before=%v run_after=%v body_w=%f scale=%f",
		base_body_height, rt.nodes[scaled_body].bounds.h,
		rt.nodes[body].text_run, rt.nodes[scaled_body].text_run,
		rt.nodes[scaled_body].bounds.w, rt.style_environment.text_scale)
}

@(test)
test_zero_percentage_tree_has_no_sidecar_state_or_idle_layout_work :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 360})
	defer alicorn.destroy_runtime(&rt)
	alicorn.invalidate_root(&rt, "zero percentage validation fixture")
	ctx, build := alicorn.begin_frame(&rt)
	if !build { testing.expect(t, false, "the fixed-width fixture should describe"); return }
	alicorn.container_begin(&ctx, .Root, key="pct-validation-zero-root",
		style=alicorn.layout_style(.Column, padding=16, gap=8))
	if row(&ctx, key="pct-validation-zero-row", width=400, height=48, gap=8) {
		_ = box(&ctx, key="pct-validation-zero-first", size=40)
		_ = box(&ctx, key="pct-validation-zero-second", size=40)
	}
	_ = button(&ctx, "Fixed action", key="pct-validation-zero-button", height=36)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)

	testing.expect(t, !rt.percent_width_sidecar_initialized && len(rt.percent_width_dependencies) == 0 &&
		len(rt.pending_percent_widths) == 0,
		"a tree without percentage declarations must not allocate the optional sidecar")
	layout_updates_before := rt.stats.layout_updates

	for _ in 0..<5 {
		rt.layout_pending = true
		rt.frame_open = true
		frame := alicorn.UI{runtime=&rt}
		alicorn.end_presentation_frame(&frame)
	}
	testing.expect(t, rt.stats.layout_updates == layout_updates_before && !rt.percent_width_sidecar_initialized,
		"repeated settled retained frames on a fixed tree must not add percentage-driven layout work")

	idle_before := rt.stats.idle_frames
	_, idle_build := alicorn.begin_frame(&rt)
	testing.expect(t, !idle_build && rt.stats.idle_frames == idle_before+1,
		"a settled zero-percentage tree must remain idle with no synthetic wake or description")
}
