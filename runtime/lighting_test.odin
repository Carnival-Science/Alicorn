#+build !js
package alicorn

import "core:testing"

LIGHTING_TEST_GROUP :: Material_Group_ID(7)

lighting_test_light :: proc(position := [2]f32{40, 30}) -> Lighting_Light {
	return Lighting_Light{position=position, height=2, color={1, 1, 1, 1}, intensity=1, radius=4}
}

@(test)
test_lighting_boundary_requires_declaration_and_nonflat_group_surfaces :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 200, 120})
	defer destroy_runtime(&rt)
	lights := [1]Lighting_Light{lighting_test_light()}

	// No declaration: a non-flat group surface stays ordinary paint.
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-root"), style=layout_style(width=200, height=120))
	surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-card"),
		style=layout_style(width=100, height=60), physical_height=1, material_group=LIGHTING_TEST_GROUP,
		fill=Color{0.3, 0.4, 0.5, 1})
	surface_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, !rt.lighting_marker_present && rt.lighting_emits == 0 &&
		!paint_command_stream_has_lighting(&rt),
		"a scene without a declaration must not allocate, emit, or publish a lighting boundary")

	// Declaration with a qualifying surface emits exactly one ordered marker.
	invalidate_root(&rt, "lighting declaration")
	ui, build = begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting declaration fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-root"), style=layout_style(width=200, height=120))
	card := surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-card"),
		style=layout_style(width=100, height=60, padding=4), physical_height=1,
		material_group=LIGHTING_TEST_GROUP, fill=Color{0.3, 0.4, 0.5, 1})
	child := container_begin(&ui, .Container, key=key_string("lighting-child-fill"),
		style=layout_style(width=88, height=20), color=Color{0.5, 0.6, 0.7, 1})
	container_end(&ui)
	surface_end(&ui)
	container_end(&ui)
	if !lighting_group(&ui, LIGHTING_TEST_GROUP, lights[:], ambient=0.4) {
		testing.expect(t, false, "a bounded declaration should be accepted inside an open frame")
	}
	end_frame(&ui)

	testing.expect(t, rt.lighting_emits == 1 && rt.lighting_marker_present,
		"one declaration over one non-flat group surface should emit exactly one boundary")
	marker_index := rt.lighting_marker_index
	testing.expect(t, marker_index > 0 && marker_index < len(rt.display) && marker_index < len(rt.display_target) &&
		len(rt.display) == len(rt.display_target),
		"the marker must be inserted into both aligned display lists")
	if marker_index > 0 && marker_index < len(rt.display) {
		marker := rt.display[marker_index]
		payload, ok := marker.payload.(Lighting_Group_Paint)
		testing.expect(t, ok && payload.group == LIGHTING_TEST_GROUP && payload.generation != 0 &&
			marker.owner == LIGHTING_MARKER_OWNER,
			"the boundary should carry the declared group, a parameter generation, and the reserved owner")
		// The card's own surface and its child's text both precede the marker.
		card_node := rt.nodes[card]
		child_node := rt.nodes[child]
		testing.expect(t, card_node != nil && child_node != nil &&
			card_node.display_index >= 0 && child_node.display_index >= 0 &&
			child_node.display_index < marker_index,
			"the boundary should sit after the group surface and its descendants so text is captured")
		expected := Rect{}
		for command in rt.display[:marker_index] {
			subsurface, is_surface := command.payload.(Surface_Paint)
			if !is_surface || subsurface.material_group != LIGHTING_TEST_GROUP { continue }
			rect := Rect{command.bounds.x+command.translation[0], command.bounds.y+command.translation[1],
				command.bounds.w, command.bounds.h}
			expected = rect if expected.w == 0 && expected.h == 0 else lighting_test_union(expected, rect)
		}
		testing.expect(t, expected.w > 0 && marker.bounds.x <= expected.x &&
			marker.bounds.y <= expected.y &&
			marker.bounds.x+marker.bounds.w >= expected.x+expected.w &&
			marker.bounds.y+marker.bounds.h >= expected.y+expected.h,
			"the boundary region should enclose the shaded surface union, including the shadow margin")
		params, params_ok := lighting_paint_params(&rt, marker)
		testing.expect(t, params_ok && params.group == LIGHTING_TEST_GROUP && params.light_count == 1 &&
			params.ambient == 0.4 && .Shadows in params.flags,
			"a host should resolve the declared light set from the marker generation")
	}

	// Undeclared next frame: the boundary is removed, not left stale.
	invalidate_root(&rt, "lighting withdrawn")
	ui, build = begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting withdrawal fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-root"), style=layout_style(width=200, height=120))
	surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-card"),
		style=layout_style(width=100, height=60), physical_height=1, material_group=LIGHTING_TEST_GROUP,
		fill=Color{0.3, 0.4, 0.5, 1})
	surface_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, !rt.lighting_marker_present && !paint_command_stream_has_lighting(&rt),
		"withdrawing the declaration must remove the retained boundary")
}

lighting_test_union :: proc(a, b: Rect) -> Rect {
	left := min(a.x, b.x)
	top := min(a.y, b.y)
	right := max(a.x+a.w, b.x+b.w)
	bottom := max(a.y+a.h, b.y+b.h)
	return Rect{left, top, right-left, bottom-top}
}

// paint_command_stream_has_lighting is a test-only scan over the published
// display list.
paint_command_stream_has_lighting :: proc(rt: ^Runtime) -> bool {
	for command in rt.display {
		if paint_command_is_lighting_group(command) { return true }
	}
	return false
}

@(test)
test_lighting_declaration_validation_and_accessibility_variants :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting validation fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-validation-root"), style=layout_style(width=120, height=80))
	lights := [1]Lighting_Light{lighting_test_light()}
	testing.expect(t, !lighting_group(&ui, MATERIAL_GROUP_NONE, lights[:]),
		"a zero material group must be rejected")
	bad := lights
	bad[0].height = -1
	testing.expect(t, !lighting_group(&ui, LIGHTING_TEST_GROUP, bad[:]),
		"a light below the paint plane must be rejected")
	bad = lights
	bad[0].intensity = 100
	testing.expect(t, !lighting_group(&ui, LIGHTING_TEST_GROUP, bad[:]),
		"an out-of-range light intensity must be rejected")
	testing.expect(t, lighting_group(&ui, LIGHTING_TEST_GROUP, lights[:], ambient=0.5),
		"a bounded declaration should be accepted")
	container_end(&ui)
	end_frame(&ui)

	flags := lighting_presentation_flags(Accessibility_Appearance_Preferences{})
	testing.expect(t, .Shadows in flags, "default presentation keeps shadow cues")
	flags = lighting_presentation_flags(Accessibility_Appearance_Preferences{reduce_motion=true})
	testing.expect(t, !(.Shadows in flags), "reduced motion disables moving shadow cues")
	flags = lighting_presentation_flags(Accessibility_Appearance_Preferences{increased_contrast=true})
	testing.expect(t, .Hard_Shadows in flags && .High_Contrast in flags,
		"increased contrast hardens penumbra and strengthens bevels")
	flags = lighting_presentation_flags(Accessibility_Appearance_Preferences{reduce_transparency=true})
	testing.expect(t, .Hard_Shadows in flags && !(.High_Contrast in flags),
		"reduced transparency removes translucent penumbra only")

	base := Lighting_Group{group=LIGHTING_TEST_GROUP, light_count=1, ambient=0.4, shadows=true}
	base.lights[0] = lighting_test_light()
	moved := base
	moved.lights[0].position[0] += 1
	no_shadows := base
	no_shadows.shadows = false
	plain := lighting_declaration_hash(base, flags)
	testing.expect(t, lighting_declaration_hash(moved, flags) != plain &&
		lighting_declaration_hash(no_shadows, flags) != plain,
		"moving a light or disabling shadows must change the generation")
	testing.expect(t, lighting_declaration_hash(base, flags) == plain,
		"repeating identical inputs must reproduce the generation")
}

@(test)
test_lighting_yields_to_backdrop_and_requires_nonflat_surface :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 200, 120})
	defer destroy_runtime(&rt)
	lights := [1]Lighting_Light{lighting_test_light()}

	// A flat surface carrying the group is not a shading target.
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting flat fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-flat-root"), style=layout_style(width=200, height=120))
	surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-flat-card"),
		style=layout_style(width=100, height=60), material_group=LIGHTING_TEST_GROUP,
		fill=Color{0.3, 0.4, 0.5, 1})
	surface_end(&ui)
	container_end(&ui)
	if !lighting_group(&ui, LIGHTING_TEST_GROUP, lights[:]) { testing.expect(t, false, "declaration should be accepted") }
	end_frame(&ui)
	testing.expect(t, !rt.lighting_marker_present,
		"a group without a non-flat surface must emit no boundary and no compositor work")

	// A backdrop boundary already owns this frame's prefix capture.
	invalidate_root(&rt, "lighting and backdrop")
	ui, build = begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting backdrop fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-flat-root"), style=layout_style(width=200, height=120))
	surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-backdrop-panel"),
		style=layout_style(width=100, height=60), fill=Color{0.2, 0.3, 0.4, 0.8}, backdrop_effect=backdrop_blur(4))
	surface_end(&ui)
	surface_begin(&ui, surface_core_color_role(.Surface), key=key_string("lighting-card"),
		style=layout_style(width=80, height=40), physical_height=1, material_group=LIGHTING_TEST_GROUP,
		fill=Color{0.3, 0.4, 0.5, 1})
	surface_end(&ui)
	container_end(&ui)
	if !lighting_group(&ui, LIGHTING_TEST_GROUP, lights[:]) { testing.expect(t, false, "declaration should be accepted") }
	end_frame(&ui)
	testing.expect(t, !rt.lighting_marker_present && !paint_command_stream_has_lighting(&rt),
		"the one-boundary rule must keep an existing backdrop boundary and skip lighting")
}

@(test)
test_lighting_generation_rejects_a_stale_marker :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 80, 60})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "lighting stale fixture should build"); return }
	container_begin(&ui, .Root, key=key_string("lighting-stale-root"), style=layout_style(width=80, height=60))
	container_end(&ui)
	end_frame(&ui)
	marker := paint_lighting_group_command(LIGHTING_MARKER_OWNER, Rect{0, 0, 10, 10}, Rect{0, 0, 10, 10},
		LIGHTING_TEST_GROUP, 1)
	_, ok := lighting_paint_params(&rt, marker)
	testing.expect(t, !ok,
		"a marker without a live declaration must not resolve light parameters")
	declaration := Lighting_Group{group=LIGHTING_TEST_GROUP, light_count=1, ambient=0.4, shadows=true}
	declaration.lights[0] = lighting_test_light()
	rt.lighting_declared = true
	rt.lighting_declaration = declaration
	flags := lighting_resolved_flags(declaration, rt.root_accessibility_appearance)
	marker.payload = Lighting_Group_Paint{LIGHTING_TEST_GROUP, lighting_declaration_hash(declaration, flags) + 1}
	_, ok = lighting_paint_params(&rt, marker)
	testing.expect(t, !ok, "a generation from another frame's declaration must be rejected")
	marker.payload = Lighting_Group_Paint{LIGHTING_TEST_GROUP, lighting_declaration_hash(declaration, flags)}
	params, resolved := lighting_paint_params(&rt, marker)
	testing.expect(t, resolved && params.light_count == 1,
		"the matching declaration generation must resolve")
}
