package alicorn

import "core:math"
import "core:mem"
import "core:sync"

// Hosted_Runtime_Status is returned by the host-driven Runtime API. A hosted
// Runtime is deliberately single-threaded; only Hosted_Waker may cross threads.
Hosted_Runtime_Status :: enum {
	Ok,
	Already_Initialized,
	Closed,
	Invalid_Argument,
	Invalid_Target,
	Wrong_Thread,
	Time_Rewound,
	Motion_Failed,
}

Hosted_Render_Proc :: proc(state: rawptr, ui: ^UI, logical_width, logical_height: int, dpi_scale: f32)
Hosted_Post_Wake_Proc :: proc(data: rawptr) -> bool
Hosted_Initialize_Proc :: proc(state: rawptr, rt: ^Runtime)
Hosted_Start_Proc :: proc(state: rawptr, waker: Hosted_Waker)
Hosted_Wake_Proc :: proc(state: rawptr, rt: ^Runtime)
Hosted_Stop_Proc :: proc(state: rawptr)
Hosted_Scheduled_Wake_Proc :: proc(state: rawptr, rt: ^Runtime)
Hosted_Pointer_Proc :: proc(state: rawptr, rt: ^Runtime, event: Pointer_Event, target: Node_ID)
Hosted_Scroll_Proc :: proc(state: rawptr, rt: ^Runtime, event: Scroll_Event)
Hosted_Scroll_Capture_Proc :: proc(state: rawptr, rt: ^Runtime, event: Scroll_Event, target: Node_ID) -> bool
Hosted_Drag_Proc :: proc(state: rawptr, rt: ^Runtime, event: Drag_Event)
Hosted_Text_Change_Proc :: proc(state: rawptr, rt: ^Runtime, change: Text_Change)
Hosted_Text_Key_Proc :: proc(
	state: rawptr,
	rt: ^Runtime,
	owner: Node_ID,
	event: Application_Text_Key_Event,
) -> bool

// Hosted_Key_Event carries one host-normalized key transition. key_code is
// deliberately opaque to Runtime; the host owns platform mapping and reports
// whether text focus or IME composition retains the key. Application dispatch
// then shares Alicorn's interaction-scope preemption policy.
Hosted_Key_Event :: struct {
	key_code: u32,
	pressed: bool,
	repeat: bool,
	modifiers: Input_Modifiers,
	text_input_focused: bool,
	composition_active: bool,
}

Hosted_Key_Proc :: proc(state: rawptr, rt: ^Runtime, focused_owner: Node_ID, event: Hosted_Key_Event) -> bool

Hosted_Text_Input_Kind :: enum { Commit, Preedit, Cancel }

// Text input passed to an application-owned text target uses UTF-8 byte
// offsets. The host converts its native character offsets at the boundary.
Hosted_Text_Input_Event :: struct {
	kind: Hosted_Text_Input_Kind,
	text: string,
	selection_start_byte: int,
	selection_end_byte: int,
}

Hosted_Text_Input_Proc :: proc(
	state: rawptr,
	rt: ^Runtime,
	owner: Node_ID,
	event: Hosted_Text_Input_Event,
)

// Hosted_Window_Description requests one host-owned secondary surface. The
// host copies the description and services the request at an event-loop safe
// point. The caller retains ownership of config.state and all callback data
// until on_stop has run (or on_open_failed runs before callbacks start).
Hosted_Window_Open_Failed_Proc :: proc(state: rawptr)
Hosted_Window_Description :: struct {
	title: string,
	width, height: int,
	always_on_top: bool,
	config: Hosted_Runtime_Config,
	on_open_failed: Hosted_Window_Open_Failed_Proc,
}

Hosted_Window_Open_Proc :: proc(data: rawptr, description: Hosted_Window_Description) -> bool
Hosted_Window_Close_Proc :: proc(data: rawptr)
Hosted_Window_Topmost_Proc :: proc(data: rawptr, always_on_top: bool) -> bool
Hosted_Window_Set_Title_Proc :: proc(data: rawptr, title: string) -> bool

// Hosted_Window_Service is optional and borrowed for the Hosted_Runtime
// lifetime. Calls are owner-thread-only. open reports whether the request was
// accepted, not whether asynchronous native window creation succeeded. Browser
// hosts and headless fixtures may leave it empty; native implementations defer
// creation and teardown until their event loop reaches a safe point.
Hosted_Window_Service :: struct {
	data: rawptr,
	open: Hosted_Window_Open_Proc,
	close: Hosted_Window_Close_Proc,
	set_always_on_top: Hosted_Window_Topmost_Proc,
	set_title: Hosted_Window_Set_Title_Proc,
}

Hosted_Host_Services :: struct {
	windows: Hosted_Window_Service,
}

Hosted_Host_Services_Proc :: proc(state: rawptr, services: Hosted_Host_Services)

hosted_window_open :: proc(service: Hosted_Window_Service, description: Hosted_Window_Description) -> bool {
	return service.open != nil && service.open(service.data, description)
}

hosted_window_close :: proc(service: Hosted_Window_Service) {
	if service.close != nil { service.close(service.data) }
}

hosted_window_set_always_on_top :: proc(service: Hosted_Window_Service, always_on_top: bool) -> bool {
	return service.set_always_on_top != nil && service.set_always_on_top(service.data, always_on_top)
}

hosted_window_set_title :: proc(service: Hosted_Window_Service, title: string) -> bool {
	return service.set_title != nil && service.set_title(service.data, title)
}

// Hosted_Runtime_Config describes one host-owned surface. It owns one retained
// Runtime for every control rendered into that surface. Renderer and native
// window ownership stay with the embedding host.
Hosted_Runtime_Config :: struct {
	state: rawptr,
	logical_width, logical_height: int,
	pixel_width, pixel_height: int,
	dpi_scale: f32,
	runtime: Runtime_Config,
	// wake_allocator must be thread-safe because retained wakers may be released
	// by worker threads. The default context allocator is used when omitted.
	wake_allocator: mem.Allocator,
	post_wake_data: rawptr,
	post_wake: Hosted_Post_Wake_Proc,
	render: Hosted_Render_Proc,
	render_overlays: Hosted_Render_Proc,
	on_initialize: Hosted_Initialize_Proc,
	on_host_services: Hosted_Host_Services_Proc,
	host_services: Hosted_Host_Services,
	on_start: Hosted_Start_Proc,
	on_wake: Hosted_Wake_Proc,
	on_scheduled_wake: Hosted_Scheduled_Wake_Proc,
	on_stop: Hosted_Stop_Proc,
	on_pointer: Hosted_Pointer_Proc,
	on_drag: Hosted_Drag_Proc,
	on_scroll_capture: Hosted_Scroll_Capture_Proc,
	on_scroll: Hosted_Scroll_Proc,
	on_text_change: Hosted_Text_Change_Proc,
	on_text_input: Hosted_Text_Input_Proc,
	on_key: Hosted_Key_Proc,
	on_text_key: Hosted_Text_Key_Proc,
}

Hosted_Runtime :: struct {
	state: ^Hosted_Runtime_State,
}

Hosted_Step_Result :: struct {
	status: Hosted_Runtime_Status,
	description_built: bool,
	render_required: bool,
	has_more_work: bool,
	root: Node_ID,
	// Absolute monotonic deadline in nanoseconds, or zero when the host should
	// wait only for native input or a worker wake.
	next_wake_ns: u64,
}

Hosted_Waker :: struct {
	control: ^Hosted_Wake_Control,
}

HOSTED_MOTION_SAMPLE_INTERVAL_NS :: u64(16_666_667)
HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS :: u64(16_000_000)
HOSTED_UNCERTIFIED_MOTION_LIMIT_NS :: u64(5_000_000_000)
HOSTED_MAX_MONOTONIC_NS :: u64(0x7fff_ffff_ffff_ffff)

@(private)
Hosted_Wake_Control :: struct {
	mutex: sync.Mutex,
	allocator: mem.Allocator,
	data: rawptr,
	post: Hosted_Post_Wake_Proc,
	references: int,
	active: bool,
	wake_queued: bool,
}

@(private)
Hosted_Runtime_State :: struct {
	allocator: mem.Allocator,
	owner_thread_id: int,
	app_state: rawptr,
	runtime: Runtime,
	wake_control: ^Hosted_Wake_Control,
	render: Hosted_Render_Proc,
	render_overlays: Hosted_Render_Proc,
	on_wake: Hosted_Wake_Proc,
	on_scheduled_wake: Hosted_Scheduled_Wake_Proc,
	on_stop: Hosted_Stop_Proc,
	on_pointer: Hosted_Pointer_Proc,
	on_drag: Hosted_Drag_Proc,
	on_scroll_capture: Hosted_Scroll_Capture_Proc,
	on_scroll: Hosted_Scroll_Proc,
	on_text_change: Hosted_Text_Change_Proc,
	on_text_key: Hosted_Text_Key_Proc,
	on_text_input: Hosted_Text_Input_Proc,
	on_key: Hosted_Key_Proc,
	logical_width, logical_height: int,
	dpi_scale: f32,
	app_deadline_ns: u64,
	drag_deadline_ns: u64,
	last_step_ns: u64,
	uncertified_motion_since_ns: u64,
	has_step_time: bool,
	motion_uncertified_timing: bool,
	renderable: bool,
	closed: bool,
}

hosted_runtime_is_owner_thread :: proc(state: ^Hosted_Runtime_State) -> bool {
	return state != nil && state.owner_thread_id == sync.current_thread_id()
}

hosted_runtime_get_state :: proc(host: ^Hosted_Runtime) -> (state: ^Hosted_Runtime_State, status: Hosted_Runtime_Status) {
	if host == nil || host.state == nil { return nil, .Closed }
	state = host.state
	if state.closed { return nil, .Closed }
	if !hosted_runtime_is_owner_thread(state) { return nil, .Wrong_Thread }
	return state, .Ok
}

hosted_runtime_metrics_valid :: proc(logical_width, logical_height, pixel_width, pixel_height: int, dpi_scale: f32) -> bool {
	return logical_width >= 0 && logical_height >= 0 && pixel_width >= 0 && pixel_height >= 0 &&
		dpi_scale > 0 && !math.is_nan(dpi_scale) && !math.is_inf(dpi_scale)
}

// hosted_runtime_init must run on the native surface's UI thread. The caller
// supplies a zero-initialized Hosted_Runtime and keeps it alive until destroy.
hosted_runtime_init :: proc(host: ^Hosted_Runtime, config: Hosted_Runtime_Config) -> Hosted_Runtime_Status {
	if host == nil { return .Invalid_Argument }
	if host.state != nil { return .Already_Initialized }
	if config.render == nil || config.post_wake == nil ||
		!hosted_runtime_metrics_valid(
			config.logical_width, config.logical_height,
			config.pixel_width, config.pixel_height, config.dpi_scale,
		) { return .Invalid_Argument }

	state_allocator := context.allocator
	wake_allocator := config.wake_allocator
	if wake_allocator.procedure == nil { wake_allocator = context.allocator }
	state := new(Hosted_Runtime_State, allocator=state_allocator)
	state^ = Hosted_Runtime_State{
		allocator=state_allocator,
		owner_thread_id=sync.current_thread_id(),
		app_state=config.state,
		render=config.render,
		render_overlays=config.render_overlays,
		on_wake=config.on_wake,
		on_scheduled_wake=config.on_scheduled_wake,
		on_stop=config.on_stop,
		on_pointer=config.on_pointer,
		on_drag=config.on_drag,
		on_scroll_capture=config.on_scroll_capture,
		on_scroll=config.on_scroll,
		on_text_change=config.on_text_change,
		on_text_key=config.on_text_key,
		on_text_input=config.on_text_input,
		on_key=config.on_key,
		logical_width=config.logical_width,
		logical_height=config.logical_height,
		dpi_scale=config.dpi_scale,
		renderable=true,
	}
	state.runtime = new_runtime(
		Rect{0, 0, f32(config.logical_width), f32(config.logical_height)},
		config=config.runtime,
	)
	if config.pixel_width > 0 && config.pixel_height > 0 && config.logical_width > 0 && config.logical_height > 0 {
		_ = set_presentation_scale(
			&state.runtime,
			f32(config.pixel_width)/f32(config.logical_width),
			f32(config.pixel_height)/f32(config.logical_height),
		)
	}
	wake_control := new(Hosted_Wake_Control, allocator=wake_allocator)
	wake_control.allocator = wake_allocator
	wake_control.data = config.post_wake_data
	wake_control.post = config.post_wake
	wake_control.references = 1 // the Hosted_Runtime's owning reference
	wake_control.active = true
	state.wake_control = wake_control
	host.state = state
	if config.on_host_services != nil { config.on_host_services(config.state, config.host_services) }
	if config.on_initialize != nil { config.on_initialize(config.state, &state.runtime) }
	if config.on_start != nil { config.on_start(config.state, Hosted_Waker{control=wake_control}) }
	return .Ok
}

// hosted_runtime_borrow returns the Runtime only on the owning thread. The
// pointer is borrowed until hosted_runtime_destroy and must not be retained by
// workers. Prefer the event, paint, and semantic accessors below.
hosted_runtime_borrow :: proc(host: ^Hosted_Runtime) -> (^Runtime, Hosted_Runtime_Status) {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return nil, status }
	return &state.runtime, .Ok
}

hosted_root_describe :: proc(state: ^Hosted_Runtime_State) -> Node_ID {
	rt := &state.runtime
	ui, should_build := begin_frame(rt)
	if !should_build { return 0 }
	root := container_begin(
		&ui,
		.Root,
		label="ui-root",
		key="alicorn.hosted.root",
		style=layout_style(.Column, grow=1),
	)
	if root != 0 {
		state.render(state.app_state, &ui, state.logical_width, state.logical_height, state.dpi_scale)
		container_end(&ui)
		if state.render_overlays != nil { state.render_overlays(state.app_state, &ui, state.logical_width, state.logical_height, state.dpi_scale) }
	}
	end_frame(&ui)
	return root
}

hosted_deadline_min :: proc(current, candidate: u64) -> u64 {
	if candidate == 0 { return current }
	if current == 0 || candidate < current { return candidate }
	return current
}

hosted_deadline_after :: proc(now_ns, interval_ns: u64) -> u64 {
	return now_ns + min(interval_ns, HOSTED_MAX_MONOTONIC_NS-now_ns)
}

hosted_runtime_next_deadline :: proc(state: ^Hosted_Runtime_State, now_ns: u64) -> u64 {
	if state == nil { return 0 }
	deadline := state.app_deadline_ns
	if !state.renderable { return deadline }
	deadline = hosted_deadline_min(deadline, tooltip_next_deadline(&state.runtime))
	deadline = hosted_deadline_min(deadline, notice_next_deadline(&state.runtime))
	deadline = hosted_deadline_min(deadline, state.drag_deadline_ns)
	activity := motion_activity(&state.runtime)
	if activity.active_owners > 0 {
		next := hosted_deadline_after(now_ns, HOSTED_MOTION_SAMPLE_INTERVAL_NS)
		deadline = hosted_deadline_min(deadline, next)
	}
	return deadline
}

hosted_runtime_advance_presentation :: proc(state: ^Hosted_Runtime_State, now_ns: u64) -> Hosted_Runtime_Status {
	if !state.renderable { return .Ok }
	rt := &state.runtime
	motion := motion_tick(rt, Motion_Time(i64(now_ns)))
	if motion.status != .Ok { return .Motion_Failed }
	_ = tooltip_advance(rt, now_ns)
	_ = notice_advance(rt, now_ns)
	if motion.unestablished_deadlines > 0 {
		if !state.motion_uncertified_timing {
			state.motion_uncertified_timing = true
			state.uncertified_motion_since_ns = now_ns if now_ns != 0 else 1
		} else if now_ns >= state.uncertified_motion_since_ns &&
			now_ns-state.uncertified_motion_since_ns >= HOSTED_UNCERTIFIED_MOTION_LIMIT_NS {
			snapped := motion_snap_unestablished(rt, Motion_Time(i64(now_ns)))
			if snapped.status != .Ok { return .Motion_Failed }
			state.motion_uncertified_timing = false
			state.uncertified_motion_since_ns = 0
		}
	} else {
		state.motion_uncertified_timing = false
		state.uncertified_motion_since_ns = 0
	}
	if !drag_autoscroll_can_step(rt) {
		state.drag_deadline_ns = 0
	} else if state.drag_deadline_ns == 0 {
		state.drag_deadline_ns = hosted_deadline_after(now_ns, HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS)
	} else if now_ns >= state.drag_deadline_ns {
		_ = drag_autoscroll_step(rt, HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS)
		state.drag_deadline_ns = hosted_deadline_after(now_ns, HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS) if drag_autoscroll_can_step(rt) else 0
	}
	return .Ok
}

// hosted_runtime_step advances due retained work and performs at most one
// application description. Call it from the native UI loop after each bounded
// batch of input events or one-shot timer. It never waits or polls.
hosted_runtime_step :: proc(host: ^Hosted_Runtime, now_ns: u64) -> Hosted_Step_Result {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return Hosted_Step_Result{status=status} }
	if now_ns > HOSTED_MAX_MONOTONIC_NS { return Hosted_Step_Result{status=.Invalid_Argument} }
	if state.has_step_time && now_ns < state.last_step_ns { return Hosted_Step_Result{status=.Time_Rewound} }
	state.has_step_time = true
	state.last_step_ns = now_ns
	rt := &state.runtime
	if advance_status := hosted_runtime_advance_presentation(state, now_ns); advance_status != .Ok {
		return Hosted_Step_Result{status=advance_status}
	}

	result := Hosted_Step_Result{status=.Ok}
	if state.app_deadline_ns != 0 && now_ns >= state.app_deadline_ns {
		state.app_deadline_ns = 0
		if state.on_scheduled_wake != nil { state.on_scheduled_wake(state.app_state, rt) }
	}
	if rt.invalidated {
		result.root = hosted_root_describe(state)
		result.description_built = true
	} else if ui, ready := begin_presentation_frame(rt); ready {
		end_presentation_frame(&ui)
	}
	result.render_required = state.renderable && frame_needs_submission(rt)
	result.has_more_work = rt.invalidated
	result.next_wake_ns = hosted_runtime_next_deadline(state, now_ns)
	return result
}

// hosted_runtime_set_deadline installs one application-owned, one-shot
// monotonic deadline. It is cleared before on_scheduled_wake runs, so that
// callback may safely arm the next one. Pass zero to cancel.
hosted_runtime_set_deadline :: proc(host: ^Hosted_Runtime, deadline_ns: u64) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if deadline_ns > HOSTED_MAX_MONOTONIC_NS { return .Invalid_Argument }
	state.app_deadline_ns = deadline_ns
	return .Ok
}

// hosted_runtime_set_renderable suspends only scheduled presentation work.
// Native events and worker wakes may still be delivered while hidden. Call
// step with the current monotonic time after restoring visibility.
hosted_runtime_set_renderable :: proc(host: ^Hosted_Runtime, renderable: bool) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if state.renderable != renderable {
		state.renderable = renderable
		state.drag_deadline_ns = 0
		if renderable { request_presentation(&state.runtime, "hosted surface restored") }
	}
	return .Ok
}

// hosted_runtime_request_presentation wakes retained paint after a host-side
// renderer or surface is replaced. It does not invalidate or rebuild the UI
// description.
hosted_runtime_request_presentation :: proc(
	host: ^Hosted_Runtime,
	reason := "hosted renderer needs retained presentation",
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	request_presentation(&state.runtime, reason)
	return .Ok
}

// hosted_runtime_resize adopts logical and drawable dimensions together.
// Pixel size may be zero while minimized; in that case the last device scale
// is retained until the host reports a drawable size again.
hosted_runtime_resize :: proc(
	host: ^Hosted_Runtime,
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if !hosted_runtime_metrics_valid(logical_width, logical_height, pixel_width, pixel_height, dpi_scale) {
		return .Invalid_Argument
	}
	rt := &state.runtime
	logical_changed := logical_width != state.logical_width || logical_height != state.logical_height
	dpi_changed := dpi_scale != state.dpi_scale
	state.logical_width, state.logical_height = logical_width, logical_height
	state.dpi_scale = dpi_scale
	if logical_changed {
		rt.viewport.w = f32(logical_width)
		rt.viewport.h = f32(logical_height)
		invalidate_root(rt, "hosted surface logical size changed")
	} else if dpi_changed {
		invalidate_root(rt, "hosted surface DPI changed")
	}
	if pixel_width > 0 && pixel_height > 0 && logical_width > 0 && logical_height > 0 {
		_ = set_presentation_scale(rt, f32(pixel_width)/f32(logical_width), f32(pixel_height)/f32(logical_height))
	}
	return .Ok
}

hosted_runtime_pointer :: proc(host: ^Hosted_Runtime, event: Pointer_Event) -> (target: Node_ID, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return 0, access_status }
	rt := &state.runtime
	cause := pointer_cause_begin(rt, event.kind)
	target = process_pointer(rt, event)
	dispatched_event := event
	if key, ok := node_identity_key(rt, target); ok { dispatched_event.target_key = key }
	if state.on_pointer != nil {
		state.on_pointer(state.app_state, rt, dispatched_event, target)
		if event.kind == .Down || event.kind == .Up {
			invalidate_root(rt, "hosted application pointer callback")
		}
	}
	if drag_event, pending := drag_event_take(rt); pending && state.on_drag != nil {
		state.on_drag(state.app_state, rt, drag_event)
	}
	cause_end(rt, cause)
	return target, .Ok
}

// hosted_runtime_key delivers a native key transition to the app callback on
// the owning UI thread. The host retains platform policy: it decides whether
// the event belongs to IME, a text owner, focus traversal, activation, or an
// application shortcut, and calls the matching runtime helper as needed.
hosted_runtime_key :: proc(host: ^Hosted_Runtime, event: Hosted_Key_Event) -> (handled: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	if event.pressed && event.key_code <= u32(Application_Key.Return) {
		key := Application_Key(event.key_code)
		if event.text_input_focused && !application_key_can_preempt_text_field(key, event.composition_active) {
			return false, .Ok
		}
		if interaction_scope_dispatch_key(&state.runtime, key, event.composition_active) { return true, .Ok }
	}
	if state.on_key == nil { return false, .Ok }
	focused_owner := focused_node(&state.runtime)
	handled = state.on_key(state.app_state, &state.runtime, focused_owner, event)
	if handled { invalidate_root(&state.runtime, "hosted application key callback") }
	return handled, .Ok
}

hosted_runtime_scroll :: proc(host: ^Hosted_Runtime, event: Scroll_Event) -> (handled: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	cause := cause_begin(&state.runtime, .Scroll, "hosted scroll event")
	if state.on_scroll_capture != nil {
		target := scroll_region_hit_test(&state.runtime, event.x, event.y)
		if target != 0 { handled = state.on_scroll_capture(state.app_state, &state.runtime, event, target) }
	}
	if !handled { handled = process_scroll(&state.runtime, event) }
	if !handled && state.on_scroll != nil {
		state.on_scroll(state.app_state, &state.runtime, event)
		handled = true
	}
	cause_end(&state.runtime, cause)
	return handled, .Ok
}

hosted_runtime_text_input :: proc(
	host: ^Hosted_Runtime,
	owner: Node_ID,
	kind: Hosted_Text_Input_Kind,
	text: string = "",
	selection_start_character := 0,
	selection_length_characters := 0,
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	rt := &state.runtime
	target_owner := owner
	if target_owner == 0 { target_owner = focused_node(rt) }
	info, found := node_info(rt, target_owner)
	if !found { return .Invalid_Target }
	text_cause := cause_begin(rt, .Text_Input, "hosted native text input")
	if info.kind == .Text_Field {
		switch kind {
		case .Commit:
			change := process_text_input(rt, target_owner, text)
			if state.on_text_change != nil { state.on_text_change(state.app_state, rt, change) }
			text_change_destroy(rt, &change)
		case .Preedit:
			_ = process_text_editing(rt, target_owner, text, selection_start_character, selection_length_characters)
		case .Cancel:
			_ = cancel_text_composition(rt, target_owner, "hosted native text composition canceled")
		}
	} else if text_input_target_is_active(rt, target_owner) && state.on_text_input != nil {
		start_byte := utf8_character_index_to_byte_offset(text, selection_start_character)
		end_character := selection_start_character + max(selection_length_characters, 0)
		end_byte := utf8_character_index_to_byte_offset(text, end_character)
		event := Hosted_Text_Input_Event{
			kind=kind,
			text=text,
			selection_start_byte=start_byte,
			selection_end_byte=end_byte,
		}
		state.on_text_input(state.app_state, rt, target_owner, event)
		invalidate_root(rt, "hosted application text input")
	} else {
		cause_end(rt, text_cause)
		return .Invalid_Target
	}
	cause_end(rt, text_cause)
	return .Ok
}

hosted_runtime_focus_changed :: proc(host: ^Hosted_Runtime, focused: bool, focus_visible := false) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	rt := &state.runtime
	if focused {
		focus_indicator_set(rt, focus_visible)
		return .Ok
	}
	owner := focused_node(rt)
	if info, found := node_info(rt, owner); found {
		if info.kind == .Text_Field {
			_ = cancel_text_composition(rt, owner, "hosted surface lost native focus")
		} else if info.text_input_target && state.on_text_input != nil {
			state.on_text_input(state.app_state, rt, owner, Hosted_Text_Input_Event{kind=.Cancel})
			invalidate_root(rt, "hosted surface lost native focus")
		}
	}
	focus_indicator_set(rt, false)
	context_menu_close(rt)
	tooltip_dismiss(rt)
	captured := rt.captured_node
	cancel_cause := pointer_cause_begin(rt, .Cancel)
	_ = cancel_pointer_capture(rt)
	state.drag_deadline_ns = 0
	if drag_event, pending := drag_event_take(rt); pending && state.on_drag != nil {
		state.on_drag(state.app_state, rt, drag_event)
	}
	if state.on_pointer != nil {
		event := Pointer_Event{kind=.Cancel}
		if key, ok := node_identity_key(rt, captured); ok { event.target_key = key }
		state.on_pointer(state.app_state, rt, event, captured)
	}
	cause_end(rt, cancel_cause)
	return .Ok
}

hosted_runtime_focus_traverse :: proc(host: ^Hosted_Runtime, direction: Focus_Direction) -> (focused: Node_ID, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return 0, access_status }
	return focus_traverse(&state.runtime, direction), .Ok
}

hosted_runtime_activate :: proc(host: ^Hosted_Runtime, key: Activation_Key) -> (activated: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	return activate_focused(&state.runtime, key), .Ok
}

hosted_runtime_adjust_focused_slider :: proc(host: ^Hosted_Runtime, direction: int) -> (adjusted: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	return adjust_focused_slider(&state.runtime, direction), .Ok
}

hosted_runtime_set_focused_slider_bound :: proc(host: ^Hosted_Runtime, bound: Slider_Bound) -> (adjusted: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	return set_focused_slider_bound(&state.runtime, bound), .Ok
}

hosted_runtime_text_command :: proc(host: ^Hosted_Runtime, owner: Node_ID, command: Text_Command) -> (change: Text_Change, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return {}, access_status }
	target_owner := owner
	if target_owner == 0 { target_owner = focused_node(&state.runtime) }
	info, found := node_info(&state.runtime, target_owner)
	if !found || info.kind != .Text_Field { return {}, .Invalid_Target }
	change = process_text_command(&state.runtime, target_owner, command)
	if change.changed && state.on_text_change != nil { state.on_text_change(state.app_state, &state.runtime, change) }
	return change, .Ok
}

// hosted_runtime_text_key routes a host-normalized navigation or deletion key
// first to an application-owned text target and then through Alicorn's shared
// Text_Field policy. Hosts must pass composition_active so active IME input
// retains its keys. The result reports whether the owner consumed the event.
hosted_runtime_text_key :: proc(
	host: ^Hosted_Runtime,
	event: Application_Text_Key_Event,
	composition_active := false,
) -> (result: Application_Text_Field_Key_Result, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return .Unhandled, access_status }
	if composition_active { return .Unhandled, .Ok }
	if application_dispatch_text_key(
		&state.runtime,
		state.app_state,
		state.on_text_key,
		event,
	) {
		#partial switch event.key {
		case .Backspace, .Delete, .Delete_Word_Backward, .Delete_Word_Forward,
		     .Delete_Line_Backward, .Delete_Line_Forward:
			return .Edit, .Ok
		case:
			return .Navigation, .Ok
		}
	}
	owner := focused_node(&state.runtime)
	route_result, change := application_route_text_field_key(&state.runtime, owner, event)
	result = route_result
	if route_result == .Edit {
		application_dispatch_text_change(&state.runtime, state.app_state, state.on_text_change, change)
	}
	return result, .Ok
}

// hosted_runtime_accessibility_action routes an advertised semantic action.
// When the action becomes an application-owned domain event, on_wake is called
// on the owner thread so the application can drain and adopt that event before
// the next description. Realized Press/Focus actions remain runtime-owned and
// do not invoke the application callback.
hosted_runtime_accessibility_action :: proc(
	host: ^Hosted_Runtime,
	id: Semantic_ID,
	action: Semantic_Action,
	text_value := "",
	numeric_value: f64 = 0,
	has_numeric_value := false,
) -> (handled: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	pending_before := len(state.runtime.semantic_requests)-state.runtime.semantic_request_read_index
	handled = semantic_action_request(&state.runtime, id, action, text_value, numeric_value, has_numeric_value)
	if handled && state.on_wake != nil &&
	   len(state.runtime.semantic_requests)-state.runtime.semantic_request_read_index > pending_before {
		_ = hosted_runtime_deliver_semantic_requests(host)
	}
	return handled, .Ok
}

// hosted_runtime_deliver_semantic_requests invokes the application callback
// when app-owned semantic requests are pending. Hosts call it after draining
// platform accessibility actions into Runtime; the callback owns the request
// policy and should drain events with semantic_request_pop.
hosted_runtime_deliver_semantic_requests :: proc(host: ^Hosted_Runtime) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	pending := len(state.runtime.semantic_requests)-state.runtime.semantic_request_read_index
	if pending > 0 && state.on_wake != nil { state.on_wake(state.app_state, &state.runtime) }
	return .Ok
}

hosted_runtime_display_commands :: proc(host: ^Hosted_Runtime) -> ([]Paint_Command, Hosted_Runtime_Status) {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return nil, status }
	return state.runtime.display[:], .Ok
}

hosted_runtime_semantic_snapshot :: proc(host: ^Hosted_Runtime, allocator := context.allocator) -> (Semantic_Snapshot, Hosted_Runtime_Status) {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return {}, status }
	return semantic_snapshot(&state.runtime, allocator), .Ok
}

hosted_runtime_frame_submission_succeeded :: proc(host: ^Hosted_Runtime) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	frame_submission_succeeded(&state.runtime)
	return .Ok
}

hosted_waker_clone :: proc(waker: Hosted_Waker) -> (clone: Hosted_Waker, ok: bool) {
	control := waker.control
	if control == nil { return }
	sync.mutex_lock(&control.mutex)
	if control.active && control.references > 0 {
		control.references += 1
		clone = waker
		ok = true
	}
	sync.mutex_unlock(&control.mutex)
	return
}

// hosted_waker_notify only posts the host event. It is safe from workers and
// coalesces repeated notifications until the host delivers one on the UI thread.
hosted_waker_notify :: proc(waker: Hosted_Waker) -> bool {
	control := waker.control
	if control == nil { return false }
	sync.mutex_lock(&control.mutex)
	if !control.active || control.post == nil || control.wake_queued {
		active := control.active
		sync.mutex_unlock(&control.mutex)
		return active
	}
	control.wake_queued = true
	posted := control.post(control.data)
	if !posted { control.wake_queued = false }
	sync.mutex_unlock(&control.mutex)
	return posted
}

// hosted_waker_release releases one retained worker reference. The caller must
// stop using this value after release; each worker copy needs its own clone.
hosted_waker_release :: proc(waker: ^Hosted_Waker) {
	if waker == nil || waker.control == nil { return }
	control := waker.control
	waker.control = nil
	sync.mutex_lock(&control.mutex)
	control.references -= 1
	free_control := control.references == 0
	allocator := control.allocator
	sync.mutex_unlock(&control.mutex)
	if free_control { free(control, allocator=allocator) }
}

// hosted_runtime_deliver_wake runs on the UI thread after the host consumes its
// posted wake event. Queued wake events delivered after close are ignored.
hosted_runtime_deliver_wake :: proc(host: ^Hosted_Runtime) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	control := state.wake_control
	sync.mutex_lock(&control.mutex)
	queued := control.wake_queued
	control.wake_queued = false
	active := control.active
	sync.mutex_unlock(&control.mutex)
	if active && queued && state.on_wake != nil { state.on_wake(state.app_state, &state.runtime) }
	return .Ok
}

// hosted_runtime_destroy is UI-thread-only and idempotent. It closes the wake
// gate before on_stop, joins application workers through that callback, then
// destroys retained Runtime memory. Cloned wakers remain safe no-ops until each
// owner releases them. Stop native timers/events and quiesce renderer callbacks
// before calling this procedure.
hosted_runtime_destroy :: proc(host: ^Hosted_Runtime) -> Hosted_Runtime_Status {
	if host == nil || host.state == nil { return .Ok }
	state := host.state
	if !hosted_runtime_is_owner_thread(state) { return .Wrong_Thread }
	if state.closed { host.state = nil; return .Ok }
	control := state.wake_control
	if control != nil {
		sync.mutex_lock(&control.mutex)
		control.active = false
		control.wake_queued = false
		control.post = nil
		control.data = nil
		sync.mutex_unlock(&control.mutex)
	}
	state.closed = true
	if state.on_stop != nil { state.on_stop(state.app_state) }
	destroy_runtime(&state.runtime)
	if control != nil {
		owner := Hosted_Waker{control=control}
		hosted_waker_release(&owner)
	}
	allocator := state.allocator
	host.state = nil
	free(state, allocator=allocator)
	return .Ok
}
