#+build !js
package cpu_renderer

import "core:testing"
import alicorn "../../runtime"

@(test)
test_gpu_surface_geometry_uses_shared_scaled_retained_mesh :: proc(t: ^testing.T) {
	vertices := make([dynamic]Vertex, 0, 80, allocator=context.temp_allocator)
	defer delete(vertices)
	rectangles := [1]alicorn.GPU_Surface_Filled_Rectangle{{bounds={1, 2, 4, 3}, color={0.1, 0.2, 0.3, 0.8}}}
	segments := [1]alicorn.GPU_Surface_Line_Segment{{start={2, 3}, end={12, 3}, thickness=2, color={1, 0, 0, 1}}}
	circles := [1]alicorn.GPU_Surface_Filled_Circle{{center={20, 10}, radius=4, color={0, 1, 0, 1}}}
	markers := [1]alicorn.GPU_Surface_Point_Marker{{center={30, 12}, diameter=4, color={0, 0, 1, 0.5}}}
	payload := alicorn.GPU_Surface_Payload_View{
		rectangles=rectangles[:], segments=segments[:], circles=circles[:], point_markers=markers[:],
	}
	command := alicorn.paint_geometry_command(7, {100, 50, 40, 30}, {0, 0, 300, 200}, {}, opacity=0.5, translation={3, 4})
	count := GPU_Surface_Vertex_Count(payload)
	ok := GPU_Surface_Append_Payload(&vertices, command, payload, 2, 1.5)
	expected := 6+6+alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3+6
	testing.expect(t, ok && count == expected && len(vertices) == expected,
		"retained custom geometry should emit the runtime's bounded rectangle, segment, circle, and marker mesh")
	if len(vertices) < expected { return }
	testing.expect(t,
		vertices[0].position == [3]f32{208, 84, 0} && vertices[2].position == [3]f32{216, 88.5, 0} &&
			vertices[0].color == [4]f32{0.1, 0.2, 0.3, 0.4},
		"rectangle coordinates should include command translation, independent pixel scales, and opacity")
	marker_index := expected-alicorn.GPU_SURFACE_POINT_MARKER_VERTICES
	testing.expect(t,
		vertices[marker_index].uv == [2]f32{0, 0} && vertices[marker_index+2].uv == [2]f32{1, 1} &&
			vertices[marker_index].color[3] == 0.25,
		"compact markers should preserve their mask UVs and multiply source alpha by command opacity")
}

@(test)
test_gpu_surface_waveform_mesh_clamps_samples_and_preserves_empty_payload :: proc(t: ^testing.T) {
	vertices := make([dynamic]Vertex, 0, 12, allocator=context.temp_allocator)
	defer delete(vertices)
	samples := [3]f32{-1, 0.5, 2}
	payload := alicorn.GPU_Surface_Payload_View{samples=samples[:], revision=1}
	command := alicorn.paint_geometry_command(8, {10, 20, 40, 30}, {0, 0, 100, 100}, {}, opacity=0.75)
	count := GPU_Surface_Vertex_Count(payload)
	ok := GPU_Surface_Append_Payload(&vertices, command, payload, 2, 1)
	testing.expect(t, ok && count == 12 && len(vertices) == 12,
		"a three-sample waveform should emit two retained line quads")
	if len(vertices) < 12 { return }
	testing.expect(t,
		vertices[0].position[1] > 49.19 && vertices[0].position[1] < 49.21 &&
			vertices[1].position[1] > 34.19 && vertices[1].position[1] < 34.21 &&
			vertices[0].color == [4]f32{0.30, 0.88, 0.96, 0.75},
		"waveform samples should clamp to the surface bounds and retain the established cyan tint and opacity")
	empty := alicorn.GPU_Surface_Payload_View{}
	testing.expect(t, GPU_Surface_Vertex_Count(empty) == 0,
		"an empty or one-sample payload should not create geometry")
}

@(test)
test_gpu_surface_mesh_keeps_primitives_before_waveform_samples :: proc(t: ^testing.T) {
	vertices := make([dynamic]Vertex, 0, 12, allocator=context.temp_allocator)
	defer delete(vertices)
	rectangles := [1]alicorn.GPU_Surface_Filled_Rectangle{{bounds={1, 2, 4, 3}, color={1, 0, 0, 1}}}
	samples := [2]f32{0, 1}
	payload := alicorn.GPU_Surface_Payload_View{rectangles=rectangles[:], samples=samples[:], revision=1}
	command := alicorn.paint_geometry_command(9, {10, 20, 40, 30}, {0, 0, 100, 100}, {})
	count := GPU_Surface_Vertex_Count(payload)
	ok := GPU_Surface_Append_Payload(&vertices, command, payload, 1, 1)
	testing.expect(t, ok && count == 12 && len(vertices) == 12,
		"a payload may contain both explicit primitives and waveform segments")
	if len(vertices) < 12 { return }
	testing.expect(t,
		vertices[0].color == [4]f32{1, 0, 0, 1} && vertices[6].color == [4]f32{0.30, 0.88, 0.96, 1},
		"explicit geometry should remain before waveform segments in the historical paint order")
}

@(test)
test_gpu_surface_marker_mask_is_shared_and_antialiased :: proc(t: ^testing.T) {
	pixels := make([]u8, GPU_SURFACE_MARKER_MASK_SIZE*GPU_SURFACE_MARKER_MASK_SIZE*4, allocator=context.temp_allocator)
	testing.expect(t, GPU_Surface_Marker_Mask_RGBA8(pixels), "the shared marker texture should fill an exact RGBA8 image")
	center := (GPU_SURFACE_MARKER_MASK_SIZE/2*GPU_SURFACE_MARKER_MASK_SIZE+GPU_SURFACE_MARKER_MASK_SIZE/2)*4
	corner := 0
	testing.expect(t, pixels[center] == 255 && pixels[center+3] == 255 && pixels[corner] == 255 && pixels[corner+3] == 0,
		"marker texture RGB should stay neutral white while center/corner alpha define the circle")
	testing.expect(t, !GPU_Surface_Marker_Mask_RGBA8(pixels[:len(pixels)-1]),
		"mask generation should reject a truncated image instead of writing out of bounds")
}
