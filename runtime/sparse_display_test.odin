#+build !js
package alicorn

import "core:fmt"
import "core:testing"

// Sparse display finalization (issue #228, milestone 1).
//
// These tests pin the range-splice path used for multi-command retained
// repaints (default buttons, sliders, checkboxes). Every sparse result is
// compared against the full-finalization path, which remains the correctness
// oracle.

SPARSE_DISPLAY_ROOT :: Source_Site{"runtime/sparse_display_test.odin", 20, 1, "sparse-display-root"}
SPARSE_DISPLAY_ROW :: Source_Site{"runtime/sparse_display_test.odin", 30, 1, "sparse-display-row"}

SPARSE_DISPLAY_ROWS :: 8

Sparse_Display_State :: struct {
	labels:        [SPARSE_DISPLAY_ROWS]string,
	label_alt:     [SPARSE_DISPLAY_ROWS]bool,
	selected:      [SPARSE_DISPLAY_ROWS]bool,
	checked:       bool,
	show_checkbox: bool,
	show_backdrop: bool,
	theme_variant: int,
	theme_id:      Style_Theme_ID,
}

sparse_display_theme :: proc(variant: int) -> Style_Theme {
	theme := DEFAULT_STYLE_THEME
	if variant == 0 {
		theme.colors[int(Style_Color_Role.Accent)] = Color{0.28, 0.55, 0.82, 1}
		theme.colors[int(Style_Color_Role.Surface)] = Color{0.075, 0.09, 0.12, 1}
		theme.colors[int(Style_Color_Role.Text)] = Color{0.90, 0.93, 0.97, 1}
		theme.colors[int(Style_Color_Role.Selection)] = Color{0.22, 0.44, 0.80, 0.35}
	} else {
		theme.colors[int(Style_Color_Role.Accent)] = Color{0.86, 0.42, 0.20, 1}
		theme.colors[int(Style_Color_Role.Surface)] = Color{0.13, 0.085, 0.07, 1}
		theme.colors[int(Style_Color_Role.Text)] = Color{0.98, 0.92, 0.86, 1}
		theme.colors[int(Style_Color_Role.Selection)] = Color{0.80, 0.38, 0.16, 0.35}
	}
	return theme
}

sparse_display_state_init :: proc(rt: ^Runtime, state: ^Sparse_Display_State) {
	state^ = Sparse_Display_State{}
	for index in 0..<SPARSE_DISPLAY_ROWS {
		state.labels[index] = "aaaaa"
	}
	state.theme_id = style_theme_register(rt, sparse_display_theme(0))
}

sparse_display_describe :: proc(rt: ^Runtime, state: ^Sparse_Display_State, count := SPARSE_DISPLAY_ROWS) {
	invalidate_root(rt, "sparse display fixture description")
	ui, build := begin_frame(rt)
	if !build { return }
	root_style := layout_style(.Column, width=560, height=420, gap=2)
	container_begin(&ui, .Root, label="sparse-display-root", key=key_string("sparse-display-root"),
		style=root_style)
	scope := style_environment_push(&ui, Style_Environment{theme=state.theme_id})
	for index in 0..<count {
		row_style := layout_style(.Row, width=520, height=32, gap=4)
		container_begin(&ui, .Container, label="sparse-display-row", key=key_u64(u64(index)+1),
			style=row_style, color=Color{0.10, 0.12, 0.16, 1})
		text_simple(&ui, state.labels[index], key=key_u64(1000+u64(index)),
			style=layout_style(.Row, width=140, height=24))
		button(&ui, "run", key_u64(2000+u64(index)),
			style=layout_style(.Row, width=110, height=28),
			state=Button_State{selected=state.selected[index]})
		container_end(&ui)
	}
	if state.show_checkbox {
		checkbox(&ui, "toggle", state.checked, key_u64(3000))
	}
	if state.show_backdrop {
		surface := surface_begin(&ui, surface_core_color_role(.Surface),
			key=key_string("sparse-display-backdrop"),
			style=layout_style(width=120, height=40),
			fill=Color{0.2, 0.3, 0.4, 0.88}, backdrop_effect=backdrop_blur(4))
		if surface != 0 { surface_end(&ui) }
	}
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
}

sparse_display_flush_presentation :: proc(rt: ^Runtime) -> bool {
	ui, ready := begin_presentation_frame(rt)
	if ready { end_presentation_frame(&ui) }
	return ready
}

sparse_display_buttons :: proc(rt: ^Runtime, out: []Node_ID) -> int {
	count := 0
	for id in rt.order {
		node, ok := rt.nodes[id]
		if !ok || node == nil || node.kind != .Button { continue }
		if count < len(out) { out[count] = id }
		count += 1
	}
	return count
}

sparse_display_node_of_kind :: proc(rt: ^Runtime, kind: Node_Kind) -> Node_ID {
	for id in rt.order {
		if node, ok := rt.nodes[id]; ok && node != nil && node.kind == kind { return id }
	}
	return 0
}

sparse_display_next_random :: proc(state: ^u64) -> u64 {
	state^ = state^*6364136223846793005 + 1442695040888963407
	return state^ >> 33
}

// sparse_display_commands_match compares every renderer-visible field of two
// paint commands, including payloads. The retained locality helpers only cover
// surfaces and text; sparse finalization also moves icons and effect markers.
sparse_display_commands_match :: proc(a, b: Paint_Command) -> bool {
	if a.owner != b.owner || a.bounds != b.bounds || a.clip != b.clip || a.opacity != b.opacity ||
		a.translation != b.translation || a.stroke_placement != b.stroke_placement ||
		a.semantic_surface_gradient != b.semantic_surface_gradient ||
		a.semantic_surface_fill != b.semantic_surface_fill {
		return false
	}
	switch a_payload in a.payload {
	case Surface_Paint:
		b_payload, ok := b.payload.(Surface_Paint)
		return ok && a_payload == b_payload
	case Text_Paint:
		b_payload, ok := b.payload.(Text_Paint)
		if !ok || a_payload.run != b_payload.run || a_payload.color != b_payload.color ||
			len(a_payload.spans) != len(b_payload.spans) {
			return false
		}
		for span, index in a_payload.spans {
			if span != b_payload.spans[index] { return false }
		}
		return true
	case Icon_Paint:
		b_payload, ok := b.payload.(Icon_Paint)
		return ok && a_payload == b_payload
	case Image_Paint:
		b_payload, ok := b.payload.(Image_Paint)
		return ok && a_payload == b_payload
	case Geometry_Paint:
		b_payload, ok := b.payload.(Geometry_Paint)
		return ok && a_payload == b_payload
	case Backdrop_Effect_Paint:
		b_payload, ok := b.payload.(Backdrop_Effect_Paint)
		return ok && a_payload == b_payload
	}
	return false
}

// sparse_display_assert_matches_full snapshots the sparse display, forces the
// full finalization oracle, and requires byte-identical output.
sparse_display_assert_matches_full :: proc(t: ^testing.T, rt: ^Runtime, label: string) -> bool {
	if len(rt.display) != len(rt.display_target) {
		testing.expectf(t, false, "%s: display (%d) and target (%d) must stay aligned", label,
			len(rt.display), len(rt.display_target))
		return false
	}
	incremental := make([]Paint_Command, len(rt.display), allocator=rt.persistent_allocator)
	copy(incremental, rt.display[:])
	layout_finalize_display(rt, .Display_Structure_Rebuild)
	matches := len(rt.display) == len(incremental)
	for index in 0..<min(len(rt.display), len(incremental)) {
		if !sparse_display_commands_match(incremental[index], rt.display[index]) {
			testing.expectf(t, false, "%s: sparse command %d differs from full finalization", label, index)
			matches = false
			break
		}
	}
	delete(incremental, rt.persistent_allocator)
	testing.expectf(t, matches, "%s: sparse display must byte-match full finalization", label)
	return matches
}

// ---------------------------------------------------------------------------
// a. Multi-command hover stays sparse and matches the full oracle.
// ---------------------------------------------------------------------------

@(test)
test_sparse_multi_command_hover_matches_full_finalization :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	sparse_display_describe(&rt, &state)
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	count := sparse_display_buttons(&rt, buttons[:])
	if count < 2 {
		testing.expect(t, false, "fixture should retain multiple hover-painted buttons")
		return
	}
	for index in 0..<count {
		if node, ok := rt.nodes[buttons[index]]; !ok || len(node.paint) <= 1 {
			testing.expect(t, false, "default buttons should retain multiple paint commands")
			return
		}
	}
	for index in 0..<count {
		button := rt.nodes[buttons[index]]
		x := button.bounds.x+button.bounds.w*0.5
		y := button.bounds.y+button.bounds.h*0.5
		full_passes := rt.stats.display_finalization_full_passes
		structure := rt.stats.global_work_by_reason[.Display_Structure_Rebuild]
		fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
		global_fallbacks := rt.stats.global_fallbacks
		compositions := rt.stats.composition_nodes_visited
		_ = process_pointer(&rt, Pointer_Event{kind=.Move, x=x, y=y, button=0})
		_ = sparse_display_flush_presentation(&rt)
		testing.expectf(t, rt.stats.display_finalization_full_passes == full_passes,
			"hover on button %d must not take a full display pass", index)
		testing.expectf(t, rt.stats.global_work_by_reason[.Display_Structure_Rebuild] == structure &&
			rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks &&
			rt.stats.global_fallbacks == global_fallbacks,
			"hover on button %d must not record a structure rebuild or fallback", index)
		testing.expectf(t, rt.stats.composition_nodes_visited-compositions > 0 &&
			rt.stats.composition_nodes_visited-compositions < u64(count*2),
			"hover on button %d should compose only the changed control", index)
		_ = sparse_display_assert_matches_full(t, &rt, fmt.tprintf("hover button %d", index))
	}
}

// ---------------------------------------------------------------------------
// b. Randomized seeded update sequences match the full oracle after each op.
// ---------------------------------------------------------------------------

Sparse_Display_Op :: enum {
	Hover,
	Selection,
	Label,
	Theme,
	Forced_Full,
}

@(test)
test_sparse_randomized_updates_match_full_finalization :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	state.show_checkbox = true
	sparse_display_describe(&rt, &state)
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	count := sparse_display_buttons(&rt, buttons[:])
	if count < 2 {
		testing.expect(t, false, "randomized fixture should retain buttons")
		return
	}

	seed: u64 = 0x5eed_0228
	random := seed
	ops := 120
	sparse_ops := 0
	for op_index in 0..<ops {
		kind := Sparse_Display_Op(sparse_display_next_random(&random) % u64(len(Sparse_Display_Op)))
		switch kind {
		case .Hover:
			button := rt.nodes[buttons[int(sparse_display_next_random(&random) % u64(count))]]
			x := button.bounds.x+button.bounds.w*0.5
			y := button.bounds.y+button.bounds.h*0.5
			_ = process_pointer(&rt, Pointer_Event{kind=.Move, x=x, y=y, button=0})
			_ = sparse_display_flush_presentation(&rt)
			sparse_ops += 1
		case .Selection:
			row := int(sparse_display_next_random(&random) % SPARSE_DISPLAY_ROWS)
			state.selected[row] = !state.selected[row]
			sparse_display_describe(&rt, &state)
			sparse_ops += 1
		case .Label:
			row := int(sparse_display_next_random(&random) % SPARSE_DISPLAY_ROWS)
			state.label_alt[row] = !state.label_alt[row]
			if state.label_alt[row] { state.labels[row] = "bbbbb" } else { state.labels[row] = "aaaaa" }
			sparse_display_describe(&rt, &state)
			sparse_ops += 1
		case .Theme:
			state.theme_variant = 1-state.theme_variant
			result := style_theme_replace(&rt, state.theme_id, sparse_display_theme(state.theme_variant))
			if result != .Replaced {
				testing.expectf(t, false, "theme op %d should replace retained paint (result=%v)", op_index, result)
			}
			_ = sparse_display_flush_presentation(&rt)
			sparse_ops += 1
		case .Forced_Full:
			layout_finalize_display(&rt, .Display_Structure_Rebuild)
			continue
		}
		// Any op that fell back to a full rebuild is still required to match;
		// the oracle below is the authority for both paths.
		_ = sparse_display_assert_matches_full(t, &rt, fmt.tprintf("seed=%#x op=%d kind=%v", seed, op_index, kind))
	}
	testing.expectf(t, sparse_ops > ops/2, "randomized sequence should exercise retained updates (%d/%d)", sparse_ops, ops)
}

// ---------------------------------------------------------------------------
// Bulk repaint policy: when most of the display changes, one full pass is both
// cheaper and still proportional to the changed content.
// ---------------------------------------------------------------------------

sparse_display_bulk_describe :: proc(rt: ^Runtime, theme_id: Style_Theme_ID, count: int) {
	invalidate_root(rt, "sparse display bulk fixture description")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, label="sparse-bulk-root", key=key_string("sparse-bulk-root"),
		style=layout_style(.Column, width=560, height=420, gap=1))
	scope := style_environment_push(&ui, Style_Environment{theme=theme_id})
	for index in 0..<count {
		button(&ui, "run", key_u64(4000+u64(index)),
			style=layout_style(.Row, width=520, height=24))
	}
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
}

@(test)
test_sparse_display_bulk_repaint_uses_one_full_pass :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	theme_id := style_theme_register(&rt, sparse_display_theme(0))
	sparse_display_bulk_describe(&rt, theme_id, 80)
	if len(rt.display_target) == 0 {
		testing.expect(t, false, "bulk fixture should retain a display list")
		return
	}
	full_passes := rt.stats.display_finalization_full_passes
	result := style_theme_replace(&rt, theme_id, sparse_display_theme(1))
	_ = sparse_display_flush_presentation(&rt)
	testing.expectf(t, result == .Replaced, "bulk theme replacement should apply (result=%v)", result)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a repaint covering most of the display should use exactly one full pass")
	_ = sparse_display_assert_matches_full(t, &rt, "bulk theme replacement")
}

// ---------------------------------------------------------------------------
// c. Fallback coverage: these update classes must take the full path.
// ---------------------------------------------------------------------------

@(test)
test_sparse_display_falls_back_when_command_count_changes :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	state.show_checkbox = true
	sparse_display_describe(&rt, &state)
	checkbox_id := sparse_display_node_of_kind(&rt, .Checkbox)
	if checkbox_id == 0 {
		testing.expect(t, false, "fixture should retain a checkbox")
		return
	}
	before := len(rt.nodes[checkbox_id].paint)
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	state.checked = true
	sparse_display_describe(&rt, &state)
	after := len(rt.nodes[checkbox_id].paint)
	testing.expectf(t, after != before, "checked checkbox should add a command (%d -> %d)", before, after)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a command-count change must take one full display finalization")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks+1,
		"a command-count change must record an incremental fallback")
	_ = sparse_display_assert_matches_full(t, &rt, "checkbox command count change")
}

SPARSE_DISPLAY_CLIP :: Source_Site{"runtime/sparse_display_test.odin", 40, 1, "sparse-display-clip"}

sparse_display_clipped_describe :: proc(rt: ^Runtime, clip_width: f32) -> Node_ID {
	invalidate_root(rt, "sparse display clipped fixture description")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, label="sparse-clip-root", key=key_string("sparse-clip-root"),
		style=layout_style(.Column, width=320, height=120))
	container_begin_ex(&ui, .Container, SPARSE_DISPLAY_CLIP, label="sparse-clip-box",
		key="sparse-clip-box", explicit_key=true,
		style=layout_style(.Column, width=clip_width, height=80, clip=true))
	id := sparse_display_emit_button(&ui, 0)
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return id
}

sparse_display_emit_button :: proc(ui: ^UI, index: int) -> Node_ID {
	button_ex(ui, "run", key=fmt.tprintf("sparse-clip-button-%d", index), explicit_key=true,
		style=layout_style(.Row, width=220, height=28))
	return ui.runtime.pending[len(ui.runtime.pending)-1].description.id
}

@(test)
test_sparse_display_falls_back_when_ancestor_clip_changes :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 120})
	defer destroy_runtime(&rt)
	button := sparse_display_clipped_describe(&rt, 300)
	if button == 0 {
		testing.expect(t, false, "clipped fixture should retain its button")
		return
	}
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	_ = sparse_display_clipped_describe(&rt, 240)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a changed ancestor clip must take the full display fallback")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks+1,
		"a changed ancestor clip must record an incremental fallback")
	_ = sparse_display_assert_matches_full(t, &rt, "ancestor clip change")
}

@(test)
test_sparse_display_falls_back_while_a_backdrop_boundary_exists :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	state.show_backdrop = true
	sparse_display_describe(&rt, &state)
	testing.expect(t, rt.retained_backdrop_effect_nodes == 1,
		"the retained backdrop boundary must be tracked")
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	_ = sparse_display_buttons(&rt, buttons[:])
	full_passes := rt.stats.display_finalization_full_passes
	button := rt.nodes[buttons[0]]
	_ = process_pointer(&rt, Pointer_Event{kind=.Move,
		x=button.bounds.x+button.bounds.w*0.5, y=button.bounds.y+button.bounds.h*0.5, button=0})
	_ = sparse_display_flush_presentation(&rt)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a live backdrop boundary must keep sparse range finalization off")
	_ = sparse_display_assert_matches_full(t, &rt, "hover with backdrop boundary")

	// Removing the boundary returns the counter to zero, so the sparse path is
	// available again.
	state.show_backdrop = false
	sparse_display_describe(&rt, &state)
	testing.expect(t, rt.retained_backdrop_effect_nodes == 0,
		"retiring the backdrop owner must release the retained boundary count")
	full_passes = rt.stats.display_finalization_full_passes
	button = rt.nodes[buttons[1]]
	_ = process_pointer(&rt, Pointer_Event{kind=.Move,
		x=button.bounds.x+button.bounds.w*0.5, y=button.bounds.y+button.bounds.h*0.5, button=0})
	_ = sparse_display_flush_presentation(&rt)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"without a backdrop boundary a button hover should remain sparse")
	_ = sparse_display_assert_matches_full(t, &rt, "hover after backdrop removal")
}

// ---------------------------------------------------------------------------
// d. True idle after retained updates.
// ---------------------------------------------------------------------------

@(test)
test_sparse_display_returns_to_true_idle :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	state.show_checkbox = true
	sparse_display_describe(&rt, &state)
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	_ = sparse_display_buttons(&rt, buttons[:])
	button := rt.nodes[buttons[0]]
	_ = process_pointer(&rt, Pointer_Event{kind=.Move,
		x=button.bounds.x+button.bounds.w*0.5, y=button.bounds.y+button.bounds.h*0.5, button=0})
	_ = sparse_display_flush_presentation(&rt)
	state.selected[0] = true
	sparse_display_describe(&rt, &state)
	_ = sparse_display_assert_matches_full(t, &rt, "idle setup")

	before := rt.stats
	for _ in 0..<200 {
		ui, build := begin_frame(&rt)
		if build { end_frame(&ui) }
	}
	testing.expect(t, rt.stats.frames_built == before.frames_built,
		"idle frames must not build the application")
	testing.expect(t, rt.stats.stage_visits == before.stage_visits &&
		rt.stats.composition_nodes_visited == before.composition_nodes_visited &&
		rt.stats.paint_nodes_visited == before.paint_nodes_visited &&
		rt.stats.display_commands_finalized == before.display_commands_finalized &&
		rt.stats.display_finalization_full_passes == before.display_finalization_full_passes,
		"idle frames must perform no paint, composition, or finalization work")
}
