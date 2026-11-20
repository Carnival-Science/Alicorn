#+build !js

package alicorn

import "core:testing"
import "core:strings"

// Issue #206 fixture: a padded fit-content scope around a fixed-height label
// row and a fixed-height retained geometry surface, nested the way a host
// application describes a time ruler. The report claimed that wrapping the
// children in `ui.panel` collapsed the scope to its padding while `ui.column`
// worked. `ui.panel` is the same Container node with a semantic-surface
// sidecar, so both wrappers must measure and place children identically.
FIT_CONTENT_PANEL_ROW_HEIGHT :: f32(18)
FIT_CONTENT_PANEL_SURFACE_HEIGHT :: f32(10)
FIT_CONTENT_PANEL_PADDING :: f32(4)

Fit_Content_Panel_Wrapper :: enum { Plain_Column, Semantic_Surface }

fit_content_panel_test_describe :: proc(
	rt: ^Runtime,
	wrapper: Fit_Content_Panel_Wrapper,
	gap: f32 = 0,
	populated := true,
	explicit_height: f32 = LAYOUT_SIZE_FIT_CONTENT,
	grow: f32 = 0,
	dpi_scale: f32 = 1,
) -> (panel, row, ticks: Node_ID) {
	invalidate_root(rt, "fit-content panel fixture")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, label="fit-content-panel-root", key=key_string("fit-content-panel-root"), style=layout_style(grow=1))
	container_begin(&ui, .Container, label="fit-content-panel-content", key=key_string("fit-content-panel-content"),
		style=layout_style(.Column, grow=1, padding=16, gap=8, clip=true))
	// Ordinary header rows keep the fixture in a nested scope instead of
	// letting the scope under test see a viewport-sized parent.
	text(&ui, "Acetate · Alicorn host spike", key=key_string("fit-content-panel-title"), style=layout_style(height=26))
	text(&ui, "Unsaved project · 1 channel", key=key_string("fit-content-panel-subtitle"), style=layout_style(height=18))

	style := layout_style(.Column, height=explicit_height, grow=grow, padding=FIT_CONTENT_PANEL_PADDING, gap=gap, clip=true)
	if wrapper == .Semantic_Surface {
		panel = surface_begin(&ui, .Surface, label="ruler", key=key_string("fit-content-panel-ruler"), style=style)
	} else {
		panel = container_begin(&ui, .Container, label="ruler", key=key_string("fit-content-panel-ruler"), style=style)
	}
	if populated {
		row = container_begin(&ui, .Container, label="ruler-labels", key=key_string("fit-content-panel-labels"),
			style=layout_style(.Row, height=FIT_CONTENT_PANEL_ROW_HEIGHT, clip=true))
		text(&ui, "", key=key_u64(1_000_000), style=layout_style(width=3, height=14))
		for index in 0 ..< 3 {
			text(&ui, "0:00", key=key_u64(u64(index+1)), style=layout_style(width=90, height=14))
		}
		container_end(&ui)
		ticks = gpu_geometry_surface(
			&ui,
			"fit-content-panel-ticks",
			layout_style(width=-1, height=FIT_CONTENT_PANEL_SURFACE_HEIGHT),
			dpi_scale,
		)
	}
	if wrapper == .Semantic_Surface { surface_end(&ui) } else { container_end(&ui) }
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return
}

fit_content_panel_test_active_children :: proc(rt: ^Runtime, node: ^Node) -> int {
	count := 0
	if node == nil { return 0 }
	for child_id in node.children {
		child, ok := rt.nodes[child_id]
		if ok && child != nil && child.active { count += 1 }
	}
	return count
}

fit_content_panel_test_has_trace :: proc(rt: ^Runtime, node: Node_ID, fragment: string) -> bool {
	for event in rt.trace.events {
		if event.kind == .Measure && event.node == node && strings.contains(event.reason, fragment) { return true }
	}
	return false
}

@(test)
test_fit_content_surface_panel_matches_column_around_label_row_and_geometry_surface :: proc(t: ^testing.T) {
	for gap in ([]f32{0, 4}) {
		want_height := FIT_CONTENT_PANEL_ROW_HEIGHT+FIT_CONTENT_PANEL_SURFACE_HEIGHT+2*FIT_CONTENT_PANEL_PADDING+gap
		column_panel: Node_ID
		surface_panel: Node_ID
		column_bounds := [3]Rect{}
		surface_bounds := [3]Rect{}
		for wrapper in Fit_Content_Panel_Wrapper {
			rt := new_runtime(Rect{0, 0, 1100, 640})
			panel, row, ticks := fit_content_panel_test_describe(&rt, wrapper, gap)
			if panel == 0 || row == 0 || ticks == 0 {
				testing.expectf(t, false, "%v fixture should describe a panel, label row, and geometry surface", wrapper)
				destroy_runtime(&rt)
				continue
			}
			panel_node := rt.nodes[panel]
			row_node := rt.nodes[row]
			ticks_node := rt.nodes[ticks]
			state := rt.measure_states[panel]
			names := "plain Column" if wrapper == .Plain_Column else "semantic-surface panel"
			testing.expectf(t, panel_node.bounds.h == want_height,
				"%s fit-content height should be row 18 + surface 10 + padding 8 + gap %.0f, got %.3f",
				names, gap, panel_node.bounds.h)
			testing.expectf(t, layout_unit_to_f32(state.result.size.height) == want_height,
				"%s retained Measure_Result should agree with its laid out height", names)
			testing.expectf(t, row_node.bounds.h == FIT_CONTENT_PANEL_ROW_HEIGHT && ticks_node.bounds.h == FIT_CONTENT_PANEL_SURFACE_HEIGHT,
				"%s children should keep their authored heights instead of collapsing into the padding", names)
			testing.expectf(t, row_node.bounds.y == panel_node.bounds.y+FIT_CONTENT_PANEL_PADDING,
				"%s first child should sit below the top padding", names)
			testing.expectf(t, ticks_node.bounds.y == row_node.bounds.y+FIT_CONTENT_PANEL_ROW_HEIGHT+gap,
				"%s geometry surface should follow the label row plus the authored gap", names)
			testing.expectf(t, ticks_node.bounds.y+ticks_node.bounds.h == panel_node.bounds.y+panel_node.bounds.h-FIT_CONTENT_PANEL_PADDING,
				"%s children should fill the padded content box without overlap or overflow", names)
			testing.expectf(t, ticks_node.bounds.w == panel_node.bounds.w-2*FIT_CONTENT_PANEL_PADDING,
				"%s geometry surface should stretch to the padded content width", names)
			if wrapper == .Plain_Column {
				column_panel = panel
				column_bounds = {panel_node.bounds, row_node.bounds, ticks_node.bounds}
			} else {
				surface_panel = panel
				surface_bounds = {panel_node.bounds, row_node.bounds, ticks_node.bounds}
				surface_style, has_surface_style := rt.semantic_surfaces[panel]
				testing.expectf(t, has_surface_style && surface_style.role == .Surface,
					"the panel wrapper should retain its semantic-surface recipe on the same layout node")
			}
			destroy_runtime(&rt)
		}
		testing.expectf(t, column_panel != 0 && surface_panel != 0,
			"both wrappers should build for gap %.0f", gap)
		testing.expectf(t, column_bounds == surface_bounds,
			"plain Column and semantic-surface panel should resolve identical bounds for every node (gap %.0f)", gap)
	}
}

@(test)
test_fit_content_surface_panel_resize_and_incremental_fresh_parity :: proc(t: ^testing.T) {
	for wrapper in Fit_Content_Panel_Wrapper {
		rt := new_runtime(Rect{0, 0, 1100, 640})
		defer destroy_runtime(&rt)
		panel, row, ticks := fit_content_panel_test_describe(&rt, wrapper)
		if panel == 0 { testing.expect(t, false, "initial panel fixture should build"); continue }
		want_height := FIT_CONTENT_PANEL_ROW_HEIGHT+FIT_CONTENT_PANEL_SURFACE_HEIGHT+2*FIT_CONTENT_PANEL_PADDING
		first := rt.nodes[panel].bounds

		// A narrow window must keep the measured height and re-place children.
		rt.viewport = Rect{0, 0, 700, 480}
		invalidate_root(&rt, "fit-content panel resize")
		panel, row, ticks = fit_content_panel_test_describe(&rt, wrapper)
		resized := rt.nodes[panel].bounds
		testing.expectf(t, resized.h == want_height && resized.w == first.w-400,
			"resize should keep the content height and shrink only the width (was %v, now %v)", first, resized)
		testing.expectf(t, rt.nodes[ticks].bounds.y == rt.nodes[row].bounds.y+FIT_CONTENT_PANEL_ROW_HEIGHT,
			"resize should keep the label row and surface adjacent")

		fresh := new_runtime(Rect{0, 0, 700, 480})
		defer destroy_runtime(&fresh)
		fresh_panel, _, _ := fit_content_panel_test_describe(&fresh, wrapper)
		testing.expectf(t, fresh_panel != 0 && rt.nodes[panel].bounds == fresh.nodes[fresh_panel].bounds,
			"incremental resize should match a clean solve")
		testing.expectf(t, layout_measure_result_equal(rt.measure_states[panel].result, fresh.measure_states[fresh_panel].result),
			"incremental resize should retain the same measured result as a clean solve")

		// Height sweeps in both directions must not clamp the rigid fit-content
		// scope: only a grow or compression weight may allocate below content.
		for height in ([]f32{140, 220, 360, 900, 640}) {
			rt.viewport = Rect{0, 0, 700, height}
			invalidate_root(&rt, "fit-content panel viewport height sweep")
			panel, _, _ = fit_content_panel_test_describe(&rt, wrapper)
			testing.expectf(t, rt.nodes[panel].bounds.h == want_height,
				"a fit-content scope without grow should keep its content height at viewport height %.0f", height)
		}
	}
}

@(test)
test_fit_content_surface_panel_reports_padding_only_measurement_and_recovers :: proc(t: ^testing.T) {
	for wrapper in Fit_Content_Panel_Wrapper {
		rt := new_runtime(Rect{0, 0, 800, 520}, Runtime_Config{trace_capacity=128})
		defer destroy_runtime(&rt)
		want_height := FIT_CONTENT_PANEL_ROW_HEIGHT+FIT_CONTENT_PANEL_SURFACE_HEIGHT+2*FIT_CONTENT_PANEL_PADDING
		padding_height := 2*FIT_CONTENT_PANEL_PADDING

		// An empty padded scope is the exact shape of the reported dark strip.
		empty_panel, _, _ := fit_content_panel_test_describe(&rt, wrapper, populated=false)
		if empty_panel == 0 { testing.expect(t, false, "empty panel fixture should build"); continue }
		testing.expectf(t, rt.nodes[empty_panel].bounds.h == padding_height,
			"an empty padded fit-content scope should measure its padding and nothing else")
		testing.expectf(t, fit_content_panel_test_active_children(&rt, rt.nodes[empty_panel]) == 0,
			"the empty fixture should have no realized children")
		testing.expectf(t, fit_content_panel_test_has_trace(&rt, empty_panel, "no realized children"),
			"a zero-child fit-content measure should explain the padding-only height in the measure trace")

		panel, row, ticks := fit_content_panel_test_describe(&rt, wrapper)
		testing.expectf(t, panel == empty_panel && rt.nodes[panel].bounds.h == want_height,
			"adding children should grow the retained scope back to its content height")
		testing.expectf(t, rt.nodes[row].bounds.h == FIT_CONTENT_PANEL_ROW_HEIGHT && rt.nodes[ticks].bounds.h == FIT_CONTENT_PANEL_SURFACE_HEIGHT,
			"the recovered scope should place both children at their authored heights")

		empty_panel, _, _ = fit_content_panel_test_describe(&rt, wrapper, populated=false)
		testing.expectf(t, rt.nodes[empty_panel].bounds.h == padding_height,
			"removing children should return the scope to its padding-only height")
		panel, _, _ = fit_content_panel_test_describe(&rt, wrapper)
		fresh := new_runtime(Rect{0, 0, 800, 520})
		defer destroy_runtime(&fresh)
		fresh_panel, _, _ := fit_content_panel_test_describe(&fresh, wrapper)
		testing.expectf(t, fresh_panel != 0 && rt.nodes[panel].bounds == fresh.nodes[fresh_panel].bounds &&
			layout_measure_result_equal(rt.measure_states[panel].result, fresh.measure_states[fresh_panel].result),
			"repeated child population should match a clean solve for the same final tree")
	}
}

@(test)
test_fit_content_surface_panel_measurement_is_dpi_independent :: proc(t: ^testing.T) {
	reference := [3]Rect{}
	for dpi_scale in ([]f32{1, 1.25, 1.5, 1.75}) {
		rt := new_runtime(Rect{0, 0, 1100, 640})
		panel, row, ticks := fit_content_panel_test_describe(&rt, .Semantic_Surface, dpi_scale=dpi_scale)
		if panel == 0 || ticks == 0 { testing.expect(t, false, "dpi fixture should build"); destroy_runtime(&rt); continue }
		bounds := [3]Rect{rt.nodes[panel].bounds, rt.nodes[row].bounds, rt.nodes[ticks].bounds}
		if dpi_scale == 1 { reference = bounds
		} else {
			testing.expectf(t, bounds == reference,
				"logical bounds should not depend on dpi scale %.2f", dpi_scale)
		}
		surface_context, ok := gpu_surface_context(&rt, ticks)
		testing.expectf(t, ok && surface_context.dpi_scale == dpi_scale,
			"the geometry surface should retain the authored dpi scale %.2f", dpi_scale)
		testing.expectf(t, ok &&
			surface_context.pixel_width == int(bounds[2].w*dpi_scale+0.5) &&
			surface_context.pixel_height == int(bounds[2].h*dpi_scale+0.5),
			"surface pixels should scale with dpi %.2f while the logical layout stays fixed", dpi_scale)
		destroy_runtime(&rt)
	}
}

@(test)
test_fit_content_surface_panel_explicit_height_and_grow_variants_keep_children_visible :: proc(t: ^testing.T) {
	// An explicit height is an authored hard size for the wrapper; children keep
	// their own heights and stay inside the padded box.
	rt := new_runtime(Rect{0, 0, 900, 600})
	defer destroy_runtime(&rt)
	explicit := f32(44)
	panel, row, ticks := fit_content_panel_test_describe(&rt, .Semantic_Surface, explicit_height=explicit)
	if panel == 0 { testing.expect(t, false, "explicit-height fixture should build"); return }
	testing.expectf(t, rt.nodes[panel].bounds.h == explicit,
		"an explicit panel height should be honored instead of the content height")
	testing.expectf(t, rt.nodes[row].bounds.h == FIT_CONTENT_PANEL_ROW_HEIGHT && rt.nodes[ticks].bounds.h == FIT_CONTENT_PANEL_SURFACE_HEIGHT,
		"an explicit panel height should not change child measurement")

	// grow=1 lets the parent allocator expand the scope past its content. The
	// measured content stays available, so the children keep their heights.
	panel, row, ticks = fit_content_panel_test_describe(&rt, .Semantic_Surface, grow=1)
	content_height := FIT_CONTENT_PANEL_ROW_HEIGHT+FIT_CONTENT_PANEL_SURFACE_HEIGHT+2*FIT_CONTENT_PANEL_PADDING
	grown := rt.nodes[panel].bounds
	state := rt.measure_states[panel]
	testing.expectf(t, grown.h >= content_height && layout_unit_to_f32(state.result.size.height) == content_height,
		"a grow scope should expand from its measured content height, not from zero (bounds %.3f, content %.3f)",
		grown.h, layout_unit_to_f32(state.result.size.height))
	testing.expectf(t, rt.nodes[row].bounds.h == FIT_CONTENT_PANEL_ROW_HEIGHT && rt.nodes[ticks].bounds.h == FIT_CONTENT_PANEL_SURFACE_HEIGHT,
		"growing the scope should keep both children at their authored heights")
}

