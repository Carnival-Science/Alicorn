package diagnostics

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"

ORGANIZATION :: "Alicorn"
APPLICATION :: "Alicorn Diagnostics"

Options :: struct {
	enabled:             bool,
	breadcrumbs_enabled: bool,
	debug_bounds:        bool,
	capture_requested:   bool,
	capture_after_ns:    u64,
	capture_dir:         string,
	automatic_capture_done: bool,
	capture_sequence:    u64,
	last_capture_dir:    string,
	// default_capture_root resolves the platform's preferred writable
	// diagnostics directory when capture_dir is empty. Hosts supply the SDL
	// preference-path lookup so this package stays platform-neutral.
	default_capture_root: proc() -> (directory, failure: string),
}

// Backend_Info names the active renderer and, when known, its adapter. Both
// strings are borrowed for the duration of a capture report.
Backend_Info :: struct {
	name:   string,
	detail: string,
}

Window_Info :: struct {
	logical_width:        int,
	logical_height:       int,
	window_logical_height: int,
	pixel_width:          int,
	pixel_height:         int,
	pixel_density:        f32,
	display_scale:        f32,
}

// Counters holds the renderer-neutral counters the reference SDL_GPU host has
// always exported. A host fills the entries its renderer measures; zeros mean
// "not reported by this renderer", matching the existing capture contract.
Counters :: struct {
	text_shape_calls:         u64,
	text_glyph_cache_hits:    u64,
	text_glyph_cache_misses:  u64,
	text_rasterizations:      u64,
	text_atlas_pages:         u64,
	text_mesh_rebuilds:       u64,
	text_mesh_cache_hits:     u64,
	text_fingerprint_ns:      u64,
	text_fingerprint_bytes:   u64,
	text_mesh_rebuild_ns:     u64,
	text_mesh_commands:       u64,
	text_vertex_uploads:      u64,
	surface_encodes:          u64,
	surface_vertex_uploads:   u64,
	solid_batches:            u64,
	solid_vertices_uploaded:  u64,
	// Solid-stream attribution (issue #104 phase A). SDL_GPU's reference path
	// rebuilds the solid stream every presented frame; these separate
	// visibility resolution, vertex expansion, draw calls, and buffer growth
	// stalls so a capture explains where the CPU time goes.
	solid_draw_calls:         u64,
	solid_build_calls:        u64,
	solid_build_ns:           u64,
	solid_build_p50_ns:       u64,
	solid_build_p95_ns:       u64,
	solid_build_p99_ns:       u64,
	solid_visibility_ns:      u64,
	solid_expand_ns:          u64,
	solid_vertex_capacity:    u64,
	solid_vertex_capacity_peak: u64,
	solid_vertex_growth_events: u64,
	solid_vertex_growth_ns:   u64,
	solid_device_idle_waits:  u64,
	solid_device_idle_ns:     u64,
	text_vertex_capacity_peak: u64,
	text_vertex_growth_events: u64,
	text_vertex_growth_ns:    u64,
	text_device_idle_waits:   u64,
	text_device_idle_ns:      u64,
	icon_vertex_growth_events: u64,
	icon_device_idle_waits:   u64,
	image_vertex_growth_events: u64,
	image_device_idle_waits:  u64,
	icon_atlas_uploads:       u64,
	icon_atlas_upload_bytes:  u64,
	icon_mesh_rebuilds:       u64,
	icon_mesh_cache_hits:     u64,
	icon_vertex_uploads:      u64,
}

Counter :: struct {
	name:  string,
	value: u64,
}

// Counter_Group is backend-specific retained-work telemetry. The WebGPU host
// reports per-pass mesh rebuild, upload, and byte counters here so a capture
// explains renderer behavior without pretending those names match SDL_GPU.
Counter_Group :: struct {
	name:     string,
	counters: []Counter,
}

Report :: struct {
	window_role:  string,
	backend:      Backend_Info,
	window:       Window_Info,
	timing:       ^Timing,
	telemetry:    ^Text_Event_Telemetry,
	rt:           ^alicorn.Runtime,
	counters:     Counters,
	groups:       []Counter_Group,
	inspector_submissions: u64,
	// failure_reason marks a capture taken because frame encoding or
	// presentation failed. It bypasses the presented-frame gate so a broken
	// frame still yields retained state, pending commands, and counters.
	failure_reason: string,
	notes:        []string,
}

timestamp :: proc(moment: time.Time) -> (stamp, iso: string, ok: bool) {
	datetime, converted := time.time_to_datetime(moment)
	if !converted { return }
	millisecond := datetime.nano/1_000_000
	stamp = fmt.tprintf("%04d%02d%02dT%02d%02d%02d.%03dZ",
		datetime.year, int(datetime.month), int(datetime.day),
		int(datetime.hour), int(datetime.minute), int(datetime.second), millisecond)
	iso = fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		datetime.year, int(datetime.month), int(datetime.day),
		int(datetime.hour), int(datetime.minute), int(datetime.second), millisecond)
	return stamp, iso, true
}

path_join :: proc(parent, child: string) -> string {
	if len(parent) == 0 { return child }
	last := parent[len(parent)-1]
	separator := "/" if last != '/' && last != '\\' else ""
	return fmt.tprintf("%s%s%s", parent, separator, child)
}

create_bundle :: proc(root, stamp: string, first_sequence: u64) -> (directory: string, sequence: u64, ok: bool, failure: string) {
	if err := os.make_directory_all(root); err != nil && err != .Exist {
		failure = fmt.tprintf("create capture root: %v", err)
		return
	}
	sequence = first_sequence
	for attempt in 0..<10_000 {
		candidate := path_join(root, fmt.tprintf("%s-%04d", stamp, sequence))
		if err := os.make_directory(candidate); err == nil {
			return candidate, sequence, true, ""
		} else if err != .Exist {
			failure = fmt.tprintf("create capture bundle: %v", err)
			return "", 0, false, failure
		}
		sequence += 1
	}
	failure = "no unused capture sequence found after 10000 attempts"
	return "", 0, false, failure
}

capture_failed :: proc(
	options: ^Options,
	attempted_path, failure: string,
	automatic_due: bool,
) {
	path_for_log := attempted_path
	if path_for_log == "" { path_for_log = "<default capture directory unavailable>" }
	failure_for_log := failure
	if failure_for_log == "" { failure_for_log = "unspecified diagnostics capture failure" }
	fmt.println("alicorn_diagnostics", "capture_failed", "path", path_for_log, "error", failure_for_log)
	// One log and one attempt per manual request. Automatic capture is also
	// latched after failure, otherwise its due condition would remain true on
	// every idle event-loop iteration.
	options.capture_requested = false
	if automatic_due { options.automatic_capture_done = true }
}

parse_options :: proc(args: []string) -> Options {
	options := Options{
		capture_after_ns = 2_000_000_000,
	}
	for argument in args {
		if argument == "--diagnostics" {
			options.enabled = true
			options.breadcrumbs_enabled = true
			continue
		}
		if argument == "--diagnostic-events" {
			options.breadcrumbs_enabled = true
			continue
		}
		if argument == "--debug-bounds" {
			options.debug_bounds = true
			continue
		}
		capture_after_prefix := "--capture-after="
		if len(argument) > len(capture_after_prefix) && argument[:len(capture_after_prefix)] == capture_after_prefix {
			seconds, ok := strconv.parse_int(argument[len(capture_after_prefix):])
			if ok && seconds >= 0 {
				options.enabled = true
				options.capture_after_ns = u64(seconds)*1_000_000_000
			}
			continue
		}
	}
	if override, overridden := capture_dir_override(args, options.capture_dir); overridden {
		options.enabled = true
		options.capture_dir = override
		options.breadcrumbs_enabled = true
	}
	return options
}

capture_dir_override :: proc(args: []string, default_dir: string) -> (directory: string, overridden: bool) {
	directory = default_dir
	for argument in args {
		capture_dir_prefix := "--capture-dir="
		if len(argument) > len(capture_dir_prefix) && argument[:len(capture_dir_prefix)] == capture_dir_prefix {
			directory = argument[len(capture_dir_prefix):]
			overridden = true
		}
	}
	return
}

write_capture :: proc(
	options: ^Options,
	started: time.Time,
	report: Report,
	recorder: ^Recorder,
) -> bool {
	automatic_due := options.enabled && !options.automatic_capture_done &&
		time.duration_nanoseconds(time.since(started)) >= i64(options.capture_after_ns)
	failure_capture := len(report.failure_reason) > 0
	if !options.capture_requested && !automatic_due && !failure_capture { return false }
	// A capture normally explains a presented frame. The host may spend several
	// idle/event-only iterations between application build and the first
	// submission, especially when a surface tick is cadence-driven; do not
	// freeze a misleading zero-GPU snapshot in that window. A recorded encode
	// or presentation failure is exactly the case where there is no presented
	// frame to explain, so it bypasses this gate.
	if report.timing == nil { return false }
	if report.timing.gpu_submissions == 0 && len(report.failure_reason) == 0 { return false }
	stamp, captured_at, timestamp_ok := timestamp(time.now())
	if !timestamp_ok { return false }

	bundle_dir: string
	capture_sequence: u64
	bundle_ok: bool
	bundle_failure: string
	attempted_root := options.capture_dir
	if options.capture_dir == "" {
		if options.default_capture_root == nil {
			capture_failed(options, "<no default capture root>", "host supplied no default capture directory", automatic_due)
			return false
		}
		capture_root, path_failure := options.default_capture_root()
		if capture_root == "" {
			capture_failed(options, "SDL_GetPrefPath(Alicorn, Alicorn Diagnostics)", path_failure, automatic_due)
			return false
		}
		defer delete(capture_root)
		attempted_root = capture_root
		bundle_dir, capture_sequence, bundle_ok, bundle_failure = create_bundle(
			capture_root, stamp, options.capture_sequence+1)
	} else {
		bundle_dir, capture_sequence, bundle_ok, bundle_failure = create_bundle(
			options.capture_dir, stamp, options.capture_sequence+1)
	}
	if !bundle_ok {
		capture_failed(options, attempted_root, bundle_failure, automatic_due)
		return false
	}

	timing := report.timing
	telemetry := report.telemetry
	p50 := timing_percentile(timing.frame_samples[:], 0.50)
	p95 := timing_percentile(timing.frame_samples[:], 0.95)
	p99 := timing_percentile(timing.frame_samples[:], 0.99)
	input_p50: u64 = 0
	input_p95: u64 = 0
	input_p99: u64 = 0
	input_max: u64 = 0
	if telemetry != nil {
		input_p50 = timing_percentile(telemetry.input_to_submit_samples[:], 0.50)
		input_p95 = timing_percentile(telemetry.input_to_submit_samples[:], 0.95)
		input_p99 = timing_percentile(telemetry.input_to_submit_samples[:], 0.99)
		input_max = telemetry.input_to_submit_max_ns
	}
	average := u64(0)
	if timing.frames > 0 { average = timing.frame_ns_total/timing.frames }
	builder, builder_err := strings.builder_make()
	if builder_err != nil {
		_ = os.remove_all(bundle_dir)
		capture_failed(options, bundle_dir, fmt.tprintf("allocate diagnostics JSON builder: %v", builder_err), automatic_due)
		return false
	}
	defer strings.builder_destroy(&builder)

	application_submissions := u64(0)
	if report.rt != nil { application_submissions = report.rt.stats.gpu_submits }
	window_role := report.window_role
	if window_role == "" { window_role = "primary" }
	fmt.sbprintf(&builder, `{{
  "schema": 1,
  "kind": "alicorn-native-diagnostics",
  "window_role": "%s",
  "capture": {{
    "id": "%s-%04d",
    "captured_at_utc": "%s",
    "sequence": %d,
    "frame": %d,
    "gpu_submissions": %d,
    "application_gpu_submissions": %d,
    "devtools_only_gpu_submissions": %d,
    "inspector_gpu_submissions": %d,
    "failure_reason": "%s"
  }},
  "gpu_driver": "%s",
  "backend": {{
    "name": "%s",
    "detail": "%s"
  }},
  "window": {{
    "logical_width": %d,
    "logical_height": %d,
    "window_logical_height": %d,
    "pixel_width": %d,
    "pixel_height": %d,
    "pixel_density": %.4f,
    "display_scale": %.4f
  }},
`, window_role, stamp, capture_sequence, captured_at, capture_sequence, timing.frames,
		timing.gpu_submissions, application_submissions, timing.gpu_submissions-application_submissions,
		report.inspector_submissions, json_escape(report.failure_reason),
		json_escape(report.backend.name), json_escape(report.backend.name), json_escape(report.backend.detail),
		report.window.logical_width, report.window.logical_height,
		report.window.window_logical_height, report.window.pixel_width, report.window.pixel_height,
		report.window.pixel_density, report.window.display_scale)
	fmt.sbprintf(&builder, `  "timing_ns": {{
    "frames": %d,
    "event_pump": %d,
    "application_build": %d,
    "application_stabilization_rebuilds": %d,
    "application_stabilization_limit_hits": %d,
    "application_tick": %d,
    "application_tick_calls": %d,
    "scheduled_wakes": %d,
    "frequent_wakes": %d,
    "opportunistic_wakes": %d,
    "scheduled_requests": %d,
    "schedule_coalesces": %d,
    "opportunistic_deferrals": %d,
    "native_host_wake_events": %d,
    "maximum_scheduled_lateness": %d,
    "motion_samples": %d,
    "motion_timer_wakes": %d,
    "motion_restore_samples": %d,
    "motion_hidden_active_observations": %d,
    "motion_coalesced_owners": %d,
    "motion_bounded_snaps": %d,
    "motion_missed_intervals": %d,
    "motion_sample_ns": %d,
    "motion_sample_max_ns": %d,
    "motion_max_active_owners": %d,
    "motion_max_lateness_ns": %d,
    "gpu_encode": %d,
    "application_gpu_encode": %d,
    "native_chrome_encode": %d,
    "devtools_hud_encode": %d,
    "inspector_encode": %d,
    "gpu_submit": %d,
    "fence_wait": %d,
    "frame_average": %d,
    "frame_p50": %d,
    "frame_p95": %d,
    "frame_p99": %d,
    "frame_max": %d,
    "event_pump_max": %d,
    "application_build_max": %d,
    "application_tick_max": %d,
    "gpu_encode_max": %d,
    "gpu_submit_max": %d,
    "fence_wait_max": %d
  }},
	`, timing.frames, timing.event_pump_ns, timing.application_build_ns,
		timing.application_stabilization_rebuilds, timing.application_stabilization_limit_hits,
		timing.application_tick_ns, timing.application_tick_calls,
		timing.scheduled_wakes, timing.frequent_wakes, timing.opportunistic_wakes,
		timing.scheduled_requests, timing.schedule_coalesces, timing.opportunistic_deferrals,
		timing.native_host_wake_events, timing.maximum_scheduled_lateness_ns,
		timing.motion_samples, timing.motion_timer_wakes, timing.motion_restore_samples,
		timing.motion_hidden_active_observations,
		timing.motion_coalesced_owners, timing.motion_bounded_snaps, timing.motion_missed_intervals,
		timing.motion_sample_ns, timing.motion_sample_max_ns, timing.motion_max_active_owners,
		timing.motion_max_lateness_ns,
		timing.gpu_encode_ns, timing.application_gpu_encode_ns, timing.native_chrome_encode_ns,
		timing.devtools_hud_encode_ns, timing.inspector_encode_ns,
		timing.gpu_submit_ns, timing.fence_wait_ns, average,
		p50, p95, p99, timing.frame_ns_max, timing.event_pump_max_ns,
		timing.application_build_max_ns, timing.application_tick_max_ns,
		timing.gpu_encode_max_ns, timing.gpu_submit_max_ns, timing.fence_wait_max_ns)

	counters := report.counters
	fmt.sbprintf(&builder, `  "gpu": {{
    "submissions": %d,
    "application_submissions": %d,
    "devtools_only_submissions": %d,
    "fence_waits": %d,
    "text_shape_calls": %d,
    "text_glyph_cache_hits": %d,
    "text_glyph_cache_misses": %d,
    "text_rasterizations": %d,
    "text_atlas_pages": %d,
    "text_mesh_rebuilds": %d,
    "text_mesh_cache_hits": %d,
    "text_fingerprint_ns": %d,
    "text_fingerprint_bytes": %d,
    "text_mesh_rebuild_ns": %d,
    "text_mesh_commands": %d,
    "text_vertex_uploads": %d,
    "surface_encodes": %d,
    "surface_vertex_uploads": %d,
    "solid_batches": %d,
    "solid_vertices_uploaded": %d,
    "solid_draw_calls": %d,
    "solid_build_calls": %d,
    "solid_build_ns": %d,
    "solid_build_p50_ns": %d,
    "solid_build_p95_ns": %d,
    "solid_build_p99_ns": %d,
    "solid_visibility_ns": %d,
    "solid_expand_ns": %d,
    "solid_vertex_capacity": %d,
    "solid_vertex_capacity_peak": %d,
    "solid_vertex_growth_events": %d,
    "solid_vertex_growth_ns": %d,
    "solid_device_idle_waits": %d,
    "solid_device_idle_ns": %d,
    "text_vertex_capacity_peak": %d,
    "text_vertex_growth_events": %d,
    "text_vertex_growth_ns": %d,
    "text_device_idle_waits": %d,
    "text_device_idle_ns": %d,
    "icon_vertex_growth_events": %d,
    "icon_device_idle_waits": %d,
    "image_vertex_growth_events": %d,
    "image_device_idle_waits": %d,
    "icon_atlas_uploads": %d,
    "icon_atlas_upload_bytes": %d,
    "icon_mesh_rebuilds": %d,
    "icon_mesh_cache_hits": %d,
    "icon_vertex_uploads": %d
  }},
`, timing.gpu_submissions, application_submissions, timing.gpu_submissions-application_submissions,
		timing.fence_waits,
		counters.text_shape_calls, counters.text_glyph_cache_hits, counters.text_glyph_cache_misses,
		counters.text_rasterizations, counters.text_atlas_pages,
		counters.text_mesh_rebuilds, counters.text_mesh_cache_hits,
		counters.text_fingerprint_ns, counters.text_fingerprint_bytes, counters.text_mesh_rebuild_ns,
		counters.text_mesh_commands, counters.text_vertex_uploads,
		counters.surface_encodes, counters.surface_vertex_uploads,
		counters.solid_batches, counters.solid_vertices_uploaded,
		counters.solid_draw_calls, counters.solid_build_calls, counters.solid_build_ns,
		counters.solid_build_p50_ns, counters.solid_build_p95_ns, counters.solid_build_p99_ns,
		counters.solid_visibility_ns, counters.solid_expand_ns,
		counters.solid_vertex_capacity, counters.solid_vertex_capacity_peak,
		counters.solid_vertex_growth_events, counters.solid_vertex_growth_ns,
		counters.solid_device_idle_waits, counters.solid_device_idle_ns,
		counters.text_vertex_capacity_peak, counters.text_vertex_growth_events,
		counters.text_vertex_growth_ns, counters.text_device_idle_waits,
		counters.text_device_idle_ns,
		counters.icon_vertex_growth_events, counters.icon_device_idle_waits,
		counters.image_vertex_growth_events, counters.image_device_idle_waits,
		counters.icon_atlas_uploads, counters.icon_atlas_upload_bytes,
		counters.icon_mesh_rebuilds, counters.icon_mesh_cache_hits, counters.icon_vertex_uploads)

	if len(report.groups) > 0 {
		strings.write_string(&builder, "  \"backend_counters\": {\n")
		for group, index in report.groups {
			fmt.sbprintf(&builder, "    \"%s\": {{", json_escape(group.name))
			for counter, counter_index in group.counters {
				comma := "," if counter_index < len(group.counters)-1 else ""
				fmt.sbprintf(&builder, "\n      \"%s\": %d%s", json_escape(counter.name), counter.value, comma)
			}
			strings.write_string(&builder, "\n    }")
			if index < len(report.groups)-1 { strings.write_string(&builder, ",") }
			strings.write_string(&builder, "\n")
		}
		strings.write_string(&builder, "  },\n")
	}

	if telemetry != nil {
		fmt.sbprintf(&builder, `  "text_events": {{
    "change_dispatches": %d,
    "changes": %d,
    "edit_key_events": %d,
    "navigation_key_events": %d,
    "selection_key_events": %d,
    "word_key_events": %d,
    "events_per_pump_max": %d,
    "oldest_event_age_max_ns": %d,
    "input_to_submit_p50_ns": %d,
    "input_to_submit_p95_ns": %d,
    "input_to_submit_p99_ns": %d,
    "input_to_submit_max_ns": %d
  }},
`, telemetry.text_change_dispatches, telemetry.text_changes,
			telemetry.text_edit_key_events, telemetry.text_navigation_key_events,
			telemetry.text_selection_key_events, telemetry.text_word_key_events,
			telemetry.events_per_pump_max, telemetry.oldest_event_age_max_ns,
			input_p50, input_p95, input_p99, input_max)
	}

	if report.rt != nil {
		rt := report.rt
		fmt.sbprintf(&builder, `  "runtime": {{
    "retained_nodes": %d,
    "display_commands": %d,
    "focused_node": %d,
    "gpu_surface_updates": %d,
    "gpu_surface_clear_count": %d,
    "gpu_surface_stale_update_rejections": %d,
    "gpu_surface_frames_consumed": %d,
    "presentation_revision": %d,
    "submitted_revision": %d,
    "frame_needs_submission": %t,
    "debug_bounds": %t
  }},
`, len(rt.nodes), len(rt.display), u64(rt.focused), rt.stats.surface_updates,
			rt.stats.surface_clear_count, rt.stats.surface_stale_update_rejections,
			rt.stats.surface_frames_consumed, rt.presentation_revision, rt.submitted_revision,
			alicorn.frame_needs_submission(rt), options.debug_bounds)
	}

	strings.write_string(&builder, `  "notes": [
    "timing values are host wall-clock measurements in nanoseconds",
    "runtime allocation telemetry excludes application allocations, GPU memory, driver memory, and OS working set",
    "solid rectangles are batched only within contiguous display-list runs; text and custom surfaces remain ordering boundaries",
    "DevTools HUD geometry and HUD-only submissions do not increment application Frame_Stats; a HUD-only swapchain redraw still composites the current application display"`)
	for note in report.notes {
		fmt.sbprintf(&builder, ",\n    \"%s\"", json_escape(note))
	}
	strings.write_string(&builder, "\n  ]\n}\n")

	json := strings.to_string(builder)
	path := fmt.tprintf("%s/diagnostics.json", bundle_dir)
	if err := os.write_entire_file(path, json); err != nil {
		_ = os.remove_all(bundle_dir)
		capture_failed(options, path, fmt.tprintf("write diagnostics JSON: %v", err), automatic_due)
		return false
	}
	// Keep the full retained-tree explanation beside the compact JSON. The
	// human-readable inspector already contains node identity, bounds, dirty
	// stages, focus/hover state, and invalidation reasons without requiring a
	// JSON escaping layer in the runtime.
	inspection := ""
	if report.rt != nil { inspection = alicorn.inspect(report.rt) }
	inspection_path := fmt.tprintf("%s/inspector.txt", bundle_dir)
	if err := os.write_entire_file(inspection_path, inspection); err != nil {
		delete(inspection)
		_ = os.remove_all(bundle_dir)
		capture_failed(options, inspection_path, fmt.tprintf("write inspector snapshot: %v", err), automatic_due)
		return false
	}
	delete(inspection)
	timeline_path := fmt.tprintf("%s/timeline.json", bundle_dir)
	if !write_timeline(timeline_path, recorder) {
		_ = os.remove_all(bundle_dir)
		capture_failed(options, timeline_path, "flight timeline writer failed", automatic_due)
		return false
	}
	options.capture_sequence = capture_sequence
	options.last_capture_dir = bundle_dir
	options.capture_requested = false
	if automatic_due { options.automatic_capture_done = true }
	fmt.println(
		"alicorn_diagnostics", "path", path, "inspector", inspection_path, "timeline", timeline_path,
		"capture_id", fmt.tprintf("%s-%04d", stamp, capture_sequence), "frame_p95_ns", p95,
		"gpu_encode_ns", timing.gpu_encode_ns,
		"text_fingerprint_ns", counters.text_fingerprint_ns,
		"text_fingerprint_bytes", counters.text_fingerprint_bytes,
		"text_mesh_rebuild_ns", counters.text_mesh_rebuild_ns,
		"text_mesh_cache_hits", counters.text_mesh_cache_hits,
	)
	return true
}

// json_escape copies value into a JSON string body. Diagnostics values are
// host-controlled identifiers, but escaping keeps adapter descriptions safe.
json_escape :: proc(value: string) -> string {
	builder, err := strings.builder_make()
	if err != nil { return "" }
	defer strings.builder_destroy(&builder)
	for ch in value {
		switch ch {
		case '"':  strings.write_string(&builder, "\\\"")
		case '\\': strings.write_string(&builder, "\\\\")
		case '\n': strings.write_string(&builder, "\\n")
		case '\r': strings.write_string(&builder, "\\r")
		case '\t': strings.write_string(&builder, "\\t")
		case:
			if ch < 0x20 {
				fmt.sbprintf(&builder, "\\u%04x", int(ch))
			} else {
				strings.write_rune(&builder, ch)
			}
		}
	}
	clone, clone_err := strings.clone(strings.to_string(builder))
	if clone_err != nil { return "" }
	return clone
}

// write_windows_json records the primary host window beside a capture. It
// mirrors the reference host's windows.json inventory with one entry and a null
// secondary window.
write_windows_json :: proc(path: string, report: Report) -> bool {
	if report.rt == nil { return false }
	rt := report.rt
	builder, err := strings.builder_make()
	if err != nil { return false }
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(&builder, `{{
  "schema": 1,
  "kind": "alicorn-native-window-diagnostics",
  "primary": {{
    "sdl_window_id": 0,
    "sdl_position_x": 0,
    "sdl_position_y": 0,
    "focused": true,
    "mouse_focused": true,
    "always_on_top": false,
    "logical_width": %d,
    "logical_height": %d,
    "window_logical_height": %d,
    "pixel_width": %d,
    "pixel_height": %d,
    "pixel_density": %.4f,
    "display_scale": %.4f,
    "runtime": {{
      "viewport": {{"x": %.3f, "y": %.3f, "width": %.3f, "height": %.3f}},
      "retained_nodes": %d,
      "display_commands": %d,
      "focused_node": %d,
      "gpu_submissions": %d,
      "frame_needs_submission": %t,
      "presentation_revision": %d,
      "submitted_revision": %d
    }},
    "backend": {{"name": "%s", "detail": "%s"}}
  }},
  "secondary": null
}}
`, report.window.logical_width, report.window.logical_height, report.window.window_logical_height,
		report.window.pixel_width, report.window.pixel_height, report.window.pixel_density,
		report.window.display_scale,
		rt.viewport.x, rt.viewport.y, rt.viewport.w, rt.viewport.h,
		len(rt.nodes), len(rt.display), u64(rt.focused), rt.stats.gpu_submits,
		alicorn.frame_needs_submission(rt), rt.presentation_revision, rt.submitted_revision,
		json_escape(report.backend.name), json_escape(report.backend.detail))
	return os.write_entire_file(path, strings.to_string(builder)) == nil
}
