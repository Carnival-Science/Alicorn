package alicorn_sdl_gpu

// The breadcrumb recorder implementation is shared. This file keeps the
// reference host's motion/window snapshot line, which reads native scheduler
// state, and adapts the shared recorder to this host's SDL clock.

import "core:fmt"
import "core:sync"
import "core:time"
import alicorn "../../runtime"
import diag "alicorn:host/diagnostics"
import "vendor:sdl3"

Native_Breadcrumb_Recorder :: diag.Breadcrumb_Recorder

native_breadcrumb_event_name_valid :: proc(name: string) -> bool {
	return diag.breadcrumb_event_name_valid(name)
}

native_breadcrumb_json_line :: proc(
	timestamp_utc: string,
	monotonic_ns: u64,
	thread_id: int,
	source, name: string,
	request_id: u64,
) -> string {
	return diag.breadcrumb_json_line(timestamp_utc, monotonic_ns, thread_id, source, name, request_id)
}

native_breadcrumb_event :: proc(
	recorder: ^Native_Breadcrumb_Recorder,
	source, name: string,
	request_id: u64 = 0,
) {
	diag.breadcrumb_event(recorder, source, name, request_id)
}

native_breadcrumb_write_line :: proc(recorder: ^Native_Breadcrumb_Recorder, line: string) {
	diag.breadcrumb_write_line(recorder, line)
}

// Motion visibility transitions carry a compact native/runtime snapshot so a
// minimize/restore fixture can identify whether an active response was really
// suspended and whether restore took one sample or replayed missed frames.
native_breadcrumb_motion_window_json_line :: proc(
	timestamp_utc: string,
	monotonic_ns: u64,
	thread_id: int,
	name: string,
	window_id: sdl3.WindowID,
	window_flags: sdl3.WindowFlags,
	window_renderable: bool,
	native_minimized: bool,
	gpu_submissions: u64,
	scheduler: ^Native_Motion_Scheduler_State,
	rt: ^alicorn.Runtime,
	activity: alicorn.Motion_Activity,
) -> string {
	if scheduler == nil || rt == nil || !diag.breadcrumb_event_name_valid(name) { return "" }
	hidden := (window_flags & sdl3.WindowFlags{.HIDDEN}) != sdl3.WindowFlags{}
	minimized := (window_flags & sdl3.WindowFlags{.MINIMIZED}) != sdl3.WindowFlags{}
	occluded := (window_flags & sdl3.WindowFlags{.OCCLUDED}) != sdl3.WindowFlags{}
	input_focus := (window_flags & sdl3.WindowFlags{.INPUT_FOCUS}) != sdl3.WindowFlags{}
	return fmt.tprintf(
		`{{"schema":1,"timestamp_utc":"%s","monotonic_ns":%d,"thread_id":%d,"source":"alicorn","event":"%s","window":{{"id":%d,"renderable":%t,"hidden":%t,"minimized":%t,"native_minimized":%t,"occluded":%t,"input_focus":%t}},"runtime":{{"active_owners":%d,"active_properties":%d,"unestablished_deadlines":%d,"frame_needs_submission":%t}},"scheduler":{{"active":%t,"suspended":%t,"suspended_since_ns":%d,"next_deadline_ns":%d,"samples":%d,"timer_wakes":%d,"restore_samples":%d,"hidden_active_observations":%d,"missed_intervals":%d,"max_lateness_ns":%d,"host_gpu_submissions":%d}}}}`+"\n",
		timestamp_utc, monotonic_ns, thread_id, name, window_id, window_renderable,
		hidden, minimized, native_minimized, occluded, input_focus,
		activity.active_owners, activity.active_properties, activity.unestablished_deadlines,
		alicorn.frame_needs_submission(rt), scheduler.active, scheduler.suspended,
		scheduler.suspended_since_ns, scheduler.next_deadline_ns, scheduler.stats.samples,
		scheduler.stats.timer_wakes, scheduler.stats.restore_samples,
		scheduler.stats.hidden_active_observations, scheduler.stats.missed_intervals,
		scheduler.stats.maximum_lateness_ns, gpu_submissions,
	)
}

native_breadcrumb_motion_window_state :: proc(
	recorder: ^Native_Breadcrumb_Recorder,
	name: string,
	window_id: sdl3.WindowID,
	window_flags: sdl3.WindowFlags,
	window_renderable: bool,
	native_minimized: bool,
	gpu_submissions: u64,
	scheduler: ^Native_Motion_Scheduler_State,
	rt: ^alicorn.Runtime,
	activity: alicorn.Motion_Activity,
) {
	if recorder == nil || scheduler == nil || rt == nil || !diag.breadcrumb_event_name_valid(name) { return }
	stamp, _, timestamp_ok := native_diagnostics_timestamp(time.now())
	if !timestamp_ok { return }
	monotonic_ns := u64(sdl3.GetTicksNS())
	thread_id := sync.current_thread_id()
	line := native_breadcrumb_motion_window_json_line(
		stamp, monotonic_ns, thread_id, name, window_id, window_flags,
		window_renderable, native_minimized, gpu_submissions, scheduler, rt, activity,
	)
	native_breadcrumb_write_line(recorder, line)
}

native_breadcrumb_application_event :: proc(data: rawptr, name: string, request_id: u64) {
	diag.breadcrumb_event(cast(^Native_Breadcrumb_Recorder)data, "application", name, request_id)
}

native_breadcrumbs_retain :: proc(recorder: ^Native_Breadcrumb_Recorder) {
	diag.breadcrumbs_retain(recorder)
}

native_breadcrumbs_release :: proc(recorder: ^Native_Breadcrumb_Recorder) {
	diag.breadcrumbs_release(recorder)
}

@(private)
native_diagnostics_monotonic_now :: proc() -> u64 {
	return u64(sdl3.GetTicksNS())
}

native_breadcrumbs_start :: proc(options: Native_Diagnostics_Options) -> ^Native_Breadcrumb_Recorder {
	return diag.breadcrumbs_start(options, native_diagnostics_monotonic_now)
}
