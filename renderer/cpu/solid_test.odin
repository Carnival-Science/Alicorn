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
