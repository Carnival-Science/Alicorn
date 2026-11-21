#+build !js

package sdl3_host

// Hosted live resize and window movement.
//
// While Windows runs its modal move/size loop, ordinary SDL event turns stop:
// the host blocks inside WaitEventTimeout, so the window would keep showing the
// frame captured when the drag started, stretched into the new size. The shared
// live-resize core (host/sdl3/live_resize) re-enters this host from the platform
// loop: exposure events redraw directly, and the per-HWND move timer provides a
// 60 Hz presentation opportunity while the pointer is held.
//
// Both entry points run through sdl3_webgpu_application_live_step, so they
// rebuild an invalidated description at the live size (the application-owned
// root contract), advance retained motion, refresh host chrome through the
// pre-present hook, and present at the configured surface size. Application
// ticks and scheduled wakes stay with the ordinary host loop.

import "core:fmt"
import alicorn "alicorn:runtime"
import live_resize "alicorn:host/sdl3/live_resize"
import presentation_host "alicorn:host/presentation"
import "vendor:sdl3"

SDL3_WebGPU_Live_Resize :: struct {
	core: live_resize.Core,
	application: ^SDL3_WebGPU_Application,
	manager: ^SDL3_WebGPU_Window_Manager,
	trace: bool,
	// frames counts live-path presentations, geometry_adoptions counts live size
	// adoptions that configured the surface, and idle_ticks counts ticks the core
	// or this host found nothing to do for.
	frames: u64,
	geometry_adoptions: u64,
	idle_ticks: u64,
	step_failures: u64,
	// peak_* record the largest live geometry a frame presented at, which is what
	// the scripted drag fixture asserts against the live window size.
	peak_logical_width: int,
	peak_pixel_width: int,
	last_logical_width: int,
	last_pixel_width: int,
}

// sdl3_webgpu_live_resize_install wires the shared core to a primary application
// and its optional secondary-window manager. Call it after the presenter is
// attached and before the event loop starts.
sdl3_webgpu_live_resize_install :: proc(
	live: ^SDL3_WebGPU_Live_Resize,
	application: ^SDL3_WebGPU_Application,
	manager: ^SDL3_WebGPU_Window_Manager,
	trace := false,
) -> bool {
	if live == nil || application == nil || !application.initialized { return false }
	live.application = application
	live.manager = manager
	live.trace = trace
	ops := live_resize.Ops{
		data=rawptr(live),
		window=sdl3_webgpu_live_resize_window,
		renderable=sdl3_webgpu_live_resize_renderable,
		has_work=sdl3_webgpu_live_resize_has_work,
		render=sdl3_webgpu_live_resize_render,
	}
	// Publish window identity first: the Windows message hook resolves HWNDs from
	// the slots, and a slot that is not live yet has no window to resolve.
	live.core.ops = ops
	sdl3_webgpu_live_resize_sync_windows(live)
	if !live_resize.live_resize_start(&live.core, ops) { return false }
	return true
}

sdl3_webgpu_live_resize_release :: proc(live: ^SDL3_WebGPU_Live_Resize) {
	if live == nil { return }
	live_resize.live_resize_stop(&live.core)
	live.application = nil
	live.manager = nil
}

// sdl3_webgpu_live_resize_sync_windows republishes slot identity after a
// secondary window is created, destroyed, or replumbed by device recovery.
sdl3_webgpu_live_resize_sync_windows :: proc(live: ^SDL3_WebGPU_Live_Resize) {
	if live == nil || live.application == nil { return }
	primary := live.application.window
	live_resize.live_resize_set_window(
		&live.core, .Primary, primary, live.application.initialized && primary != nil,
	)
	child_window: ^sdl3.Window
	child_live := false
	if live.manager != nil && live.manager.child != nil {
		child := live.manager.child
		child_window = child.window
		child_live = child.application.initialized && child.window != nil
	}
	live_resize.live_resize_set_window(&live.core, .Secondary, child_window, child_live)
}

// sdl3_webgpu_live_resize_reconcile is the once-per-host-turn cleanup point for
// a modal loop whose exit message SDL never observed.
sdl3_webgpu_live_resize_reconcile :: proc(live: ^SDL3_WebGPU_Live_Resize) {
	if live == nil { return }
	live_resize.live_resize_reconcile(&live.core)
}

@(private)
sdl3_webgpu_live_resize_application :: proc(
	live: ^SDL3_WebGPU_Live_Resize,
	slot: live_resize.Slot,
) -> ^SDL3_WebGPU_Application {
	if live == nil { return nil }
	switch slot {
	case .Primary:
		return live.application
	case .Secondary:
		if live.manager == nil || live.manager.child == nil { return nil }
		return &live.manager.child.application
	}
	return nil
}

@(private)
sdl3_webgpu_live_resize_window :: proc(
	data: rawptr,
	slot: live_resize.Slot,
) -> ^sdl3.Window {
	live := cast(^SDL3_WebGPU_Live_Resize)data
	application := sdl3_webgpu_live_resize_application(live, slot)
	if application == nil { return nil }
	return application.window
}

@(private)
sdl3_webgpu_live_resize_renderable :: proc(
	data: rawptr,
	slot: live_resize.Slot,
) -> bool {
	live := cast(^SDL3_WebGPU_Live_Resize)data
	application := sdl3_webgpu_live_resize_application(live, slot)
	if application == nil || !application.initialized || !application.visible { return false }
	if application.presenter.state == nil || application.presenter_device_lost { return false }
	lw, lh, pw, ph, ok := sdl3_webgpu_application_window_metrics(application.window)
	return ok && lw > 0 && lh > 0 && pw > 0 && ph > 0
}

// sdl3_webgpu_live_resize_has_work decides whether a modal-loop tick could
// advance this slot. It is deliberately conservative: a pending geometry change,
// an invalidated description, retained motion, pending presentation work, or a
// frame still in flight all justify one more opportunity. A static window that
// was just presented at its live size stops the timer, so a plain move does not
// spin.
@(private)
sdl3_webgpu_live_resize_has_work :: proc(
	data: rawptr,
	slot: live_resize.Slot,
) -> bool {
	live := cast(^SDL3_WebGPU_Live_Resize)data
	application := sdl3_webgpu_live_resize_application(live, slot)
	if application == nil || !application.initialized { return false }
	if !sdl3_webgpu_live_resize_renderable(data, slot) { return false }
	if sdl3_webgpu_live_resize_geometry_changed(live, application) { return true }
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return false }
	if rt.invalidated || alicorn.frame_needs_submission(rt) { return true }
	if alicorn.motion_activity(rt).active_owners > 0 { return true }
	return sdl3_webgpu_application_has_in_flight(application)
}

@(private)
sdl3_webgpu_live_resize_geometry_changed :: proc(
	live: ^SDL3_WebGPU_Live_Resize,
	application: ^SDL3_WebGPU_Application,
) -> bool {
	lw, lh, pw, ph, ok := sdl3_webgpu_application_window_metrics(application.window)
	if !ok { return false }
	pixel_density, display_scale := sdl3_webgpu_application_window_scales(application.window, lw, pw)
	return lw != application.last_logical_width || lh != application.last_logical_height ||
		pw != application.last_pixel_width || ph != application.last_pixel_height ||
		pixel_density != application.pixel_density || display_scale != application.display_scale
}

// sdl3_webgpu_live_resize_render is one bounded live frame. Geometry is adopted
// first so the surface is configured at the live size before the description is
// rebuilt; presenting a rebuilt description into the old swapchain is what
// produced the stretched last frame.
@(private)
sdl3_webgpu_live_resize_render :: proc(
	data: rawptr,
	slot: live_resize.Slot,
	now_ns: u64,
	cause: live_resize.Cause,
) {
	live := cast(^SDL3_WebGPU_Live_Resize)data
	application := sdl3_webgpu_live_resize_application(live, slot)
	if application == nil || !application.initialized { return }
	if !sdl3_webgpu_live_resize_renderable(data, slot) {
		live.idle_ticks += 1
		return
	}
	// A live frame may be the only wgpu API traffic while the modal loop owns the
	// thread, so poll explicitly: submission completions retire here instead of
	// waiting for the next ordinary host turn.
	presentation_host.hosted_surface_presenter_poll(&application.presenter)
	geometry_changed := sdl3_webgpu_live_resize_geometry_changed(live, application)
	if geometry_changed {
		resized := sdl3_webgpu_application_resize(application)
		if resized != .Ok && resized != .Suspended {
			live.step_failures += 1
			return
		}
		if resized == .Ok { live.geometry_adoptions += 1 }
	}
	step := sdl3_webgpu_application_live_step(application, now_ns)
	if step.status != .Ok {
		live.step_failures += 1
		return
	}
	if step.presentation != .Ok {
		if step.presentation == .No_Frame { live.idle_ticks += 1 }
		return
	}
	live.frames += 1
	live_resize.live_resize_note_presented_frame(&live.core, cause)
	live.last_logical_width = application.last_logical_width
	live.last_pixel_width = application.last_pixel_width
	live.peak_logical_width = max(live.peak_logical_width, application.last_logical_width)
	live.peak_pixel_width = max(live.peak_pixel_width, application.last_pixel_width)
	if live.trace {
		fmt.printf(
			"live_resize_frame slot=%v cause=%v t_ns=%d logical=%dx%d pixels=%dx%d geometry=%v\n",
			slot, cause, now_ns, application.last_logical_width, application.last_logical_height,
			application.last_pixel_width, application.last_pixel_height, geometry_changed,
		)
	}
}

// sdl3_webgpu_live_resize_report publishes the live-resize summary the scripted
// drag fixture parses. It prints the same class of counters the SDL_GPU
// reference host reports at shutdown.
sdl3_webgpu_live_resize_report :: proc(live: ^SDL3_WebGPU_Live_Resize) {
	if live == nil { return }
	counters := live.core.counters
	fmt.println(
		"webgpu_live_resize",
		"frames", live.frames,
		"geometry_adoptions", live.geometry_adoptions,
		"idle_ticks", live.idle_ticks,
		"step_failures", live.step_failures,
		"peak_logical_width", live.peak_logical_width,
		"peak_pixel_width", live.peak_pixel_width,
		"expose_events", counters.expose_events,
		"expose_frames", counters.expose_frames,
		"move_enter_messages", counters.move_enter_messages,
		"move_exit_messages", counters.move_exit_messages,
		"move_timer_wakes", counters.move_timer_wakes,
		"move_position_messages", counters.move_position_messages,
		"move_position_changed_messages", counters.move_position_changed_messages,
		"move_redraws", counters.move_redraws,
		"move_primary_redraws", counters.move_primary_redraws,
		"move_secondary_redraws", counters.move_secondary_redraws,
		"move_skipped_ticks", counters.move_skipped_ticks,
		"deferred_exposes", counters.deferred_exposes,
		"deferred_timer_ticks", counters.deferred_timer_ticks,
	)
}
