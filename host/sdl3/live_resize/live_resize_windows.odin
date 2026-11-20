#+build windows

package sdl3_live_resize

// Windows modal move/size loop support. The platform enters a nested modal loop
// for a pointer drag on a caption or frame edge; SDL's ordinary event pump does
// not run until the drag ends, so the host would otherwise present the last
// pre-drag frame at the new size. The message hook tracks the modal loop, and a
// per-HWND timer re-enters the host's frame path at a display-like cadence while
// the left button is held.

import "base:runtime"
import "vendor:sdl3"
import win "core:sys/windows"

live_resize_windows_install :: proc(core: ^Core) -> bool {
	if core == nil { return false }
	// The hook is process-global and window-independent: WM_ENTERSIZEMOVE names
	// the HWND, and slots are resolved lazily so a host may publish its windows
	// after installing.
	sdl3.SetWindowsMessageHook(live_resize_windows_message_hook, rawptr(core))
	return true
}

live_resize_windows_remove :: proc(core: ^Core) {
	if core == nil { return }
	for slot in SLOTS {
		live_resize_windows_kill_timer(core, slot)
	}
	sdl3.SetWindowsMessageHook(nil, nil)
}

live_resize_windows_reconcile :: proc(core: ^Core) {
	if core == nil { return }
	if win.GetAsyncKeyState(win.VK_LBUTTON) >= 0 {
		for slot in SLOTS {
			if core.slots[slot_index(slot)].move_active {
				live_resize_stop_slot(core, slot)
			}
		}
	}
}

live_resize_windows_message_hook :: proc "c" (userdata: rawptr, message: ^win.MSG) -> bool {
	context = runtime.default_context()
	core := cast(^Core)userdata
	if core == nil || !core.active || message == nil { return true }
	switch message.message {
	case win.WM_ENTERSIZEMOVE:
		slot, found := live_resize_windows_slot_for_hwnd(core, message.hwnd)
		if !found { return true }
		live_resize_windows_begin_move(core, slot, message.hwnd)
	case win.WM_EXITSIZEMOVE:
		slot, found := live_resize_windows_slot_for_hwnd(core, message.hwnd)
		if !found { return true }
		core.counters.move_exit_messages += 1
		live_resize_stop_slot(core, slot)
	case win.WM_MOVING:
		for slot in SLOTS {
			if live_resize_windows_move_hwnd(core, slot) == rawptr(message.hwnd) &&
			   core.slots[slot_index(slot)].move_active {
				core.counters.move_position_messages += 1
			}
		}
	case win.WM_WINDOWPOSCHANGED:
		for slot in SLOTS {
			if live_resize_windows_move_hwnd(core, slot) == rawptr(message.hwnd) &&
			   core.slots[slot_index(slot)].move_active {
				core.counters.move_position_changed_messages += 1
			}
		}
		live_resize_windows_ensure_timer(core)
	case win.WM_SIZE, win.WM_SHOWWINDOW:
		live_resize_windows_ensure_timer(core)
	}
	return true
}

live_resize_windows_begin_move :: proc(core: ^Core, slot: Slot, hwnd: win.HWND) {
	if core == nil || hwnd == nil { return }
	index := slot_index(slot)
	if index < 0 { return }
	core.counters.move_enter_messages += 1
	core.slots[index].move_active = true
	core.slots[index].move_hwnd = rawptr(hwnd)
	// Keyboard-driven system-menu moves keep ordinary event semantics. The live
	// timer exists specifically for a visible pointer drag, where the modal loop
	// otherwise withholds host turns.
	if win.GetAsyncKeyState(win.VK_LBUTTON) >= 0 { return }
	live_resize_windows_ensure_timer(core)
}

live_resize_windows_ensure_timer :: proc(core: ^Core) {
	if core == nil || !core.active { return }
	if win.GetAsyncKeyState(win.VK_LBUTTON) >= 0 { return }
	slot, found := live_resize_windows_active_move_slot(core)
	if !found { return }
	if core.slots[slot_index(slot)].move_timer_active { return }
	if !live_resize_has_work(core) { return }
	hwnd := cast(win.HWND)live_resize_windows_move_hwnd(core, slot)
	if hwnd == nil { return }
	timer_id := win.SetTimer(hwnd, win.UINT_PTR(MOVE_TIMER_ID),
		win.UINT(MOVE_TIMER_INTERVAL_MS), live_resize_windows_timer_proc)
	if timer_id != 0 { core.slots[slot_index(slot)].move_timer_active = true }
}

live_resize_windows_timer_proc :: proc "system" (
	hwnd: win.HWND,
	message: win.UINT,
	timer_id: win.UINT_PTR,
	_tick: win.DWORD,
) {
	context = runtime.default_context()
	if message != win.WM_TIMER || timer_id != win.UINT_PTR(MOVE_TIMER_ID) { return }
	core := global_core
	if core == nil || !core.active { return }
	slot, found := live_resize_windows_slot_for_hwnd(core, hwnd)
	if !found || !core.slots[slot_index(slot)].move_active { return }
	core.counters.move_timer_wakes += 1
	if win.GetAsyncKeyState(win.VK_LBUTTON) >= 0 {
		live_resize_stop_slot(core, slot)
		return
	}
	if core.timer_rendering {
		core.counters.deferred_timer_ticks += 1
		return
	}
	core.timer_rendering = true
	defer core.timer_rendering = false
	now_ns := live_resize_now()
	for target in SLOTS {
		if !live_resize_slot_active(core, target) { continue }
		if !live_resize_slot_has_work(core, target) {
			core.counters.move_skipped_ticks += 1
			continue
		}
		core.counters.move_redraws += 1
		switch target {
		case .Primary: core.counters.move_primary_redraws += 1
		case .Secondary: core.counters.move_secondary_redraws += 1
		}
		live_resize_service(core, target, now_ns, .Timer)
	}
	if !live_resize_has_work(core) {
		// Retain move identity for WM_EXITSIZEMOVE/release cleanup, but stop
		// timer wakes as soon as every visible slot has settled.
		live_resize_windows_kill_timer(core, slot)
	}
}

live_resize_windows_kill_timer :: proc(core: ^Core, slot: Slot) {
	if core == nil { return }
	index := slot_index(slot)
	if index < 0 { return }
	if core.slots[index].move_timer_active {
		if hwnd := cast(win.HWND)live_resize_windows_move_hwnd(core, slot); hwnd != nil {
			_ = win.KillTimer(hwnd, win.UINT_PTR(MOVE_TIMER_ID))
		}
	}
	core.slots[index].move_timer_active = false
}

live_resize_windows_active_move_slot :: proc(core: ^Core) -> (Slot, bool) {
	if core == nil { return .Primary, false }
	if core.slots[slot_index(.Primary)].move_active { return .Primary, true }
	if core.slots[slot_index(.Secondary)].move_active { return .Secondary, true }
	return .Primary, false
}

live_resize_windows_slot_for_hwnd :: proc(core: ^Core, hwnd: win.HWND) -> (Slot, bool) {
	if core == nil || hwnd == nil { return .Primary, false }
	for slot in SLOTS {
		if live_resize_windows_move_hwnd(core, slot) == rawptr(hwnd) { return slot, true }
	}
	return .Primary, false
}

live_resize_windows_move_hwnd :: proc(core: ^Core, slot: Slot) -> rawptr {
	if core == nil { return nil }
	index := slot_index(slot)
	if index < 0 { return nil }
	if recorded := core.slots[index].move_hwnd; recorded != nil { return recorded }
	hwnd, found := live_resize_windows_slot_for_window(core, slot)
	if !found { return nil }
	return rawptr(hwnd)
}

live_resize_windows_slot_for_window :: proc(core: ^Core, slot: Slot) -> (win.HWND, bool) {
	window := live_resize_slot_window(core, slot)
	if window == nil { return nil, false }
	properties := sdl3.GetWindowProperties(window)
	hwnd := cast(win.HWND)sdl3.GetPointerProperty(properties, sdl3.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	return hwnd, hwnd != nil
}
