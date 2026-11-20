#+build !js

package alicorn

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// Hosted_Services_Test_App exercises the hosted scheduler, clipboard, file-drop,
// tick, and corrective-description surface without a native window.
Hosted_Services_Test_App :: struct {
	host: ^Hosted_Runtime,
	// clock is the injected monotonic time used by scheduler requests.
	clock: u64,
	scheduler: Application_Scheduler,
	scheduler_available: bool,
	clipboard: Clipboard_Service,
	clipboard_text: string,
	clipboard_ok: bool,
	services_seen: bool,
	builds: int,
	ticks: int,
	scheduled_frequent: int,
	scheduled_opportunistic: int,
	last_class: Scheduled_Wake_Class,
	file_drops: int,
	drop_ok: bool,
	clicks: int,
}

hosted_services_test_clock :: proc(data: rawptr) -> u64 {
	return (cast(^Hosted_Services_Test_App)data).clock
}

hosted_services_test_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_services_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Services_Test_App)data
	app.builds += 1
	root := container_begin(
		ui,
		.Root,
		label="hosted-services-root",
		key="hosted-services-root",
		style=layout_style(.Column, padding=8, gap=4),
	)
	if root == 0 { return }
	if button(ui, "Increment", key="hosted-services-button", style=layout_style(.Row, width=120, height=32)) {
		app.clicks += 1
	}
	text(ui, fmt.tprintf("count %d", app.clicks), key="hosted-services-count")
	container_end(ui)
}

hosted_services_test_services :: proc(data: rawptr, services: Hosted_Host_Services) {
	app := cast(^Hosted_Services_Test_App)data
	app.services_seen = true
	app.scheduler = services.scheduler
	app.scheduler_available = services.scheduler.schedule != nil && services.scheduler.cancel != nil &&
		services.scheduler.read_stats != nil
	app.clipboard = services.clipboard
	ok := ClipboardSetText(services.clipboard, "hosted clipboard roundtrip")
	text_value, read_ok := ClipboardGetText(services.clipboard)
	defer if len(text_value) > 0 { delete(text_value) }
	app.clipboard_ok = ok && read_ok && text_value == "hosted clipboard roundtrip"
}

hosted_services_test_scheduled :: proc(data: rawptr, _rt: ^Runtime, class: Scheduled_Wake_Class) {
	app := cast(^Hosted_Services_Test_App)data
	app.last_class = class
	switch class {
	case .Frequent: app.scheduled_frequent += 1
	case .Opportunistic: app.scheduled_opportunistic += 1
	}
}

hosted_services_test_tick :: proc(data: rawptr, _rt: ^Runtime) {
	app := cast(^Hosted_Services_Test_App)data
	app.ticks += 1
}

hosted_services_test_file_drop :: proc(data: rawptr, _rt: ^Runtime, path: string) {
	app := cast(^Hosted_Services_Test_App)data
	app.file_drops += 1
	app.drop_ok = path == "C:/alicorn/drop.txt"
}

Hosted_Services_Clipboard_Backend :: struct {
	text: string,
}

hosted_services_clipboard_get :: proc(data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	backend := cast(^Hosted_Services_Clipboard_Backend)data
	cloned, err := strings.clone(backend.text, allocator)
	return cloned, err == nil
}

hosted_services_clipboard_set :: proc(data: rawptr, text: string) -> bool {
	backend := cast(^Hosted_Services_Clipboard_Backend)data
	if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	cloned, err := strings.clone(text, context.allocator)
	if err != nil { return false }
	backend.text = cloned
	return true
}

hosted_services_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Services_Test_App,
	backend: ^Hosted_Services_Clipboard_Backend,
	policy: Interaction_Update_Policy,
	with_services := true,
	with_tick := false,
) -> Hosted_Runtime_Status {
	app.host = host
	config := Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=320,
		logical_height=200,
		pixel_width=320,
		pixel_height=200,
		dpi_scale=1,
		post_wake_data=rawptr(app),
		post_wake=hosted_services_test_post,
		render=hosted_services_test_render,
		monotonic_now=hosted_services_test_clock,
		monotonic_now_data=rawptr(app),
		on_scheduled_wake=hosted_services_test_scheduled,
		on_file_drop=hosted_services_test_file_drop,
		interaction_update_policy=policy,
	}
	if with_tick { config.on_tick = hosted_services_test_tick }
	if with_services {
		config.on_host_services = hosted_services_test_services
		config.host_services.clipboard = Clipboard_Service{
			data=rawptr(backend),
			get_text=hosted_services_clipboard_get,
			set_text=hosted_services_clipboard_set,
		}
	}
	return hosted_runtime_init(host, config)
}

@(test)
test_hosted_services_publish_native_shaped_scheduler_and_clipboard :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	if hosted_services_test_open(&host, &app, &backend, .Explicit) != .Ok {
		testing.expect(t, false, "hosted services fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	testing.expect(t, app.services_seen && app.scheduler_available,
		"host services are delivered before start with a fully populated scheduler")
	testing.expect(t, app.clipboard_ok,
		"the hosted clipboard service is the synchronous native shape and supports a set/get roundtrip")
}

@(test)
test_hosted_scheduler_classes_arm_cancel_coalesce_and_run_once :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Explicit) != .Ok {
		testing.expect(t, false, "hosted scheduler fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	app.clock = 1_000
	testing.expect(t, application_schedule_after(app.scheduler, .Frequent, 100),
		"a frequent deadline should be accepted through the published scheduler service")
	armed := hosted_runtime_step(&host, 1_000)
	testing.expect(t, armed.next_wake_ns == 1_100 && app.scheduled_frequent == 0,
		"a future class deadline is reported to the host without running early")
	early := hosted_runtime_step(&host, 1_099)
	testing.expect(t, early.next_wake_ns == 1_100 && app.scheduled_frequent == 0,
		"a pending class deadline must not spuriously run")
	due := hosted_runtime_step(&host, 1_100)
	testing.expect(t, due.next_wake_ns == 0 && app.scheduled_frequent == 1 &&
		app.last_class == .Frequent,
		"the due class runs once with its class and leaves no recurring timer")
	stats := application_scheduler_stats(app.scheduler)
	testing.expect(t, stats.frequent_wakes == 1 && stats.scheduled == 1 && !stats.frequent_pending &&
		stats.maximum_lateness_ns == 0,
		"the scheduler reports run, request, pending, and lateness state")
	testing.expect(t, application_cancel_scheduled_wake(app.scheduler, .Frequent),
		"cancel accepts a class whether or not it is pending")
	app.clock = 2_000
	_ = hosted_runtime_step(&host, 2_000)
	testing.expect(t, application_schedule_after(app.scheduler, .Frequent, 10) &&
		application_schedule_after(app.scheduler, .Frequent, 20),
		"a class deadline is replaceable")
	stats = application_scheduler_stats(app.scheduler)
	testing.expect(t, stats.coalesced == 1 && stats.frequent_pending,
		"replacing pending work in one class is observable as coalesced")
	_ = hosted_runtime_step(&host, 2_010)
	testing.expect(t, app.scheduled_frequent == 1, "the replaced frequent deadline should still be future work")
	_ = hosted_runtime_step(&host, 2_020)
	testing.expect(t, app.scheduled_frequent == 2,
		"the final replacement deadline runs once, not the discarded earlier deadline")
}

@(test)
test_hosted_opportunistic_wake_waits_for_input_quiet :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Explicit) != .Ok {
		testing.expect(t, false, "hosted opportunistic fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1_000)
	_ = hosted_runtime_note_interaction(&host, 1_000)
	testing.expect(t, application_schedule_after(app.scheduler, .Opportunistic, 10),
		"an opportunistic deadline should be accepted")
	deferred := hosted_runtime_step(&host, 1_010)
	stats := application_scheduler_stats(app.scheduler)
	testing.expect(t, app.scheduled_opportunistic == 0 && stats.opportunistic_deferrals == 1 &&
		deferred.next_wake_ns == 1_000+APPLICATION_OPPORTUNISTIC_QUIET_NS,
		"opportunistic work waits for 150 ms of input quiet and reports the deferral")
	before := hosted_runtime_step(&host, 1_000+APPLICATION_OPPORTUNISTIC_QUIET_NS-1)
	testing.expect(t, app.scheduled_opportunistic == 0 && before.next_wake_ns == 1_000+APPLICATION_OPPORTUNISTIC_QUIET_NS,
		"the deferred deadline must not run before the quiet window elapses")
	_ = hosted_runtime_step(&host, 1_000+APPLICATION_OPPORTUNISTIC_QUIET_NS)
	testing.expect(t, app.scheduled_opportunistic == 1 && app.last_class == .Opportunistic,
		"opportunistic work runs after the quiet window with its class")
}

@(test)
test_hosted_file_drop_routes_borrowed_path_and_invalidates :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Explicit) != .Ok {
		testing.expect(t, false, "hosted file-drop fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	builds_before := app.builds
	testing.expect(t, hosted_runtime_file_drop(&host, "C:/alicorn/drop.txt") == .Ok,
		"a host file drop is delivered on the owner thread")
	step := hosted_runtime_step(&host, 2)
	testing.expect(t, app.file_drops == 1 && app.drop_ok,
		"the application receives the exact borrowed drop path")
	testing.expect(t, step.description_built && app.builds > builds_before,
		"a dropped file invalidates the application description")
}

@(test)
test_hosted_tick_matches_native_bounded_cadence :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Explicit, with_tick=true) != .Ok {
		testing.expect(t, false, "hosted tick fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	first := hosted_runtime_step(&host, 0)
	testing.expect(t, app.ticks == 0 && first.next_wake_ns == HOSTED_TICK_INTERVAL_NS,
		"installing on_tick arms one bounded tick deadline but does not fire on the first pass")
	_ = hosted_runtime_step(&host, HOSTED_TICK_INTERVAL_NS-1)
	testing.expect(t, app.ticks == 0, "ticks respect the same 16.67 ms cadence as the native host")
	ticked := hosted_runtime_step(&host, HOSTED_TICK_INTERVAL_NS)
	testing.expect(t, app.ticks == 1 && ticked.next_wake_ns == 2*HOSTED_TICK_INTERVAL_NS,
		"a due tick runs once and re-arms the next bounded cadence deadline")
}

@(test)
test_hosted_corrective_policy_updates_visible_state_after_consumed_interaction :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Correct_After_Interaction) != .Ok {
		testing.expect(t, false, "hosted corrective fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	builds_before := app.builds
	focused, focus_status := hosted_runtime_focus_traverse(&host, .Next)
	if !testing.expect(t, focus_status == .Ok && focused != 0,
		"the fixture should expose a focusable control") { return }
	activated, activate_status := hosted_runtime_activate(&host, .Enter)
	if !testing.expect(t, activate_status == .Ok && activated,
		"the focused control should accept activation") { return }
	step := hosted_runtime_step(&host, 2)
	testing.expect(t, app.clicks == 1 && step.description_built,
		"the consumed activation should produce one corrective description sequence")
	testing.expect(t, app.builds == builds_before+2,
		"the corrective policy rebuilds once after the interaction description")
}

@(test)
test_hosted_explicit_policy_keeps_one_description_per_step :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Services_Test_App
	backend := Hosted_Services_Clipboard_Backend{}
	defer if len(backend.text) > 0 { delete(backend.text, context.allocator) }
	if hosted_services_test_open(&host, &app, &backend, .Explicit) != .Ok {
		testing.expect(t, false, "hosted explicit fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	builds_before := app.builds
	focused, _ := hosted_runtime_focus_traverse(&host, .Next)
	if focused == 0 { testing.expect(t, false, "the explicit fixture should expose a control"); return }
	_, _ = hosted_runtime_activate(&host, .Enter)
	_ = hosted_runtime_step(&host, 2)
	testing.expect(t, app.clicks == 1 && app.builds == builds_before+1,
		"Explicit keeps the host in charge of invalidation and performs one description pass")
}
