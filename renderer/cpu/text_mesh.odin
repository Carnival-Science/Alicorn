package cpu_renderer

import alicorn "../../runtime"

// Text_Glyph_Mesh is the backend-neutral, physical-pixel quad for one
// rasterized atlas glyph. The renderer resolves the glyph's slot; this helper
// preserves Alicorn's existing snap, clip, UV, and tint policy when converting
// it into vertices.
Text_Glyph_Mesh :: struct {
	vertices: [6]Vertex,
	subpixel_bucket: u8,
	visible: bool,
}

Build_Text_Glyph_Mesh :: proc(
	glyph: alicorn.Text_Glyph,
	command: alicorn.Paint_Command,
	bearing: [2]f32,
	pixel_size: [2]u16,
	uv_rect: [4]f32,
	paint_color: alicorn.Color,
	is_color: bool,
	scale_x, scale_y: f32,
) -> (mesh: Text_Glyph_Mesh) {
	physical_x := (command.bounds.x + glyph.x) * scale_x
	physical_y := (command.bounds.y + glyph.y) * scale_y
	snapped_x, subpixel_bucket := Snap_Text_X(physical_x)
	snapped_y := Snap_Text_Y(physical_y)
	mesh.subpixel_bucket = subpixel_bucket
	if pixel_size[0] == 0 || pixel_size[1] == 0 { return }

	x0 := snapped_x + bearing[0]
	y0 := snapped_y + bearing[1]
	x1 := x0 + f32(pixel_size[0])
	y1 := y0 + f32(pixel_size[1])
	if command.translation[0] == 0 && command.translation[1] == 0 &&
	   !Text_Quad_Visible(x0, y0, x1, y1, command.clip, scale_x, scale_y) {
		return
	}
	color := Vertex_Color(paint_color, command.opacity, is_color)
	u0, v0, u1, v1 := uv_rect[0], uv_rect[1], uv_rect[2], uv_rect[3]
	mesh.vertices = [6]Vertex{
		{[3]f32{x0, y0, 0}, color, [2]f32{u0, v0}},
		{[3]f32{x1, y0, 0}, color, [2]f32{u1, v0}},
		{[3]f32{x1, y1, 0}, color, [2]f32{u1, v1}},
		{[3]f32{x0, y0, 0}, color, [2]f32{u0, v0}},
		{[3]f32{x1, y1, 0}, color, [2]f32{u1, v1}},
		{[3]f32{x0, y1, 0}, color, [2]f32{u0, v1}},
	}
	mesh.visible = true
	return
}
