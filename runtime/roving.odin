package alicorn

// Roving focus is a pure index model over a caller-owned item projection. It
// carries no runtime state, allocates nothing, and never mutates application
// state: a caller supplies a view of the current item set and asks where a
// navigation key proposes focus to go. The caller owns the focused index,
// selection policy, reveal requests, and invalidation.
//
// The view is a value. callers may rebuild it every frame because the item
// count, stride, disabled set, and pagination can all change. When membership
// shrinks, the model refuses to move an out-of-range current index; the caller
// re-clamps with roving_clamp and repairs focus with roving_nearest_enabled.
//
// columns <= 1 describes a linear list. A positive columns value describes a
// grid with that stride. The zero value of Roving_View is a linear,
// non-wrapping, all-enabled set, and grid consumers that stay close to the
// shipped icon-picker behavior pass only columns, page, and home_end=.Row.
Roving_View :: struct {
	// count is the number of logical items. It is caller-owned and may change
	// between calls.
	count:   int,
	// columns is the grid stride. Values <= 1 mean a linear list.
	columns: int,
	// enabled reports whether an item at an index may receive focus. A nil
	// callback means every item in range is enabled. The callback is borrowed
	// for the duration of one call and must not mutate the set.
	enabled: proc(data: rawptr, index: int) -> bool,
	data:    rawptr,
	// page is the number of items Page_Up/Page_Down traverse. Values <= 0
	// leave page moves without a proposal. In a grid a caller usually supplies
	// columns*visible_rows.
	page:    int,
	// wrap continues a move at the opposite end of the item set. For a grid
	// whose row_bounded is set, wrap also permits Left/Right to cross a row
	// edge, because the caller explicitly opted into wrap-around movement.
	wrap:    bool,
	// row_bounded stops Left/Right at the current row's edges instead of
	// crossing into the adjacent row. It only applies to grids and only while
	// wrap is false; Up/Down always move by the full stride.
	row_bounded: bool,
	// home_end selects whether Home/End target the row or the whole set. The
	// zero value targets the whole set.
	home_end: Roving_Home_End,
}

Roving_Home_End :: enum {
	All,
	Row,
}

Roving_Move :: enum {
	Left,
	Right,
	Up,
	Down,
	Page_Up,
	Page_Down,
	Home,
	End,
}

// roving_move_for_key maps the runtime's normalized navigation vocabulary to a
// roving move. Activation keys and editing keys stay outside the model: a
// caller decides how Return, Toggle, and text input affect its items.
roving_move_for_key :: proc(key: Application_Key) -> (move: Roving_Move, ok: bool) {
	#partial switch key {
	case .Left:
		return .Left, true
	case .Right:
		return .Right, true
	case .Up:
		return .Up, true
	case .Down:
		return .Down, true
	case .Page_Up:
		return .Page_Up, true
	case .Page_Down:
		return .Page_Down, true
	case .Home:
		return .Home, true
	case .End:
		return .End, true
	}
	return {}, false
}

// roving_move_for_text_key maps the normalized editing-navigation vocabulary
// delivered to a focused generic text target. Home/End here are document
// bounds; a roving consumer decides whether that means the row or the set.
roving_move_for_text_key :: proc(key: Application_Text_Navigation_Key) -> (move: Roving_Move, ok: bool) {
	#partial switch key {
	case .Left:
		return .Left, true
	case .Right:
		return .Right, true
	case .Up:
		return .Up, true
	case .Down:
		return .Down, true
	case .Page_Up:
		return .Page_Up, true
	case .Page_Down:
		return .Page_Down, true
	case .Home:
		return .Home, true
	case .End:
		return .End, true
	}
	return {}, false
}

// roving_index_valid reports whether index names an item in the current view.
roving_index_valid :: proc(view: Roving_View, index: int) -> bool {
	return index >= 0 && index < view.count
}

// roving_enabled reports whether an in-range index may receive focus. It
// returns false for an out-of-range index.
roving_enabled :: proc(view: Roving_View, index: int) -> bool {
	if !roving_index_valid(view, index) { return false }
	if view.enabled == nil { return true }
	return view.enabled(view.data, index)
}

// roving_clamp maps an index into the current item range without consulting
// the enabled policy. It returns -1 for an empty view. Callers re-clamp the
// application's focused index after the item count changes.
roving_clamp :: proc(view: Roving_View, index: int) -> int {
	if view.count <= 0 { return -1 }
	return clamp(index, 0, view.count-1)
}

// roving_first_enabled and roving_last_enabled return the first and last
// enabled index, or -1 when the set has no enabled item.
roving_first_enabled :: proc(view: Roving_View) -> int {
	return roving_scan(view, 0, 1, 0, view.count)
}

roving_last_enabled :: proc(view: Roving_View) -> int {
	return roving_scan(view, view.count-1, -1, 0, view.count)
}

// roving_first_enabled_from scans from a caller-supplied index in the given
// direction (positive or negative) and returns the first enabled index, or -1.
// The start index is clamped into the view; this is the repair search a caller
// uses when its stable item identity is still present but its old index is not.
roving_first_enabled_from :: proc(view: Roving_View, start: int, direction: int = 1) -> int {
	clamped := roving_clamp(view, start)
	if clamped < 0 { return -1 }
	return roving_scan(view, clamped, 1 if direction >= 0 else -1, 0, view.count)
}

// roving_nearest_enabled repairs a focus index after membership or disabled
// state changed. It returns the index itself when enabled, otherwise the
// nearest enabled index, preferring the requested direction. prefer must be
// positive or negative; zero is treated as forward. It returns -1 when no item
// is enabled.
roving_nearest_enabled :: proc(view: Roving_View, index: int, prefer: int = 1) -> int {
	start := roving_clamp(view, index)
	if start < 0 { return -1 }
	if roving_enabled(view, start) { return start }
	direction := 1 if prefer >= 0 else -1
	for distance in 1..=view.count {
		forward := start+distance*direction
		if roving_index_valid(view, forward) && roving_enabled(view, forward) { return forward }
		backward := start-distance*direction
		if roving_index_valid(view, backward) && roving_enabled(view, backward) { return backward }
	}
	return -1
}

// roving_propose returns the index a navigation move proposes, or -1 when the
// move is unavailable, the current index is outside the current view, or no
// enabled item lies in the direction of travel. The model never returns a
// disabled index and never returns the current index as a "move": callers
// treat -1 as "leave focus where it is".
//
// The contract for a grid mirrors the shipped icon-picker behavior:
//   - Left/Right move one index, Up/Down move one row (columns indices).
//   - moves stop at the set boundary unless wrap is set;
//   - a disabled landing index is skipped in the direction of travel;
//   - Home/End target the row or the whole set according to home_end;
//   - Page_Up/Page_Down move by page indices and are unavailable when page <= 0.
roving_propose :: proc(view: Roving_View, current: int, move: Roving_Move) -> int {
	if view.count <= 0 || !roving_index_valid(view, current) { return -1 }
	grid := view.columns > 1
	stride := view.columns if grid else 1
	result := -1
	switch move {
	case .Left:
		result = roving_step(view, current, -1, grid)
	case .Right:
		result = roving_step(view, current, 1, grid)
	case .Up:
		result = roving_step(view, current, -stride, false)
	case .Down:
		result = roving_step(view, current, stride, false)
	case .Page_Up:
		if view.page <= 0 { return -1 }
		result = roving_step(view, current, -view.page, false)
	case .Page_Down:
		if view.page <= 0 { return -1 }
		result = roving_step(view, current, view.page, false)
	case .Home:
		result = roving_home(view, current)
	case .End:
		result = roving_end(view, current)
	}
	if result == current { return -1 }
	return result
}

@(private)
roving_scan :: proc(view: Roving_View, start, direction, lower, upper: int) -> int {
	for index := start; index >= lower && index < upper; index += direction {
		if roving_enabled(view, index) { return index }
	}
	return -1
}

@(private)
roving_step :: proc(view: Roving_View, current, delta: int, horizontal_grid: bool) -> int {
	if delta == 0 { return -1 }
	direction := 1 if delta > 0 else -1
	row_locked := horizontal_grid && view.row_bounded && !view.wrap
	target := current+delta
	if row_locked {
		first := (current/view.columns)*view.columns
		last := min(first+view.columns, view.count)
		if target < first || target >= last { return -1 }
		return roving_scan(view, target, direction, first, last)
	}
	if target < 0 || target >= view.count {
		if !view.wrap { return -1 }
		target = ((target%view.count)+view.count)%view.count
	}
	if view.wrap {
		index := target
		for _ in 0..<view.count {
			if index < 0 { index += view.count }
			if index >= view.count { index -= view.count }
			if roving_enabled(view, index) { return index }
			index += direction
		}
		return -1
	}
	return roving_scan(view, target, direction, 0, view.count)
}

@(private)
roving_home :: proc(view: Roving_View, current: int) -> int {
	if view.columns > 1 && view.home_end == .Row {
		first := (current/view.columns)*view.columns
		// Mirror the shipped grid policy: search forward from the row start,
		// then fall back to the nearest enabled item before it. This keeps Home
		// useful when the active row begins with a disabled run.
		if index := roving_scan(view, first, 1, 0, view.count); index >= 0 { return index }
		return roving_scan(view, first, -1, 0, view.count)
	}
	return roving_first_enabled(view)
}

@(private)
roving_end :: proc(view: Roving_View, current: int) -> int {
	if view.columns > 1 && view.home_end == .Row {
		first := (current/view.columns)*view.columns
		last := min(first+view.columns, view.count)-1
		// Mirror the grid policy: last enabled at or before the row end, then
		// the nearest enabled item after it when the row tail is disabled.
		if index := roving_scan(view, last, -1, 0, view.count); index >= 0 { return index }
		return roving_scan(view, last+1, 1, 0, view.count)
	}
	return roving_last_enabled(view)
}
