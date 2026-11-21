#+build windows

package sdl3_live_resize

// Windows-only tests for the modal-loop message timestamp the hosted presenter
// uses to report geometry-to-present age. The hook runs on the owner thread
// during a real drag; these tests drive it with synthetic WINDOWPOS messages so
// the size gating is pinned without a platform window. The stamp's value comes
// from SDL's tick clock, which is not initialized in this headless package, so
// the test asserts assignment/gating rather than a nonzero wall time.

import "core:testing"
import win "core:sys/windows"

@(test)
test_geometry_message_timestamp_tracks_size_changes_only :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	entry := &core.slots[slot_index(.Primary)]
	entry.move_active = true
	entry.move_hwnd = rawptr(uintptr(1))

	hwnd := transmute(win.HWND)uintptr(1)
	position := win.WINDOWPOS{hwnd=hwnd, cx=800, cy=600}
	message := win.MSG{
		hwnd=hwnd,
		message=win.WM_WINDOWPOSCHANGED,
		lParam=win.LPARAM(uintptr(&position)),
	}

	_ = live_resize_windows_message_hook(rawptr(&core), &message)
	testing.expect(t, entry.geometry_message_cx == 800 && entry.geometry_message_cy == 600,
		"the first size-changing window position is recorded for the slot")

	live_resize_clear_geometry_message_ns(&core, .Primary)
	entry.geometry_message_ns = 7
	_ = live_resize_windows_message_hook(rawptr(&core), &message)
	testing.expect_value(t, entry.geometry_message_ns, u64(7))
	testing.expect(t, core.counters.move_position_changed_messages == 2,
		"a pure move still counts as a position change")

	position.cx = 900
	_ = live_resize_windows_message_hook(rawptr(&core), &message)
	testing.expect(t, entry.geometry_message_cx == 900 && entry.geometry_message_ns != 7,
		"a new outer size stamps the geometry message again")
}
