#+build !js

package alicorn

import "core:strings"
import "core:testing"

// A capture bundle must distinguish a resolved fallback glyph from an
// unresolved .notdef box without a screenshot. The bundled faces do not cover
// U+22EF HORIZONTAL MIDLINE ELLIPSIS, so a bundled-only runtime records the
// primary face, the shaped glyph id (0 = .notdef), and the unresolved marker.
@(test)
test_inspector_records_text_run_face_and_unresolved_coverage :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 80})
	defer destroy_runtime(&rt)
	if !text_engine_load_default_fonts(&rt) {
		testing.expect(t, false, "bundled fonts should load for the resolution fixture")
		return
	}
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "resolution fixture should begin a frame"); return }
	container_begin_simple(&ui, .Root, label="resolution-root", key=key_string("resolution-root"), style=layout_style(.Row, width=200, height=40))
	_ = text(&ui, "\u22EF", key=key_string("midline-ellipsis"))
	container_end(&ui)
	end_frame(&ui)

	inspection := inspect(&rt)
	defer delete(inspection)
	testing.expect(t, strings.contains(inspection, "faces=[1] unresolved=true"),
		"an uncovered bundled glyph must report its primary face and unresolved coverage")
	testing.expect(t, !strings.contains(inspection, "text fallback glyphs:"),
		"bundled-only shaping must not claim fallback-glyph provenance")
}
