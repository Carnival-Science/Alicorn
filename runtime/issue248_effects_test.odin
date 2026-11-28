#+build !js
package alicorn

import "core:testing"

ISSUE248_EFFECT_TEST_ROOT :: Source_Site{"runtime/issue248_effects_test.odin", 10, 1, "issue248_effect_root"}
ISSUE248_EFFECT_TEST_SURFACE :: Source_Site{"runtime/issue248_effects_test.odin", 20, 1, "issue248_effect_surface"}
ISSUE248_EFFECT_TEST_TEXT :: Source_Site{"runtime/issue248_effects_test.odin", 30, 1, "issue248_effect_text"}

issue248_effect_test_stack :: proc(color_variant: bool = false, inset: f32 = 1) -> Issue248_Surface_Effect_Stack {
	highlight := Color{1, 1, 1, 0.055}
	if color_variant { highlight = Color{0.92, 0.57, 0.24, 0.14} }
	return Issue248_Surface_Effect_Stack{count=2, layers=[4]Issue248_Surface_Effect_Layer{
		{kind=.Inset_Fill, inset=inset, color=highlight},
		{kind=.Stroke, inset=inset, stroke_fill=Color{0.001, 0, 0, 0},
			stroke=Paint_Stroke{color=Color{0.72, 0.49, 0.24, 0.58}, width=1}, stroke_placement=.Inside},
		{}, {},
	}}
}

issue248_effect_test_describe :: proc(
	rt: ^Runtime,
	width: f32 = 280,
	stack: Issue248_Surface_Effect_Stack = {},
	attach_effects: bool = false,
	include_surface: bool = true,
) -> Node_ID {
	invalidate_root(rt, "issue 248 retained effects test")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin_ex(&ui, .Root, ISSUE248_EFFECT_TEST_ROOT, key="issue248-effect-root", explicit_key=true,
		style=layout_style(.Column, width=640, height=480))
	owner := Node_ID(0)
	if include_surface {
		owner = surface_begin(&ui, surface_core_color_role(.Surface), key=key_u64(1),
			style=layout_style(.Column, width=width, height=52, clip=true),
			shape=surface_shape_rounded_corners(Surface_Corner_Radii{top_left=7, top_right=11, bottom_right=5, bottom_left=3}),
			fill=Color{0.105, 0.135, 0.185, 1},
			stroke=Paint_Stroke{color=Color{0.24, 0.29, 0.37, 1}, width=1},
			stroke_placement=.Inside,
			label="issue 248 effect owner")
		if attach_effects && !issue248_surface_effect_stack_set(rt, owner, stack) {
			rt.diagnostic = "issue 248 effect stack declaration failed"
		}
		_ = text(&ui, "Retained surface", key=key_string("issue248-effect-caption"),
			style=layout_style(.Row, height=20), color=Color{0.82, 0.85, 0.9, 1})
		surface_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)
	return owner
}

issue248_effect_test_owned_commands :: proc(rt: ^Runtime, owner: Node_ID) -> int {
	count := 0
	for command in rt.display_target {
		if issue248_surface_effect_command_belongs_to(rt, command.owner, owner) { count += 1 }
	}
	return count
}

@(test)
test_issue248_retained_effects_are_sparse_and_stay_in_owner_paint :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 480})
	defer destroy_runtime(&rt)

	owner := issue248_effect_test_describe(&rt, stack=issue248_effect_test_stack(), attach_effects=true)
	owner_node, owner_found := rt.nodes[owner]
	text_node: ^Node
	for _, node in rt.nodes {
		if node != nil && node.kind == .Text { text_node = node; break }
	}
	state := issue248_surface_effect_state(&rt)
	testing.expect(t, owner_found && owner_node != nil && text_node != nil &&
		len(rt.nodes) == 3 && state != nil && len(state.command_owners) == 2,
		"effect layers must be sparse paint products, not additional retained layout nodes")
	testing.expect(t, issue248_effect_test_owned_commands(&rt, owner) == 3,
		"the base and two effect layers should occupy one logical owner's retained display range")
	if owner_found && owner_node != nil && state != nil {
		effect_command_owner := Node_ID(0)
		for command in owner_node.paint {
			if command.owner != owner { effect_command_owner = command.owner; break }
		}
		testing.expect(t, effect_command_owner != 0 &&
			presentation_output_node_in_root(&rt, effect_command_owner, owner_node.parent),
			"effect commands should route with their logical owner to an independently presented root")
		testing.expect(t, effect_command_owner != 0 &&
			drag_preview_owner_is_descendant(&rt, effect_command_owner, owner_node.parent),
			"effect commands should follow their owner when its subtree is captured for drag preview")
	}
	if state != nil && owner_found && owner_node != nil && len(owner_node.paint) >= 3 {
		first_shape_ok := false
		second_shape_ok := false
		for command in owner_node.paint {
			if command.owner == owner { continue }
			surface, surface_ok := command.payload.(Surface_Paint)
			if !surface_ok { continue }
			shape, shape_ok := surface_paint_shape_resolve(&rt, command.owner, surface.shape)
			if !shape_ok { continue }
			metadata := state.command_owners[command.owner]
			if metadata.layer_index == 0 {
				first_shape_ok = shape.kind == .Rounded_Rectangle_Per_Corner &&
					shape.corner_radii == Surface_Corner_Radii{6, 10, 4, 2}
			} else if metadata.layer_index == 1 {
				second_shape_ok = shape.kind == .Rounded_Rectangle_Per_Corner &&
					shape.corner_radii == Surface_Corner_Radii{6, 10, 4, 2}
			}
		}
		testing.expect(t, first_shape_ok && second_shape_ok,
			"per-corner shape data must resolve for each inset layer without growing Paint_Command")
	}
	if !owner_found || owner_node == nil || text_node == nil { return }

	before_frame := rt.stats
	before_effects := issue248_surface_effect_stats(&rt)
	testing.expect(t, before_effects.pending_descriptions_examined == 1,
		"declaring an effect immediately after a new owner should examine only the newest pending description")
	stack := issue248_effect_test_stack(color_variant=true)
	set_ok := issue248_surface_effect_stack_set(&rt, owner, stack)
	update_paint(&rt)
	after_effects := issue248_surface_effect_stats(&rt)
	testing.expect(t, set_ok && after_effects.geometry_cache_hits == before_effects.geometry_cache_hits+1 &&
		after_effects.geometry_lowerings == before_effects.geometry_lowerings,
		"changing only a layer color should reuse the owner's relative geometry")
	testing.expect(t, rt.stats.measure_nodes_examined == before_frame.measure_nodes_examined &&
		rt.stats.layout_nodes_visited == before_frame.layout_nodes_visited &&
		rt.stats.text_shape_requests == before_frame.text_shape_requests &&
		rt.stats.paint_nodes_visited == before_frame.paint_nodes_visited+1,
		"a layer color update should repaint one owner without layout, measurement, or text shaping")
	retained_text_node, retained_text_found := rt.nodes[text_node.id]
	testing.expect(t, retained_text_found && retained_text_node == text_node && retained_text_node.text == "Retained surface",
		"effect repaint should preserve the retained text child identity and value")
	testing.expect(t, issue248_effect_test_owned_commands(&rt, owner) == 3,
		"effect repaint should preserve the ordered paint range")

	before_frame = rt.stats
	before_effects = after_effects
	stack = issue248_effect_test_stack(color_variant=true, inset=2)
	set_ok = issue248_surface_effect_stack_set(&rt, owner, stack)
	update_paint(&rt)
	after_effects = issue248_surface_effect_stats(&rt)
	testing.expect(t, set_ok && after_effects.geometry_lowerings == before_effects.geometry_lowerings+1 &&
		after_effects.geometry_cache_hits == before_effects.geometry_cache_hits,
		"changing layer insets should lower only the affected owner's relative geometry")
	testing.expect(t, rt.stats.measure_nodes_examined == before_frame.measure_nodes_examined &&
		rt.stats.layout_nodes_visited == before_frame.layout_nodes_visited &&
		rt.stats.text_shape_requests == before_frame.text_shape_requests,
		"an effect inset change should not measure, lay out, or reshape text")
	testing.expect(t, rt.stats.paint_nodes_visited == before_frame.paint_nodes_visited+1,
		"an effect inset change should repaint only its surface owner")
	testing.expect(t, rt.stats.display_commands_finalized-before_frame.display_commands_finalized == 3,
		"an effect inset change should finalize only the owner's base and effect layers")

	before_effects = after_effects
	owner = issue248_effect_test_describe(&rt, width=304, stack=stack, attach_effects=true)
	after_effects = issue248_surface_effect_stats(&rt)
	testing.expect(t, after_effects.geometry_lowerings == before_effects.geometry_lowerings+1,
		"resizing the owner should lower relative effect geometry once")
	testing.expect(t, issue248_effect_test_owned_commands(&rt, owner) == 3,
		"resizing must preserve the base and effect command order")

	one_layer := stack
	one_layer.count = 1
	commands_before_remove_one := len(rt.display_target)
	removed_one := issue248_surface_effect_stack_set(&rt, owner, one_layer)
	update_paint(&rt)
	testing.expect(t, removed_one && issue248_effect_test_owned_commands(&rt, owner) == 2 &&
		len(issue248_surface_effect_state(&rt).command_owners) == 1 &&
		len(rt.display_target) == commands_before_remove_one-1,
		"removing one layer should splice only that layer's retained command")

	commands_before_remove_all := len(rt.display_target)
	removed := issue248_surface_effect_stack_set(&rt, owner, {})
	update_paint(&rt)
	state = issue248_surface_effect_state(&rt)
	_, effect_entry_remains := state.entries[owner]
	testing.expect(t, removed && issue248_effect_test_owned_commands(&rt, owner) == 1 && !effect_entry_remains &&
		len(rt.display_target) == commands_before_remove_all-1,
		"removing effects should splice only their commands from the retained owner range")
}

@(test)
test_issue248_initial_owner_lookup_scales_with_immediate_declarations :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 1280, 900})
	defer destroy_runtime(&rt)
	OWNER_COUNT :: 128

	ui, build := begin_frame(&rt)
	if !build {
		testing.expect(t, false, "initial effect-owner fixture should begin its frame")
		return
	}
	container_begin(&ui, .Root, key=key_string("issue248-many-owner-root"),
		style=layout_style(.Column, width=-1, height=-1))
	stack := issue248_effect_test_stack()
	all_declarations_succeeded := true
	for index in 0..<OWNER_COUNT {
		owner := surface_begin(&ui, surface_core_color_role(.Surface),
			key=key_u64(u64(index+1)),
			style=layout_style(.Column, width=240, height=40),
			fill=Color{0.1, 0.1, 0.1, 1})
		if owner == 0 || !issue248_surface_effect_stack_set(&rt, owner, stack) {
			all_declarations_succeeded = false
		}
		surface_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)

	state := issue248_surface_effect_state(&rt)
	testing.expect(t, all_declarations_succeeded && state != nil && len(state.entries) == OWNER_COUNT,
		"every immediately declared owner should retain its sparse effect descriptor")
	if state != nil {
		testing.expect(t, state.stats.pending_descriptions_examined == OWNER_COUNT,
			"initial construction should examine one pending description per owner, not rescan earlier descriptions")
	}
}

@(test)
test_issue248_new_owner_must_declare_effects_before_children :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 480})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !build {
		testing.expect(t, false, "late declaration fixture should begin its frame")
		return
	}
	container_begin(&ui, .Root, key=key_string("issue248-late-owner-root"),
		style=layout_style(.Column, width=-1, height=-1))
	owner := surface_begin(&ui, surface_core_color_role(.Surface), key=key_u64(1),
		style=layout_style(.Column, width=240, height=48), fill=Color{0.1, 0.1, 0.1, 1})
	child := surface_begin(&ui, surface_core_color_role(.Surface), key=key_u64(2),
		style=layout_style(.Column, width=120, height=24), fill=Color{0.2, 0.2, 0.2, 1})
	accepted := issue248_surface_effect_stack_set(&rt, owner, issue248_effect_test_stack())
	testing.expect(t, owner != 0 && child != 0 && !accepted && rt.issue248_surface_effects == nil,
		"a newly described owner must declare its effects before describing children, without allocating sidecar state on rejection")
	surface_end(&ui)
	surface_end(&ui)
	container_end(&ui)
	end_frame(&ui)
}

@(test)
test_issue248_flat_surface_allocates_no_effect_sidecar :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 480})
	defer destroy_runtime(&rt)
	_ = issue248_effect_test_describe(&rt)
	testing.expect(t, rt.issue248_surface_effects == nil,
		"ordinary flat surfaces should not allocate the optional effect sidecar")
}

@(test)
test_issue248_retiring_effect_owner_releases_sparse_descriptors :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 480})
	defer destroy_runtime(&rt)
	owner := issue248_effect_test_describe(&rt, stack=issue248_effect_test_stack(), attach_effects=true)
	state := issue248_surface_effect_state(&rt)
	if owner == 0 || state == nil || len(state.command_owners) != 2 {
		testing.expect(t, false, "effect fixture should retain both sparse layer descriptors")
		return
	}
	_ = issue248_effect_test_describe(&rt, include_surface=false)
	testing.expect(t, len(state.entries) == 0 && len(state.command_owners) == 0,
		"retiring the owner should release effect descriptors and synthetic paint-owner metadata")
}
