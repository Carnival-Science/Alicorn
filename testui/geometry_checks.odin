package testui

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"

Layout_Check_Kind :: enum {
	Inside,
	Fills_Width,
	Aligned,
}

Layout_Check_Axis :: enum {
	Center_X,
	Center_Y,
	Left,
	Right,
	Top,
	Bottom,
}

Layout_Check_Failure :: enum {
	None,
	Invalid_Handle,
	Stale_Snapshot,
	Missing_Bounds,
	Missing_Parent,
	Invalid_Tolerance,
	Outside_Container,
	Width_Mismatch,
	Alignment_Mismatch,
}

// Layout_Check_Report describes one geometry assertion without allocating.
// delta is the greatest edge overflow/mismatch in logical pixels.
Layout_Check_Report :: struct {
	ok: bool,
	kind: Layout_Check_Kind,
	failure: Layout_Check_Failure,
	delta, tolerance: f32,
	subject_bounds, reference_bounds: alicorn.Rect,
}

Text_Visibility_Failure :: enum {
	None,
	Invalid_Handle,
	Stale_Snapshot,
	Missing_Bounds,
	Empty_Expected_Text,
	Missing_Text_Paint,
	Text_Not_Shaped,
	No_Shaped_Glyphs,
	No_Visible_Glyphs,
}

// Text_Visibility_Report verifies the CPU-side presentation contract: the
// expected bytes occur in a current shaped run, and every matching glyph has
// nontransparent paint and intersects the node and command clip. It does not
// claim that a GPU or platform renderer produced pixels.
Text_Visibility_Report :: struct {
	ok: bool,
	failure: Text_Visibility_Failure,
	matching_glyphs, visible_glyphs: int,
}

layout_check_element_failure :: proc(handle: ^Test_Handle($T), element: ^Element) -> Layout_Check_Failure {
	if handle == nil || handle.runtime == nil || element == nil { return .Invalid_Handle }
	if element.handle_generation != handle.generation || element.description_epoch != handle.description_epoch {
		return .Stale_Snapshot
	}
	if !element.has_bounds || element.bounds.w <= 0 || element.bounds.h <= 0 { return .Missing_Bounds }
	return .None
}

layout_check_tolerance_valid :: proc(tolerance: f32) -> bool {
	return alicorn.number_is_finite(tolerance) && tolerance >= 0
}

layout_max_edge_overflow :: proc(inner, outer: alicorn.Rect) -> f32 {
	left := max(outer.x-inner.x, 0)
	top := max(outer.y-inner.y, 0)
	right := max(inner.x+inner.w-(outer.x+outer.w), 0)
	bottom := max(inner.y+inner.h-(outer.y+outer.h), 0)
	return max(max(left, right), max(top, bottom))
}

// expect_inside checks that a current element's finalized logical bounds fit
// inside a current reference element, allowing tolerance on each edge.
expect_inside :: proc(
	handle: ^Test_Handle($T),
	element, reference: ^Element,
	tolerance: f32 = 0.5,
) -> Layout_Check_Report {
	report := Layout_Check_Report{kind=.Inside, tolerance=tolerance}
	report.failure = layout_check_element_failure(handle, element)
	if report.failure != .None { return report }
	report.failure = layout_check_element_failure(handle, reference)
	if report.failure != .None { return report }
	if !layout_check_tolerance_valid(tolerance) {
		report.failure = .Invalid_Tolerance
		return report
	}
	report.subject_bounds = element.bounds
	report.reference_bounds = reference.bounds
	report.delta = layout_max_edge_overflow(element.bounds, reference.bounds)
	report.ok = report.delta <= tolerance
	if !report.ok { report.failure = .Outside_Container }
	return report
}

// expect_no_overflow checks that the element fits its immediate retained
// layout parent. Use expect_inside when the intended container is not the
// element's direct parent.
expect_no_overflow :: proc(
	handle: ^Test_Handle($T),
	element: ^Element,
	tolerance: f32 = 0.5,
) -> Layout_Check_Report {
	report := Layout_Check_Report{kind=.Inside, tolerance=tolerance}
	report.failure = layout_check_element_failure(handle, element)
	if report.failure != .None { return report }
	if !layout_check_tolerance_valid(tolerance) {
		report.failure = .Invalid_Tolerance
		return report
	}
	info, found := alicorn.node_info(handle.runtime, element.visual_node)
	if !found || info.parent == 0 {
		report.failure = .Missing_Parent
		return report
	}
	parent, parent_found := alicorn.node_info(handle.runtime, info.parent)
	if !parent_found || parent.bounds.w <= 0 || parent.bounds.h <= 0 {
		report.failure = .Missing_Parent
		return report
	}
	report.subject_bounds = element.bounds
	report.reference_bounds = parent.bounds
	report.delta = layout_max_edge_overflow(element.bounds, parent.bounds)
	report.ok = report.delta <= tolerance
	if !report.ok { report.failure = .Outside_Container }
	return report
}

// expect_fills_width checks both horizontal edges against the reference. This
// catches width and horizontal placement errors with one tolerance.
expect_fills_width :: proc(
	handle: ^Test_Handle($T),
	element, reference: ^Element,
	tolerance: f32 = 0.5,
) -> Layout_Check_Report {
	report := Layout_Check_Report{kind=.Fills_Width, tolerance=tolerance}
	report.failure = layout_check_element_failure(handle, element)
	if report.failure != .None { return report }
	report.failure = layout_check_element_failure(handle, reference)
	if report.failure != .None { return report }
	if !layout_check_tolerance_valid(tolerance) {
		report.failure = .Invalid_Tolerance
		return report
	}
	report.subject_bounds = element.bounds
	report.reference_bounds = reference.bounds
	left_delta := absf(element.bounds.x-reference.bounds.x)
	right_delta := absf((element.bounds.x+element.bounds.w)-(reference.bounds.x+reference.bounds.w))
	report.delta = max(left_delta, right_delta)
	report.ok = report.delta <= tolerance
	if !report.ok { report.failure = .Width_Mismatch }
	return report
}

// expect_aligned compares corresponding logical edges or centers in the
// finalized bounds of two current elements.
expect_aligned :: proc(
	handle: ^Test_Handle($T),
	element, reference: ^Element,
	axis: Layout_Check_Axis,
	tolerance: f32 = 0.5,
) -> Layout_Check_Report {
	report := Layout_Check_Report{kind=.Aligned, tolerance=tolerance}
	report.failure = layout_check_element_failure(handle, element)
	if report.failure != .None { return report }
	report.failure = layout_check_element_failure(handle, reference)
	if report.failure != .None { return report }
	if !layout_check_tolerance_valid(tolerance) {
		report.failure = .Invalid_Tolerance
		return report
	}
	report.subject_bounds = element.bounds
	report.reference_bounds = reference.bounds
	actual := layout_alignment_coordinate(element.bounds, axis)
	expected := layout_alignment_coordinate(reference.bounds, axis)
	report.delta = absf(actual-expected)
	report.ok = report.delta <= tolerance
	if !report.ok { report.failure = .Alignment_Mismatch }
	return report
}

layout_alignment_coordinate :: proc(bounds: alicorn.Rect, axis: Layout_Check_Axis) -> f32 {
	switch axis {
	case .Center_X: return bounds.x+bounds.w*0.5
	case .Center_Y: return bounds.y+bounds.h*0.5
	case .Left: return bounds.x
	case .Right: return bounds.x+bounds.w
	case .Top: return bounds.y
	case .Bottom: return bounds.y+bounds.h
	}
	return 0
}

absf :: proc(value: f32) -> f32 {
	return -value if value < 0 else value
}

layout_check_diagnostic :: proc(report: Layout_Check_Report) -> string {
	if report.ok { return "layout assertion passed" }
	return fmt.tprintf(
		"layout assertion failed: kind=%v reason=%v delta=%.2fpx tolerance=%.2fpx subject=%v reference=%v",
		report.kind, report.failure, report.delta, report.tolerance,
		report.subject_bounds, report.reference_bounds,
	)
}

visible_text_element_failure :: proc(handle: ^Test_Handle($T), element: ^Element) -> Text_Visibility_Failure {
	if handle == nil || handle.runtime == nil || element == nil { return .Invalid_Handle }
	if element.handle_generation != handle.generation || element.description_epoch != handle.description_epoch {
		return .Stale_Snapshot
	}
	if !element.has_bounds || element.visual_node == 0 { return .Missing_Bounds }
	return .None
}

visible_rect_intersects :: proc(a, b: alicorn.Rect) -> bool {
	return a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0 &&
		a.x < b.x+b.w && a.x+a.w > b.x && a.y < b.y+b.h && a.y+a.h > b.y
}

visible_text_owner_bounds :: proc(
	rt: ^alicorn.Runtime,
	owner, root: alicorn.Node_ID,
) -> (bounds: alicorn.Rect, found: bool) {
	current := owner
	for current != 0 {
		info, ok := alicorn.node_info(rt, current)
		if !ok { return {}, false }
		if current == root { return info.bounds, true }
		if info.parent == current { return {}, false }
		current = info.parent
	}
	return {}, false
}

// expect_visible_text checks the current retained text product and finalized
// paint stream. It is a headless visibility oracle, not pixel verification.
// Keep native readback coverage for rasterization, glyph residency and shader
// defects that cannot be observed without a renderer.
expect_visible_text :: proc(
	handle: ^Test_Handle($T),
	element: ^Element,
	expected_text: string,
) -> Text_Visibility_Report {
	report := Text_Visibility_Report{}
	report.failure = visible_text_element_failure(handle, element)
	if report.failure != .None { return report }
	if len(expected_text) == 0 {
		report.failure = .Empty_Expected_Text
		return report
	}
	display, display_ok := alicorn.paint_display_list(handle.runtime)
	if !display_ok {
		report.failure = .Invalid_Handle
		return report
	}
	text_paint_found := false
	text_shaped := false
	for command in display.commands {
		paint, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text { continue }
		owner_bounds, owner_in_element := visible_text_owner_bounds(
			handle.runtime, command.owner, element.visual_node,
		)
		if !owner_in_element { continue }
		text_paint_found = true
		run, run_ok := alicorn.paint_text_run_resolve(handle.runtime, paint.run)
		if !run_ok || run == nil { continue }
		text_start := strings.index(run.value, expected_text)
		if text_start < 0 { continue }
		text_shaped = true
		text_end := text_start+len(expected_text)
		for glyph in run.glyphs {
			if glyph.cluster_start >= text_end || glyph.cluster_end <= text_start { continue }
			report.matching_glyphs += 1
			if command.opacity <= 0 || glyph.line_index < 0 || glyph.line_index >= len(run.lines) { continue }
			color := alicorn.text_paint_color_for_cluster(paint.spans, glyph.cluster_start, glyph.cluster_end, paint.color)
			if color.a <= 0 { continue }
			line := run.lines[glyph.line_index]
			advance := absf(glyph.x_advance)
			margin := run.size*0.1
			glyph_bounds := alicorn.Rect{
				command.bounds.x+glyph.x-margin+command.translation[0],
				command.bounds.y+line.y+command.translation[1],
				max(advance, run.size*0.2)+margin*2,
				line.height,
			}
			if visible_rect_intersects(glyph_bounds, command.clip) &&
				visible_rect_intersects(glyph_bounds, owner_bounds) &&
				visible_rect_intersects(glyph_bounds, element.bounds) {
				report.visible_glyphs += 1
			}
		}
	}
	if !text_paint_found {
		report.failure = .Missing_Text_Paint
	} else if !text_shaped {
		report.failure = .Text_Not_Shaped
	} else if report.matching_glyphs == 0 {
		report.failure = .No_Shaped_Glyphs
	} else if report.visible_glyphs != report.matching_glyphs {
		report.failure = .No_Visible_Glyphs
	} else {
		report.ok = true
	}
	return report
}

visible_text_diagnostic :: proc(report: Text_Visibility_Report) -> string {
	if report.ok { return "visible text assertion passed" }
	return fmt.tprintf(
		"visible text assertion failed: reason=%v matching-glyphs=%d visible-glyphs=%d",
		report.failure, report.matching_glyphs, report.visible_glyphs,
	)
}
