#+build !js

package alicorn

import "core:testing"

@(private)
roving_test_enabled :: proc(data: rawptr, index: int) -> bool {
	disabled := cast(^[16]bool)data
	return !disabled[index]
}

@(private)
roving_test_view :: proc(disabled: ^[16]bool, count: int, columns := 0) -> Roving_View {
	return Roving_View{
		count=count,
		columns=columns,
		enabled=roving_test_enabled,
		data=rawptr(disabled),
	}
}

@(test)
test_roving_linear_moves_stop_at_boundaries_unless_wrapped :: proc(t: ^testing.T) {
	disabled: [16]bool
	view := roving_test_view(&disabled, 4)
	testing.expect_value(t, roving_propose(view, 0, .Down), 1)
	testing.expect_value(t, roving_propose(view, 3, .Down), -1)
	testing.expect_value(t, roving_propose(view, 0, .Up), -1)
	testing.expect_value(t, roving_propose(view, 2, .Left), 1)
	testing.expect_value(t, roving_propose(view, 2, .Right), 3)
	testing.expect_value(t, roving_propose(view, 2, .Page_Down), -1)

	wrapped := view
	wrapped.wrap = true
	testing.expect_value(t, roving_propose(wrapped, 3, .Down), 0)
	testing.expect_value(t, roving_propose(wrapped, 0, .Up), 3)
	testing.expect_value(t, roving_propose(wrapped, 0, .Left), 3)
}

@(test)
test_roving_skips_disabled_items_in_travel_direction :: proc(t: ^testing.T) {
	disabled: [16]bool
	disabled[2] = true
	disabled[3] = true
	view := roving_test_view(&disabled, 6)
	testing.expect_value(t, roving_propose(view, 1, .Down), 4)
	testing.expect_value(t, roving_propose(view, 4, .Up), 1)
	testing.expect_value(t, roving_propose(view, 1, .Right), 4)
	testing.expect_value(t, roving_last_enabled(view), 5)
	testing.expect_value(t, roving_first_enabled(view), 0)
	testing.expect_value(t, roving_first_enabled_from(view, 2, 1), 4)
	testing.expect_value(t, roving_first_enabled_from(view, 2, -1), 1)
	testing.expect_value(t, roving_first_enabled_from(view, 9, 1), 5)

	// Wrap skips the disabled run at the end as well.
	wrapped := view
	wrapped.wrap = true
	testing.expect_value(t, roving_propose(wrapped, 5, .Down), 0)
	testing.expect_value(t, roving_propose(wrapped, 0, .Up), 5)
}

@(test)
test_roving_grid_uses_stride_and_crosses_rows_by_default :: proc(t: ^testing.T) {
	disabled: [16]bool
	view := roving_test_view(&disabled, 10, 4)
	testing.expect_value(t, roving_propose(view, 1, .Down), 5)
	testing.expect_value(t, roving_propose(view, 5, .Up), 1)
	testing.expect_value(t, roving_propose(view, 1, .Right), 2)
	// The reference grid behavior crosses a row edge for Left/Right.
	testing.expect_value(t, roving_propose(view, 4, .Left), 3)
	testing.expect_value(t, roving_propose(view, 3, .Right), 4)
	// Up/Down stop at the item boundary rather than clamping into the row.
	testing.expect_value(t, roving_propose(view, 8, .Down), -1)
	testing.expect_value(t, roving_propose(view, 1, .Up), -1)
}

@(test)
test_roving_grid_row_bounds_clamp_horizontal_moves :: proc(t: ^testing.T) {
	disabled: [16]bool
	view := Roving_View{
		count=10,
		columns=4,
		enabled=roving_test_enabled,
		data=rawptr(&disabled),
		row_bounded=true,
	}
	testing.expect_value(t, roving_propose(view, 0, .Left), -1)
	testing.expect_value(t, roving_propose(view, 3, .Right), -1)
	testing.expect_value(t, roving_propose(view, 0, .Right), 1)
	testing.expect_value(t, roving_propose(view, 4, .Left), -1)
	// Up/Down remain stride moves even when rows are bounded.
	testing.expect_value(t, roving_propose(view, 4, .Down), 8)

	// An explicit wrap policy lets Left cross to the previous row's end.
	wrapped := view
	wrapped.wrap = true
	testing.expect_value(t, roving_propose(wrapped, 4, .Left), 3)
	testing.expect_value(t, roving_propose(wrapped, 0, .Left), 9)
}

@(test)
test_roving_grid_row_bounds_skip_disabled_within_the_row :: proc(t: ^testing.T) {
	disabled: [16]bool
	disabled[1] = true
	view := Roving_View{
		count=8,
		columns=4,
		enabled=roving_test_enabled,
		data=rawptr(&disabled),
		row_bounded=true,
	}
	testing.expect_value(t, roving_propose(view, 0, .Right), 2)
	testing.expect_value(t, roving_propose(view, 2, .Left), 0)
	// No enabled item remains between 2 and the row end, so focus stays.
	disabled[3] = true
	testing.expect_value(t, roving_propose(view, 2, .Right), -1)
}

@(test)
test_roving_home_and_end_choose_row_or_whole_set :: proc(t: ^testing.T) {
	disabled: [16]bool
	disabled[0] = true
	disabled[6] = true
	global := roving_test_view(&disabled, 10, 4)
	testing.expect_value(t, roving_propose(global, 5, .Home), 1)
	testing.expect_value(t, roving_propose(global, 5, .End), 9)

	row := global
	row.home_end = .Row
	// Row 1 is indices 4..7; index 6 is disabled, so End is 7.
	testing.expect_value(t, roving_propose(row, 5, .Home), 4)
	testing.expect_value(t, roving_propose(row, 5, .End), 7)

	// A fully disabled row falls back across the surrounding set, matching the
	// shipped icon-picker policy: Home searches forward first, End backward.
	disabled[4] = true
	disabled[5] = true
	disabled[7] = true
	testing.expect_value(t, roving_propose(row, 4, .Home), 8)
	testing.expect_value(t, roving_propose(row, 4, .End), 3)
}

@(test)
test_roving_page_moves_require_a_page_and_follow_stride :: proc(t: ^testing.T) {
	disabled: [16]bool
	view := roving_test_view(&disabled, 20)
	view.page = 5
	testing.expect_value(t, roving_propose(view, 2, .Page_Down), 7)
	testing.expect_value(t, roving_propose(view, 7, .Page_Up), 2)
	testing.expect_value(t, roving_propose(view, 18, .Page_Down), -1)
	view.wrap = true
	testing.expect_value(t, roving_propose(view, 18, .Page_Down), 3)
}

@(test)
test_roving_membership_changes_are_caller_owned :: proc(t: ^testing.T) {
	disabled: [16]bool
	view := roving_test_view(&disabled, 4)
	testing.expect_value(t, roving_clamp(view, 9), 3)
	testing.expect_value(t, roving_nearest_enabled(view, 9), 3)

	// Shrinking the set invalidates the old current index; the model refuses a
	// move and the caller re-clamps and repairs.
	view.count = 2
	testing.expect_value(t, roving_propose(view, 3, .Down), -1)
	testing.expect_value(t, roving_clamp(view, 3), 1)
	testing.expect_value(t, roving_nearest_enabled(view, 3), 1)

	// Growing the set makes the previously clamped index navigable again.
	view.count = 5
	testing.expect_value(t, roving_propose(view, 1, .Down), 2)
	testing.expect_value(t, roving_first_enabled(view), 0)
	testing.expect_value(t, roving_last_enabled(view), 4)
}

@(test)
test_roving_empty_single_and_all_disabled_sets :: proc(t: ^testing.T) {
	disabled: [16]bool
	empty := roving_test_view(&disabled, 0)
	testing.expect_value(t, roving_clamp(empty, 0), -1)
	testing.expect_value(t, roving_nearest_enabled(empty, 0), -1)
	testing.expect_value(t, roving_propose(empty, 0, .Home), -1)
	testing.expect_value(t, roving_first_enabled(empty), -1)

	single := roving_test_view(&disabled, 1)
	testing.expect_value(t, roving_propose(single, 0, .Down), -1)
	testing.expect_value(t, roving_propose(single, 0, .Home), -1)

	for index in 0..<6 { disabled[index] = true }
	blocked := roving_test_view(&disabled, 6)
	testing.expect_value(t, roving_first_enabled(blocked), -1)
	testing.expect_value(t, roving_last_enabled(blocked), -1)
	testing.expect_value(t, roving_nearest_enabled(blocked, 2), -1)
	testing.expect_value(t, roving_propose(blocked, 2, .Down), -1)
	blocked.wrap = true
	testing.expect_value(t, roving_propose(blocked, 2, .Down), -1)
}

@(test)
test_roving_nil_predicate_enables_every_item :: proc(t: ^testing.T) {
	view := Roving_View{count=3, columns=2}
	testing.expect(t, roving_enabled(view, 0) && roving_enabled(view, 2), "nil predicate enables every item")
	testing.expect(t, !roving_enabled(view, 3), "out-of-range indexes are never enabled")
	testing.expect_value(t, roving_propose(view, 0, .Down), 2)
	testing.expect_value(t, roving_propose(view, 0, .Home), -1)
}

@(test)
test_roving_move_for_key_maps_navigation_only :: proc(t: ^testing.T) {
	cases := [8]struct{ key: Application_Key, move: Roving_Move }{
		{.Left, .Left},
		{.Right, .Right},
		{.Up, .Up},
		{.Down, .Down},
		{.Page_Up, .Page_Up},
		{.Page_Down, .Page_Down},
		{.Home, .Home},
		{.End, .End},
	}
	for entry in cases {
		move, ok := roving_move_for_key(entry.key)
		testing.expect(t, ok && move == entry.move, "every navigation key maps to its move")
	}
	_, ok := roving_move_for_key(.Return)
	testing.expect(t, !ok, "activation keys are outside the roving model")
	_, ok = roving_move_for_key(.Toggle)
	testing.expect(t, !ok, "toggle remains an activation decision for the caller")
	text_move, text_ok := roving_move_for_text_key(.Down)
	testing.expect(t, text_ok && text_move == .Down, "text navigation keys map through the same vocabulary")
	_, text_ok = roving_move_for_text_key(.Backspace)
	testing.expect(t, !text_ok, "editing keys stay with the text owner")
}
