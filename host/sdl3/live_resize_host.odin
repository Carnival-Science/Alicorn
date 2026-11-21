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
import sdl3_file_drag "alicorn:host/sdl3/file_drag"
import live_resize "alicorn:host/sdl3/live_resize"
import presentation_host "alicorn:host/presentation"
import "vendor:sdl3"

// One 60 Hz frame budget. An inter-present interval above this is a frame the
// desktop compositor had to hold; the scripted harness reports both this and the
// two-frame class separately.
LIVE_RESIZE_FRAME_BUDGET_NS :: u64(16_666_667)

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
	// geometry_to_present_max_ns is the worst interval between the window
	// position message that moved the client area and the frame that first
	// presented at the new size. It is the window in which the desktop
	// compositor held the old frame.
	geometry_to_present_max_ns: u64,
	// peak_* record the largest live geometry a frame presented at, which is what
	// the scripted drag fixture asserts against the live window size.
	peak_logical_width: int,
	peak_pixel_width: int,
	last_logical_width: int,
	last_pixel_width: int,
	// Stage D slice 5 inter-present accounting. last_present_ns is cleared when a
	// move finishes so the gap between two drags is not reported as a stale
	// frame. An interval over one 60 Hz budget is a frame the compositor had to
	// hold; over two is the class the founder's stretched screenshots show.
	last_present_ns: u64,
	present_interval_count: u64,
	present_interval_total_ns: u64,
	present_interval_max_ns: u64,
	present_gaps_over_frame: u64,
	present_gaps_over_two_frames: u64,
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
	// The hosted presenter can rebuild and present a new drawable size as soon
	// as SDL has queued the resize, so adopt geometry at the message instead of
	// waiting for the compositor's next exposure. This is the interval in which
	// the desktop stretches the previous frame.
	live_resize.live_resize_set_geometry_dispatch(&live.core, true)
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
	// A finished drag must not contribute its idle gap to the next drag's
	// inter-present distribution.
	if live.core.counters.move_enter_messages == live.core.counters.move_exit_messages {
		live.last_present_ns = 0
	}
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
	// A native file drag owns a modal OLE loop on this thread. The application
	// is suspended inside its own pointer callback, so re-entering its retained
	// description from a live-resize timer would corrupt application state.
	// This mirrors the re-entrancy guard Stage C slice 1 added for the platform
	// move/size loop.
	if sdl3_file_drag.is_active() { return false }
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
	frame_start_ns := u64(sdl3.GetTicksNS())
	// A live frame may be the only wgpu API traffic while the modal loop owns the
	// thread, so poll explicitly: submission completions retire here instead of
	// waiting for the next ordinary host turn.
	poll_start_ns := u64(sdl3.GetTicksNS())
	presentation_host.hosted_surface_presenter_poll(&application.presenter)
	poll_ns := u64(sdl3.GetTicksNS()) - poll_start_ns
	geometry_changed := sdl3_webgpu_live_resize_geometry_changed(live, application)
	reconfigured := false
	adopt_ns: u64
	if geometry_changed {
		reconfigure_start_ns := u64(sdl3.GetTicksNS())
		resized := sdl3_webgpu_application_resize(application)
		adopt_ns = u64(sdl3.GetTicksNS()) - reconfigure_start_ns
		if resized != .Ok && resized != .Suspended {
			live.step_failures += 1
			return
		}
		if resized == .Ok {
			live.geometry_adoptions += 1
			reconfigured = true
		}
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
	presented_ns := u64(sdl3.GetTicksNS())
	geometry_to_present_ns: u64
	if reconfigured {
		if geometry_message_ns := live_resize.live_resize_geometry_message_ns(&live.core, slot); geometry_message_ns != 0 && presented_ns >= geometry_message_ns {
			geometry_to_present_ns = presented_ns - geometry_message_ns
			live.geometry_to_present_max_ns = max(live.geometry_to_present_max_ns, geometry_to_present_ns)
		}
		live_resize.live_resize_clear_geometry_message_ns(&live.core, slot)
	}
	interval_ns: u64
	if live.last_present_ns != 0 && presented_ns >= live.last_present_ns {
		interval_ns = presented_ns - live.last_present_ns
		live.present_interval_count += 1
		live.present_interval_total_ns += interval_ns
		live.present_interval_max_ns = max(live.present_interval_max_ns, interval_ns)
		if interval_ns > LIVE_RESIZE_FRAME_BUDGET_NS { live.present_gaps_over_frame += 1 }
		if interval_ns > 2*LIVE_RESIZE_FRAME_BUDGET_NS { live.present_gaps_over_two_frames += 1 }
	}
	live.last_present_ns = presented_ns
	live.frames += 1
	live_resize.live_resize_note_presented_frame(&live.core, cause)
	live.last_logical_width = application.last_logical_width
	live.last_pixel_width = application.last_pixel_width
	live.peak_logical_width = max(live.peak_logical_width, application.last_logical_width)
	live.peak_pixel_width = max(live.peak_pixel_width, application.last_pixel_width)
	if live.trace {
		configures, _ := presentation_host.hosted_surface_presenter_configuration_stats(&application.presenter)
		renderer_stats, _ := presentation_host.hosted_surface_presenter_renderer_stats(&application.presenter)
		timing := step.timing
		fmt.printf(
			"live_resize_frame slot=%v cause=%v t_ns=%d presented_ns=%d interval_ns=%d geometry_to_present_ns=%d logical=%dx%d pixels=%dx%d geometry=%v reconfigured=%v reconfigure_ns=%d adopt_ns=%d configure_total=%d description_ns=%d description_passes=%d reconcile_nodes=%d layout_nodes=%d paint_nodes=%d pre_present_ns=%d runtime_step_ns=%d acquire_ns=%d encode_ns=%d submit_ns=%d present_ns=%d step_to_present_ns=%d post_present_ns=%d poll_ns=%d frame_ns=%d solid_mesh_rebuilds=%d text_mesh_rebuilds=%d surface_mesh_rebuilds=%d\n",
			slot, cause, now_ns, presented_ns, interval_ns, geometry_to_present_ns,
			application.last_logical_width, application.last_logical_height,
			application.last_pixel_width, application.last_pixel_height,
			geometry_changed, reconfigured, timing.surface_reconfigure_ns, adopt_ns, configures,
			timing.description_ns, timing.description_passes,
			timing.reconcile_nodes_visited, timing.layout_nodes_visited, timing.paint_nodes_visited,
			timing.pre_present_ns, timing.runtime_step_ns, timing.surface_acquire_ns,
			timing.renderer_encode_ns, timing.queue_submit_ns, timing.surface_present_ns,
			timing.step_to_present_ns, step.post_present_ns, poll_ns, presented_ns-frame_start_ns,
			renderer_stats.solid.mesh_rebuilds, renderer_stats.text.mesh_rebuilds,
			renderer_stats.surfaces.mesh_rebuilds,
		)
	}
}

// sdl3_webgpu_live_resize_report publishes the live-resize summary the scripted
// drag fixture parses. It prints the same class of counters the SDL_GPU
// reference host reports at shutdown.
sdl3_webgpu_live_resize_report :: proc(live: ^SDL3_WebGPU_Live_Resize) {
	if live == nil { return }
	counters := live.core.counters
	configures: u64
	configure_total_ns: u64
	configure_last_ns: u64
	if live.application != nil {
		if stats, ok := presentation_host.hosted_surface_presenter_configuration_stats(&live.application.presenter); ok {
			configures = stats.configures
			configure_total_ns = stats.total_ns
			configure_last_ns = stats.last_ns
		}
	}
	fmt.println(
		"webgpu_live_resize",
		"frames", live.frames,
		"geometry_adoptions", live.geometry_adoptions,
		"idle_ticks", live.idle_ticks,
		"step_failures", live.step_failures,
		"peak_logical_width", live.peak_logical_width,
		"peak_pixel_width", live.peak_pixel_width,
		"surface_configures", configures,
		"surface_configure_total_ns", configure_total_ns,
		"surface_configure_last_ns", configure_last_ns,
		"present_intervals", live.present_interval_count,
		"present_interval_total_ns", live.present_interval_total_ns,
		"present_interval_max_ns", live.present_interval_max_ns,
		"present_gaps_over_frame", live.present_gaps_over_frame,
		"present_gaps_over_two_frames", live.present_gaps_over_two_frames,
		"geometry_to_present_max_ns", live.geometry_to_present_max_ns,
		"expose_events", counters.expose_events,
		"expose_frames", counters.expose_frames,
		"geometry_events", counters.geometry_events,
		"geometry_frames", counters.geometry_frames,
		"deferred_geometry_events", counters.deferred_geometry_events,
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
