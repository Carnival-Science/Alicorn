package alicorn_sdl_gpu

import "core:math"
import "core:testing"
import alicorn "../../runtime"

surface_test_near :: proc(a, b: f32, epsilon: f32 = 0.001) -> bool {
	delta := a - b
	if delta < 0 { delta = -delta }
	return delta <= epsilon
}

@(test)
test_surface_segment_scales_vertices :: proc(t: ^testing.T) {
	vertices: [dynamic]Native_Text_Vertex
	defer delete(vertices)

	ok := native_surface_append_segment(
		&vertices,
		10, 20,
		30, 40,
		2, 2,
		2,
		[4]f32{1, 1, 1, 1},
	)
	testing.expect(t, ok && len(vertices) == 6, "scaled surface segment must emit its complete triangle")
	if len(vertices) != 6 { return }

	// The first vertex is the logical start minus the normalized line normal.
	// At 2x Retina scale both coordinates must be in physical pixels.
	logical_nx := -1 / math.sqrt(f32(2))
	logical_ny := 1 / math.sqrt(f32(2))
	testing.expect(t,
		surface_test_near(vertices[0].position.x, (10-logical_nx)*2) &&
			surface_test_near(vertices[0].position.y, (20-logical_ny)*2),
		"surface line vertices must convert logical coordinates to physical pixels")
}

@(test)
test_surface_point_marker_uses_six_vertices_and_circle_mask :: proc(t: ^testing.T) {
	vertices: [dynamic]Native_Text_Vertex
	defer delete(vertices)
	color := [4]f32{0.8, 0.3, 0.1, 0.5}
	ok := native_surface_append_point_marker(&vertices, 20, 30, 2, 1.5, 4, color)
	testing.expect(t, ok && len(vertices) == alicorn.GPU_SURFACE_POINT_MARKER_VERTICES,
		"a compact point marker should emit one six-vertex quad")
	if len(vertices) != 6 { return }
	top_left := [3]f32{36, 42, 0}
	bottom_right := [3]f32{44, 48, 0}
	uv_top_left := [2]f32{0, 0}
	uv_top_right := [2]f32{1, 0}
	uv_bottom_right := [2]f32{1, 1}
	testing.expect(t,
		vertices[0].position == top_left && vertices[2].position == bottom_right &&
			vertices[0].uv == uv_top_left && vertices[1].uv == uv_top_right &&
			vertices[2].uv == uv_bottom_right && vertices[0].color == color,
		"marker quad should scale its logical bounds and map the circle-mask texture")
	testing.expect(t,
		native_surface_marker_mask_alpha(NATIVE_SURFACE_MARKER_MASK_SIZE/2, NATIVE_SURFACE_MARKER_MASK_SIZE/2) == 255 &&
			native_surface_marker_mask_alpha(0, 0) == 0,
		"circle mask should be opaque at its center and transparent at the corner")
}

@(test)
test_waveform_mesh_fits_exact_runtime_sample_limit :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 120, 40})
	defer alicorn.destroy_runtime(&rt)
	alicorn.invalidate_root(&rt, "waveform mesh capacity test")
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "initial waveform tree should build")
		return
	}
	alicorn.container_begin(&ui, .Root, label="waveform-capacity-root")
	surface := alicorn.gpu_surface(&ui, "waveform-capacity-surface", alicorn.Rect{0, 0, 120, 40}, 120, 40, 1)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	samples := make([]f32, alicorn.GPU_SURFACE_MAX_WAVEFORM_SAMPLES)
	defer delete(samples)
	for i in 0..<len(samples) { samples[i] = 0.5 }
	testing.expect(t, alicorn.gpu_surface_update(&rt, surface, samples),
		"runtime should accept exactly the waveform capacity")

	renderer := Native_Surface_Renderer{
		runtime=&rt,
		vertices=make([dynamic]Native_Text_Vertex, 0, alicorn.GPU_SURFACE_MAX_VERTICES),
	}
	defer delete(renderer.vertices)
	node := rt.nodes[surface]
	command := alicorn.paint_geometry_command(surface, node.bounds, node.clip, alicorn.paint_geometry_handle_for_node(node))
	testing.expect(t, native_surface_rebuild_mesh(&renderer, command, 1, 1),
		"native waveform mesh at the documented maximum should build")
	testing.expect(t, len(node.paint) == 2 && alicorn.paint_command_is_surface(node.paint[0]),
		"waveform backdrop should be retained as a generic surface command")
	testing.expect(t, len(renderer.vertices) == (alicorn.GPU_SURFACE_MAX_WAVEFORM_SAMPLES-1)*6,
		"maximum waveform geometry should use 8,184 vertices; its separate backdrop uses six")
	testing.expect(t, len(renderer.vertices)+6 <= alicorn.GPU_SURFACE_MAX_VERTICES,
		"waveform geometry plus its generic backdrop should remain within the 8,192-vertex budget")
}

@(test)
test_dense_sample_marker_mesh_fits_retained_budget :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 720, 360})
	defer alicorn.destroy_runtime(&rt)
	alicorn.invalidate_root(&rt, "dense sample marker mesh capacity test")
	ui, should_build := alicorn.begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "initial geometry surface tree should build")
		return
	}
	alicorn.container_begin(&ui, .Root, label="dense-marker-root")
	surface := alicorn.gpu_geometry_surface(&ui, "dense-marker-surface", alicorn.layout_style(width=640, height=240), 1)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

	segments := make([]alicorn.GPU_Surface_Line_Segment, 426)
	defer delete(segments)
	markers := make([]alicorn.GPU_Surface_Point_Marker, 427)
	defer delete(markers)
	for i in 0..<len(segments) {
		segments[i] = alicorn.GPU_Surface_Line_Segment{
			start={f32(i), 100}, end={f32(i+1), 101}, thickness=1, color={0.25, 0.8, 0.95, 1},
		}
	}
	for i in 0..<len(markers) {
		markers[i] = alicorn.GPU_Surface_Point_Marker{
			center={f32(i), 100}, diameter=4, color={1, 0.85, 0.2, 1},
		}
	}
	testing.expect(t, alicorn.gpu_surface_update_geometry_with_markers(
		&rt, surface, segments, nil, markers,
	), "dense high-zoom samples should be accepted as compact marker geometry")
	node := rt.nodes[surface]
	command := alicorn.paint_geometry_command(surface, node.bounds, node.clip, alicorn.paint_geometry_handle_for_node(node))
	renderer := Native_Surface_Renderer{
		runtime=&rt,
		vertices=make([dynamic]Native_Text_Vertex, 0, alicorn.GPU_SURFACE_MAX_VERTICES),
	}
	defer delete(renderer.vertices)
	testing.expect(t, native_surface_rebuild_mesh(&renderer, command, 1, 1),
		"native mesh should expand compact markers and connecting lines")
	expected_vertices := (426 + 427) * alicorn.GPU_SURFACE_POINT_MARKER_VERTICES
	testing.expect(t, len(renderer.vertices) == expected_vertices && expected_vertices == 5118 &&
		expected_vertices <= alicorn.GPU_SURFACE_MAX_VERTICES,
		"427 markers and 426 sample segments should use 5,118 vertices under the 8,192 budget")
	if len(renderer.vertices) > 0 {
		last_marker_first_vertex := 426*6 + 426*6
		testing.expect(t, renderer.vertices[last_marker_first_vertex].uv == [2]f32{0, 0},
			"marker quads should follow connecting segments so sample points remain visually prominent")
	}
}
