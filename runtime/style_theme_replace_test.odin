#+build !js
package alicorn

import "core:testing"

STYLE_THEME_REPLACE_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

test_theme_for_live_replace :: proc(color: Color) -> Style_Theme {
	theme := DEFAULT_STYLE_THEME
	theme.colors[int(Style_Color_Role.Accent)] = color
	return theme
}

@(test)
test_live_theme_replace_keeps_stable_id_and_bounded_registry :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 80}, Runtime_Config{trace_capacity=4})
	defer destroy_runtime(&rt)
	initial := test_theme_for_live_replace(Color{0.2, 0.1, 0.1, 1})
	id := style_theme_register(&rt, initial)
	testing.expect(t, id != 0, "valid development theme should register")
	registered_count := len(rt.style_themes)

	node := new(Node, allocator=rt.persistent_allocator)
	node^ = Node{
		id=41,
		active=true,
		present=true,
		style_environment=Style_Environment{theme=id},
		button_variant=.Primary,
		caret=Text_Position{byte=17, affinity=.Trailing},
		selection_anchor=Text_Position{byte=4, affinity=.Leading},
		selection_focus=Text_Position{byte=17, affinity=.Trailing},
		scroll_offset_y=240,
	}
	rt.nodes[node.id] = node
	rt.focused = node.id
	rt.semantic_revision = 17
	first_style := style_button_resolve_retained(&rt, node, Button_Visual_State{})
	_ = first_style
	previous_generation := node.style_generations.paint
	registered_snapshot := rt.style_themes[int(u32(id))-1]
	testing.expect(t, style_theme_replace(&rt, id, registered_snapshot) == .Unchanged, "identical candidate should be recognized as a no-op")
	rt.invalidated = false

	for index in 0..<4 {
		red := f32(index%2)*0.5 + 0.2
		candidate := test_theme_for_live_replace(Color{red, 0.15, 0.2, 1})
		testing.expect(t, style_theme_replace(&rt, id, candidate) == .Replaced, "valid theme candidate should replace in place")
		testing.expect(t, rt.style_themes[int(u32(id))-1].colors[int(Style_Color_Role.Accent)] == candidate.colors[int(Style_Color_Role.Accent)],
			"the stable theme ID should resolve to the newest accepted values")
		testing.expect(t, style_theme_color(&rt, id, .Accent) == candidate.colors[int(Style_Color_Role.Accent)],
			"the style query API should expose the newest color value")
		cached, cached_ok := rt.computed_styles[node.id]
		testing.expect(t, cached_ok && !cached.valid, "replacement should invalidate the retained computed style")
		updated_style := style_button_resolve_retained(&rt, node, Button_Visual_State{})
		fresh_style := style_button_resolve(&rt, node.style_environment, .Primary, Button_Visual_State{})
		testing.expect(t, updated_style == fresh_style,
			"same-ID replacement must recompute the cached style from the newest theme")
	}
	bytes_after_warmup := rt.allocation_stats.persistent_requested_bytes_live
	for index in 4..<64 {
		red := f32(index%2)*0.5 + 0.2
		candidate := test_theme_for_live_replace(Color{red, 0.15, 0.2, 1})
		testing.expect(t, style_theme_replace(&rt, id, candidate) == .Replaced, "repeated theme candidate should replace")
		updated_style := style_button_resolve_retained(&rt, node, Button_Visual_State{})
		fresh_style := style_button_resolve(&rt, node.style_environment, .Primary, Button_Visual_State{})
		testing.expect(t, updated_style == fresh_style,
			"repeated replacement should keep computed paint current")
	}

	testing.expect(t, len(rt.style_themes) == registered_count, "repeated live edits must not grow the theme registry")
	testing.expect(t, rt.allocation_stats.persistent_requested_bytes_live == bytes_after_warmup,
		"after bounded trace/cache warmup, repeated replacements must not grow live runtime allocations")
	testing.expect(t, node.style_generations.paint > previous_generation, "same-ID replacement must advance paint generations")
	testing.expect(t, Dirty_Stage.Paint in node.dirty && Dirty_Stage.Composite in node.dirty,
		"paint replacement must queue repaint and composition")
	testing.expect(t, Dirty_Stage.Measure not_in node.dirty && !rt.layout_pending && rt.stats.layout_nodes_visited == 0,
		"paint-only replacement must not schedule or visit layout")
	testing.expect(t, rt.presentation_pending, "paint-only replacement should request presentation")
	testing.expect(t, !rt.invalidated, "paint-only replacement must not request an application description rebuild")
	testing.expect(t, rt.semantic_revision == 17, "visual theme replacement must not change semantic revision")
	testing.expect(t, rt.focused == node.id && node.caret.byte == 17 && node.selection_anchor.byte == 4 &&
		node.selection_focus.byte == 17 && node.scroll_offset_y == 240,
		"paint-only replacement must preserve focus, text selection, caret, and scroll anchoring")
}

@(test)
test_live_theme_replace_rejects_invalid_or_open_frame_candidates :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&rt)
	id := style_theme_register(&rt, test_theme_for_live_replace(Color{0.2, 0.1, 0.1, 1}))
	old_color := style_theme_color(&rt, id, .Text)

	invalid := test_theme_for_live_replace(Color{0.4, 0.1, 0.1, 1})
	invalid.colors[int(Style_Color_Role.Text)].r = 2
	testing.expect(t, style_theme_replace(&rt, id, invalid) == .Rejected, "invalid candidate should be rejected")
	testing.expect(t, style_theme_color(&rt, id, .Text) == old_color, "invalid candidate must preserve last good theme")

	rt.frame_open = true
	valid := test_theme_for_live_replace(Color{0.7, 0.1, 0.1, 1})
	testing.expect(t, style_theme_replace(&rt, id, valid) == .Rejected, "replacement during an open frame should be rejected")
	rt.frame_open = false
	testing.expect(t, style_theme_color(&rt, id, .Text) == old_color, "rejected publication must not mutate the active theme")
	testing.expect(t, style_theme_replace(&rt, DEFAULT_STYLE_THEME_ID, valid) == .Rejected, "the default theme must remain immutable")
}

@(test)
test_live_theme_metric_replace_invalidates_root_and_measurement :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&rt)
	theme := DEFAULT_STYLE_THEME
	theme.control_metrics.defined = true
	id := style_theme_register(&rt, theme)
	node := new(Node, allocator=rt.persistent_allocator)
	node^ = Node{
		id=42,
		active=true,
		present=true,
		style_environment=Style_Environment{theme=id},
	}
	rt.nodes[node.id] = node

	next := theme
	next.control_metrics.button.preferred_height += 4
	testing.expect(t, style_theme_replace(&rt, id, next) == .Replaced, "valid metric candidate should replace")
	testing.expect(t, rt.invalidated, "metric replacement should rebuild application-authored metric consumers")
	testing.expect(t, Dirty_Stage.Measure in node.dirty, "metric replacement must invalidate measurement")
	testing.expect(t, rt.layout_pending && node.style_generations.metrics > 0,
		"metric replacement must schedule retained layout and advance metric generation")
	testing.expect(t, rt.semantic_revision == 0, "metric-only theme change must not mutate accessibility semantics")
}

@(test)
test_live_theme_replacement_is_runtime_local :: proc(t: ^testing.T) {
	left := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&left)
	right := new_runtime(Rect{0, 0, 120, 80})
	defer destroy_runtime(&right)
	left_id := style_theme_register(&left, test_theme_for_live_replace(Color{0.2, 0.1, 0.1, 1}))
	right_id := style_theme_register(&right, test_theme_for_live_replace(Color{0.3, 0.1, 0.1, 1}))
	testing.expect(t, left_id == right_id, "independent windows may use the same local theme ID")

	replacement := test_theme_for_live_replace(Color{0.8, 0.1, 0.1, 1})
	testing.expect(t, style_theme_replace(&left, left_id, replacement) == .Replaced, "one runtime should accept its own replacement")
	testing.expect(t, style_theme_color(&left, left_id, .Accent) == replacement.colors[int(Style_Color_Role.Accent)],
		"the updated runtime should expose its own replacement")
	testing.expect(t, style_theme_color(&right, right_id, .Accent) == Color{0.3, 0.1, 0.1, 1},
		"a separate runtime's window theme must remain unchanged")
}

test_theme_for_live_text_color :: proc(text_color: Color) -> Style_Theme {
	theme := DEFAULT_STYLE_THEME
	theme.colors[int(Style_Color_Role.Text)] = text_color
	return theme
}

// Describes one description-resolved Text node and one description-resolved
// Text_Field under the given theme. Both pass the default color so their ink is
// resolved from the theme's Text role at description time. explicit_color can
// override the plain Text node to cover caller-owned colors.
style_theme_replace_text_tree :: proc(
	rt: ^Runtime,
	theme_id: Style_Theme_ID,
	explicit_color := DEFAULT_COLOR,
) -> (text_id, field_id: Node_ID) {
	invalidate_root(rt, "theme text replacement fixture description")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, key=key_string("theme-text-root"), style=layout_style(.Column, width=320, height=140, gap=4))
	scope := style_environment_push(&ui, Style_Environment{theme=theme_id})
	text_id = text_simple(&ui, "theme resolved text", key=key_string("theme-text"), style=layout_style(width=200, height=24), color=explicit_color)
	field_id = text_field_simple(&ui, "theme resolved field", key=key_string("theme-text-field"), style=layout_style(width=200, height=28))
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
	return
}

style_theme_replace_settle :: proc(rt: ^Runtime) {
	for _ in 0..<4 {
		ui, more := begin_frame(rt)
		if !more { break }
		end_frame(&ui)
	}
}

style_theme_replace_text_paint_color :: proc(rt: ^Runtime, owner: Node_ID) -> (color: Color, found: bool) {
	view, view_ok := paint_display_list(rt)
	if !view_ok { return }
	for command in view.commands {
		if command.owner != owner { continue }
		if text, is_text := command.payload.(Text_Paint); is_text { return text.color, true }
	}
	return
}

@(test)
test_paint_only_theme_replace_recomputes_description_resolved_text_color :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 140})
	defer destroy_runtime(&rt)
	testing.expect(t, text_engine_load_font(&rt.text_engine, STYLE_THEME_REPLACE_TEST_FONT),
		"theme text replacement fixture font should load")

	first := test_theme_for_live_text_color(Color{0.11, 0.22, 0.33, 1})
	second := test_theme_for_live_text_color(Color{0.66, 0.55, 0.44, 1})
	id := style_theme_register(&rt, first)
	testing.expect(t, id != 0, "the fixture theme should register")
	if id == 0 { return }

	text_id, field_id := style_theme_replace_text_tree(&rt, id)
	style_theme_replace_settle(&rt)
	text_node, text_ok := rt.nodes[text_id]
	field_node, field_ok := rt.nodes[field_id]
	testing.expect(t, text_ok && field_ok, "the fixture should retain both text nodes")
	if !text_ok || !field_ok { return }
	expect_text := first.colors[int(Style_Color_Role.Text)]
	testing.expect(t, text_node.color_theme_resolved && text_node.color == expect_text,
		"default Text ink should be recorded as theme-resolved with the first theme's Text color")
	testing.expect(t, field_node.color_theme_resolved && field_node.color == expect_text,
		"default Text_Field ink should be recorded as theme-resolved with the first theme's Text color")
	before_text_color, before_text_ok := style_theme_replace_text_paint_color(&rt, text_id)
	before_field_color, before_field_ok := style_theme_replace_text_paint_color(&rt, field_id)
	testing.expect(t, before_text_ok && before_text_color == expect_text,
		"the initial Text paint should use the first theme's Text color")
	testing.expect(t, before_field_ok && before_field_color == expect_text,
		"the initial Text_Field paint should use the first theme's Text color")

	descriptions_before := rt.stats.descriptions_emitted
	frames_before := rt.stats.frames_built
	testing.expect(t, style_theme_replace(&rt, id, second) == .Replaced,
		"the color-only replacement should be accepted")
	testing.expect(t, !rt.invalidated && rt.presentation_pending,
		"the color-only replacement should only request presentation")
	expect_replaced := second.colors[int(Style_Color_Role.Text)]
	testing.expect(t, text_node.color == expect_replaced && field_node.color == expect_replaced,
		"the replacement walk should recompute theme-resolved ink before repainting")

	presentation, ready := begin_presentation_frame(&rt)
	testing.expect(t, ready, "the paint-only replacement should schedule a retained presentation frame")
	if ready { end_presentation_frame(&presentation) }
	testing.expect(t, rt.stats.descriptions_emitted == descriptions_before && rt.stats.frames_built == frames_before,
		"recomputing theme-resolved ink must not rebuild application descriptions")

	after_text_color, after_text_ok := style_theme_replace_text_paint_color(&rt, text_id)
	after_field_color, after_field_ok := style_theme_replace_text_paint_color(&rt, field_id)
	testing.expect(t, after_text_ok && after_text_color == expect_replaced,
		"the retained Text paint should adopt the replacement theme's Text color")
	testing.expect(t, after_field_ok && after_field_color == expect_replaced,
		"the retained Text_Field paint should adopt the replacement theme's Text color")
}

@(test)
test_paint_only_theme_replace_preserves_explicit_text_color :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 140})
	defer destroy_runtime(&rt)
	testing.expect(t, text_engine_load_font(&rt.text_engine, STYLE_THEME_REPLACE_TEST_FONT),
		"theme text replacement fixture font should load")

	first := test_theme_for_live_text_color(Color{0.11, 0.22, 0.33, 1})
	second := test_theme_for_live_text_color(Color{0.66, 0.55, 0.44, 1})
	id := style_theme_register(&rt, first)
	testing.expect(t, id != 0, "the fixture theme should register")
	if id == 0 { return }

	explicit := Color{0.95, 0.2, 0.25, 1}
	text_id, field_id := style_theme_replace_text_tree(&rt, id, explicit)
	style_theme_replace_settle(&rt)
	text_node, text_ok := rt.nodes[text_id]
	field_node, field_ok := rt.nodes[field_id]
	testing.expect(t, text_ok && field_ok, "the fixture should retain both text nodes")
	if !text_ok || !field_ok { return }
	testing.expect(t, !text_node.color_theme_resolved && text_node.color == explicit,
		"an explicit caller color must remain caller-owned")
	testing.expect(t, field_node.color_theme_resolved,
		"a default Text_Field color remains theme-resolved alongside the explicit Text node")

	testing.expect(t, style_theme_replace(&rt, id, second) == .Replaced,
		"the color-only replacement should be accepted")
	presentation, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&presentation) }

	testing.expect(t, !text_node.color_theme_resolved && text_node.color == explicit,
		"the replacement walk must not overwrite an explicit caller color")
	paint_color, paint_ok := style_theme_replace_text_paint_color(&rt, text_id)
	testing.expect(t, paint_ok && paint_color == explicit,
		"the retained explicit caller color must keep painting after replacement")
	expect_replaced := second.colors[int(Style_Color_Role.Text)]
	testing.expect(t, field_node.color == expect_replaced,
		"theme-resolved siblings should still follow the replacement theme")
}

@(test)
test_paint_only_theme_replace_matches_fresh_runtime_text_paint :: proc(t: ^testing.T) {
	incremental := new_runtime(Rect{0, 0, 320, 140})
	defer destroy_runtime(&incremental)
	testing.expect(t, text_engine_load_font(&incremental.text_engine, STYLE_THEME_REPLACE_TEST_FONT),
		"theme text replacement fixture font should load")

	first := test_theme_for_live_text_color(Color{0.11, 0.22, 0.33, 1})
	second := test_theme_for_live_text_color(Color{0.66, 0.55, 0.44, 1})
	id := style_theme_register(&incremental, first)
	testing.expect(t, id != 0, "the incremental fixture theme should register")
	if id == 0 { return }
	text_id, field_id := style_theme_replace_text_tree(&incremental, id)
	style_theme_replace_settle(&incremental)
	testing.expect(t, style_theme_replace(&incremental, id, second) == .Replaced,
		"the incremental runtime should accept the color-only replacement")
	presentation, ready := begin_presentation_frame(&incremental)
	if ready { end_presentation_frame(&presentation) }
	testing.expect(t, ready, "the incremental runtime should present the replacement")

	fresh := new_runtime(Rect{0, 0, 320, 140})
	defer destroy_runtime(&fresh)
	testing.expect(t, text_engine_load_font(&fresh.text_engine, STYLE_THEME_REPLACE_TEST_FONT),
		"the fresh comparison fixture font should load")
	fresh_id := style_theme_register(&fresh, second)
	testing.expect(t, fresh_id == id, "the fresh runtime should register the same theme ID")
	fresh_text_id, fresh_field_id := style_theme_replace_text_tree(&fresh, fresh_id)
	style_theme_replace_settle(&fresh)

	for pair in ([2][2]Node_ID{{text_id, fresh_text_id}, {field_id, fresh_field_id}}) {
		incremental_node, incremental_ok := incremental.nodes[pair[0]]
		fresh_node, fresh_ok := fresh.nodes[pair[1]]
		testing.expect(t, incremental_ok && fresh_ok, "both runtimes should retain the compared text node")
		if !incremental_ok || !fresh_ok { continue }
		testing.expect(t, !incremental_node.color_theme_resolved || incremental_node.color == fresh_node.color,
			"the retained theme-resolved color should match a fresh description of the replaced theme")
		incremental_color, incremental_color_ok := style_theme_replace_text_paint_color(&incremental, pair[0])
		fresh_color, fresh_color_ok := style_theme_replace_text_paint_color(&fresh, pair[1])
		testing.expect(t, incremental_color_ok && fresh_color_ok && incremental_color == fresh_color &&
			incremental_color == second.colors[int(Style_Color_Role.Text)],
			"the retained text paint should match a fresh runtime describing the replaced theme")
		incremental_info, incremental_info_ok := node_info(&incremental, pair[0])
		fresh_info, fresh_info_ok := node_info(&fresh, pair[1])
		testing.expect(t, incremental_info_ok && fresh_info_ok && incremental_info == fresh_info,
			"the public Node_Info projection should match the fresh runtime")
	}
}

