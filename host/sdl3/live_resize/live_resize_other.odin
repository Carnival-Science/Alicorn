#+build !windows

package sdl3_live_resize

// Non-Windows platforms have no modal move loop to hook. macOS delivers exposure
// events from Cocoa's live-resize session, which the shared event watch already
// services; Linux compositors resize interactively outside the application. The
// core keeps the same API so hosts do not branch per platform.

live_resize_windows_install :: proc(core: ^Core) -> bool {
	return core != nil
}

live_resize_windows_remove :: proc(_core: ^Core) {}

live_resize_windows_reconcile :: proc(_core: ^Core) {}

live_resize_windows_kill_timer :: proc(_core: ^Core, _slot: Slot) {}
