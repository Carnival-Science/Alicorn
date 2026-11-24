#+build !js
package alicorn

import "core:testing"

gpu_surface_retype_test_describe :: proc(rt: ^Runtime, kind: Node_Kind) -> Node_ID {
	invalidate_root(rt, "custom surface retype test")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, key=key_string("surface-retype-root"), style=layout_style(.Column, width=100, height=80))
	text_value := ""
	if kind == .Text { text_value = "plain text" }
	id := emit_key(
		&ui,
		kind,
		Source_Site{file="gpu_surface_test.odin", line=1},
		label="retyped surface",
		text=text_value,
		key=key_string("surface-retype-node"),
		style=layout_style(.Row, width=40, height=30),
		paint_background=false,
		surface_pixel_width=40,
		surface_pixel_height=30,
	)
	container_end(&ui)
	end_frame(&ui)
	return id
}

@(test)
test_gpu_surface_waveform_sample_limit_is_atomic :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 180})
	defer destroy_runtime(&rt)

	invalidate_root(&rt, "waveform sample limit test")
	ui, should_build := begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "initial surface tree should build")
		return
	}
	container_begin(&ui, .Root, label="waveform-limit-root")
	surface := gpu_surface(&ui, "waveform-limit-surface", Rect{0, 0, 120, 40}, 120, 40, 1)
	container_end(&ui)
	end_frame(&ui)

	samples := make([]f32, GPU_SURFACE_MAX_WAVEFORM_SAMPLES)
	defer delete(samples)
	for i in 0..<len(samples) { samples[i] = f32(i) / f32(len(samples)) }
	testing.expect(t, gpu_surface_update(&rt, surface, samples),
		"the exact waveform sample limit should be accepted")
	node := rt.nodes[surface]
	testing.expect(t, u64(node.surface_payload_revision) == 1 && len(node.surface_samples) == GPU_SURFACE_MAX_WAVEFORM_SAMPLES,
		"accepted boundary update should retain the full payload and assign a payload revision")
	if len(node.surface_samples) != GPU_SURFACE_MAX_WAVEFORM_SAMPLES { return }
	first_sample := node.surface_samples[0]
	last_sample := node.surface_samples[len(node.surface_samples)-1]
	gpu_surface_frame_consumed(&rt)
	previous_presentation_revision := rt.presentation_revision
	previous_update_count := rt.stats.surface_updates

	oversized := make([]f32, GPU_SURFACE_MAX_WAVEFORM_SAMPLES+1)
	defer delete(oversized)
	for i in 0..<len(oversized) { oversized[i] = 1 }
	testing.expect(t, !gpu_surface_update(&rt, surface, oversized),
		"one sample above the waveform limit should be rejected")
	testing.expect(t,
		u64(node.surface_payload_revision) == 1 && len(node.surface_samples) == GPU_SURFACE_MAX_WAVEFORM_SAMPLES &&
			node.surface_samples[0] == first_sample && node.surface_samples[len(node.surface_samples)-1] == last_sample,
		"rejected update should preserve the previous samples and revision")
	testing.expect(t,
		!rt.surface_frame_pending && rt.presentation_revision == previous_presentation_revision &&
			rt.stats.surface_updates == previous_update_count,
		"rejected update should not queue a frame, advance presentation, or increment updates")
}

@(test)
test_gpu_surface_compact_point_markers_validate_budget_and_lifecycle :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 1920, 180})
	defer destroy_runtime(&rt)

	invalidate_root(&rt, "compact point marker geometry test")
	ui, should_build := begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "initial geometry surface tree should build")
		return
	}
	container_begin(&ui, .Root, label="point-marker-root")
	surface := gpu_geometry_surface(&ui, "point-marker-surface", layout_style(width=1920, height=80), 1)
	container_end(&ui)
	end_frame(&ui)

	segments := make([]GPU_Surface_Line_Segment, 426)
	defer delete(segments)
	markers := make([]GPU_Surface_Point_Marker, 427)
	defer delete(markers)
	for i in 0..<len(segments) {
		segments[i] = GPU_Surface_Line_Segment{
			start={f32(i*3), 10}, end={f32((i+1)*3), 12}, thickness=1, color={0.2, 0.8, 0.9, 1},
		}
	}
	for i in 0..<len(markers) {
		markers[i] = GPU_Surface_Point_Marker{
			center={f32(i*3), 11}, diameter=4, color={0.95, 0.9, 0.2, 1},
		}
	}
	// At 3 logical pixels per sample, a 1,280px viewport shows 427 samples.
	// Their connected lines plus compact markers require 5,118 vertices.
	testing.expect(t, gpu_surface_geometry_fits(len(segments), 0, 0, len(markers)),
		"dense waveform markers and connecting segments should fit the shared geometry budget")
	testing.expect(t, gpu_surface_update_geometry_with_markers(
		&rt, surface, segments, nil, markers,
	), "valid compact point markers should be retained")

	wide_segments := make([]GPU_Surface_Line_Segment, 639)
	defer delete(wide_segments)
	wide_markers := make([]GPU_Surface_Point_Marker, 640)
	defer delete(wide_markers)
	for i in 0..<len(wide_segments) {
		wide_segments[i] = GPU_Surface_Line_Segment{
			start={f32(i*3), 10}, end={f32((i+1)*3), 12}, thickness=1, color={0.2, 0.8, 0.9, 1},
		}
	}
	for i in 0..<len(wide_markers) {
		wide_markers[i] = GPU_Surface_Point_Marker{
			center={f32(i*3), 11}, diameter=4, color={0.95, 0.9, 0.2, 1},
		}
	}
	// The same density in a 1,920px viewport produces 640 samples and 7,674
	// vertices including 639 connected waveform segments.
	testing.expect(t, gpu_surface_geometry_fits(len(wide_segments), 0, 0, len(wide_markers)),
		"a 1,920px dense sample view should fit its connected lines and markers")
	testing.expect(t, gpu_surface_update_geometry_with_markers(
		&rt, surface, wide_segments, nil, wide_markers,
	), "the full 1,920px dense sample batch should be accepted")
	node := rt.nodes[surface]
	handle := paint_geometry_handle_for_node(node)
	payload, payload_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, payload_ok && len(payload.segments) == 639 && len(payload.point_markers) == 640,
		"the borrowed payload view should expose the full 1,920px segment and marker snapshot")
	if !payload_ok || len(payload.point_markers) != 640 { return }
	accepted_revision := payload.revision
	accepted_last_marker := payload.point_markers[len(payload.point_markers)-1]

	too_many := make([]GPU_Surface_Point_Marker, GPU_SURFACE_MAX_VERTICES/GPU_SURFACE_POINT_MARKER_VERTICES+1)
	defer delete(too_many)
	for i in 0..<len(too_many) {
		too_many[i] = GPU_Surface_Point_Marker{center={f32(i), 8}, diameter=3, color={1, 1, 1, 1}}
	}
	testing.expect(t, !gpu_surface_update_geometry_with_rectangles_and_markers(&rt, surface, nil, nil, nil, too_many),
		"marker geometry exceeding the shared vertex limit should be rejected")
	invalid := [1]GPU_Surface_Point_Marker{{center={5, 5}, diameter=0, color={1, 1, 1, 1}}}
	testing.expect(t, !gpu_surface_update_geometry_with_rectangles_and_markers(&rt, surface, nil, nil, nil, invalid[:]),
		"zero-diameter markers should be rejected")
	after_rejection, after_rejection_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, after_rejection_ok && after_rejection.revision == accepted_revision &&
		len(after_rejection.segments) == 639 && len(after_rejection.point_markers) == 640 &&
		after_rejection.point_markers[639] == accepted_last_marker,
		"over-budget or invalid replacements should preserve the last accepted marker payload and revision")

	testing.expect(t, gpu_surface_clear(&rt, surface), "clearing a marker payload should succeed")
	cleared, cleared_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, cleared_ok && len(cleared.point_markers) == 0 && len(cleared.segments) == 0,
		"clearing the geometry payload should release retained point markers")
}

@(test)
test_gpu_surface_rectangle_updates_do_not_grow_persistent_allocations :: proc(t: ^testing.T) {
	allocations := Runtime_Allocation_Stats{}
	rt := new_runtime(Rect{0, 0, 640, 120}, config=Runtime_Config{allocation_stats=&allocations})
	defer destroy_runtime(&rt)

	invalidate_root(&rt, "rectangle allocation test")
	ui, should_build := begin_frame(&rt)
	if !should_build {
		testing.expect(t, false, "initial rectangle surface tree should build")
		return
	}
	container_begin(&ui, .Root, key=key_string("rectangle-allocation-root"), style=layout_style(.Column, width=640, height=120))
	surface := gpu_geometry_surface(&ui, "rectangle-allocation-surface", layout_style(width=640, height=120), 1)
	container_end(&ui)
	end_frame(&ui)

	rectangles := make([]GPU_Surface_Filled_Rectangle, 512)
	defer delete(rectangles)
	for index in 0..<len(rectangles) {
		rectangles[index] = GPU_Surface_Filled_Rectangle{
			bounds={f32(index%640), f32(index%80), 4, 12},
			color={0.2, 0.4, 0.6, 1},
		}
	}
	testing.expect(t, gpu_surface_update_geometry_with_rectangles(&rt, surface, rectangles, nil, nil),
		"the initial rectangle payload should be accepted")
	calls_after_first := allocations.persistent_alloc_calls
	for _ in 0..<8 {
		testing.expect(t, gpu_surface_update_geometry_with_rectangles(&rt, surface, rectangles, nil, nil),
			"repeat rectangle payloads should stay accepted")
	}
	testing.expect(t, allocations.persistent_alloc_calls == calls_after_first,
		"rect-only payload updates must reuse the retained rectangle capacity without allocating")
	testing.expect(t, len(rt.nodes[surface].surface_rectangles) == len(rectangles),
		"the retained rectangle payload should keep its full count")
}

@(test)
test_gpu_surface_stroke_path_is_owned_and_released_with_its_surface :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 160, 100})
	defer destroy_runtime(&rt)
	id := gpu_surface_retype_test_describe(&rt, .Custom_Surface)
	if id == 0 { testing.expect(t, false, "initial custom surface should be retained"); return }

	points := [3]GPU_Surface_Point{{10, 12}, {40, 18}, {80, 14}}
	path := GPU_Surface_Stroke_Path{points=points[:], thickness=2, color={0.2, 0.8, 0.9, 1}}
	testing.expect(t, gpu_surface_update_geometry_with_rectangles_and_stroke_path(
		&rt, id, nil, nil, nil, path,
	), "valid connected stroke paths should be accepted")
	node := rt.nodes[id]
	handle := paint_geometry_handle_for_node(node)
	payload, payload_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, payload_ok && len(payload.stroke_path.points) == 3 &&
		payload.stroke_path.points[0] == GPU_Surface_Point{10, 12} &&
		payload.stroke_path.thickness == 2 && payload.stroke_path.color == path.color,
		"the borrowed payload should expose a complete retained stroke path")
	if !payload_ok || len(payload.stroke_path.points) != 3 { return }
	points[0].x = -1
	testing.expect(t, payload.stroke_path.points[0].x == 10,
		"the retained payload must own its points independently of the caller's slice")

	invalid := GPU_Surface_Stroke_Path{points=points[:], thickness=0, color=path.color}
	accepted_revision := payload.revision
	testing.expect(t, !gpu_surface_update_geometry_with_rectangles_and_stroke_path(
		&rt, id, nil, nil, nil, invalid,
	), "invalid stroke replacements should be rejected")
	retained, retained_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, retained_ok && retained.revision == accepted_revision &&
		len(retained.stroke_path.points) == 3 && retained.stroke_path.points[0].x == 10,
		"rejected replacements must preserve the accepted stroke and payload revision")

	testing.expect(t, gpu_surface_clear(&rt, id), "clearing a stroke path should succeed")
	cleared, cleared_ok := gpu_surface_payload_resolve(&rt, handle)
	testing.expect(t, cleared_ok && len(cleared.stroke_path.points) == 0,
		"clearing a surface should release its retained stroke path")

	testing.expect(t, gpu_surface_update_geometry_with_rectangles_and_stroke_path(
		&rt, id, nil, nil, nil, path,
	), "a cleared surface should accept a new stroke path")
	text_id := gpu_surface_retype_test_describe(&rt, .Text)
	_, retained_after_retype := rt.gpu_surface_stroke_paths[id]
	testing.expect(t, text_id == id && !retained_after_retype,
		"retyping away from a custom surface should release its stroke sidecar")
}

@(test)
test_retyping_away_from_custom_surface_discards_image_layers :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 100, 80})
	defer destroy_runtime(&rt)
	encoded := image_asset_test_qoi()
	handle, err := image_load_bytes(&rt, encoded[:])
	if err != .None { testing.expect(t, false, "QOI image fixture should load"); return }
	id := gpu_surface_retype_test_describe(&rt, .Custom_Surface)
	if id == 0 { testing.expect(t, false, "initial custom surface should be retained"); return }
	marker := [1]GPU_Surface_Point_Marker{{center={10, 10}, diameter=3, color={1, 1, 1, 1}}}
	testing.expect(t, gpu_surface_update_geometry_with_markers(&rt, id, nil, nil, marker[:]),
		"custom surfaces should retain compact marker payloads")
	layer := GPU_Surface_Image{image=handle, bounds=Rect{0,0,10,10}}
	testing.expect(t, gpu_surface_update_images(&rt, id, []GPU_Surface_Image{layer}),
		"a valid image layer should be retained by the custom surface")

	id_after_text := gpu_surface_retype_test_describe(&rt, .Text)
	_, retained_while_text := rt.gpu_surface_images[id]
	_, retained_markers_while_text := rt.gpu_surface_point_markers[id]
	testing.expect(t, id_after_text == id && !retained_while_text && !retained_markers_while_text,
		"changing the same retained identity away from Custom_Surface should release its image and marker payloads")

	id_after_surface := gpu_surface_retype_test_describe(&rt, .Custom_Surface)
	presentation, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&presentation) }
	image_commands := 0
	for command in rt.display {
		if command.owner == id {
			if paint, ok := command.payload.(Image_Paint); ok && paint.image == handle { image_commands += 1 }
		}
	}
	_, retained_after_return := rt.gpu_surface_images[id]
	_, retained_markers_after_return := rt.gpu_surface_point_markers[id]
	testing.expect(t, id_after_surface == id && !retained_after_return && !retained_markers_after_return && image_commands == 0,
		"returning to Custom_Surface should not resurrect image layers or markers from the prior surface kind")
}
