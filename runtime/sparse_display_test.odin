#+build !js
package alicorn

import "core:fmt"
import "core:testing"
import "core:time"

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
	row_background: [SPARSE_DISPLAY_ROWS]bool,
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
		state.row_background[index] = true
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
		row_color := Color{0.10, 0.12, 0.16, 1}
		if !state.row_background[index] { row_color = NO_BACKGROUND_COLOR }
		container_begin(&ui, .Container, label="sparse-display-row", key=key_u64(u64(index)+1),
			style=row_style, color=row_color)
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
	case Lighting_Group_Paint:
		b_payload, ok := b.payload.(Lighting_Group_Paint)
		return ok && a_payload == b_payload
	}
	return false
}

// sparse_display_assert_matches_full snapshots the sparse display and the
// retained tree's display_index values, forces a complete structural rebuild
// (the strongest oracle), and requires byte-identical lists plus identical
// indices. The snapshot is then restored so consecutive sparse operations keep
// building on the incremental state instead of on a fresh rebuild.
sparse_display_assert_matches_full :: proc(t: ^testing.T, rt: ^Runtime, label: string) -> bool {
	if len(rt.display) != len(rt.display_target) {
		testing.expectf(t, false, "%s: display (%d) and target (%d) must stay aligned", label,
			len(rt.display), len(rt.display_target))
		return false
	}
	incremental_display := make([]Paint_Command, len(rt.display), allocator=rt.persistent_allocator)
	defer delete(incremental_display, rt.persistent_allocator)
	copy(incremental_display, rt.display[:])
	incremental_target := make([]Paint_Command, len(rt.display_target), allocator=rt.persistent_allocator)
	defer delete(incremental_target, rt.persistent_allocator)
	copy(incremental_target, rt.display_target[:])
	indices := make(map[Node_ID]int, allocator=rt.persistent_allocator)
	defer delete(indices)
	for id in rt.order {
		if node, ok := rt.nodes[id]; ok && node != nil { indices[id] = node.display_index }
	}
	rebuild_display(rt)
	matches := len(rt.display) == len(incremental_display) &&
		len(rt.display_target) == len(incremental_target)
	if matches {
		for index in 0..<len(incremental_display) {
			if !sparse_display_commands_match(incremental_display[index], rt.display[index]) {
				testing.expectf(t, false, "%s: sparse finalized command %d differs from a full rebuild",
					label, index)
				matches = false
				break
			}
		}
	}
	if matches {
		for index in 0..<len(incremental_target) {
			if !sparse_display_commands_match(incremental_target[index], rt.display_target[index]) {
				testing.expectf(t, false, "%s: sparse target command %d differs from a full composition",
					label, index)
				matches = false
				break
			}
		}
	}
	if matches {
		for id, index in indices {
			node, ok := rt.nodes[id]
			if !ok || node == nil { continue }
			if node.display_index != index {
				testing.expectf(t, false, "%s: node %d display_index %d differs from a full composition (%d)",
					label, id, index, node.display_index)
				matches = false
				break
			}
		}
	}
	if len(rt.display) == len(incremental_display) { copy(rt.display[:], incremental_display) }
	if len(rt.display_target) == len(incremental_target) { copy(rt.display_target[:], incremental_target) }
	for id, index in indices {
		if node, ok := rt.nodes[id]; ok && node != nil { node.display_index = index }
	}
	testing.expectf(t, matches, "%s: sparse display must byte-match a full rebuild", label)
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
	Focus,
	Checkbox,
	Row_Background,
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
		case .Focus:
			target := buttons[int(sparse_display_next_random(&random) % u64(count))]
			previous := rt.focused
			rt.focus_visible = true
			rt.focused = target
			if previous != 0 && previous != target {
				invalidate_interaction_paint(&rt, previous, "randomized focus ring disappeared")
			}
			if previous != target {
				invalidate_interaction_paint(&rt, target, "randomized focus ring appeared")
				_ = sparse_display_flush_presentation(&rt)
			}
			sparse_ops += 1
		case .Checkbox:
			state.checked = !state.checked
			sparse_display_describe(&rt, &state)
			sparse_ops += 1
		case .Row_Background:
			row := int(sparse_display_next_random(&random) % SPARSE_DISPLAY_ROWS)
			state.row_background[row] = !state.row_background[row]
			sparse_display_describe(&rt, &state)
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
// Bounded tail policy: a count change near the start of a large display moves
// more tail than the change costs, so one linear full pass wins. The same
// change near the end splices without touching the rest of the list.
// ---------------------------------------------------------------------------

sparse_display_tail_describe :: proc(rt: ^Runtime, theme_id: Style_Theme_ID, count: int) {
	invalidate_root(rt, "sparse display tail fixture description")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin(&ui, .Root, label="sparse-tail-root", key=key_string("sparse-tail-root"),
		style=layout_style(.Column, width=560, height=420, gap=1))
	scope := style_environment_push(&ui, Style_Environment{theme=theme_id})
	for index in 0..<count {
		button(&ui, "run", key_u64(9000+u64(index)),
			style=layout_style(.Row, width=520, height=20))
	}
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
}

SPARSE_DISPLAY_TAIL_ROWS :: 400

@(test)
test_sparse_display_count_change_large_tail_takes_bulk_full_pass :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	theme_id := style_theme_register(&rt, sparse_display_theme(0))
	sparse_display_tail_describe(&rt, theme_id, SPARSE_DISPLAY_TAIL_ROWS)
	buttons := make([]Node_ID, SPARSE_DISPLAY_TAIL_ROWS, allocator=rt.persistent_allocator)
	defer delete(buttons, rt.persistent_allocator)
	count := sparse_display_buttons(&rt, buttons)
	if count != SPARSE_DISPLAY_TAIL_ROWS {
		testing.expectf(t, false, "tail fixture should retain %d buttons, got %d",
			SPARSE_DISPLAY_TAIL_ROWS, count)
		return
	}
	rt.focus_visible = true
	first := buttons[0]
	before := len(rt.nodes[first].paint)
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	rejections := rt.stats.display_splice_tail_rejections
	splices := rt.stats.display_splice_count
	rt.focused = first
	invalidate_interaction_paint(&rt, first, "test large-tail focus ring appeared")
	_ = sparse_display_flush_presentation(&rt)
	testing.expectf(t, len(rt.nodes[first].paint) > before,
		"focus should add ring commands to the first button")
	testing.expect(t, rt.stats.display_splice_tail_rejections == rejections+1,
		"a count change near the start of a large display must exceed the tail policy")
	testing.expect(t, rt.stats.display_splice_count == splices,
		"a rejected tail must not splice")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a rejected tail must take exactly one full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks+1,
		"a rejected tail must record the incremental fallback")
	_ = sparse_display_assert_matches_full(t, &rt, "large-tail focus change")
}

@(test)
test_sparse_display_count_change_late_node_splices_in_large_display :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	theme_id := style_theme_register(&rt, sparse_display_theme(0))
	sparse_display_tail_describe(&rt, theme_id, SPARSE_DISPLAY_TAIL_ROWS)
	buttons := make([]Node_ID, SPARSE_DISPLAY_TAIL_ROWS, allocator=rt.persistent_allocator)
	defer delete(buttons, rt.persistent_allocator)
	count := sparse_display_buttons(&rt, buttons)
	if count != SPARSE_DISPLAY_TAIL_ROWS {
		testing.expectf(t, false, "tail fixture should retain %d buttons, got %d",
			SPARSE_DISPLAY_TAIL_ROWS, count)
		return
	}
	rt.focus_visible = true
	last := buttons[count-1]
	before := len(rt.nodes[last].paint)
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	rejections := rt.stats.display_splice_tail_rejections
	splices := rt.stats.display_splice_count
	tail_nodes := rt.stats.display_splice_tail_nodes
	rt.focused = last
	invalidate_interaction_paint(&rt, last, "test late focus ring appeared")
	_ = sparse_display_flush_presentation(&rt)
	testing.expectf(t, len(rt.nodes[last].paint) > before,
		"focus should add ring commands to the last button")
	testing.expect(t, rt.stats.display_splice_tail_rejections == rejections,
		"a late node must stay inside the tail policy")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"a late count change must splice")
	testing.expect(t, rt.stats.display_splice_tail_nodes == tail_nodes,
		"a late node has no following display commands to shift")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"a late count change must not take a full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"a late count change must not fall back")
	_ = sparse_display_assert_matches_full(t, &rt, "late-node focus change")
}

// ---------------------------------------------------------------------------
// c. Count-changing splices: focus rings and checkmarks add or remove a
// command. Both directions splice, keep every following display_index, and
// match a full rebuild byte for byte.
// ---------------------------------------------------------------------------

@(test)
test_sparse_display_count_change_focus_toggle_splices :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	sparse_display_describe(&rt, &state)
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	count := sparse_display_buttons(&rt, buttons[:])
	if count < 2 {
		testing.expect(t, false, "focus fixture should retain multiple buttons")
		return
	}
	rt.focus_visible = true
	// Focus a button in the middle of the list: the ring is appended to its
	// paint list and every following row must shift by the ring's commands.
	target := buttons[count/2]
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices := rt.stats.display_splice_count
	bytes := rt.stats.display_splice_bytes_moved
	tail_nodes := rt.stats.display_splice_tail_nodes
	before := len(rt.nodes[target].paint)
	rt.focused = target
	invalidate_interaction_paint(&rt, target, "test focus ring appeared")
	_ = sparse_display_flush_presentation(&rt)
	after := len(rt.nodes[target].paint)
	testing.expectf(t, after > before, "focus should add ring commands (%d -> %d)", before, after)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"a focus ring appearing must not take a full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"a focus ring appearing must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"a focus ring appearing must record one splice")
	testing.expect(t, rt.stats.display_splice_bytes_moved > bytes,
		"a focus ring appearing must move the following display tail")
	testing.expect(t, rt.stats.display_splice_tail_nodes > tail_nodes,
		"a focus ring appearing must shift the following nodes' display_index")
	_ = sparse_display_assert_matches_full(t, &rt, "focus ring appeared")

	// Move focus to a later button: the old owner loses its ring (shrink) and
	// the new owner gains one (grow) in the same frame.
	full_passes = rt.stats.display_finalization_full_passes
	fallbacks = rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices = rt.stats.display_splice_count
	previous := target
	next := buttons[count-1]
	next_before := len(rt.nodes[next].paint)
	rt.focused = next
	invalidate_interaction_paint(&rt, previous, "test focus ring disappeared")
	invalidate_interaction_paint(&rt, next, "test focus ring appeared")
	_ = sparse_display_flush_presentation(&rt)
	testing.expectf(t, len(rt.nodes[next].paint) > next_before,
		"the new focus owner should gain its ring commands")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"moving focus must not take a full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"moving focus must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+2,
		"moving focus should splice the shrink and the grow")
	_ = sparse_display_assert_matches_full(t, &rt, "focus moved to a later button")
}

@(test)
test_sparse_display_count_change_checkbox_toggles_both_directions :: proc(t: ^testing.T) {
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
	unchecked := len(rt.nodes[checkbox_id].paint)
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices := rt.stats.display_splice_count
	rejections := rt.stats.display_splice_tail_rejections

	// Grow: the checkmark icon is inserted before the label command.
	state.checked = true
	sparse_display_describe(&rt, &state)
	checked := len(rt.nodes[checkbox_id].paint)
	testing.expectf(t, checked == unchecked+1, "checking should add one command (%d -> %d)",
		unchecked, checked)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"checking must not take a full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"checking must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"checking must splice the grown range")
	testing.expect(t, rt.stats.display_splice_tail_rejections == rejections,
		"checking is a small-tail splice")
	_ = sparse_display_assert_matches_full(t, &rt, "checkbox checked")

	// Shrink: removing the checkmark moves the following tail backwards.
	full_passes = rt.stats.display_finalization_full_passes
	fallbacks = rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices = rt.stats.display_splice_count
	state.checked = false
	sparse_display_describe(&rt, &state)
	testing.expectf(t, len(rt.nodes[checkbox_id].paint) == unchecked,
		"unchecking should remove the checkmark command")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"unchecking must not take a full display pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"unchecking must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"unchecking must splice the shrunk range")
	_ = sparse_display_assert_matches_full(t, &rt, "checkbox unchecked")
}

@(test)
test_sparse_display_zero_count_range_grows_and_shrinks :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	sparse_display_describe(&rt, &state)
	rows := make([dynamic]Node_ID, 0, allocator=rt.persistent_allocator)
	defer delete(rows)
	for id in rt.order {
		if node, ok := rt.nodes[id]; ok && node != nil && node.kind == .Container &&
			node.parent != 0 && len(node.children) == 2 {
			append(&rows, id)
		}
	}
	if len(rows) < 2 {
		testing.expect(t, false, "fixture should retain keyed row containers")
		return
	}
	row := rows[0]
	background_count := len(rt.nodes[row].paint)
	if background_count != 1 {
		testing.expectf(t, false, "row container should start with one background command, got %d",
			background_count)
		return
	}
	full_passes := rt.stats.display_finalization_full_passes
	fallbacks := rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices := rt.stats.display_splice_count

	// Shrink to zero: the node leaves the display and its index becomes the
	// zero-command sentinel while the following rows shift backwards.
	state.row_background[0] = false
	sparse_display_describe(&rt, &state)
	testing.expect(t, len(rt.nodes[row].paint) == 0,
		"removing the row background should empty its command list")
	testing.expect(t, rt.nodes[row].display_index == -1,
		"a zero-command node must use the -1 display_index sentinel")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"shrinking a range to zero commands must not take a full pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"shrinking a range to zero commands must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"shrinking a range to zero commands must splice")
	_ = sparse_display_assert_matches_full(t, &rt, "row background removed")

	// Grow from zero: insertion is anchored at the first descendant command,
	// before the label and button commands.
	full_passes = rt.stats.display_finalization_full_passes
	fallbacks = rt.stats.global_work_by_reason[.Display_Incremental_Fallback]
	splices = rt.stats.display_splice_count
	state.row_background[0] = true
	sparse_display_describe(&rt, &state)
	testing.expect(t, len(rt.nodes[row].paint) == 1,
		"restoring the row background should emit its surface command")
	index := rt.nodes[row].display_index
	testing.expect(t, index >= 0 && index < len(rt.display_target) &&
		rt.display_target[index].owner == row,
		"the regrown range must start at its own first command")
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"growing a range from zero commands must not take a full pass")
	testing.expect(t, rt.stats.global_work_by_reason[.Display_Incremental_Fallback] == fallbacks,
		"growing a range from zero commands must not fall back")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"growing a range from zero commands must splice")
	_ = sparse_display_assert_matches_full(t, &rt, "row background restored")
}

// ---------------------------------------------------------------------------
// c. Fallback coverage: these update classes must take the full path.
// ---------------------------------------------------------------------------

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

@(test)
test_sparse_display_count_change_falls_back_while_an_overlay_tail_exists :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	state.show_checkbox = true
	sparse_display_describe(&rt, &state)
	checkbox_id := sparse_display_node_of_kind(&rt, .Checkbox)
	if checkbox_id == 0 {
		testing.expect(t, false, "overlay fixture should retain a checkbox")
		return
	}
	// A drag preview is appended after every top-level tree and re-appended by
	// rebuild_display. A count-changing splice must not move that overlay tail.
	rt.drag.phase = .Dragging
	full_passes := rt.stats.display_finalization_full_passes
	splices := rt.stats.display_splice_count
	state.checked = true
	sparse_display_describe(&rt, &state)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes+1,
		"a frame with an overlay tail must take the full display pass")
	testing.expect(t, rt.stats.display_splice_count == splices,
		"a frame with an overlay tail must not splice")

	// Clearing the overlay returns to the sparse path with an aligned display.
	rt.drag.phase = .Idle
	rt.composition_rebuild = true
	invalidate_interaction_paint(&rt, checkbox_id, "overlay tail cleared")
	_ = sparse_display_flush_presentation(&rt)
	full_passes = rt.stats.display_finalization_full_passes
	splices = rt.stats.display_splice_count
	state.checked = false
	sparse_display_describe(&rt, &state)
	testing.expect(t, rt.stats.display_finalization_full_passes == full_passes,
		"without an overlay tail the count change should splice")
	testing.expect(t, rt.stats.display_splice_count == splices+1,
		"without an overlay tail the count change should record one splice")
	_ = sparse_display_assert_matches_full(t, &rt, "overlay cleared")
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

// ---------------------------------------------------------------------------
// e. Splice cost instrumentation: the tail fixup must stay cheaper than the
// full pass it replaces. This test prints the measured counters used by the
// issue #228 report; correctness assertions remain deterministic.
// ---------------------------------------------------------------------------

sparse_display_sort_i64 :: proc(values: []i64) {
	for index in 1..<len(values) {
		key := values[index]
		position := index - 1
		for position >= 0 && values[position] > key {
			values[position+1] = values[position]
			position -= 1
		}
		values[position+1] = key
	}
}

sparse_display_percentile_i64 :: proc(values: []i64, percent: int) -> i64 {
	if len(values) == 0 { return 0 }
	index := (len(values)-1)*percent/100
	if index < 0 { index = 0 }
	if index >= len(values) { index = len(values)-1 }
	return values[index]
}

@(test)
test_sparse_display_count_change_splice_cost_bounded :: proc(t: ^testing.T) {
	iterations := 48
	rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&rt)
	state: Sparse_Display_State
	sparse_display_state_init(&rt, &state)
	sparse_display_describe(&rt, &state)
	buttons: [SPARSE_DISPLAY_ROWS]Node_ID
	count := sparse_display_buttons(&rt, buttons[:])
	if count < 2 {
		testing.expect(t, false, "cost fixture should retain multiple buttons")
		return
	}
	rt.focus_visible = true
	rt.focused = buttons[0]
	invalidate_interaction_paint(&rt, buttons[0], "splice cost warmup")
	_ = sparse_display_flush_presentation(&rt)

	splice_update_ns := make([]i64, iterations, allocator=rt.persistent_allocator)
	defer delete(splice_update_ns, rt.persistent_allocator)
	full_update_ns := make([]i64, iterations, allocator=rt.persistent_allocator)
	defer delete(full_update_ns, rt.persistent_allocator)
	splices_before := rt.stats.display_splice_count
	bytes_before := rt.stats.display_splice_bytes_moved
	tail_nodes_before := rt.stats.display_splice_tail_nodes
	tail_commands_before := rt.stats.display_splice_tail_commands
	internal_before := rt.stats.display_splice_elapsed_ns
	for index in 0..<iterations {
		target := buttons[index%2]
		previous := rt.focused
		rt.focused = target
		if previous != 0 && previous != target {
			invalidate_interaction_paint(&rt, previous, "splice cost focus loss")
		}
		if previous != target { invalidate_interaction_paint(&rt, target, "splice cost focus gain") }
		started := time.now()
		_ = sparse_display_flush_presentation(&rt)
		splice_update_ns[index] = i64(time.duration_nanoseconds(time.since(started)))
	}
	splices := rt.stats.display_splice_count - splices_before
	internal_ns := rt.stats.display_splice_elapsed_ns - internal_before
	bytes_moved := rt.stats.display_splice_bytes_moved - bytes_before
	tail_nodes := rt.stats.display_splice_tail_nodes - tail_nodes_before
	tail_commands := rt.stats.display_splice_tail_commands - tail_commands_before
	testing.expectf(t, splices >= u64(2*(iterations-1)),
		"each focus move should splice the ring shrink and grow (%d splices)", splices)
	testing.expect(t, tail_nodes > 0 && bytes_moved > 0 && tail_commands > 0,
		"middle-of-list focus changes should move a following tail")

	for index in 0..<iterations {
		target := buttons[index%2]
		previous := rt.focused
		rt.focused = target
		rt.composition_rebuild = true
		if previous != 0 && previous != target {
			invalidate_interaction_paint(&rt, previous, "full cost focus loss")
		}
		if previous != target { invalidate_interaction_paint(&rt, target, "full cost focus gain") }
		started := time.now()
		_ = sparse_display_flush_presentation(&rt)
		full_update_ns[index] = i64(time.duration_nanoseconds(time.since(started)))
	}
	sparse_display_sort_i64(splice_update_ns[:])
	sparse_display_sort_i64(full_update_ns[:])
	splice_p50 := sparse_display_percentile_i64(splice_update_ns[:], 50)
	splice_p95 := sparse_display_percentile_i64(splice_update_ns[:], 95)
	full_p50 := sparse_display_percentile_i64(full_update_ns[:], 50)
	full_p95 := sparse_display_percentile_i64(full_update_ns[:], 95)
	fmt.printf("SPARSE_M2_BENCH fixture=rows%d updates=%d splice_update_p50_ns=%d splice_update_p95_ns=%d full_update_p50_ns=%d full_update_p95_ns=%d splices=%d internal_ns_per_update=%d bytes_moved_per_update=%d tail_nodes_per_update=%d tail_commands_per_update=%d\n",
		count, iterations, splice_p50, splice_p95, full_p50, full_p95, splices,
		internal_ns/u64(iterations), bytes_moved/u64(iterations),
		tail_nodes/u64(iterations), tail_commands/u64(iterations))
	testing.expect(t, internal_ns > 0, "splice timing must be recorded")
	// The deterministic splice counters above are host-independent. This
	// wall-clock ordering is only a release gate on the Windows reference host:
	// paravirtual macOS CI timing is too noisy to prove it (and is not the
	// platform the #228 capture measured).
	when ODIN_OS == .Windows {
		testing.expect(t, splice_p50 < full_p50,
			"the bounded-tail splice should be cheaper than a full rebuild of the same change")
	}

	// Late-node leg: the changed node is last, so the moved tail is empty at
	// every display size. This isolates fixup cost from display length.
	late_rt := new_runtime(Rect{0, 0, 560, 420})
	defer destroy_runtime(&late_rt)
	late_theme := style_theme_register(&late_rt, sparse_display_theme(0))
	sparse_display_tail_describe(&late_rt, late_theme, SPARSE_DISPLAY_TAIL_ROWS)
	late_buttons := make([]Node_ID, SPARSE_DISPLAY_TAIL_ROWS, allocator=late_rt.persistent_allocator)
	defer delete(late_buttons, late_rt.persistent_allocator)
	late_count := sparse_display_buttons(&late_rt, late_buttons)
	if late_count != SPARSE_DISPLAY_TAIL_ROWS {
		testing.expect(t, false, "late cost fixture should retain all buttons")
		return
	}
	late_rt.focus_visible = true
	last := late_buttons[late_count-1]
	late_splice_ns := make([]i64, iterations, allocator=late_rt.persistent_allocator)
	defer delete(late_splice_ns, late_rt.persistent_allocator)
	late_full_ns := make([]i64, iterations, allocator=late_rt.persistent_allocator)
	defer delete(late_full_ns, late_rt.persistent_allocator)
	late_tail_nodes_before := late_rt.stats.display_splice_tail_nodes
	for index in 0..<iterations {
		if index%2 == 0 { late_rt.focused = last } else { late_rt.focused = 0 }
		invalidate_interaction_paint(&late_rt, last, "late splice cost toggle")
		started := time.now()
		_ = sparse_display_flush_presentation(&late_rt)
		late_splice_ns[index] = i64(time.duration_nanoseconds(time.since(started)))
	}
	late_tail_nodes := late_rt.stats.display_splice_tail_nodes - late_tail_nodes_before
	testing.expect(t, late_tail_nodes == 0,
		"a last-node count change must not shift any following display_index")
	for index in 0..<iterations {
		if index%2 == 0 { late_rt.focused = last } else { late_rt.focused = 0 }
		late_rt.composition_rebuild = true
		invalidate_interaction_paint(&late_rt, last, "late full cost toggle")
		started := time.now()
		_ = sparse_display_flush_presentation(&late_rt)
		late_full_ns[index] = i64(time.duration_nanoseconds(time.since(started)))
	}
	sparse_display_sort_i64(late_splice_ns[:])
	sparse_display_sort_i64(late_full_ns[:])
	late_splice_p50 := sparse_display_percentile_i64(late_splice_ns[:], 50)
	late_full_p50 := sparse_display_percentile_i64(late_full_ns[:], 50)
	fmt.printf("SPARSE_M2_BENCH_LATE fixture=buttons%d updates=%d splice_update_p50_ns=%d full_update_p50_ns=%d tail_nodes=%d\n",
		late_count, iterations, late_splice_p50, late_full_p50, late_tail_nodes)
	when ODIN_OS == .Windows {
		testing.expect(t, late_splice_p50 < late_full_p50,
			"a late-node splice should be cheaper than a full rebuild of the same change")
	}
}
