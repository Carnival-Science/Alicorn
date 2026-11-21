package alicorn_sdl_gpu

// The Windows modal move/size machinery lives in the shared SDL3 host layer
// (host/sdl3/live_resize): the message hook, the per-HWND timer, the SDL event
// watch, and the re-entrancy guards are the same code the hosted SDL3/WebGPU
// host runs. This file only adapts the reference renderer to that core and
// publishes its telemetry under the historical field names.

import alicorn "../../runtime"
import sdl3_file_drag "alicorn:host/sdl3/file_drag"
import live_resize "alicorn:host/sdl3/live_resize"
import "vendor:sdl3"

// active_live_resize_state lets the secondary-window teardown path retire its
// slot before the SDL window is destroyed. There is one core per process, so a
// single borrow is sufficient and mirrors SDL's process-global message hook.
active_live_resize_state: ^Native_Live_Resize_State

// native_live_resize_slot_window resolves the SDL window a shared-core slot
// refers to in this host's ownership model.
native_live_resize_slot_window :: proc(state: ^Native_Live_Resize_State, slot: live_resize.Slot) -> ^sdl3.Window {
	if state == nil { return nil }
	switch slot {
	case .Primary:
		return state.window
	case .Secondary:
		if state.secondary_manager == nil { return nil }
		child := state.secondary_manager.child
		if child == nil || !child.active { return nil }
		return child.window
	}
	return nil
}

native_live_resize_slot_renderable :: proc(state: ^Native_Live_Resize_State, slot: live_resize.Slot) -> bool {
	// A native file drag owns a modal OLE loop on this thread. The application
	// is suspended inside its own pointer callback; do not re-enter its
	// retained description from a live-resize timer. Same guard as the hosted
	// SDL3/WebGPU live-resize adapter.
	if sdl3_file_drag.is_active() { return false }
	window := native_live_resize_slot_window(state, slot)
	if window == nil { return false }
	flags := sdl3.GetWindowFlags(window)
	if !native_motion_window_renderable_for_window(window, flags) { return false }
	if slot == .Secondary {
		child := state.secondary_manager.child
		if child == nil { return false }
		return !child.presentation_suspended
	}
	return true
}

native_live_resize_slot_has_work :: proc(state: ^Native_Live_Resize_State, slot: live_resize.Slot) -> bool {
	if state == nil || !native_live_resize_slot_renderable(state, slot) { return false }
	window := native_live_resize_slot_window(state, slot)
	if window == nil { return false }
	flags := sdl3.GetWindowFlags(window)
	switch slot {
	case .Primary:
		if state.rt == nil || state.motion_scheduler_state == nil { return false }
		activity := alicorn.motion_activity(state.rt)
		return native_motion_scheduler_has_renderable_work(state.motion_scheduler_state, activity.active_owners, true)
	case .Secondary:
		child := state.secondary_manager.child
		if child == nil || child.runtime == nil { return false }
		activity := alicorn.motion_activity(child.runtime)
		return native_motion_scheduler_has_renderable_work(&child.motion_scheduler, activity.active_owners, true)
	}
	return false
}

// native_live_resize_slot_render is the shared core's render callback. It keeps
// the reference host's policy: a timer tick only samples when the retained
// motion scheduler is due, while an exposure always rebuilds and presents.
native_live_resize_slot_render :: proc(
	data: rawptr,
	slot: live_resize.Slot,
	now_ns: u64,
	cause: live_resize.Cause,
) {
	state := cast(^Native_Live_Resize_State)data
	if state == nil || !state.active { return }
	switch slot {
	case .Primary:
		native_live_resize_present_if_due(state, .Primary, nil, now_ns, cause)
	case .Secondary:
		child := state.secondary_manager.child if state.secondary_manager != nil else nil
		if child == nil || !child.active { return }
		native_live_resize_present_if_due(state, .Secondary, child, now_ns, cause)
	}
}

native_live_resize_ops :: proc(state: ^Native_Live_Resize_State) -> live_resize.Ops {
	return live_resize.Ops{
		data=rawptr(state),
		window=native_live_resize_slot_window_ops,
		renderable=native_live_resize_slot_renderable_ops,
		has_work=native_live_resize_slot_has_work_ops,
		render=native_live_resize_slot_render,
	}
}

native_live_resize_slot_window_ops :: proc(data: rawptr, slot: live_resize.Slot) -> ^sdl3.Window {
	return native_live_resize_slot_window(cast(^Native_Live_Resize_State)data, slot)
}

native_live_resize_slot_renderable_ops :: proc(data: rawptr, slot: live_resize.Slot) -> bool {
	return native_live_resize_slot_renderable(cast(^Native_Live_Resize_State)data, slot)
}

native_live_resize_slot_has_work_ops :: proc(data: rawptr, slot: live_resize.Slot) -> bool {
	return native_live_resize_slot_has_work(cast(^Native_Live_Resize_State)data, slot)
}

// native_live_resize_install starts the shared core around this host's windows.
// It replaces the host's own event watch and Windows message hook.
native_live_resize_install :: proc(state: ^Native_Live_Resize_State) -> bool {
	if state == nil { return false }
	if !live_resize.live_resize_start(&state.core, native_live_resize_ops(state)) { return false }
	live_resize.live_resize_set_window(&state.core, .Primary, state.window, state.window != nil)
	active_live_resize_state = state
	return true
}

native_live_resize_release :: proc(state: ^Native_Live_Resize_State) {
	if state == nil { return }
	live_resize.live_resize_stop(&state.core)
	if active_live_resize_state == state { active_live_resize_state = nil }
}

// native_live_resize_sync_windows republishes slot identity after a secondary
// window opens or closes.
native_live_resize_sync_windows :: proc(state: ^Native_Live_Resize_State) {
	if state == nil { return }
	live_resize.live_resize_set_window(
		&state.core, .Primary, state.window, state.window != nil && state.active,
	)
	child_window: ^sdl3.Window
	child_live := false
	if state.secondary_manager != nil {
		child := state.secondary_manager.child
		if child != nil && child.active {
			child_window = child.window
			child_live = child.window != nil
		}
	}
	live_resize.live_resize_set_window(&state.core, .Secondary, child_window, child_live)
}

native_live_resize_reconcile :: proc(state: ^Native_Live_Resize_State) {
	if state == nil { return }
	live_resize.live_resize_reconcile(&state.core)
}

// native_live_resize_present_if_due is the reference renderer's per-window live
// frame. Exposure dispatches always rebuild and present; timer dispatches only
// sample when the retained motion scheduler is due, matching the pre-extraction
// host. Suspension handling stays here because it is renderer policy.
native_live_resize_present_if_due :: proc(
	state: ^Native_Live_Resize_State,
	target: live_resize.Slot,
	child: ^Native_Secondary_Window,
	now_ns: u64,
	cause: live_resize.Cause,
) {
	if state == nil { return }
	scheduler := native_live_resize_slot_scheduler(state, target, child)
	rt := native_live_resize_slot_runtime(state, target, child)
	window := state.window if target == .Primary else child.window if target == .Secondary && child != nil else nil
	if scheduler == nil || rt == nil || window == nil { return }
	flags := sdl3.GetWindowFlags(window)
	window_renderable := native_motion_window_renderable_for_window(window, flags)
	activity := alicorn.motion_activity(rt)
	if target == .Secondary && child != nil {
		// The outer SDL event loop may be blocked, so native flags are the current
		// visibility source when a sibling is minimized or restored mid-drag.
		child.presentation_suspended = !window_renderable
	}
	if cause == .Timer && !native_motion_scheduler_service_due(scheduler, activity.active_owners, window_renderable, now_ns) {
		return
	}
	if !window_renderable {
		update := native_live_resize_motion_advance(
			scheduler, rt, native_live_resize_slot_timing(state, target, child),
			false, now_ns, flags, sdl3.GetWindowID(window),
			native_motion_window_native_minimized(window), state.motion_breadcrumbs,
		)
		if update.status != .Ok { fail("retained motion suspension during Windows move failed") }
		return
	}
	before_samples := scheduler.stats.samples
	before_submissions := u64(0)
	if target == .Primary { before_submissions = state.timing.gpu_submissions }
	else if child != nil { before_submissions = child.timing.gpu_submissions }
	if target == .Primary { native_live_resize_redraw(state) }
	else if target == .Secondary {
		native_secondary_window_live_resize_redraw(state.secondary_manager, child, request_presentation=false)
	}
	after_samples := scheduler.stats.samples
	after_submissions := before_submissions
	if target == .Primary { after_submissions = state.timing.gpu_submissions }
	else if child != nil { after_submissions = child.timing.gpu_submissions }
	sample_delta := after_samples-before_samples
	submission_delta := after_submissions-before_submissions
	if cause == .Expose {
		state.live_resize_motion_samples += sample_delta
		state.live_resize_gpu_submissions += submission_delta
	} else {
		state.windows_move_motion_samples += sample_delta
		state.windows_move_gpu_submissions += submission_delta
		if target == .Primary {
			state.windows_move_primary_motion_samples += sample_delta
			state.windows_move_primary_gpu_submissions += submission_delta
		} else {
			state.windows_move_secondary_motion_samples += sample_delta
			state.windows_move_secondary_gpu_submissions += submission_delta
		}
	}
}

native_live_resize_slot_scheduler :: proc(
	state: ^Native_Live_Resize_State,
	target: live_resize.Slot,
	child: ^Native_Secondary_Window,
) -> ^Native_Motion_Scheduler_State {
	if target == .Primary { return state.motion_scheduler_state }
	if target == .Secondary && child != nil { return &child.motion_scheduler }
	return nil
}

native_live_resize_slot_runtime :: proc(
	state: ^Native_Live_Resize_State,
	target: live_resize.Slot,
	child: ^Native_Secondary_Window,
) -> ^alicorn.Runtime {
	if target == .Primary { return state.rt }
	if target == .Secondary && child != nil { return child.runtime }
	return nil
}

native_live_resize_slot_timing :: proc(
	state: ^Native_Live_Resize_State,
	target: live_resize.Slot,
	child: ^Native_Secondary_Window,
) -> ^Native_Host_Timing {
	if target == .Primary { return state.timing }
	if target == .Secondary && child != nil { return &child.timing }
	return nil
}

native_live_resize_secondary_destroy :: proc(child: ^Native_Secondary_Window) {
	if child == nil { return }
	state := active_live_resize_state
	if state == nil { return }
	live_resize.live_resize_clear_window(&state.core, .Secondary)
}
