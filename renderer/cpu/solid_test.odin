#+build !js
package cpu_renderer

import "core:testing"
import alicorn "../../runtime"

@(test)
test_solid_surface_mesh_assembly_is_backend_neutral :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime({0, 0, 80, 60})
	defer alicorn.destroy_runtime(&rt)
	vertices := make([dynamic]Vertex, 0, 12, allocator=context.temp_allocator)
	defer delete(vertices)

	draw := alicorn.paint_surface_command(
		1, {2, 3, 10, 8}, {0, 0, 80, 60}, {0.2, 0.4, 0.6, 1},
	)
	count, visible := Solid_Surface_Vertex_Count(&rt, draw, 1, 1, 80, 60)
	mesh := Append_Surface_Mesh(&vertices, &rt, draw, 1, 1, 80, 60)
	testing.expect(t, visible && count == 6 && mesh.first_vertex == 0 && mesh.vertex_count == 6,
		"the shared solid builder should preflight and emit the same six-vertex flat surface")
	testing.expect(t, len(vertices) == 6 && vertices[0].position == [3]f32{2, 3, 0} &&
		vertices[2].position == [3]f32{12, 11, 0} && vertices[0].color == [4]f32{0.2, 0.4, 0.6, 1},
		"surface coordinates and fill data should remain in the backend-neutral vertex product")
	testing.expect(t, !mesh.has_scissor,
		"an ordinary flat surface should keep the existing no-scissor fast path")
}

@(test)
test_solid_surface_mesh_leaves_non_surface_commands_empty :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime({0, 0, 80, 60})
	defer alicorn.destroy_runtime(&rt)
	vertices := make([dynamic]Vertex, 0, 12, allocator=context.temp_allocator)
	defer delete(vertices)
	display := [2]alicorn.Paint_Command{
		alicorn.paint_text_command(2, {0, 0, 20, 20}, {0, 0, 80, 60}, {}, {1, 1, 1, 1}),
		alicorn.paint_geometry_command(3, {0, 0, 20, 20}, {0, 0, 80, 60}, {}),
	}
	all_empty := true
	for draw in display {
		count, visible := Solid_Surface_Vertex_Count(&rt, draw, 1, 1, 80, 60)
		mesh := Append_Surface_Mesh(&vertices, &rt, draw, 1, 1, 80, 60)
		if count != 0 || visible || mesh.vertex_count != 0 || len(vertices) != 0 { all_empty = false }
	}
	testing.expect(t, all_empty,
		"text and geometry commands should not leak into the surface mesh lane")
}

@(test)
test_solid_surface_mesh_fingerprint_ignores_unrelated_paint_revision :: proc(t: ^testing.T) {
	surface := alicorn.paint_surface_command(
		1, {2, 3, 10, 8}, {0, 0, 80, 60}, {0.2, 0.4, 0.6, 1},
	)
	text := alicorn.paint_text_command(
		2, {4, 16, 20, 12}, {0, 0, 80, 60}, {}, {1, 1, 1, 1},
	)
	display := [2]alicorn.Paint_Command{surface, text}
	initial := Solid_Surface_Mesh_Fingerprint(nil, display[:], 1, 1, 80, 60)

	display[1].bounds.x += 3
	changed_text, _ := display[1].payload.(alicorn.Text_Paint)
	changed_text.color = {0.8, 0.2, 0.1, 1}
	display[1].payload = changed_text
	unchanged_solid := Solid_Surface_Mesh_Fingerprint(nil, display[:], 1, 1, 80, 60)
	testing.expect(t, initial == unchanged_solid,
		"text-only changes should preserve the solid surface mesh fingerprint")

	changed_surface, _ := display[0].payload.(alicorn.Surface_Paint)
	changed_surface.fill = {0.9, 0.2, 0.1, 1}
	display[0].payload = changed_surface
	changed_solid := Solid_Surface_Mesh_Fingerprint(nil, display[:], 1, 1, 80, 60)
	testing.expect(t, changed_solid != initial,
		"surface paint changes must invalidate the solid mesh fingerprint")

	shifted := [3]alicorn.Paint_Command{text, surface, display[1]}
	testing.expect(t,
		Solid_Surface_Mesh_Fingerprint(nil, shifted[:], 1, 1, 80, 60) != initial,
		"a changed paint index must invalidate draw-command mapping")
}
