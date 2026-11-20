package sdl3_live_resize

// The shared SDL3 live-resize core owns the host-side machinery every Alicorn
// renderer needs while the platform withholds ordinary event-loop turns:
//
//   * the SDL event watch that turns WINDOW_EXPOSED into a direct redraw,
//   * the Windows message hook that tracks WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE,
//   * the per-HWND timer that gives a modal move/size loop a rendering cadence,
//   * re-entrancy guards for both entry points, and
//   * the counters hosts publish as live-resize telemetry.
//
// Renderers keep their own frame policy. A host supplies Ops callbacks and the
// core decides when a slot is worth servicing. Native SDL_GPU and hosted
// SDL3/WebGPU both consume this package, so the mechanism is not duplicated.
//
// Threading: every callback runs on the SDL owner thread. The event watch is
// filtered to WINDOW_EXPOSED first so events delivered from producer threads
// never reach host state; SDL documents that exposure events can be redrawn
// directly from the watcher.

import "base:runtime"
import "vendor:sdl3"

// Slot identifies one independently schedulable host window. Both Alicorn SDL3
// hosts own a primary window and at most one secondary window.
Slot :: enum {
	Primary,
	Secondary,
}

SLOT_COUNT :: 2

SLOTS := [SLOT_COUNT]Slot{.Primary, .Secondary}

// MOVE_TIMER_ID and MOVE_TIMER_INTERVAL_MS mirror the reference host: one timer
// per moving HWND, at a display-like cadence, gives the Windows modal loop the
// same presentation opportunities an ordinary event loop turn would provide.
MOVE_TIMER_ID :: 0xA11C
MOVE_TIMER_INTERVAL_MS :: 17

// Cause names which live-resize entry point is driving a frame. Hosts use it for
// telemetry; the core uses it to attribute counters.
Cause :: enum {
	Expose,
	Timer,
}

// Ops is the renderer-side contract. All callbacks are optional; a core with no
// `render` callback still tracks move state and counters.
Ops :: struct {
	data: rawptr,
	// window returns the slot's live SDL window, or nil when the slot is unused.
	window: proc(data: rawptr, slot: Slot) -> ^sdl3.Window,
	// renderable reports whether the slot can present right now. The core calls
	// it only on the owner thread and never inside a host description.
	renderable: proc(data: rawptr, slot: Slot) -> bool,
	// has_work reports whether a modal-loop tick could advance retained work for
	// the slot. It gates timer installation and timer continuation.
	has_work: proc(data: rawptr, slot: Slot) -> bool,
	// render performs at most one bounded frame for the slot. It must be safe to
	// call when nothing is due; hosts return without presenting in that case.
	render: proc(data: rawptr, slot: Slot, now_ns: u64, cause: Cause),
}

Counters :: struct {
	// Expose entry point.
	expose_events: u64,
	expose_frames: u64,
	// Windows modal move/size loop entry point.
	move_enter_messages: u64,
	move_exit_messages: u64,
	move_timer_wakes: u64,
	move_position_messages: u64,
	move_position_changed_messages: u64,
	move_redraws: u64,
	move_primary_redraws: u64,
	move_secondary_redraws: u64,
	move_skipped_ticks: u64,
	// Re-entrancy guard observations.
	deferred_exposes: u64,
	deferred_timer_ticks: u64,
}

Slot_State :: struct {
	window: ^sdl3.Window,
	window_id: sdl3.WindowID,
	active: bool,
	// move_active tracks WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE for this slot;
	// move_timer_active records whether the shared move timer is running for it.
	move_active: bool,
	move_timer_active: bool,
	move_hwnd: rawptr,
}

// Core is a zero-initialized value the host owns for the window lifetime.
Core :: struct {
	active: bool,
	// rendering guards re-entrant expose/timer dispatch. SDL may deliver an
	// exposure from inside a GPU call that pumps events, so a nested dispatch
	// must be deferred rather than re-entering the host's frame path.
	rendering: bool,
	pending: bool,
	pending_slot: Slot,
	// timer_rendering is the Windows timer's own guard. A timer callback can be
	// re-entered by message pumping inside a present, which must not nest.
	timer_rendering: bool,
	slots: [SLOT_COUNT]Slot_State,
	ops: Ops,
	counters: Counters,
	windows_hook_installed: bool,
	event_watch_installed: bool,
}

// live_resize_now is the shared monotonic clock for the live-resize paths. It is
// SDL's tick clock, the same source the reference host and both schedulers use.
live_resize_now :: proc() -> u64 {
	return u64(sdl3.GetTicksNS())
}

slot_index :: proc(slot: Slot) -> int {
	switch slot {
	case .Primary: return 0
	case .Secondary: return 1
	}
	return -1
}

// live_resize_start activates the core around a host's Ops. It installs the SDL
// event watch and, on Windows, the message hook. Only one core may be active per
// process because SDL's Windows message hook is process-global.
live_resize_start :: proc(core: ^Core, ops: Ops) -> bool {
	if core == nil || core.active || ops.render == nil { return false }
	if global_core != nil && global_core != core { return false }
	core.ops = ops
	core.active = true
	if !sdl3.AddEventWatch(live_resize_event_watch, rawptr(core)) {
		core.active = false
		return false
	}
	core.event_watch_installed = true
	global_core = core
	when ODIN_OS == .Windows {
		if live_resize_windows_install(core) {
			core.windows_hook_installed = true
		}
	}
	return true
}

// live_resize_stop removes platform hooks and clears slot state. It is safe to
// call on a partially installed core and after the windows are destroyed.
live_resize_stop :: proc(core: ^Core) {
	if core == nil { return }
	when ODIN_OS == .Windows {
		live_resize_windows_remove(core)
	}
	core.windows_hook_installed = false
	core.active = false
	if core.event_watch_installed {
		sdl3.RemoveEventWatch(live_resize_event_watch, rawptr(core))
		core.event_watch_installed = false
	}
	for slot in SLOTS {
		core.slots[slot_index(slot)] = {}
	}
	if global_core == core { global_core = nil }
	core.rendering = false
	core.pending = false
	core.timer_rendering = false
}

// live_resize_set_window publishes a slot's current window identity. Hosts call
// it when a window is created, replaced after device recovery, or destroyed.
live_resize_set_window :: proc(core: ^Core, slot: Slot, window: ^sdl3.Window, active: bool) {
	if core == nil { return }
	index := slot_index(slot)
	if index < 0 { return }
	entry := &core.slots[index]
	if entry.window != window || entry.active != active {
		if !active { live_resize_stop_slot(core, slot) }
	}
	entry.window = window
	entry.active = active && window != nil
	entry.window_id = sdl3.GetWindowID(window) if entry.active else 0
}

// live_resize_clear_window retires a slot before its SDL window is destroyed so
// a pending timer can never target a dead HWND.
live_resize_clear_window :: proc(core: ^Core, slot: Slot) {
	if core == nil { return }
	index := slot_index(slot)
	if index < 0 { return }
	live_resize_stop_slot(core, slot)
	core.slots[index] = {}
}

live_resize_slot_active :: proc(core: ^Core, slot: Slot) -> bool {
	if core == nil { return false }
	index := slot_index(slot)
	return index >= 0 && core.slots[index].active
}

live_resize_slot_window :: proc(core: ^Core, slot: Slot) -> ^sdl3.Window {
	if core == nil { return nil }
	index := slot_index(slot)
	if index < 0 || !core.slots[index].active { return nil }
	if core.ops.window != nil {
		if window := core.ops.window(core.ops.data, slot); window != nil { return window }
	}
	return core.slots[index].window
}

live_resize_slot_for_window_id :: proc(core: ^Core, window_id: sdl3.WindowID) -> (Slot, bool) {
	if core == nil || window_id == 0 { return .Primary, false }
	for slot in SLOTS {
		entry := core.slots[slot_index(slot)]
		if entry.active && entry.window_id == window_id { return slot, true }
	}
	return .Primary, false
}

live_resize_renderable :: proc(core: ^Core, slot: Slot) -> bool {
	if core == nil || !core.active || !live_resize_slot_active(core, slot) { return false }
	if core.ops.renderable == nil { return true }
	return core.ops.renderable(core.ops.data, slot)
}

live_resize_slot_has_work :: proc(core: ^Core, slot: Slot) -> bool {
	if core == nil || !core.active || !live_resize_slot_active(core, slot) { return false }
	if core.ops.has_work == nil { return true }
	return core.ops.has_work(core.ops.data, slot)
}

// live_resize_has_work reports whether any live slot could advance inside a
// modal loop. The Windows timer is only installed while this is true.
live_resize_has_work :: proc(core: ^Core) -> bool {
	if core == nil || !core.active { return false }
	for slot in SLOTS {
		if live_resize_slot_has_work(core, slot) { return true }
	}
	return false
}

// live_resize_service performs one guarded frame dispatch for a slot. Nested
// dispatches set `pending` and are coalesced by the outer call, mirroring the
// reference host's bounded two-pass loop.
live_resize_service :: proc(core: ^Core, slot: Slot, now_ns: u64, cause: Cause) {
	if core == nil || !core.active || core.ops.render == nil { return }
	if !live_resize_slot_active(core, slot) { return }
	if core.rendering {
		core.pending = true
		core.pending_slot = slot
		if cause == .Expose { core.counters.deferred_exposes += 1 }
		else { core.counters.deferred_timer_ticks += 1 }
		return
	}
	core.rendering = true
	defer core.rendering = false
	serve_slot := slot
	for _ in 0..<2 {
		core.pending = false
		dispatch_time := now_ns if now_ns != 0 else live_resize_now()
		core.ops.render(core.ops.data, serve_slot, dispatch_time, cause)
		if !core.pending { return }
		serve_slot = core.pending_slot
	}
}

// live_resize_reconcile runs once per ordinary host-loop turn. The Windows modal
// pointer loop can consume WM_EXITSIZEMOVE before SDL's message hook observes
// it, so the first host turn after release is the bounded cleanup point.
live_resize_reconcile :: proc(core: ^Core) {
	if core == nil || !core.active { return }
	when ODIN_OS == .Windows {
		live_resize_windows_reconcile(core)
	}
}

// live_resize_stop_slot ends one slot's move participation and kills its timer.
live_resize_stop_slot :: proc(core: ^Core, slot: Slot) {
	if core == nil { return }
	index := slot_index(slot)
	if index < 0 { return }
	when ODIN_OS == .Windows {
		live_resize_windows_kill_timer(core, slot)
	}
	core.slots[index].move_timer_active = false
	core.slots[index].move_active = false
	core.slots[index].move_hwnd = nil
}

@(private)
global_core: ^Core

@(private)
live_resize_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	// The watcher runs on whichever thread pushes the event. Host state is only
	// touched for the one event SDL documents as safe to redraw from the watcher,
	// and that event is delivered on the main thread.
	context = runtime.default_context()
	if event == nil { return true }
	if event.type != .WINDOW_EXPOSED || event.window.data1 != 1 { return true }
	core := cast(^Core)userdata
	if core == nil || !core.active { return true }
	context = runtime.default_context()
	slot, found := live_resize_slot_for_window_id(core, event.window.windowID)
	if !found { return true }
	core.counters.expose_events += 1
	live_resize_service(core, slot, live_resize_now(), .Expose)
	return true
}

// live_resize_note_presented_frame lets a host count a frame it presented from an
// exposure dispatch. Hosted renderers call it after a successful present so the
// core can publish `expose_frames` without knowing the renderer's result type.
live_resize_note_presented_frame :: proc(core: ^Core, cause: Cause) {
	if core == nil { return }
	switch cause {
	case .Expose: core.counters.expose_frames += 1
	case .Timer:
	}
}
