#+build !js

package webgpu_renderer

import "core:testing"
import alicorn "../../runtime"
import cpu_renderer "../cpu"

// WebGPU text paint spans are resolved from the retained display command, not
// from a run cache. These tests pin the two properties Scratchpad's syntax
// highlighting depends on: per-glyph span color resolution for every span
// strategy, and mesh-cache invalidation when only span colors change.

WEBGPU_TEXT_SPAN_TEST_FONT :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

webgpu_text_span_test_row :: proc(rt: ^alicorn.Runtime, spans: []alicorn.Text_Paint_Span) -> alicorn.Node_ID {
	ui, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	alicorn.container_begin(&ui, .Root, key="webgpu-text-span-root", style=alicorn.layout_style(.Column, grow=1))
	id := alicorn.text_ex(
		&ui, "func main() { return 1 }", key="webgpu-text-span-row",
		font=.Monospace, style=alicorn.layout_style(.Row, height=20),
	)
	_ = alicorn.text_paint_spans(&ui, id, spans)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return id
}

webgpu_text_span_test_command :: proc(rt: ^alicorn.Runtime, owner: alicorn.Node_ID) -> (alicorn.Text_Paint, bool) {
	for command in rt.display {
		if command.owner != owner { continue }
		if paint, is_text := command.payload.(alicorn.Text_Paint); is_text { return paint, true }
	}
	return {}, false
}

@(test)
test_webgpu_text_span_colors_survive_the_presentation_list :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, WEBGPU_TEXT_SPAN_TEST_FONT) {
		testing.expect(t, false, "the span fixture should load a shaped font")
		return
	}
	spans := []alicorn.Text_Paint_Span{
		{start=0, end=4, color=alicorn.Color{0.40, 0.20, 0.60, 1}, color_set=true},
		{start=5, end=9, color=alicorn.Color{0.10, 0.30, 0.70, 1}, color_set=true},
		{start=15, end=21, color=alicorn.Color{0.60, 0.30, 0.10, 1}, color_set=true},
	}
	node := webgpu_text_span_test_row(&rt, spans)
	if node == 0 { testing.expect(t, false, "the span fixture should describe a row"); return }
	paint, found := webgpu_text_span_test_command(&rt, node)
	testing.expect(t, found && len(paint.spans) == 3,
		"the retained display list must carry every described span")
	run, run_ok := alicorn.paint_text_run_resolve(&rt, paint.run)
	if !run_ok || run == nil {
		testing.expect(t, false, "the span row must retain a shaped text run")
		return
	}

	strategy, single_index, starts_sorted := cpu_renderer.Span_Strategy(len(run.value), paint.spans)
	testing.expect(t, strategy == .Sorted_Non_Overlapping,
		"ordered disjoint syntax spans use the sorted strategy")
	clusters_ordered := cpu_renderer.Glyph_Clusters_Are_Ordered(run.glyphs[:])
	winners: []int
	cursor := 0
	checked := 0
	for glyph in run.glyphs {
		if glyph.control_advance { continue }
		color := Text_Resolved_Glyph_Color(
			len(run.value), paint.spans, strategy, single_index, starts_sorted,
			clusters_ordered, &cursor, winners, glyph, paint.color,
		)
		switch {
		case glyph.cluster_start >= 0 && glyph.cluster_start < 4:
			testing.expect(t, color == paint.spans[0].color, "the keyword span must color its glyphs")
			checked += 1
		case glyph.cluster_start >= 5 && glyph.cluster_start < 9:
			testing.expect(t, color == paint.spans[1].color, "the function span must color its glyphs")
			checked += 1
		case glyph.cluster_start >= 15 && glyph.cluster_start < 21:
			testing.expect(t, color == paint.spans[2].color, "the string span must color its glyphs")
			checked += 1
		case glyph.cluster_start >= 10 && glyph.cluster_start < 14:
			testing.expect(t, color == paint.color, "unspanned glyphs keep the node text color")
			checked += 1
		}
	}
	testing.expect(t, checked >= 8, "the fixture must resolve colors for several glyph classes")
}

@(test)
test_webgpu_text_span_mesh_fingerprint_tracks_span_colors :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, WEBGPU_TEXT_SPAN_TEST_FONT) {
		testing.expect(t, false, "the span fixture should load a shaped font")
		return
	}
	first := []alicorn.Text_Paint_Span{
		{start=0, end=4, color=alicorn.Color{0.40, 0.20, 0.60, 1}, color_set=true},
	}
	second := []alicorn.Text_Paint_Span{
		{start=0, end=4, color=alicorn.Color{0.10, 0.60, 0.20, 1}, color_set=true},
	}
	renderer: Text_Renderer
	_ = webgpu_text_span_test_row(&rt, first)
	fingerprint_first := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	// Re-describing the identical row with a different span color must invalidate
	// the retained glyph mesh; a color-blind cache would keep the old vertices.
	// The node identity is stable, so only the span color changed.
	alicorn.invalidate_root(&rt, "webgpu text span color update")
	ui, build := alicorn.begin_frame(&rt)
	if !build { testing.expect(t, false, "the span update frame should build"); return }
	alicorn.container_begin(&ui, .Root, key="webgpu-text-span-root", style=alicorn.layout_style(.Column, grow=1))
	id := alicorn.text_ex(
		&ui, "func main() { return 1 }", key="webgpu-text-span-row",
		font=.Monospace, style=alicorn.layout_style(.Row, height=20),
	)
	_ = alicorn.text_paint_spans(&ui, id, second)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	paint, found := webgpu_text_span_test_command(&rt, id)
	testing.expect(t, found && len(paint.spans) == 1 && paint.spans[0].color == second[0].color,
		"the updated display command must carry the new span color")
	fingerprint_second := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	testing.expect(t, fingerprint_first != fingerprint_second,
		"span-only color changes must invalidate the retained WebGPU text mesh")
}

// Edit-sequence cache check: the WebGPU glyph mesh is one list-wide product, so
// it must rebuild when any row's value or spans change and must remain reusable
// when the identical description is presented again. Scratchpad's rebased-span
// frame is exactly the first case: the value grew and the tokens after the
// insertion shifted.
webgpu_text_span_edit_row :: proc(
	rt: ^alicorn.Runtime,
	value: string,
	spans: []alicorn.Text_Paint_Span,
) -> (paint: alicorn.Text_Paint, run_value: string, found: bool) {
	alicorn.invalidate_root(rt, "webgpu text edit-sequence description")
	ui, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ui, .Root, key="webgpu-text-edit-root", style=alicorn.layout_style(.Column, grow=1))
	id := alicorn.text_ex(
		&ui, value, key="webgpu-text-edit-row",
		font=.Monospace, style=alicorn.layout_style(.Row, height=20),
	)
	_ = alicorn.text_paint_spans(&ui, id, spans)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	for command in rt.display {
		if command.owner != id { continue }
		text, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text { continue }
		paint, found = text, true
		if run, ok := alicorn.paint_text_run_resolve(rt, text.run); ok && run != nil {
			run_value = run.value
		}
		return
	}
	return
}

@(test)
test_webgpu_text_span_edit_sequence_reuses_only_identical_meshes :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, WEBGPU_TEXT_SPAN_TEST_FONT) {
		testing.expect(t, false, "the edit-sequence fixture should load a shaped font")
		return
	}
	renderer: Text_Renderer
	settled := []alicorn.Text_Paint_Span{
		{start=0, end=4, color=alicorn.Color{0.40, 0.20, 0.60, 1}, color_set=true},
		{start=5, end=9, color=alicorn.Color{0.10, 0.30, 0.70, 1}, color_set=true},
	}
	rebased := []alicorn.Text_Paint_Span{
		{start=0, end=5, color=alicorn.Color{0.40, 0.20, 0.60, 1}, color_set=true},
		{start=6, end=10, color=alicorn.Color{0.10, 0.30, 0.70, 1}, color_set=true},
	}
	settled_value := "func main() { return 1 }"
	edited_value := "xfunc main() { return 1 }"

	paint, value, found := webgpu_text_span_edit_row(&rt, settled_value, settled)
	if !found || len(paint.spans) != 2 || value != settled_value {
		testing.expect(t, false, "the settled edit-sequence row should carry its spans and value")
		return
	}
	settled_fingerprint := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	_, repeat_value, repeat_found := webgpu_text_span_edit_row(&rt, settled_value, settled)
	if !repeat_found || repeat_value != settled_value {
		testing.expect(t, false, "an identical re-description should keep the row paintable")
		return
	}
	repeat_fingerprint := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	testing.expect(t, repeat_fingerprint == settled_fingerprint,
		"an identical description must reuse the retained WebGPU text mesh")

	paint, value, found = webgpu_text_span_edit_row(&rt, edited_value, rebased)
	if !found || value != edited_value {
		testing.expect(t, false, "the edited row should resolve its new value")
		return
	}
	testing.expect(t, len(paint.spans) == 2 &&
		paint.spans[0].start == 0 && paint.spans[0].end == 5 &&
		paint.spans[1].start == 6 && paint.spans[1].end == 10,
		"the edited row's rebased spans must reach the WebGPU command")
	edited_fingerprint := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	testing.expect(t, edited_fingerprint != repeat_fingerprint,
		"a value-and-span edit must invalidate the retained WebGPU text mesh")
	_, final_value, final_found := webgpu_text_span_edit_row(&rt, edited_value, rebased)
	if !final_found || final_value != edited_value {
		testing.expect(t, false, "the settled edited row should stay paintable")
		return
	}
	final_fingerprint := text_mesh_fingerprint(&renderer, &rt, rt.display[:], 320, 120, 1, 1)
	testing.expect(t, final_fingerprint == edited_fingerprint,
		"the settled edited description must reuse its mesh instead of rebuilding every frame")
}
