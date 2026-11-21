package alicorn_sdl_gpu

import "base:runtime"
import "core:time"
import alicorn "../../runtime"
import sdl_host "alicorn:host/sdl3/input"
import "vendor:sdl3"

NATIVE_DESCRIPTION_STABILIZATION_LIMIT :: 4

// Host presentation can be requested by app content, native chrome, DevTools,
// or the inspector. Keep this decision explicit so host-only wake paths can
// be verified without attributing them to application work.
native_frame_submission_requested :: proc(
	application, native_chrome, devtools_hud, inspector: bool,
	retained_effect_retry := false,
) -> bool {
	return application || native_chrome || devtools_hud || inspector || retained_effect_retry
}

Native_Description_Stabilization :: struct {
	passes: int,
	stable: bool,
}

// In-build application invalidations describe a newer state than the
// description that raised them. Rebuild a small bounded number of times before
// the host submits a GPU frame, so transient intermediate descriptions are not
// visibly presented. Event/button consumption remains owned by the runtime.
native_application_build_until_stable :: proc(
	application: ^Application,
	rt: ^alicorn.Runtime,
	metrics: ^Window_Metrics,
	timing: ^Native_Host_Timing,
	stop_on_hard_error := false,
) -> Native_Description_Stabilization {
	result := Native_Description_Stabilization{}
	for rt.invalidated && (!stop_on_hard_error || !rt.hard_error) && result.passes < NATIVE_DESCRIPTION_STABILIZATION_LIMIT {
		interaction_sequence := rt.interaction_consumption_sequence
		// Intent-based motion resolves targets from the same monotonic domain as
		// native presentation sampling. Inject it before every application
		// description so app code never needs its own motion clock.
		_ = native_motion_clock_set_current_time(rt)
		build_start := time.now()
		_ = application.build(application.state, rt, metrics.logical_width, metrics.logical_height, metrics.display_scale)
		build_ns := u64(time.duration_nanoseconds(time.since(build_start)))
		native_timing_accumulate(&timing.application_build_ns, &timing.application_build_max_ns, build_ns)
		native_timing_add_build(timing, build_ns)
		result.passes += 1
		if application.interaction_update_policy == .Correct_After_Interaction &&
		   rt.interaction_consumption_sequence != interaction_sequence && !rt.invalidated {
			alicorn.invalidate_root(rt, "corrective description after consumed interaction")
		}
	}
	result.stable = !rt.invalidated || (stop_on_hard_error && rt.hard_error)
	if result.passes > 1 { timing.application_stabilization_rebuilds += u64(result.passes-1) }
	if !result.stable { timing.application_stabilization_limit_hits += 1 }
	return result
}

// Native_Menu_Runtime is a host-owned bridge. Platform adapters keep HWND,
// NSWindow, HMENU, NSMenu and selectors outside the application API.
Native_Menu_Runtime :: struct {
	window:          ^sdl3.Window,
	application:     ^Application,
	runtime:         ^alicorn.Runtime,
	inspector:       ^Native_Inspector_Overlay,
	// These host-owned objects share the native menu bridge's lifetime. The
	// primary application loop publishes temporary access to them while it runs.
	inspector_storage: Native_Inspector_Overlay,
	host_waker_storage: Native_Host_Event_Waker,
	platform_data:   rawptr,
	// The window/client coordinate space includes this host-owned top chrome;
	// application logical coordinates begin immediately below it.
	content_inset_top: f32,
	chrome_appearance: Window_Chrome_Appearance,
	chrome_appearance_resolved: bool,
	chrome_redraw_pending: bool,
	host_waker: ^Native_Host_Event_Waker,
	pending_command: Application_Command_ID,
	has_pending:     bool,
}

native_menu_take_pending_shared :: proc(menu: ^Native_Menu_Runtime) -> (Application_Command_ID, bool) {
	if menu == nil || !menu.has_pending { return {}, false }
	command := menu.pending_command
	menu.pending_command = {}
	menu.has_pending = false
	return command, true
}

native_menu_try_shortcut_shared :: proc(
	menu: ^Native_Menu_Runtime,
	keycode: int,
	modifiers: sdl3.Keymod,
	repeat: bool,
) -> bool {
	if menu == nil || menu.application == nil || menu.application.on_menu_command == nil { return false }
	command, found := native_menu_match_shortcut(menu.application, keycode, modifiers)
	if !found { return false }
	if !repeat { native_menu_dispatch_command(menu, command) }
	return true
}

// native_menu_modifiers translates SDL modifier state into the runtime's
// platform-neutral menu vocabulary. Primary is Ctrl on Windows/Linux and
// Command on macOS; Super is the Windows key on Windows/Linux and Control on
// macOS. host/sdl3/input owns the same conversion for hosted SDL3 hosts.
native_menu_modifiers :: proc(modifiers: sdl3.Keymod) -> Application_Menu_Modifiers {
	return sdl_host.menu_modifiers_from_sdl(modifiers)
}

native_menu_match_shortcut :: proc(
	application: ^Application,
	keycode: int,
	modifiers: sdl3.Keymod,
) -> (Application_Command_ID, bool) {
	if application == nil { return {}, false }
	return alicorn.menu_match_shortcut(application.menus, rune(keycode), native_menu_modifiers(modifiers))
}

// A native chrome transition must wake the SDL loop when it is waiting for
// events. Coalesce repeated pointer messages until the requested frame lands.
native_menu_request_chrome_redraw :: proc(menu: ^Native_Menu_Runtime) {
	if menu == nil { return }
	was_pending := menu.chrome_redraw_pending
	menu.chrome_redraw_pending = true
	if !was_pending { native_host_event_wake(menu.host_waker) }
}

native_window_chrome_appearance_equal :: proc(a, b: Window_Chrome_Appearance) -> bool {
	if a.defined != b.defined { return false }
	if !a.defined { return true }
	return a.background == b.background && a.foreground == b.foreground
}

// Resolve the app's optional chrome colors at description boundaries. If app
// paint already needs a frame, that submission will include the new host
// appearance. Otherwise request a host-only frame to repaint chrome.
native_menu_sync_chrome_appearance :: proc(menu: ^Native_Menu_Runtime, request_redraw := true) -> bool {
	if menu == nil || menu.application == nil || menu.runtime == nil ||
	   menu.application.window_chrome_appearance == nil {
		return false
	}
	next := menu.application.window_chrome_appearance(menu.application.state, menu.runtime)
	if menu.chrome_appearance_resolved && native_window_chrome_appearance_equal(menu.chrome_appearance, next) {
		return false
	}
	menu.chrome_appearance = next
	menu.chrome_appearance_resolved = true
	if request_redraw { native_menu_request_chrome_redraw(menu) }
	return true
}

native_menu_dispatch_command :: proc(menu: ^Native_Menu_Runtime, command: Application_Command_ID) {
	if menu == nil || menu.application == nil || menu.application.on_menu_command == nil { return }
	// One shared enabled gate: top-level direct commands use their borrowed
	// description state, item commands require an enabled carrying item, and
	// registered runtime actions must be enabled.
	if !alicorn.menu_command_enabled(menu.application.menus, menu.runtime, command) { return }
	cause: alicorn.Cause_Scope
	if menu.runtime != nil {
		cause = alicorn.cause_begin(menu.runtime, .Native_Command, "native menu command", command)
	}
	menu.application.on_menu_command(menu.application.state, menu.runtime, command)
	if menu.runtime != nil { alicorn.invalidate_root(menu.runtime, "application menu command") }
	if menu.runtime != nil { alicorn.cause_end(menu.runtime, cause) }
}

Native_Application_Waker :: struct {
	event_type: sdl3.EventType,
	active:     bool,
}

NATIVE_OPPORTUNISTIC_QUIET_NS :: u64(150_000_000)

native_application_schedule_after :: proc(data: rawptr, class: Scheduled_Wake_Class, delay_ns: u64) -> bool {
	return scheduled_wake_schedule(cast(^Native_Scheduled_Wake_State)data, class, u64(sdl3.GetTicksNS()), delay_ns)
}

native_application_cancel_scheduled :: proc(data: rawptr, class: Scheduled_Wake_Class) -> bool {
	return scheduled_wake_cancel(cast(^Native_Scheduled_Wake_State)data, class)
}

native_application_scheduler_stats :: proc(data: rawptr) -> Application_Scheduler_Stats {
	return scheduled_wake_read_stats(cast(^Native_Scheduled_Wake_State)data)
}

native_event_is_user_interaction :: proc(kind: sdl3.EventType) -> bool {
	#partial switch kind {
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT, .TEXT_EDITING,
		.MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
		return true
	}
	return false
}

native_dispatch_scheduled_wakes :: proc(
	application: ^Application,
	rt: ^alicorn.Runtime,
	state: ^Native_Scheduled_Wake_State,
	last_interaction_ns: u64,
	timing: ^Native_Host_Timing,
) {
	if application == nil || state == nil || !state.active { return }
	classes := [2]Scheduled_Wake_Class{.Frequent, .Opportunistic}
	for class in classes {
		now_ns := u64(sdl3.GetTicksNS())
		if !scheduled_wake_is_due(state, class, now_ns) { continue }
		index := scheduled_wake_class_index(class)
		if class == .Opportunistic {
			deferred_until, defer_work := scheduled_wake_defer_until_quiet(now_ns, last_interaction_ns, NATIVE_OPPORTUNISTIC_QUIET_NS)
			if defer_work {
				state.deadlines_ns[index] = deferred_until
				state.stats.opportunistic_deferrals += 1
				timing.opportunistic_deferrals += 1
				continue
			}
		}
		deadline_ns := state.deadlines_ns[index]
		lateness_ns := u64(0)
		if now_ns > deadline_ns { lateness_ns = now_ns-deadline_ns }
		scheduled_wake_record_run(state, class, lateness_ns)
		timing.scheduled_wakes += 1
		timing.maximum_scheduled_lateness_ns = max(timing.maximum_scheduled_lateness_ns, lateness_ns)
		if application.on_scheduled_wake != nil {
			reason := class == .Frequent ? "frequent scheduled work" : "opportunistic scheduled work"
			cause := alicorn.cause_begin(rt, .Scheduled_Wake, reason)
			application.on_scheduled_wake(application.state, rt, class)
			alicorn.cause_end(rt, cause)
		}
	}
}

native_application_wake :: proc(data: rawptr) {
	state := cast(^Native_Application_Waker)data
	if state == nil || !state.active { return }
	event := sdl3.Event{type=state.event_type}
	_ = sdl3.PushEvent(&event)
}

native_application_request_quit :: proc(data: rawptr) {
	state := cast(^bool)data
	if state != nil { state^ = true }
}
