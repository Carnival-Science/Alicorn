package ui

import "core:fmt"
import "core:math"
import "core:testing"
import alicorn "alicorn:runtime"

// Issue #207: a shared domain-space transform positions ruler/meter labels and
// the retained tick geometry. Labels are ordinary Text nodes placed by
// `positioned_text`; there is no fixed-width cell row or synthetic spacer.

UI_POSITIONED_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
UI_POSITIONED_RULER_HEIGHT :: f32(44)
UI_POSITIONED_RULER_DIVISIONS :: 6
UI_POSITIONED_RULER_LABELS :: UI_POSITIONED_RULER_DIVISIONS+1

ui_positioned_test_close :: proc(a, b: f32) -> bool {
	return math.abs(a-b) <= 0.02
}

// One transform serves both ticks and major labels. The application owns the
// domain values; Alicorn only resolves the resulting owner-local coordinates.
ui_positioned_test_time_to_pixel :: proc(time, start, duration, width: f32) -> f32 {
	if duration <= 0 { return 0 }
	return (time-start)/duration*width
}

ui_positioned_test_meter_to_pixel :: proc(value, minimum, maximum, width: f32) -> f32 {
	if maximum <= minimum { return 0 }
	return (value-minimum)/(maximum-minimum)*width
}

ui_positioned_test_display_index :: proc(rt: ^alicorn.Runtime, owner: alicorn.Node_ID) -> int {
	for command, index in rt.display {
		if command.owner == owner { return index }
	}
	return -1
}

ui_positioned_test_describe_ruler :: proc(
	rt: ^alicorn.Runtime,
	width, start, duration, dpi_scale: f32,
) -> (owner, ticks: alicorn.Node_ID, labels: [UI_POSITIONED_RULER_LABELS]alicorn.Node_ID) {
	alicorn.invalidate_root(rt, "ui positioned ruler fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ctx, .Root, key="ui-positioned-ruler-root", style=alicorn.layout_style(.Column))
	owner = alicorn.container_begin(&ctx, .Container, key="ui-positioned-ruler-owner",
		style=alicorn.layout_style(.Column, width=width, height=UI_POSITIONED_RULER_HEIGHT, clip=true))
	ticks = alicorn.gpu_geometry_surface(&ctx, "ui-positioned-ruler-ticks",
		alicorn.layout_style(width=-1, height=UI_POSITIONED_RULER_HEIGHT), dpi_scale)
	for index in 0 ..< UI_POSITIONED_RULER_LABELS {
		time := start+duration*f32(index)/f32(UI_POSITIONED_RULER_DIVISIONS)
		x := ui_positioned_test_time_to_pixel(time, start, duration, width)
		labels[index] = positioned_text(
			&ctx,
			fmt.tprintf("%.0fs", time),
			x,
			8,
			key=u64(1000+index),
			size=11,
			horizontal=alicorn.Positioned_Horizontal.Start,
			vertical=alicorn.Positioned_Vertical.Top,
		)
	}
	alicorn.container_end(&ctx)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

ui_positioned_test_describe_meter :: proc(
	rt: ^alicorn.Runtime,
	width: f32,
) -> (owner, ticks: alicorn.Node_ID, labels: [5]alicorn.Node_ID) {
	alicorn.invalidate_root(rt, "ui positioned meter fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ctx, .Root, key="ui-positioned-meter-root", style=alicorn.layout_style(.Column))
	owner = alicorn.container_begin(&ctx, .Container, key="ui-positioned-meter-owner",
		style=alicorn.layout_style(.Column, width=width, height=28, clip=true))
	ticks = alicorn.gpu_geometry_surface(&ctx, "ui-positioned-meter-ticks",
		alicorn.layout_style(width=-1, height=28), 1)
	for index in 0 ..< 5 {
		value := f32(index)*25
		x := ui_positioned_test_meter_to_pixel(value, 0, 100, width)
		// Meter labels sit to the left of their tick and use End alignment.
		labels[index] = positioned_text(&ctx, fmt.tprintf("%.0f%%", value), x, 4,
			key=u64(2000+index), size=10, horizontal=alicorn.Positioned_Horizontal.End)
	}
	alicorn.container_end(&ctx)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

@(test)
test_positioned_text_matches_manual_position_child :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 240})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, UI_POSITIONED_TEST_FONT) {
		testing.expect(t, false, "positioned helper fixture font should load")
		return
	}
	alicorn.invalidate_root(&rt, "positioned helper equivalence fixture")
	ctx, build := alicorn.begin_frame(&rt)
	if !build { testing.expect(t, false, "positioned helper fixture should describe"); return }
	alicorn.container_begin(&ctx, .Root, key="positioned-helper-root", style=alicorn.layout_style(.Column))
	owner := alicorn.container_begin(&ctx, .Container, key="positioned-helper-owner",
		style=alicorn.layout_style(.Column, width=480, height=96, clip=true))
	helper := positioned_text(&ctx, "0:10", 120, 12, key="positioned-helper-label", size=12,
		horizontal=alicorn.Positioned_Horizontal.Center, vertical=alicorn.Positioned_Vertical.Middle)
	manual := alicorn.text(&ctx, "0:10", key="positioned-manual-label",
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, font_size=12})
	manual_ok := alicorn.position_child(&ctx, manual, alicorn.positioned(120, 12,
		horizontal=.Center, vertical=.Middle))
	alicorn.container_end(&ctx)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	testing.expect(t, helper != 0 && manual != 0 && manual_ok,
		"both positioned authoring paths should describe a label")
	helper_node, helper_ok := rt.nodes[helper]
	manual_node, manual_ok_retained := rt.nodes[manual]
	testing.expect(t, helper != manual && helper_ok && manual_ok_retained &&
		rt.nodes[owner] != nil,
		"helper and manual labels should stay distinct retained nodes")
	testing.expect(t, helper_node.bounds == manual_node.bounds &&
		helper_node.clip == manual_node.clip,
		"positioned_text should resolve the same geometry as an explicit position_child")
	testing.expect(t, len(helper_node.paint) == len(manual_node.paint) &&
		len(helper_node.paint) > 0,
		"both authoring paths should emit the same ordinary text paint")
}

@(test)
test_positioned_ruler_labels_share_tick_transform_and_keep_geometry :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 400})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, UI_POSITIONED_TEST_FONT) {
		testing.expect(t, false, "ruler fixture font should load")
		return
	}
	width: f32 = 900
	owner_id, ticks, labels := ui_positioned_test_describe_ruler(&rt, width, 0, 60, 1)
	owner := rt.nodes[owner_id]
	if owner == nil || ticks == 0 || labels[0] == 0 {
		testing.expect(t, false, "ruler fixture should retain its owner, ticks, and labels")
		return
	}
	segments: [UI_POSITIONED_RULER_LABELS]alicorn.GPU_Surface_Line_Segment
	for index in 0 ..< UI_POSITIONED_RULER_LABELS {
		time := 60*f32(index)/f32(UI_POSITIONED_RULER_DIVISIONS)
		x := ui_positioned_test_time_to_pixel(time, 0, 60, width)
		segments[index] = alicorn.GPU_Surface_Line_Segment{
			start=alicorn.GPU_Surface_Point{x, 0},
			end=alicorn.GPU_Surface_Point{x, 8},
			thickness=1,
			color=alicorn.Color{1, 1, 1, 1},
		}
	}
	testing.expect(t, alicorn.gpu_surface_update_geometry(&rt, ticks, segments[:], nil),
		"the ruler fixture should retain its tick geometry")
	revision := u64(rt.nodes[ticks].surface_payload_revision)

	for index in 0 ..< UI_POSITIONED_RULER_LABELS {
		label := rt.nodes[labels[index]]
		anchor := label.bounds.x-owner.bounds.x
		testing.expectf(t, alicorn.rect_equal(label.clip, owner.bounds),
			"label %d should inherit the clipped owner bounds", index)
		testing.expectf(t, ui_positioned_test_close(anchor, segments[index].start.x),
			"label %d and its tick should use the same time-to-pixel transform (%.3f vs %.3f)",
			index, anchor, segments[index].start.x)
	}

	// Declaration order remains the paint order: the retained tick surface
	// paints below the labels, and labels paint in authored sequence.
	ticks_display := ui_positioned_test_display_index(&rt, ticks)
	previous_display := ticks_display
	testing.expect(t, ticks_display >= 0, "the tick surface should appear in the display list")
	for index in 0 ..< UI_POSITIONED_RULER_LABELS {
		display := ui_positioned_test_display_index(&rt, labels[index])
		testing.expectf(t, display > previous_display,
			"label %d should paint after the geometry surface and preceding labels", index)
		previous_display = display
	}

	// A width-only re-description keeps the same label texts, so retained
	// shaping is reusable even though every label moves.
	shapes_before := rt.stats.text_shape_requests
	_, ticks_after, labels_after := ui_positioned_test_describe_ruler(&rt, 700, 0, 60, 1)
	testing.expect(t, ticks_after == ticks && labels_after[0] == labels[0],
		"a label layout change should retain the same nodes")
	testing.expectf(t, ui_positioned_test_close(
		rt.nodes[labels_after[1]].bounds.x-rt.nodes[owner_id].bounds.x,
		ui_positioned_test_time_to_pixel(10, 0, 60, 700)),
		"labels should follow the new shared transform")
	testing.expect(t, rt.stats.text_shape_requests == shapes_before,
		"unchanged label text must reuse retained shaping across a move")
	testing.expect(t, u64(rt.nodes[ticks].surface_payload_revision) == revision,
		"label placement changes must not rebuild retained tick geometry")

	// Pan/zoom changes domain coordinates and label text; retained geometry is
	// still untouched until the application explicitly updates it.
	_, _, panned := ui_positioned_test_describe_ruler(&rt, 700, 15, 30, 1)
	testing.expectf(t, ui_positioned_test_close(
		rt.nodes[panned[0]].bounds.x-rt.nodes[owner_id].bounds.x,
		ui_positioned_test_time_to_pixel(15, 15, 30, 700)),
		"a panned ruler should place labels from the application's domain transform")
	testing.expect(t, u64(rt.nodes[ticks].surface_payload_revision) == revision,
		"pan/zoom label updates must not rebuild retained tick geometry")
}

@(test)
test_positioned_text_meter_uses_end_alignment :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 240})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, UI_POSITIONED_TEST_FONT) {
		testing.expect(t, false, "meter fixture font should load")
		return
	}
	width: f32 = 600
	owner_id, ticks, labels := ui_positioned_test_describe_meter(&rt, width)
	owner := rt.nodes[owner_id]
	segments: [5]alicorn.GPU_Surface_Line_Segment
	for index in 0 ..< 5 {
		x := ui_positioned_test_meter_to_pixel(f32(index)*25, 0, 100, width)
		segments[index] = alicorn.GPU_Surface_Line_Segment{
			start=alicorn.GPU_Surface_Point{x, 20},
			end=alicorn.GPU_Surface_Point{x, 28},
			thickness=1,
			color=alicorn.Color{1, 1, 1, 1},
		}
	}
	testing.expect(t, alicorn.gpu_surface_update_geometry(&rt, ticks, segments[:], nil),
		"the meter fixture should retain its tick geometry")
	for index in 0 ..< 5 {
		label := rt.nodes[labels[index]]
		testing.expectf(t, ui_positioned_test_close(
			label.bounds.x+label.bounds.w-owner.bounds.x, segments[index].start.x),
			"meter label %d should End-align to its tick", index)
	}
}

@(test)
test_positioned_text_logical_bounds_ignore_dpi_and_match_fresh_layout :: proc(t: ^testing.T) {
	reference := [UI_POSITIONED_RULER_LABELS+2]alicorn.Rect{}
	for dpi_scale in ([]f32{1, 1.25, 1.5, 1.75}) {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 400})
		if !alicorn.text_engine_load_font(&rt.text_engine, UI_POSITIONED_TEST_FONT) {
			testing.expect(t, false, "dpi fixture font should load")
			alicorn.destroy_runtime(&rt)
			return
		}
		_ = alicorn.set_presentation_scale(&rt, dpi_scale, dpi_scale)
		owner_id, ticks, labels := ui_positioned_test_describe_ruler(&rt, 900, 0, 60, dpi_scale)
		bounds := [UI_POSITIONED_RULER_LABELS+2]alicorn.Rect{}
		bounds[0] = rt.nodes[owner_id].bounds
		bounds[1] = rt.nodes[ticks].bounds
		for index in 0 ..< UI_POSITIONED_RULER_LABELS {
			bounds[2+index] = rt.nodes[labels[index]].bounds
		}
		if dpi_scale == 1 {
			reference = bounds
		} else {
			testing.expectf(t, bounds == reference,
				"positioned logical bounds should not depend on dpi scale %.2f", dpi_scale)
		}
		surface_context, context_ok := alicorn.gpu_surface_context(&rt, ticks)
		testing.expectf(t, context_ok && surface_context.dpi_scale == dpi_scale &&
			surface_context.pixel_width == int(reference[1].w*dpi_scale+0.5),
			"the shared tick surface should scale pixels at dpi %.2f", dpi_scale)
		alicorn.destroy_runtime(&rt)
	}

	// Incremental re-description at a resized width must match a fresh runtime.
	incremental := alicorn.new_runtime(alicorn.Rect{0, 0, 1000, 400})
	if !alicorn.text_engine_load_font(&incremental.text_engine, UI_POSITIONED_TEST_FONT) {
		testing.expect(t, false, "incremental fixture font should load")
		alicorn.destroy_runtime(&incremental)
		return
	}
	_, _, _ = ui_positioned_test_describe_ruler(&incremental, 900, 0, 60, 1)
	_, incremental_ticks, incremental_labels := ui_positioned_test_describe_ruler(&incremental, 700, 0, 60, 1)
	fresh := alicorn.new_runtime(alicorn.Rect{0, 0, 700, 400})
	if !alicorn.text_engine_load_font(&fresh.text_engine, UI_POSITIONED_TEST_FONT) {
		testing.expect(t, false, "fresh fixture font should load")
		alicorn.destroy_runtime(&incremental)
		alicorn.destroy_runtime(&fresh)
		return
	}
	_, fresh_ticks, fresh_labels := ui_positioned_test_describe_ruler(&fresh, 700, 0, 60, 1)
	testing.expect(t, ui_positioned_test_rect_equal(incremental.nodes[incremental_ticks].bounds, fresh.nodes[fresh_ticks].bounds),
		"incremental and fresh tick surfaces should resolve the same bounds after resize")
	for index in 0 ..< UI_POSITIONED_RULER_LABELS {
		testing.expectf(t, ui_positioned_test_rect_equal(
			incremental.nodes[incremental_labels[index]].bounds,
			fresh.nodes[fresh_labels[index]].bounds),
			"incremental and fresh label %d should resolve the same bounds after resize", index)
	}
	alicorn.destroy_runtime(&incremental)
	alicorn.destroy_runtime(&fresh)
}

@(private)
ui_positioned_test_rect_equal :: proc(a, b: alicorn.Rect) -> bool {
	return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h
}
