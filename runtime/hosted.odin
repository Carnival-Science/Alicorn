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
// Hosted_Scheduled_Wake_Proc matches native/sdl_gpu's
// Application_Scheduled_Wake_Proc: the due class is supplied and the runtime
// has already cleared that class before the callback runs.
Hosted_Scheduled_Wake_Proc :: Application_Scheduled_Wake_Proc
// Hosted_File_Drop_Proc matches Application_File_Drop_Proc. The path is
// borrowed from the host's event storage for the callback only.
Hosted_File_Drop_Proc :: proc(state: rawptr, rt: ^Runtime, path: string)
// Hosted_Tick_Proc matches Application_Tick_Proc. Hosted runtimes invoke it at
// the same bounded 60 Hz cadence as the native host and never use it as an
// idle poll.
Hosted_Tick_Proc :: proc(state: rawptr, rt: ^Runtime)
// Hosted_After_Frame_Proc runs after end_frame for the same description pass
// and before the host presents that frame. It mirrors the reference SDL_GPU
// application ordering: prepare -> begin_frame -> describe -> end_frame ->
// after_frame -> present/commit acknowledgement. It runs on every completed
// description pass, including the last one, whether or not another frame is
// scheduled. Post-layout work such as focus restoration, scroll restoration,
// and deferred geometry fixes belongs here; a callback that changes retained
// layout or paint state must explicitly invalidate the supplied Runtime.
Hosted_After_Frame_Proc :: proc(state: rawptr, rt: ^Runtime)
// Hosted_Monotonic_Now_Proc supplies the monotonic nanosecond domain used for
// scheduler deadlines and interaction timestamps. Hosts should install the
// same clock they pass to hosted_runtime_step; when omitted, the last step
// time is used.
Hosted_Monotonic_Now_Proc :: proc(data: rawptr) -> u64

// Interaction_Update_Policy mirrors native/sdl_gpu's
// Application_Interaction_Update_Policy.
Interaction_Update_Policy :: enum {
	Explicit,
	Correct_After_Interaction,
}
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
// opaque to Runtime: Alicorn never interprets SDL, wx, or platform key
// constants, and an external host's numeric key space cannot preempt text or
// interaction scopes. A host that has translated a key into Alicorn's
// Application_Key vocabulary passes that value to
// hosted_runtime_application_key. The opaque event still reaches on_key so the
// application retains its own shortcut policy.
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

// Hosted_Quit_Service lets an application complete a close request it deferred
// from on_close_requested after its own save/discard flow has finished. The
// host owns the resulting shutdown and retires the service after on_stop.
Hosted_Quit_Request_Proc :: proc(data: rawptr)
Hosted_Quit_Service :: struct {
	data:    rawptr,
	request: Hosted_Quit_Request_Proc,
}

hosted_quit_request :: proc(service: Hosted_Quit_Service) {
	if service.request != nil { service.request(service.data) }
}

Hosted_Host_Services :: struct {
	windows:   Hosted_Window_Service,
	dialogs:   Hosted_Dialog_Service,
	quit:      Hosted_Quit_Service,
	// clipboard is the synchronous native SDL3 clipboard shape. Browser hosts
	// may leave it empty; they publish the asynchronous alicorn:host/clipboard
	// service through UI_Host_Services instead.
	clipboard: Clipboard_Service,
	// scheduler is always supplied by the hosted Runtime. It owns one
	// replaceable Frequent and one replaceable Opportunistic deadline for this
	// surface and mirrors native/sdl_gpu's Application_Scheduler.
	scheduler: Application_Scheduler,
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

// Hosted_Menu_Command_Proc receives one host-normalized native command. It
// matches native/sdl_gpu's Application_Menu_Command_Proc so applications can
// map menu handlers directly once the host exposes menus.
Hosted_Menu_Command_Proc :: proc(state: rawptr, rt: ^Runtime, command: Action_ID)

Hosted_Close_Result :: enum { Allow, Defer }

// Hosted_Close_Requested_Proc decides whether a host close request may proceed.
// Defer keeps the surface alive; the application calls hosted_quit_request when
// its own save/discard policy completes. Without a callback the host closes.
Hosted_Close_Requested_Proc :: proc(state: rawptr, rt: ^Runtime) -> Hosted_Close_Result

// Hosted_Runtime_Config describes one host-owned surface. It owns one retained
// Runtime for every control rendered into that surface. Renderer and native
// window ownership stay with the embedding host.
Hosted_Runtime_Config :: struct {
	state: rawptr,
	logical_width, logical_height: int,
	pixel_width, pixel_height: int,
	dpi_scale: f32,
	runtime: Runtime_Config,
	// menus are borrowed for the Hosted_Runtime lifetime. A host's native menu
	// adapter snapshots labels and structure at initialization; Action_State is
	// read from this borrowed storage whenever a menu opens or an accelerator
	// matches. menu_presentation is host policy (see Menu_Presentation).
	menus: []Menu,
	menu_presentation: Menu_Presentation,
	// window_decorations selects native chrome policy. Integrated_Title_Bar is
	// the Windows host-owned titlebar band; Content_Title_Bar is the macOS
	// full-size-content mode. System leaves chrome entirely with the platform.
	window_decorations: Window_Decoration_Mode,
	// window_chrome_height is the application-authored header height. It is
	// informational for hosts that measure their own native band.
	window_chrome_height: f32,
	// The chrome callbacks mirror native/sdl_gpu's Application fields. The
	// layout callback is sampled after retained layout; its returned slice is
	// borrowed only for that call.
	window_chrome_metrics: Window_Chrome_Metrics_Proc,
	window_chrome_layout: Window_Chrome_Layout_Proc,
	window_chrome_appearance: Window_Chrome_Appearance_Proc,
	// chrome_paint appends host-owned chrome commands after application paint
	// during presentation. Width and height include the chrome band.
	chrome_paint: Hosted_Chrome_Paint_Proc,
	chrome_paint_data: rawptr,
	// diagnostics_paint appends host-owned diagnostic overlays after
	// application paint and chrome for the next presented frame. The built-in
	// hosts install it automatically; applications never opt in. Returning nil
	// means diagnostics are hidden.
	diagnostics_paint: Hosted_Chrome_Paint_Proc,
	diagnostics_paint_data: rawptr,
	// content_inset_top reserves host-owned chrome above the application
	// viewport. The host updates it with hosted_runtime_set_content_inset when
	// native geometry changes.
	content_inset_top: f32,
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
	on_menu_command: Hosted_Menu_Command_Proc,
	on_close_requested: Hosted_Close_Requested_Proc,
	on_dialog: Hosted_Dialog_Proc,
	// on_file_drop receives one borrowed path per host file-drop event. Browser
	// hosts have no equivalent and leave it unused.
	on_file_drop: Hosted_File_Drop_Proc,
	// on_tick is the optional ~60 Hz application callback. Installing it keeps
	// the hosted deadline cadence armed; it is not an idle poll.
	on_tick: Hosted_Tick_Proc,
	// interaction_update_policy requests a corrective description after a
	// consumed widget interaction, mirroring the native host's bounded
	// stabilization loop.
	interaction_update_policy: Interaction_Update_Policy,
	// monotonic_now supplies scheduler/interaction timestamps. The host should
	// pass the same clock used for hosted_runtime_step.
	monotonic_now: Hosted_Monotonic_Now_Proc,
	monotonic_now_data: rawptr,
	// on_after_frame runs after end_frame of the description pass that just
	// completed and before presentation, matching the reference host's
	// build-then-after-frame ordering. It runs every described frame, including
	// the final frame before an idle period.
	on_after_frame: Hosted_After_Frame_Proc,
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
HOSTED_TICK_INTERVAL_NS :: u64(16_666_667)
HOSTED_DRAG_AUTOSCROLL_INTERVAL_NS :: u64(16_000_000)
HOSTED_UNCERTIFIED_MOTION_LIMIT_NS :: u64(5_000_000_000)
HOSTED_MAX_MONOTONIC_NS :: u64(0x7fff_ffff_ffff_ffff)
HOSTED_DESCRIPTION_STABILIZATION_LIMIT :: 4

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
	menus: []Menu,
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
	on_menu_command: Hosted_Menu_Command_Proc,
	on_close_requested: Hosted_Close_Requested_Proc,
	on_dialog: Hosted_Dialog_Proc,
	on_file_drop: Hosted_File_Drop_Proc,
	on_tick: Hosted_Tick_Proc,
	on_after_frame: Hosted_After_Frame_Proc,
	interaction_update_policy: Interaction_Update_Policy,
	monotonic_now: Hosted_Monotonic_Now_Proc,
	monotonic_now_data: rawptr,
	window_decorations: Window_Decoration_Mode,
	window_chrome_height: f32,
	window_chrome_metrics: Window_Chrome_Metrics_Proc,
	window_chrome_layout: Window_Chrome_Layout_Proc,
	window_chrome_appearance: Window_Chrome_Appearance_Proc,
	chrome_paint: Hosted_Chrome_Paint_Proc,
	chrome_paint_data: rawptr,
	diagnostics_paint: Hosted_Chrome_Paint_Proc,
	diagnostics_paint_data: rawptr,
	logical_width, logical_height: int,
	window_logical_width, window_logical_height: int,
	content_inset_top: f32,
	// hosted_display stages window-space application paint plus host chrome for
	// one presentation. It is reused across frames and owned by this state.
	hosted_display: [dynamic]Paint_Command,
	dpi_scale: f32,
	// scheduled owns the two replaceable application deadlines. app deadlines
	// and interaction timestamps use the host's monotonic clock.
	scheduled: Scheduled_Wake_State,
	scheduler_stats: Application_Scheduler_Stats,
	last_interaction_ns: u64,
	last_tick_ns: u64,
	has_tick: bool,
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

// hosted_app_logical_height mirrors native/sdl_gpu's content transform: the
// application viewport excludes host-owned chrome, keeps at least one logical
// pixel for a non-empty window, and never reports a negative height.
hosted_app_logical_height :: proc(window_height: int, inset_top: f32) -> int {
	if window_height <= 0 { return 0 }
	height := f32(window_height)
	inset := clamp(inset_top, 0, height)
	app := max(height-inset, min(height, 1))
	return int(app)
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
	inset_top := clamp(config.content_inset_top, 0, f32(config.logical_height))
	state^ = Hosted_Runtime_State{
		allocator=state_allocator,
		owner_thread_id=sync.current_thread_id(),
		app_state=config.state,
		menus=config.menus,
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
		on_menu_command=config.on_menu_command,
		on_close_requested=config.on_close_requested,
		on_dialog=config.on_dialog,
		on_file_drop=config.on_file_drop,
		on_tick=config.on_tick,
		on_after_frame=config.on_after_frame,
		interaction_update_policy=config.interaction_update_policy,
		monotonic_now=config.monotonic_now,
		monotonic_now_data=config.monotonic_now_data,
		window_decorations=config.window_decorations,
		window_chrome_height=config.window_chrome_height,
		window_chrome_metrics=config.window_chrome_metrics,
		window_chrome_layout=config.window_chrome_layout,
		window_chrome_appearance=config.window_chrome_appearance,
		chrome_paint=config.chrome_paint,
		chrome_paint_data=config.chrome_paint_data,
		diagnostics_paint=config.diagnostics_paint,
		diagnostics_paint_data=config.diagnostics_paint_data,
		logical_width=config.logical_width,
		logical_height=hosted_app_logical_height(config.logical_height, inset_top),
		window_logical_width=config.logical_width,
		window_logical_height=config.logical_height,
		content_inset_top=inset_top,
		dpi_scale=config.dpi_scale,
		renderable=true,
	}
	state.runtime = new_runtime(
		Rect{0, 0, f32(state.logical_width), f32(state.logical_height)},
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
	services := config.host_services
	services.scheduler = hosted_runtime_scheduler_service(state)
	if config.on_host_services != nil { config.on_host_services(config.state, services) }
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

// hosted_runtime_clock_now reads the host's monotonic clock. A host that does
// not install one falls back to the last step time, which keeps scheduler
// deadlines relative to the hosted loop's only known time domain.
hosted_runtime_clock_now :: proc(state: ^Hosted_Runtime_State) -> u64 {
	if state == nil { return 0 }
	now := state.last_step_ns
	if state.monotonic_now != nil {
		now = state.monotonic_now(state.monotonic_now_data)
	}
	return min(now, HOSTED_MAX_MONOTONIC_NS)
}

@(private)
hosted_scheduler_schedule :: proc(data: rawptr, class: Scheduled_Wake_Class, delay_ns: u64) -> bool {
	state := cast(^Hosted_Runtime_State)data
	if state == nil || state.closed { return false }
	if scheduled_wake_class_index(class) < 0 { return false }
	if state.scheduled.pending[scheduled_wake_class_index(class)] {
		state.scheduler_stats.coalesced += 1
	}
	if !scheduled_wake_state_schedule(&state.scheduled, class, hosted_runtime_clock_now(state), delay_ns) {
		return false
	}
	state.scheduler_stats.scheduled += 1
	return true
}

@(private)
hosted_scheduler_cancel :: proc(data: rawptr, class: Scheduled_Wake_Class) -> bool {
	state := cast(^Hosted_Runtime_State)data
	if state == nil || state.closed { return false }
	return scheduled_wake_state_cancel(&state.scheduled, class)
}

@(private)
hosted_scheduler_read_stats :: proc(data: rawptr) -> Application_Scheduler_Stats {
	state := cast(^Hosted_Runtime_State)data
	if state == nil { return {} }
	result := state.scheduler_stats
	result.frequent_pending = state.scheduled.pending[0]
	result.opportunistic_pending = state.scheduled.pending[1]
	return result
}

hosted_runtime_scheduler_service :: proc(state: ^Hosted_Runtime_State) -> Application_Scheduler {
	if state == nil { return {} }
	return Application_Scheduler{
		data=rawptr(state),
		schedule=hosted_scheduler_schedule,
		cancel=hosted_scheduler_cancel,
		read_stats=hosted_scheduler_read_stats,
	}
}

// hosted_runtime_note_interaction updates the input-quiet timestamp used to
// defer Opportunistic work. Hosts with an event queue call it for keyboard,
// text, pointer, and scroll input; the standard hosted input entry points also
// call it so a host cannot silently lose the quiet window. Pass zero to use the
// installed monotonic clock.
hosted_runtime_note_interaction :: proc(host: ^Hosted_Runtime, now_ns: u64 = 0) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	timestamp := now_ns
	if timestamp == 0 { timestamp = hosted_runtime_clock_now(state) }
	timestamp = min(timestamp, HOSTED_MAX_MONOTONIC_NS)
	if timestamp != 0 { state.last_interaction_ns = timestamp }
	return .Ok
}

@(private)
hosted_dispatch_scheduled_wakes :: proc(state: ^Hosted_Runtime_State, now_ns: u64) {
	classes := [SCHEDULED_WAKE_CLASS_COUNT]Scheduled_Wake_Class{.Frequent, .Opportunistic}
	for class in classes {
		if !scheduled_wake_state_is_due(&state.scheduled, class, now_ns) { continue }
		index := scheduled_wake_class_index(class)
		if class == .Opportunistic {
			deferred_until, defer_work := scheduled_wake_defer_until_quiet(
				now_ns, state.last_interaction_ns, APPLICATION_OPPORTUNISTIC_QUIET_NS,
			)
			if defer_work {
				state.scheduled.deadlines_ns[index] = deferred_until
				state.scheduler_stats.opportunistic_deferrals += 1
				continue
			}
		}
		deadline_ns := state.scheduled.deadlines_ns[index]
		lateness_ns := u64(0)
		if now_ns > deadline_ns { lateness_ns = now_ns-deadline_ns }
		state.scheduled.pending[index] = false
		if class == .Frequent { state.scheduler_stats.frequent_wakes += 1 }
		else { state.scheduler_stats.opportunistic_wakes += 1 }
		state.scheduler_stats.maximum_lateness_ns = max(state.scheduler_stats.maximum_lateness_ns, lateness_ns)
		if state.on_scheduled_wake != nil {
			reason := class == .Frequent ? "frequent scheduled work" : "opportunistic scheduled work"
			cause := cause_begin(&state.runtime, .Scheduled_Wake, reason)
			state.on_scheduled_wake(state.app_state, &state.runtime, class)
			cause_end(&state.runtime, cause)
		}
	}
}

@(private)
hosted_dispatch_tick :: proc(state: ^Hosted_Runtime_State, now_ns: u64) {
	if state.on_tick == nil { return }
	if !state.has_tick {
		state.has_tick = true
		state.last_tick_ns = now_ns
		return
	}
	if now_ns < state.last_tick_ns || now_ns-state.last_tick_ns < HOSTED_TICK_INTERVAL_NS { return }
	tick_cause := cause_begin(&state.runtime, .Application, "application tick")
	state.on_tick(state.app_state, &state.runtime)
	cause_end(&state.runtime, tick_cause)
	state.last_tick_ns = now_ns
}

@(private)
hosted_tick_deadline :: proc(state: ^Hosted_Runtime_State, now_ns: u64) -> u64 {
	if state.on_tick == nil { return 0 }
	if !state.has_tick { return hosted_deadline_after(now_ns, HOSTED_TICK_INTERVAL_NS) }
	return hosted_deadline_after(state.last_tick_ns, HOSTED_TICK_INTERVAL_NS)
}

// hosted_description_root identifies the application root described in the
// open frame. The reference host requires the application description to own
// its root, so a top-level `.Root` node is authoritative; a top-level node of
// another kind is adopted as a fallback so a malformed description still
// reports something useful to the host.
@(private)
hosted_description_root :: proc(rt: ^Runtime) -> Node_ID {
	fallback: Node_ID
	for item in rt.pending {
		if item.kind != .Description { continue }
		description := item.description
		if description.parent != 0 { continue }
		if fallback == 0 { fallback = description.id }
		if description.kind == .Root { return description.id }
	}
	return fallback
}

// hosted_root_describe runs one bounded application description sequence. The
// application's description establishes the root directly, exactly like
// native/sdl_gpu's Application.build contract; the hosted runtime does not wrap
// it in a host-owned root column. Host-owned chrome remains expressed through
// content_inset_top, which reduces the application viewport, and host chrome /
// diagnostics paint are appended at the presentation boundary.
hosted_root_describe :: proc(state: ^Hosted_Runtime_State) -> Node_ID {
	rt := &state.runtime
	root: Node_ID
	passes := 0
	for rt.invalidated && passes < HOSTED_DESCRIPTION_STABILIZATION_LIMIT {
		interaction_sequence := rt.interaction_consumption_sequence
		ui, should_build := begin_frame(rt)
		if !should_build { break }
		state.render(state.app_state, &ui, state.logical_width, state.logical_height, state.dpi_scale)
		root = hosted_description_root(rt)
		if state.render_overlays != nil {
			state.render_overlays(state.app_state, &ui, state.logical_width, state.logical_height, state.dpi_scale)
		}
		end_frame(&ui)
		// Post-layout application work runs after end_frame of this same pass and
		// before the host presents it, matching native/sdl_gpu. It runs even when
		// no further frame is scheduled.
		if state.on_after_frame != nil { state.on_after_frame(state.app_state, rt) }
		passes += 1
		if state.interaction_update_policy == .Correct_After_Interaction &&
		   rt.interaction_consumption_sequence != interaction_sequence && !rt.invalidated {
			invalidate_root(rt, "corrective description after consumed interaction")
		}
	}
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
	deadline: u64
	if scheduled_deadline, found := scheduled_wake_state_next_deadline(&state.scheduled); found {
		deadline = scheduled_deadline
	}
	// Ticks run while hidden as well, matching the reference host's event loop.
	deadline = hosted_deadline_min(deadline, hosted_tick_deadline(state, now_ns))
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
// bounded application description sequence. Call it from the native UI loop
// after each bounded batch of input events or one-shot timer. It never waits or
// polls.
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
	hosted_dispatch_tick(state, now_ns)
	hosted_dispatch_scheduled_wakes(state, now_ns)
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

// hosted_runtime_set_deadline installs one legacy application-owned, one-shot
// monotonic deadline in the Frequent class. It is cleared before
// on_scheduled_wake runs, so that callback may safely arm the next one. Pass
// zero to cancel. Prefer the Hosted_Host_Services.scheduler service for new
// code because it preserves the wake class.
hosted_runtime_set_deadline :: proc(host: ^Hosted_Runtime, deadline_ns: u64) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if deadline_ns > HOSTED_MAX_MONOTONIC_NS { return .Invalid_Argument }
	state.scheduled.pending[0] = deadline_ns != 0
	state.scheduled.deadlines_ns[0] = deadline_ns
	return .Ok
}

// hosted_runtime_file_drop delivers one native file-drop path to the
// application callback under the same host-event cause as the reference SDL
// host and invalidates the description. The path is borrowed only for the
// callback.
hosted_runtime_file_drop :: proc(host: ^Hosted_Runtime, path: string) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if state.on_file_drop != nil {
		drop_cause := cause_begin(&state.runtime, .Host_Event, "hosted file drop")
		state.on_file_drop(state.app_state, &state.runtime, path)
		invalidate_root(&state.runtime, "hosted application file drop")
		cause_end(&state.runtime, drop_cause)
	}
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
	next_inset := clamp(state.content_inset_top, 0, f32(logical_height))
	next_height := hosted_app_logical_height(logical_height, next_inset)
	logical_changed := logical_width != state.logical_width || next_height != state.logical_height
	window_logical_changed := logical_width != state.window_logical_width || logical_height != state.window_logical_height
	dpi_changed := dpi_scale != state.dpi_scale
	state.window_logical_width, state.window_logical_height = logical_width, logical_height
	state.content_inset_top = next_inset
	state.logical_width, state.logical_height = logical_width, next_height
	state.dpi_scale = dpi_scale
	if logical_changed || window_logical_changed {
		rt.viewport.w = f32(logical_width)
		rt.viewport.h = f32(next_height)
		invalidate_root(rt, "hosted surface logical size changed")
	} else if dpi_changed {
		invalidate_root(rt, "hosted surface DPI changed")
	}
	if pixel_width > 0 && pixel_height > 0 && logical_width > 0 && logical_height > 0 {
		_ = set_presentation_scale(rt, f32(pixel_width)/f32(logical_width), f32(pixel_height)/f32(logical_height))
	}
	return .Ok
}

// hosted_runtime_set_content_inset publishes host-owned chrome reserved above
// the application viewport. Input coordinates over that band are withheld from
// the application (unless a capture is active), application descriptions see
// the reduced height, and presentation translates app paint below the band.
// Mirrors native/sdl_gpu's content_inset_top semantics.
hosted_runtime_set_content_inset :: proc(
	host: ^Hosted_Runtime,
	inset_top: f32,
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if math.is_nan(inset_top) || math.is_inf(inset_top) { return .Invalid_Argument }
	next := clamp(inset_top, 0, f32(state.window_logical_height))
	if next == state.content_inset_top { return .Ok }
	state.content_inset_top = next
	next_height := hosted_app_logical_height(state.window_logical_height, next)
	if next_height != state.logical_height {
		state.logical_height = next_height
		state.runtime.viewport.w = f32(state.logical_width)
		state.runtime.viewport.h = f32(next_height)
		invalidate_root(&state.runtime, "hosted surface content inset changed")
	}
	return .Ok
}

// hosted_runtime_content_inset reports the current host chrome inset.
hosted_runtime_content_inset :: proc(host: ^Hosted_Runtime) -> (inset_top: f32, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return 0, access_status }
	return state.content_inset_top, .Ok
}

hosted_runtime_pointer :: proc(host: ^Hosted_Runtime, event: Pointer_Event) -> (target: Node_ID, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return 0, access_status }
	_ = hosted_runtime_note_interaction(host, event.timestamp_ns)
	rt := &state.runtime
	dispatched_event := event
	if state.content_inset_top > 0 && event.kind != .Cancel {
		// Pointer coordinates arrive in window-logical space. The application
		// viewport starts below host-owned chrome. A captured interaction keeps
		// receiving the event (clamped) until the host cancels it explicitly,
		// matching the native host's chrome-ownership handoff.
		if event.y < state.content_inset_top || event.y >= f32(state.window_logical_height) {
			if rt.captured_node == 0 { return 0, .Ok }
			dispatched_event.y = 0
		} else {
			dispatched_event.y -= state.content_inset_top
		}
	}
	cause := pointer_cause_begin(rt, dispatched_event.kind)
	target = process_pointer(rt, dispatched_event)
	if key, ok := node_identity_key(rt, target); ok { dispatched_event.target_key = key }
	if state.on_pointer != nil {
		state.on_pointer(state.app_state, rt, dispatched_event, target)
		if dispatched_event.kind == .Down || dispatched_event.kind == .Up {
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
// the owning UI thread. key_code remains opaque: Runtime does not interpret
// host key constants, so an external host's own numeric values can never
// trigger Alicorn text-field or interaction-scope preemption. The host retains
// platform policy and calls hosted_runtime_application_key when it has
// translated a key into the Application_Key vocabulary.
// hosted_runtime_pointer_cancel cancels a captured application interaction
// when host chrome takes pointer ownership. It mirrors the native host's
// explicit pointer-cancel path without changing window focus.
hosted_runtime_pointer_cancel :: proc(host: ^Hosted_Runtime) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	rt := &state.runtime
	captured := rt.captured_node
	drag_was_active := drag_is_active(rt)
	if captured == 0 && !drag_was_active { return .Ok }
	cancel_cause := pointer_cause_begin(rt, .Cancel)
	_ = cancel_pointer_capture(rt)
	state.drag_deadline_ns = 0
	if drag_was_active && drag_is_active(rt) { _ = drag_cancel(rt) }
	if drag_event, pending := drag_event_take(rt); pending && state.on_drag != nil {
		state.on_drag(state.app_state, rt, drag_event)
	}
	if state.on_pointer != nil {
		cancelled := Pointer_Event{kind=.Cancel}
		if key, ok := node_identity_key(rt, captured); ok { cancelled.target_key = key }
		state.on_pointer(state.app_state, rt, cancelled, captured)
	}
	cause_end(rt, cancel_cause)
	return .Ok
}

hosted_runtime_key :: proc(host: ^Hosted_Runtime, event: Hosted_Key_Event) -> (handled: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	_ = hosted_runtime_note_interaction(host)
	if state.on_key == nil { return false, .Ok }
	focused_owner := focused_node(&state.runtime)
	handled = state.on_key(state.app_state, &state.runtime, focused_owner, event)
	if handled { invalidate_root(&state.runtime, "hosted application key callback") }
	return handled, .Ok
}

// hosted_runtime_application_key delivers one key the host has explicitly
// mapped to Alicorn's Application_Key vocabulary. The typed key enables the
// shared interaction-scope preemption policy and the text-field/IME guard;
// the accompanying Hosted_Key_Event still reaches on_key for application
// shortcuts, with its key_code remaining opaque. Hosts that have not adopted
// Application_Key must use hosted_runtime_key instead.
hosted_runtime_application_key :: proc(
	host: ^Hosted_Runtime,
	key: Application_Key,
	event: Hosted_Key_Event,
) -> (handled: bool, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return false, access_status }
	_ = hosted_runtime_note_interaction(host)
	if event.pressed {
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
	_ = hosted_runtime_note_interaction(host)
	dispatched_event := event
	if state.content_inset_top > 0 {
		if event.y < state.content_inset_top || event.y >= f32(state.window_logical_height) {
			return false, .Ok
		}
		dispatched_event.y -= state.content_inset_top
	}
	cause := cause_begin(&state.runtime, .Scroll, "hosted scroll event")
	if state.on_scroll_capture != nil {
		target := scroll_region_hit_test(&state.runtime, dispatched_event.x, dispatched_event.y)
		if target != 0 { handled = state.on_scroll_capture(state.app_state, &state.runtime, dispatched_event, target) }
	}
	if !handled { handled = process_scroll(&state.runtime, dispatched_event) }
	if !handled && state.on_scroll != nil {
		state.on_scroll(state.app_state, &state.runtime, dispatched_event)
		handled = true
	}
	cause_end(&state.runtime, cause)
	return handled, .Ok
}

// hosted_runtime_request_close asks the application whether a host close
// request may proceed. A missing callback preserves the host's immediate-close
// behavior. A Defer result requires the host to keep the surface alive until
// the application completes its policy through Hosted_Quit_Service.
hosted_runtime_request_close :: proc(
	host: ^Hosted_Runtime,
) -> (result: Hosted_Close_Result, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return .Allow, access_status }
	if state.on_close_requested != nil {
		result = state.on_close_requested(state.app_state, &state.runtime)
	}
	return result, .Ok
}

// hosted_runtime_menu_command routes one host-normalized command through the
// application callback under the same native-command cause used by the SDL_GPU
// host. Hosts call it when their menus, accelerators, or chrome actions fire.
// Commands rejected by the shared enabled gate (a disabled top-level direct
// command, a command carried only by disabled menu items, or a disabled
// runtime action) are neither delivered nor traced.
hosted_runtime_menu_command :: proc(
	host: ^Hosted_Runtime,
	command: Action_ID,
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if state.on_menu_command != nil {
		if !menu_command_enabled(state.menus, &state.runtime, command) { return .Ok }
		cause := cause_begin(&state.runtime, .Native_Command, "hosted menu command", command)
		state.on_menu_command(state.app_state, &state.runtime, command)
		invalidate_root(&state.runtime, "hosted application menu command")
		cause_end(&state.runtime, cause)
	}
	return .Ok
}

// hosted_runtime_dialog delivers one host-owned asynchronous dialog completion.
// The host calls it on the Runtime owner thread after copying the completion out
// of its event source. Result strings remain borrowed for the callback.
hosted_runtime_dialog :: proc(
	host: ^Hosted_Runtime,
	result: ^File_Dialog_Result,
) -> Hosted_Runtime_Status {
	state, status := hosted_runtime_get_state(host)
	if status != .Ok { return status }
	if state.on_dialog != nil {
		cause := cause_begin(&state.runtime, .Async_Wake, "hosted file dialog completed")
		state.on_dialog(state.app_state, &state.runtime, result)
		cause_end(&state.runtime, cause)
	}
	return .Ok
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
	_ = hosted_runtime_note_interaction(host)
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

// hosted_paint_command_apply_content_inset translates application logical
// geometry into window space exactly once, at the presentation boundary.
hosted_paint_command_apply_content_inset :: proc(command: Paint_Command, inset_top: f32) -> Paint_Command {
	result := command
	if inset_top > 0 {
		result.bounds.y += inset_top
		result.clip.y += inset_top
	}
	return result
}

// hosted_runtime_presentation_list returns the commands a presenter should
// encode for this surface. Application paint is translated below host-owned
// chrome and host chrome paint is appended after it, mirroring native/sdl_gpu's
// draw_display_list overlay order. With no inset and no chrome provider the
// retained display list is returned without copying. Otherwise commands are
// staged in Runtime-owned storage and remain valid until the next call.
hosted_runtime_presentation_list :: proc(
	host: ^Hosted_Runtime,
	allocator := context.allocator,
) -> (view: Paint_Display_List_View, status: Hosted_Runtime_Status) {
	state, access_status := hosted_runtime_get_state(host)
	if access_status != .Ok { return {}, access_status }
	rt := &state.runtime
	if rt.frame_open { return {}, .Invalid_Argument }
	has_chrome := state.chrome_paint != nil && state.window_decorations != .System
	has_diagnostics := state.diagnostics_paint != nil
	if state.content_inset_top <= 0 && !has_chrome && !has_diagnostics {
		view = Paint_Display_List_View{commands=rt.display[:], revision=rt.presentation_revision}
		return view, .Ok
	}
	// Host chrome and diagnostic paint are transient: shape/command storage
	// comes from the Runtime scratch arena and is invalid after the next Runtime
	// mutation.
	chrome_allocator := allocator
	if rt.scratch_allocator.procedure != nil { chrome_allocator = rt.scratch_allocator }
	chrome: []Paint_Command
	if has_chrome {
		chrome = state.chrome_paint(
			state.chrome_paint_data,
			rt,
			f32(state.window_logical_width),
			f32(state.window_logical_height),
			chrome_allocator,
		)
	}
	// Diagnostics are appended last so bounds outlines and the performance HUD
	// stay above application paint and host chrome, matching native/sdl_gpu's
	// overlay order.
	overlays: []Paint_Command
	if has_diagnostics {
		overlays = state.diagnostics_paint(
			state.diagnostics_paint_data,
			rt,
			f32(state.window_logical_width),
			f32(state.window_logical_height),
			chrome_allocator,
		)
	}
	required := len(rt.display)+len(chrome)+len(overlays)
	clear(&state.hosted_display)
	if required > 0 && state.hosted_display == nil {
		state.hosted_display = make([dynamic]Paint_Command, 0, required, allocator=state.allocator)
		if state.hosted_display == nil { return {}, .Invalid_Argument }
	}
	if required > cap(state.hosted_display) && state.hosted_display != nil {
		reserve(&state.hosted_display, required)
	}
	for command in rt.display {
		append(&state.hosted_display, hosted_paint_command_apply_content_inset(command, state.content_inset_top))
	}
	for command in chrome { append(&state.hosted_display, command) }
	for command in overlays { append(&state.hosted_display, command) }
	view = Paint_Display_List_View{
		commands=state.hosted_display[:],
		revision=rt.presentation_revision,
	}
	return view, .Ok
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
	if state.hosted_display != nil { delete(state.hosted_display) }
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
