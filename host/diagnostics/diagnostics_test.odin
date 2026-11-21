package diagnostics

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"

@(test)
test_hud_emits_panel_text_and_activity_strip :: proc(t: ^testing.T) {
	recorder: Recorder
	record(&recorder, Sample{timestamp_ns=900_000_000, app_builds=1, gpu_submissions=1})
	record(&recorder, Sample{timestamp_ns=1_500_000_000, app_builds=1, gpu_submissions=1, cause_kind=.Keyboard})

	quads: [4096]Quad
	count := 0
	target := Quad_Target{
		data=rawptr(&Target_Probe{quads=quads[:], count=&count}),
		emit=probe_emit,
	}
	ok := emit_quads(target, &recorder, 1_600_000_000, {}, false, 800, 600, 1, 1, "test invalidation")
	testing.expect(t, ok, "the shared HUD should emit geometry for a visible panel")
	testing.expect(t, count > 100, "the HUD includes the panel, nine text lines, and the activity strip")

	// The panel is anchored to the top-right corner with a 12 px margin at 1x.
	found_panel := false
	for i in 0..<count {
		quad := quads[i]
		if quad.color == ([4]f32{0.025, 0.035, 0.055, 0.96}) {
			found_panel = true
			testing.expect(t, int(quad.x+quad.w) == 788 && int(quad.y) == 12,
				"the HUD panel stays right-aligned with the native 12 px margin")
		}
	}
	testing.expect(t, found_panel, "the HUD panel background is emitted")
}

@(test)
test_hud_scales_glyphs_for_high_dpi_targets :: proc(t: ^testing.T) {
	recorder: Recorder
	record(&recorder, Sample{timestamp_ns=1_000, app_builds=1})
	small: [4096]Quad
	large: [16384]Quad
	small_count, large_count := 0, 0
	_ = emit_quads(Quad_Target{data=rawptr(&Target_Probe{quads=small[:], count=&small_count}), emit=probe_emit},
		&recorder, 1_000, {}, false, 800, 600, 1, 1)
	_ = emit_quads(Quad_Target{data=rawptr(&Target_Probe{quads=large[:], count=&large_count}), emit=probe_emit},
		&recorder, 1_000, {}, false, 1600, 1200, 2, 2)
	testing.expect(t, large_count > 0 && small_count > 0,
		"both DPI targets should emit HUD geometry")
	testing.expect(t, large[0].w > small[0].w,
		"a 2x target uses a 2x panel width, matching the native host")
}

@(test)
test_bounds_emit_one_group_per_visible_command :: proc(t: ^testing.T) {
	display := [3]alicorn.Paint_Command{
		alicorn.paint_surface_command(1, {10, 10, 20, 20}, {0, 0, 100, 100}, alicorn.Color{1, 1, 1, 1}),
		alicorn.paint_surface_command(2, {-50, -50, 10, 10}, {0, 0, 100, 100}, alicorn.Color{1, 1, 1, 1}),
		alicorn.paint_surface_command(3, {90, 90, 40, 40}, {0, 0, 100, 100}, alicorn.Color{1, 1, 1, 1}),
	}
	quads: [64]Quad
	count, groups := 0, 0
	probe: Target_Probe
	probe.quads = quads[:]
	probe.count = &count
	probe.groups = &groups
	emit_bounds(Quad_Target{
		data=rawptr(&probe), emit=probe_emit,
		begin_group=probe_begin, end_group=probe_end,
	}, display[:], 1, 1, 100, 100)
	testing.expect(t, count == 8, "two visible commands should produce eight edge quads")
	testing.expect(t, groups == 2, "each visible command is one clipping group")
	// The third command is clipped to the target edge but still outlined.
	testing.expect(t, quads[4].x == 90 && quads[4].w == 10,
		"clipped bounds use the target edge instead of drawing outside it")
}

@(test)
test_capture_on_encode_failure_bypasses_presented_frame_gate :: proc(t: ^testing.T) {
	root, dir_err := os.make_directory_temp("", "alicorn-shared-diagnostics-*", context.temp_allocator)
	if dir_err != nil {
		testing.expect(t, false, "temporary diagnostics directory could not be created")
		return
	}
	defer _ = os.remove_all(root)
	options := Options{enabled=true, capture_requested=true, capture_dir=root}
	timing := Timing{gpu_submissions=0, frames=0}
	runtime := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&runtime)
	recorder: Recorder
	record(&recorder, Sample{timestamp_ns=1, app_builds=1})
	report := Report{
		backend=Backend_Info{name="webgpu/d3d12", detail="adapter test"},
		window=Window_Info{logical_width=320, logical_height=200, window_logical_height=200, pixel_width=320, pixel_height=200, pixel_density=1, display_scale=1},
		timing=&timing,
		rt=&runtime,
		failure_reason="frame encode failed",
		groups=[]Counter_Group{{
			name="solid",
			counters=[]Counter{{name="mesh_rebuilds", value=3}},
		}},
	}
	started := time.now()
	ok := write_capture(&options, started, report, &recorder)
	testing.expect(t, ok, "a recorded encode/present failure must produce a capture without a presented frame")
	bundle := options.last_capture_dir
	testing.expect(t, len(bundle) > 0 && os.exists(bundle), "the capture bundle directory exists")
	json, read_err := os.read_entire_file(path_join(bundle, "diagnostics.json"), context.temp_allocator)
	testing.expect(t, read_err == nil, "diagnostics.json is written")
	text := string(json)
	testing.expect(t, strings.contains(text, `"failure_reason": "frame encode failed"`),
		"the capture names the encode/presentation failure")
	testing.expect(t, strings.contains(text, `"backend_counters"`) && strings.contains(text, `"mesh_rebuilds": 3`),
		"backend-specific renderer counters are included")
	testing.expect(t, os.exists(path_join(bundle, "inspector.txt")), "retained-state inspection is included")
	testing.expect(t, os.exists(path_join(bundle, "timeline.json")), "the flight recorder timeline is included")
}

@(test)
test_capture_still_requires_a_presented_frame_without_failure :: proc(t: ^testing.T) {
	root, dir_err := os.make_directory_temp("", "alicorn-shared-diagnostics-gate-*", context.temp_allocator)
	if dir_err != nil {
		testing.expect(t, false, "temporary diagnostics directory could not be created")
		return
	}
	defer _ = os.remove_all(root)
	options := Options{enabled=true, capture_requested=true, capture_dir=root}
	timing := Timing{}
	runtime := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&runtime)
	recorder: Recorder
	report := Report{timing=&timing, rt=&runtime}
	testing.expect(t, !write_capture(&options, time.now(), report, &recorder),
		"a manual capture before the first frame keeps the reference host's presented-frame gate")
	testing.expect(t, options.capture_requested,
		"an unattempted request is not consumed by the gate")
}

@(test)
test_capture_failure_consumes_request_and_latches_automatic :: proc(t: ^testing.T) {
	root, dir_err := os.make_directory_temp("", "alicorn-shared-diagnostics-fail-*", context.temp_allocator)
	if dir_err != nil {
		testing.expect(t, false, "temporary diagnostics directory could not be created")
		return
	}
	defer _ = os.remove_all(root)
	blocked := path_join(root, "not-a-directory")
	_ = os.write_entire_file(blocked, "x")
	options := Options{enabled=true, capture_requested=true, capture_dir=blocked}
	capture_failed(&options, blocked, "cannot create bundle", automatic_due=true)
	testing.expect(t, !options.capture_requested && options.automatic_capture_done,
		"failure consumes one manual request and latches the automatic attempt")
}

@(test)
test_parse_options_matches_reference_flags :: proc(t: ^testing.T) {
	args := [4]string{
		"alicorn", "--diagnostics", "--capture-after=3", "--capture-dir=C:\\tmp\\captures",
	}
	options := parse_options(args[:])
	testing.expect(t, options.enabled && options.breadcrumbs_enabled,
		"--diagnostics enables captures and breadcrumbs")
	testing.expect(t, options.capture_after_ns == 3_000_000_000,
		"--capture-after is seconds")
	testing.expect(t, options.capture_dir == "C:\\tmp\\captures",
		"--capture-dir is preserved verbatim")

	events_only := parse_options([]string{"alicorn", "--diagnostic-events"})
	testing.expect(t, events_only.breadcrumbs_enabled && !events_only.enabled,
		"--diagnostic-events records breadcrumbs without captures or overlays")
	bounds := parse_options([]string{"alicorn", "--debug-bounds"})
	testing.expect(t, bounds.debug_bounds, "--debug-bounds starts retained-bounds inspection")
}

@(test)
test_timeline_export_is_versioned_and_bounded :: proc(t: ^testing.T) {
	recorder: Recorder
	record(&recorder, Sample{timestamp_ns=10, app_builds=1, cause_kind=.Keyboard})
	pointer_record(&recorder, Pointer_Sample{timestamp_ns=11, kind=.Down, x=1.5, y=2.5, button=1})
	json := timeline_json(&recorder)
	defer delete(json)
	testing.expect(t, len(json) > 0, "timeline export produces JSON")
	testing.expect(t, strings.contains(json, `"schema": 1`), "timeline carries its schema version")
	testing.expect(t, strings.contains(json, `"kind": "alicorn-flight-recorder"`), "timeline identifies its producer")
	testing.expect(t, strings.contains(json, `"activity_class": "app"`), "samples classify retained work")
	testing.expect(t, strings.contains(json, `"pointer_event_count": 1`), "pointer samples are included")
}

@(test)
test_breadcrumb_json_line_rejects_paths_and_injection :: proc(t: ^testing.T) {
	testing.expect(t, breadcrumb_event_name_valid("dialog.callback_completed"),
		"lowercase dotted event names stay valid")
	testing.expect(t, !breadcrumb_event_name_valid("C:\\Users\\secret"),
		"paths are not valid event names")
	testing.expect(t, !breadcrumb_event_name_valid("event\"injection"),
		"quotes are not valid event names")
	line := breadcrumb_json_line("2026-11-20T12:00:00.000Z", 42, 3, "alicorn", "session.started", 0)
	testing.expect(t, strings.contains(line, `"schema":1`) && strings.contains(line, `"monotonic_ns":42`),
		"breadcrumb lines keep the fixed schema")
}

// Target_Probe records emitted quads and groups for overlay-structure tests.
Target_Probe :: struct {
	quads:  []Quad,
	count:  ^int,
	groups: ^int,
}

probe_emit :: proc(data: rawptr, quad: Quad) -> bool {
	probe := cast(^Target_Probe)data
	if probe == nil || probe.count == nil || probe.quads == nil { return false }
	if probe.count^ >= len(probe.quads) { return false }
	probe.quads[probe.count^] = quad
	probe.count^ += 1
	return true
}

probe_begin :: proc(data: rawptr) -> bool {
	probe := cast(^Target_Probe)data
	if probe != nil && probe.groups != nil { probe.groups^ += 1 }
	return true
}

probe_end :: proc(_data: rawptr) {}

