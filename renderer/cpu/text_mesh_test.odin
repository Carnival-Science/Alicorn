#+build !js
package cpu_renderer

import "core:testing"
import alicorn "../../runtime"

@(test)
test_text_glyph_mesh_keeps_snapping_uv_and_tint_backend_neutral :: proc(t: ^testing.T) {
	command := alicorn.paint_text_command(1, {10, 20, 40, 20}, {10, 20, 40, 20}, {}, {0.2, 0.3, 0.4, 0.8}, opacity=0.5)
	glyph := alicorn.Text_Glyph{x=0.9, y=2.2}
	mesh := Build_Text_Glyph_Mesh(
		glyph, command, {1, -2}, {4, 5}, {0.1, 0.2, 0.3, 0.4},
		alicorn.Color{0.2, 0.3, 0.4, 0.8}, false, 1, 1,
	)
	testing.expect(t, mesh.visible && mesh.subpixel_bucket == 0,
		"glyph mesh should retain quarter-pixel carry snapping and visibility")
	testing.expect(t, mesh.vertices[0].position == [3]f32{12, 20, 0} &&
		mesh.vertices[2].position == [3]f32{16, 25, 0},
		"glyph bearings and bitmap size should produce the existing physical-pixel bounds")
	testing.expect(t, mesh.vertices[0].uv == [2]f32{0.1, 0.2} &&
		mesh.vertices[2].uv == [2]f32{0.3, 0.4} &&
		mesh.vertices[0].color == [4]f32{0.2, 0.3, 0.4, 0.4},
		"monochrome glyphs should preserve atlas UVs and paint tint/opacity")
}

@(test)
test_text_glyph_mesh_uses_neutral_rgb_for_color_glyphs_and_honors_clip :: proc(t: ^testing.T) {
	command := alicorn.paint_text_command(1, {0, 0, 20, 20}, {0, 0, 8, 8}, {}, {0.7, 0.2, 0.1, 0.6}, opacity=0.5)
	glyph := alicorn.Text_Glyph{x=12, y=2}
	mesh := Build_Text_Glyph_Mesh(glyph, command, {}, {4, 4}, {0, 0, 1, 1}, alicorn.Color{0.7, 0.2, 0.1, 0.6}, true, 1, 1)
	testing.expect(t, !mesh.visible,
		"a stationary atlas quad entirely outside the command clip should be culled")
	command.translation = {1, 0}
	translated := Build_Text_Glyph_Mesh(glyph, command, {}, {4, 4}, {0, 0, 1, 1}, alicorn.Color{0.7, 0.2, 0.1, 0.6}, true, 1, 1)
	testing.expect(t, translated.visible && translated.vertices[0].color == [4]f32{1, 1, 1, 0.3},
		"translated glyphs should remain available for motion and color atlases should retain their own RGB")
}
