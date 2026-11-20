package ui

import "core:testing"
import alicorn "alicorn:runtime"

// Issue #206: a padded fit-content `ui.panel` around a fixed-height label row
// and a retained geometry surface was reported to collapse to its padding
// (a dark strip) while the same tree authored with `ui.column` worked.
//
// These fixtures pin the layout contract. `panel` is one Container node with a
// semantic-surface sidecar, so it must resolve exactly the same bounds as
// `column` while keeping its paint, clip, and default sizing behavior. They
// also pin the authoring rule that produces the reported strip for both
// wrappers: a scoped helper closes at the end of the block it was called in,
// so children described after that block belong to the parent instead.
UI_FIT_PANEL_ROW_HEIGHT :: f32(18)
UI_FIT_PANEL_SURFACE_HEIGHT :: f32(10)
UI_FIT_PANEL_PADDING :: f32(4)
UI_FIT_PANEL_FILL :: alicorn.Color{0.07, 0.09, 0.13, 1}

ui_fit_panel_wrapper :: enum { Column, Panel }

// ui_fit_panel_ruler_body describes the ruler children inside the already-open
// padded scope. Keeping this in one helper keeps the suite's two wrappers
// otherwise identical without moving the children out of the scope.
ui_fit_panel_ruler_body :: proc(ctx: ^UI, dpi_scale: f32) -> (label_row, ticks: alicorn.Node_ID) {
	if row(ctx, height=UI_FIT_PANEL_ROW_HEIGHT, clip=true, label="ruler-labels") {
		label_row = ctx.runtime.stack[len(ctx.runtime.stack)-1]
		text(ctx, "", key=u64(1_000_000), style=alicorn.layout_style(width=3, height=14))
		for index in 0 ..< 3 {
			text(ctx, "0:00", key=u64(index+1), style=alicorn.layout_style(width=90, height=14))
		}
	}
	ticks = alicorn.gpu_geometry_surface(
		ctx,
		"ui-fit-panel-ticks",
		alicorn.layout_style(width=-1, height=UI_FIT_PANEL_SURFACE_HEIGHT),
		dpi_scale,
		.Pointer,
	)
	return
}

ui_fit_panel_describe :: proc(
	rt: ^alicorn.Runtime,
	wrapper: ui_fit_panel_wrapper,
	dpi_scale: f32 = 1,
) -> (scope, label_row, ticks: alicorn.Node_ID) {
	alicorn.invalidate_root(rt, "ui fit-content panel fixture")
	ctx, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ctx, .Root, label="ui-fit-panel-root", key="ui-fit-panel-root", style=alicorn.layout_style(grow=1))
	alicorn.container_begin(&ctx, .Container, label="ui-fit-panel-content", key="ui-fit-panel-content",
		style=alicorn.layout_style(.Column, grow=1, padding=16, gap=8, clip=true))
	text(&ctx, "Acetate · Alicorn host spike", key="ui-fit-panel-title", style=alicorn.layout_style(height=26))
	text(&ctx, "Unsaved project · 1 channel", key="ui-fit-panel-subtitle", style=alicorn.layout_style(height=18))

	// A @(deferred_in_out) scope closes at the end of the block it was opened
	// in, so the helper call and its children must share this block. Routing the
	// open call through another proc would close it before the children.
	if wrapper == .Panel {
		if panel(&ctx, key="ui-fit-panel-ruler", padding=UI_FIT_PANEL_PADDING, gap=0, clip=true,
			fill=UI_FIT_PANEL_FILL, label="ruler") {
			scope = ctx.runtime.stack[len(ctx.runtime.stack)-1]
			label_row, ticks = ui_fit_panel_ruler_body(&ctx, dpi_scale)
		}
	} else {
		if column(&ctx, key="ui-fit-panel-ruler", padding=UI_FIT_PANEL_PADDING, gap=0, clip=true, label="ruler") {
			scope = ctx.runtime.stack[len(ctx.runtime.stack)-1]
			label_row, ticks = ui_fit_panel_ruler_body(&ctx, dpi_scale)
		}
	}

	alicorn.container_end(&ctx)
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return
}

@(test)
test_panel_fit_content_ruler_fixture_matches_column_and_keeps_surface_contract :: proc(t: ^testing.T) {
	reference := [3]alicorn.Rect{}
	for wrapper in ui_fit_panel_wrapper {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1100, 640})
		scope, row_id, ticks := ui_fit_panel_describe(&rt, wrapper)
		if scope == 0 || row_id == 0 || ticks == 0 {
			testing.expectf(t, false, "%v fixture should describe a scope, label row, and geometry surface", wrapper)
			alicorn.destroy_runtime(&rt)
			continue
		}
		scope_node := rt.nodes[scope]
		row_node := rt.nodes[row_id]
		want_height := UI_FIT_PANEL_ROW_HEIGHT+UI_FIT_PANEL_SURFACE_HEIGHT+2*UI_FIT_PANEL_PADDING
		names := "ui.column" if wrapper == .Column else "ui.panel"
		testing.expectf(t, scope_node.bounds.h == want_height,
			"%s should measure row 18 + surface 10 + padding 8, got %.3f", names, scope_node.bounds.h)
		testing.expectf(t, row_node.bounds.h == UI_FIT_PANEL_ROW_HEIGHT && rt.nodes[ticks].bounds.h == UI_FIT_PANEL_SURFACE_HEIGHT,
			"%s children should keep their authored heights", names)
		testing.expectf(t, rt.nodes[ticks].bounds.y == row_node.bounds.y+UI_FIT_PANEL_ROW_HEIGHT,
			"%s surface should follow the label row without overlap", names)
		testing.expectf(t, alicorn.layout_unit_to_f32(rt.measure_states[scope].result.size.height) == want_height,
			"%s retained measurement should agree with the laid out content height", names)
		testing.expectf(t, row_node.parent == scope && rt.nodes[ticks].parent == scope,
			"%s should own both children", names)
		// Clipping still follows the padded scope bounds.
		testing.expectf(t, row_node.clip == scope_node.bounds,
			"%s clip should intersect children with the padded scope bounds", names)
		// The geometry surface remains a hit target at its resolved center.
		center := alicorn.Rect{
			rt.nodes[ticks].bounds.x+rt.nodes[ticks].bounds.w/2,
			rt.nodes[ticks].bounds.y+rt.nodes[ticks].bounds.h/2,
			0, 0,
		}
		testing.expectf(t, alicorn.hit_test(&rt, center.x, center.y) == ticks,
			"%s geometry surface should stay hit-testable after layout", names)

		bounds := [3]alicorn.Rect{scope_node.bounds, row_node.bounds, rt.nodes[ticks].bounds}
		if wrapper == .Column {
			reference = bounds
			testing.expect(t, len(scope_node.paint) == 0,
				"ui.column should remain a plain non-painting container")
		} else {
			testing.expect(t, bounds == reference,
				"ui.panel should resolve exactly the same bounds as ui.column")
			style, found := rt.semantic_surfaces[scope]
			testing.expect(t, found && style.role == .Surface && scope_node.kind == .Container,
				"ui.panel should stay one Container node with a semantic-surface sidecar")
			paint_ok := false
			if len(scope_node.paint) == 1 {
				paint, ok := scope_node.paint[0].payload.(alicorn.Surface_Paint)
				paint_ok = ok && paint.fill == UI_FIT_PANEL_FILL
			}
			testing.expect(t, paint_ok,
				"ui.panel should keep its retained surface paint command")
			testing.expect(t, rt.nodes[ticks].surface_kind == .Geometry,
				"the retained geometry surface should not be re-typed by the panel wrapper")
		}
		alicorn.destroy_runtime(&rt)
	}
}

@(test)
test_panel_default_fit_content_sizing_without_children_is_padding_only :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 400, 240})
	defer alicorn.destroy_runtime(&rt)
	ctx, build := alicorn.begin_frame(&rt)
	if !build { testing.expect(t, false, "default panel fixture should describe the initial frame"); return }
	alicorn.container_begin(&ctx, .Root, label="ui-fit-panel-default-root", key="ui-fit-panel-default-root", style=alicorn.layout_style(grow=1))
	empty, padded: alicorn.Node_ID
	if panel(&ctx, key="ui-fit-panel-empty", fill=UI_FIT_PANEL_FILL) {
		empty = ctx.runtime.stack[len(ctx.runtime.stack)-1]
	}
	if panel(&ctx, key="ui-fit-panel-padded", padding=UI_FIT_PANEL_PADDING, fill=UI_FIT_PANEL_FILL) {
		padded = ctx.runtime.stack[len(ctx.runtime.stack)-1]
	}
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	if empty == 0 || padded == 0 { testing.expect(t, false, "default panels should build"); return }
	testing.expect(t, rt.nodes[empty].bounds.h == 0 && rt.nodes[padded].bounds.h == 2*UI_FIT_PANEL_PADDING,
		"a panel without children keeps its default fit-content sizing: zero content plus padding")
	testing.expect(t, len(rt.nodes[padded].paint) == 1,
		"the padding-only height still paints the panel surface, which is the reported dark strip")
}

@(test)
test_panel_children_described_after_scope_block_measure_padding_only_for_both_wrappers :: proc(t: ^testing.T) {
	for wrapper in ui_fit_panel_wrapper {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 520})
		alicorn.invalidate_root(&rt, "ui fit-content panel scope misuse")
		ctx, build := alicorn.begin_frame(&rt)
		if !build { testing.expect(t, false, "scope misuse fixture should describe its initial frame"); alicorn.destroy_runtime(&rt); continue }
		alicorn.container_begin(&ctx, .Root, label="ui-fit-panel-misuse-root", key="ui-fit-panel-misuse-root", style=alicorn.layout_style(grow=1))
		content := alicorn.container_begin(&ctx, .Container, label="ui-fit-panel-misuse-content", key="ui-fit-panel-misuse-content",
			style=alicorn.layout_style(.Column, grow=1, padding=16, gap=8, clip=true))
		scope: alicorn.Node_ID
		// The scoped helper closes at the end of this if block. Capturing the id
		// and describing the children afterwards leaves the scope empty.
		if wrapper == .Panel {
			if panel(&ctx, key="ui-fit-panel-ruler", padding=UI_FIT_PANEL_PADDING, gap=0, clip=true,
				fill=UI_FIT_PANEL_FILL, label="ruler") {
				scope = ctx.runtime.stack[len(ctx.runtime.stack)-1]
			}
		} else {
			if column(&ctx, key="ui-fit-panel-ruler", padding=UI_FIT_PANEL_PADDING, gap=0, clip=true, label="ruler") {
				scope = ctx.runtime.stack[len(ctx.runtime.stack)-1]
			}
		}
		label_row, ticks := ui_fit_panel_ruler_body(&ctx, 1)
		alicorn.container_end(&ctx)
		alicorn.container_end(&ctx)
		alicorn.end_frame(&ctx)
		names := "ui.column" if wrapper == .Column else "ui.panel"
		if scope == 0 { testing.expectf(t, false, "%s misuse fixture should still open its scope", names); alicorn.destroy_runtime(&rt); continue }
		testing.expectf(t, rt.nodes[scope].bounds.h == 2*UI_FIT_PANEL_PADDING,
			"%s with children described outside its block measures padding only (the reported dark strip)", names)
		testing.expectf(t, rt.nodes[label_row].parent == content && rt.nodes[ticks].parent == content,
			"%s misuse leaves the children in the parent scope instead of the padded surface", names)
		testing.expectf(t, rt.nodes[content].bounds.h > UI_FIT_PANEL_ROW_HEIGHT,
			"%s children still lay out in the parent, so the collapse is a scope error rather than lost content", names)
		alicorn.destroy_runtime(&rt)
	}
}

@(test)
test_panel_fit_content_ruler_fixture_is_dpi_independent :: proc(t: ^testing.T) {
	reference := [3]alicorn.Rect{}
	for dpi_scale in ([]f32{1, 1.25, 1.5, 1.75}) {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1100, 640})
		scope, row_id, ticks := ui_fit_panel_describe(&rt, .Panel, dpi_scale=dpi_scale)
		if scope == 0 || ticks == 0 { testing.expect(t, false, "dpi panel fixture should build"); alicorn.destroy_runtime(&rt); continue }
		bounds := [3]alicorn.Rect{rt.nodes[scope].bounds, rt.nodes[row_id].bounds, rt.nodes[ticks].bounds}
		if dpi_scale == 1 { reference = bounds
		} else {
			testing.expectf(t, bounds == reference,
				"ui.panel logical bounds should not depend on dpi scale %.2f", dpi_scale)
		}
		surface_context, ok := alicorn.gpu_surface_context(&rt, ticks)
		testing.expectf(t, ok && surface_context.dpi_scale == dpi_scale &&
			surface_context.pixel_height == int(bounds[2].h*dpi_scale+0.5),
			"the geometry surface should keep its logical height and scale pixels at dpi %.2f", dpi_scale)
		alicorn.destroy_runtime(&rt)
	}
}
