#+build !js
package alicorn

import "core:testing"

@(test)
test_builtin_icon_masks_cover_all_ids_and_physical_sizes :: proc(t: ^testing.T) {
    testing.expect(t, icon_atlas_validate(), "embedded icon masks and manifest must be valid")
    for raw_id in int(Icon_ID.Check)..<int(Icon_ID.Count) {
        for size in ICON_ATLAS_MIN_SIZE..=ICON_ATLAS_MAX_SIZE {
            entry, valid := icon_atlas_lookup(Icon_ID(raw_id), size)
            testing.expect(t, valid && entry.size == size, "every built-in icon has a distinct rasterization at every supported physical size")
            page := ICON_ATLAS_PAGES[entry.page]
            coverage, partial := false, false
            for y in entry.y..<entry.y+entry.size {
                for x in entry.x..<entry.x+entry.size {
                    pixel := page.pixels[y*page.width+x]
                    if pixel > 0 { coverage = true }
                    if pixel > 0 && pixel < 255 { partial = true }
                }
            }
            testing.expect(t, coverage && partial, "each mask must contain artwork and antialiased edge coverage")
            gutters_clear := true
            for y in entry.y-ICON_ATLAS_GUTTER..<entry.y+entry.size+ICON_ATLAS_GUTTER {
                for x in entry.x-ICON_ATLAS_GUTTER..<entry.x+entry.size+ICON_ATLAS_GUTTER {
                    if x >= entry.x && x < entry.x+entry.size && y >= entry.y && y < entry.y+entry.size { continue }
                    if page.pixels[y*page.width+x] != 0 { gutters_clear = false }
                }
            }
            testing.expect(t, gutters_clear, "transparent gutters must isolate icons during atlas filtering")
        }
    }
    _, invalid := icon_atlas_lookup(.None, 16)
    small, _ := icon_atlas_lookup(.Search, 4)
    large, _ := icon_atlas_lookup(.Search, 128)
    testing.expect(t, !invalid && small.size == 8 && large.size == 64, "invalid IDs must be rejected and unsupported sizes must choose the nearest endpoint")
}

@(test)
test_icon_widget_retains_theme_tinted_paint_without_text :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 160, 80})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "icon fixture should begin a frame"); return }
	container_begin_simple(&ui, .Root, label="icon-test-root", key=key_string("root"), style=layout_style(.Row, width=120, height=40))
	expected_color := style_color(&ui, .Accent)
	id := icon(&ui, .Folder_Open, key=key_string("folder"), size=20, color_role=.Accent)
	close_id, _ := icon_button(&ui, "Dismiss example", .Close, key=key_string("dismiss"))
	container_end(&ui)
	end_frame(&ui)
	node, found := rt.nodes[id]
	if !found { testing.expect(t, false, "the icon should be retained in the layout tree"); return }
	icon_seen := false
	for command in node.paint {
		if retained, ok := command.payload.(Icon_Paint); ok && retained.id == .Folder_Open &&
			retained.color == expected_color {
			icon_seen = true
		}
	}
	testing.expect(t, icon_seen && node.text == "" && node.label == "",
		"the icon should retain its theme tint and mask identity without depending on a text glyph")
	close_node, close_found := rt.nodes[close_id]
	close_icon_seen, close_text_seen := false, false
	for command in close_node.paint {
		if painted, ok := command.payload.(Icon_Paint); ok && painted.id == .Close { close_icon_seen = true }
		if paint_command_is_text(command) { close_text_seen = true }
	}
	close_semantic, close_semantic_found := semantic_node_lookup(&rt, semantic_visual_id(close_id))
	testing.expect(t, close_found && close_icon_seen && !close_text_seen && close_semantic_found &&
		close_semantic.role == .Button && close_semantic.label == "Dismiss example",
		"an icon-only control should retain its mask visual while exposing a proper accessible button name")
}

icons_test_describe_accent :: proc(rt: ^Runtime, tint: Color) -> Node_ID {
	invalidate_root(rt, "icon tint changed")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin_simple(&ui, .Root, key=key_string("tint-root"), style=layout_style(.Row, width=100, height=40))
	scope := style_environment_push(&ui, Style_Environment{accent=style_accent(tint)})
	id := icon(&ui, .Search, key=key_string("search"), size=20, color_role=.Accent)
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
	return id
}

@(test)
test_icon_tint_change_preserves_measurement_layout_and_mask_identity :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0,0,100,40})
	defer destroy_runtime(&rt)
	id := icons_test_describe_accent(&rt, Color{0.2,0.4,0.8,1})
	if id == 0 { testing.expect(t, false, "icon should be retained"); return }
	bounds := rt.nodes[id].bounds
	old_color := rt.nodes[id].color
	measures, layouts := rt.stats.measure_requests, rt.stats.layout_nodes_visited
	next := icons_test_describe_accent(&rt, Color{0.8,0.4,0.2,1})
	testing.expect(t, next == id && rt.nodes[id].bounds == bounds && rt.nodes[id].icon_id == .Search && rt.nodes[id].color != old_color,
		"theme tint should update retained paint without changing the icon or its geometry")
	testing.expect(t, rt.stats.measure_requests == measures && rt.stats.layout_nodes_visited == layouts,
		"an icon tint change should perform no measurement or layout work")
}

icons_test_icon_button_selected :: proc(rt: ^Runtime, selected: bool) -> (id: Node_ID, clicked: bool) {
	invalidate_root(rt, "icon button selected fixture")
	ui, build := begin_frame(rt)
	if !build { return 0, false }
	container_begin_simple(&ui, .Root, key=key_string("icon-selected-root"), style=layout_style(.Row, width=80, height=48))
	id, clicked = icon_button(&ui, "Selection tool", .Settings, key=key_string("icon-selected"), variant=.Quiet, selected=selected)
	container_end(&ui)
	end_frame(&ui)
	return
}

icons_test_surface_fill :: proc(node: ^Node) -> (fill: Color, found: bool) {
	for command in node.paint {
		if surface, ok := command.payload.(Surface_Paint); ok {
			return surface.fill, true
		}
	}
	return {}, false
}

@(test)
test_icon_button_selected_state_keeps_identity_recipe_and_semantics :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 60})
	defer destroy_runtime(&rt)
	id, _ := icons_test_icon_button_selected(&rt, false)
	if id == 0 { testing.expect(t, false, "icon button fixture should describe its first frame"); return }
	unselected := rt.nodes[id]
	unselected_fill, unselected_fill_found := icons_test_surface_fill(unselected)
	unselected_fill_visible := unselected_fill_found && unselected_fill.a > 0
	unselected_semantic, unselected_semantic_found := semantic_node_lookup(&rt, semantic_visual_id(id))
	testing.expect(t, !unselected.selected && unselected_semantic_found && !semantic_states_has(unselected_semantic.states, .Selected),
		"the default icon button should stay unselected in retained and semantic state")

	selected_id, clicked := icons_test_icon_button_selected(&rt, true)
	selected := rt.nodes[selected_id]
	selected_fill, selected_fill_found := icons_test_surface_fill(selected)
	selected_fill_visible := selected_fill_found && selected_fill.a > 0
	selected_semantic, selected_semantic_found := semantic_node_lookup(&rt, semantic_visual_id(selected_id))
	testing.expect(t, selected_id == id && !clicked, "changing controlled selected state must not replace the icon button identity or report a press")
	testing.expect(t, selected.selected && selected.icon_id == .Settings && selected.label == "",
		"selected state should update the retained button while keeping the decorative icon and empty text label")
	testing.expect(t, !unselected_fill_visible && selected_fill_visible,
		"selected appearance should resolve through the existing Quiet button recipe and paint the selected surface")
	testing.expect(t, selected_semantic_found && selected_semantic.role == .Button && selected_semantic.label == "Selection tool" &&
		semantic_states_has(selected_semantic.states, .Selected) && semantic_actions_has(selected_semantic.actions, .Press),
		"selected icon buttons should publish the same accessible name, Selected state, and Press action as regular buttons")

	restored_id, _ := icons_test_icon_button_selected(&rt, false)
	restored := rt.nodes[restored_id]
	restored_fill, restored_fill_found := icons_test_surface_fill(restored)
	restored_fill_visible := restored_fill_found && restored_fill.a > 0
	restored_semantic, restored_semantic_found := semantic_node_lookup(&rt, semantic_visual_id(restored_id))
	testing.expect(t, restored_id == id && !restored.selected,
		"clearing selected should update the same retained icon button identity")
	testing.expect(t, restored_fill_visible == unselected_fill_visible,
		"clearing selected should restore the original recipe paint")
	testing.expect(t, restored_semantic_found && !semantic_states_has(restored_semantic.states, .Selected),
		"clearing selected should restore the original semantic state")

	testing.expect(t, focus(&rt, id) && activate_focused(&rt, .Enter),
		"a selected icon button should keep the ordinary keyboard activation model")
	_, clicked = icons_test_icon_button_selected(&rt, true)
	testing.expect(t, clicked, "keyboard activation should still report one controlled press while selected")
}

// The Pinned "more actions" control used U+22EF HORIZONTAL MIDLINE ELLIPSIS,
// which the bundled faces do not cover. The semantic replacement is the
// font-independent More_Horizontal icon. This pins the control shape a consumer
// can adopt without depending on any system fallback face.
@(test)
test_more_horizontal_icon_button_needs_no_text_glyph :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 60})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "more-actions fixture should begin a frame"); return }
	container_begin_simple(&ui, .Root, label="more-root", key=key_string("more-root"), style=layout_style(.Row, width=64, height=40))
	_, _ = icon_button(&ui, "More actions", .More_Horizontal, key=key_string("pinned-more"), style=layout_style(.Row, width=32, height=32))
	container_end(&ui)
	end_frame(&ui)
	found := false
	for _, &node in rt.nodes {
		if node.icon_id != .More_Horizontal { continue }
		found = true
		icon_paint, text_paint := false, false
		for command in node.paint {
			if painted, ok := command.payload.(Icon_Paint); ok && painted.id == .More_Horizontal { icon_paint = true }
			if paint_command_is_text(command) { text_paint = true }
		}
		semantic, semantic_found := semantic_node_lookup(&rt, semantic_visual_id(node.id))
		testing.expect(t, icon_paint && !text_paint && node.text_run_valid == false,
			"the more-actions control must paint a coverage mask and no text run")
		testing.expect(t, semantic_found && semantic.role == .Button && semantic.label == "More actions",
			"the icon-only control must still expose the explicit accessible name")
	}
	testing.expect(t, found, "the More_Horizontal icon button should be retained")
}
