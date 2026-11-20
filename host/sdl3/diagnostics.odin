package sdl3_host

// Host-owned diagnostics for the SDL3/WebGPU runtime path. The model, overlay
// geometry, recorder, and capture schema come from alicorn:host/diagnostics;
// this file supplies SDL keys, the WebGPU backend identity and renderer
// counters, the SDL preference path, and the hosted paint target.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"
import diag "alicorn:host/diagnostics"
import presentation_host "alicorn:host/presentation"
import webgpu_renderer "alicorn:renderer/webgpu"
import "vendor:sdl3"

// SDL3_Diagnostics is owned by the host loop for the lifetime of one run. It
// never enters the application's retained tree and adds no nodes or paint.
SDL3_Diagnostics :: struct {
	options:              diag.Options,
	started:              time.Time,
	recorder:             diag.Recorder,
	cursor:               diag.Cursor,
	timing:               diag.Timing,
	telemetry:            diag.Text_Event_Telemetry,
	hud:                  diag.HUD,
	hud_redraw_pending:   bool,
	hud_deadline_ns:      u64,
	preview:              diag.Sample,
	preview_valid:        bool,
	last_cause:           alicorn.Cause_Context,
	debug_bounds:         bool,
	backend:              diag.Backend_Info,
	application:          ^SDL3_WebGPU_Application,
	breadcrumbs:          ^diag.Breadcrumb_Recorder,
	last_timing_serial:   u64,
	event_pump_ns_this_loop: u64,
	paint_commands:       [dynamic]alicorn.Paint_Command,
	initialized:          bool,
}

@(private)
sdl3_diagnostics_monotonic_now :: proc() -> u64 {
	return u64(sdl3.GetTicksNS())
}

@(private)
sdl3_diagnostics_default_capture_dir :: proc() -> (directory, failure: string) {
	native_path := sdl3.GetPrefPath(diag.ORGANIZATION, diag.APPLICATION)
	if native_path != nil {
		defer sdl3.free(rawptr(native_path))
		cloned, clone_err := strings.clone_from_cstring(cstring(native_path), context.allocator)
		if clone_err != nil {
			return "", fmt.tprintf("copy SDL_GetPrefPath result: %v", clone_err)
		}
		return cloned, ""
	}
	sdl_failure := "unknown SDL error"
	if error_cstring := sdl3.GetError(); error_cstring != nil {
		sdl_failure = string(error_cstring)
	}
	return "", fmt.tprintf("SDL_GetPrefPath failed: %s", sdl_failure)
}

// sdl3_diagnostics_init installs host diagnostics on an initialized application.
// backend_name and backend_detail are copied; the caller may release its wgpu
// adapter info immediately after the call.
sdl3_diagnostics_init :: proc(
	diagnostics: ^SDL3_Diagnostics,
	application: ^SDL3_WebGPU_Application,
	backend_name, backend_detail: string,
) -> bool {
	if diagnostics == nil || application == nil || !application.initialized { return false }
	diagnostics^ = SDL3_Diagnostics{}
	diagnostics.options = diag.parse_options(os.args)
	diagnostics.options.default_capture_root = sdl3_diagnostics_default_capture_dir
	diagnostics.debug_bounds = diagnostics.options.debug_bounds
	diagnostics.started = time.now()
	diagnostics.application = application
	if len(backend_name) > 0 {
		if cloned, err := strings.clone(backend_name); err == nil { diagnostics.backend.name = cloned }
	}
	if len(backend_detail) > 0 {
		if cloned, err := strings.clone(backend_detail); err == nil { diagnostics.backend.detail = cloned }
	}
	diagnostics.hud_deadline_ns = 0
	diagnostics.paint_commands = make([dynamic]alicorn.Paint_Command, 0, 4096, context.allocator)
	diagnostics.breadcrumbs = diag.breadcrumbs_start(diagnostics.options, sdl3_diagnostics_monotonic_now)
	// Host diagnostics measure their own frame stages. Enabling the presenter's
	// bounded CPU timing buffer keeps the HUD and captures truthful without
	// changing --timings semantics: that report still drains its own samples.
	_ = presentation_host.hosted_surface_presenter_set_timing_enabled(&application.presenter, true)
	if rt, status := alicorn.hosted_runtime_borrow(&application.hosted); status == .Ok {
		diagnostics.cursor = diag.cursor_init(rt, &diagnostics.timing, &diagnostics.telemetry)
	}
	diagnostics.initialized = true
	application.diagnostics = diagnostics
	return true
}

sdl3_diagnostics_destroy :: proc(diagnostics: ^SDL3_Diagnostics) {
	if diagnostics == nil { return }
	if diagnostics.initialized {
		diag.breadcrumb_event(diagnostics.breadcrumbs, "alicorn", "session.ended")
	}
	diag.breadcrumbs_release(diagnostics.breadcrumbs)
	delete(diagnostics.backend.name)
	delete(diagnostics.backend.detail)
	delete(diagnostics.paint_commands)
	diagnostics^ = {}
}

@(private)
sdl3_diagnostics_request_paint :: proc(diagnostics: ^SDL3_Diagnostics, reason: string) {
	if diagnostics == nil || diagnostics.application == nil { return }
	_ = reason
	diagnostics.hud_redraw_pending = true
	// Overlay redraws never mutate the application Runtime: they re-composite
	// the current retained display plus the HUD/bounds. That keeps a visible HUD
	// from looking like application work or driving a redraw feedback loop.
	presentation_host.hosted_surface_presenter_request_overlay_redraw(&diagnostics.application.presenter)
}

// sdl3_diagnostics_key mirrors the reference SDL_GPU dispatch contract:
//   F10 (no Shift) toggles the performance HUD and is consumed before
//   application key routing. F11 toggles retained-bounds inspection and
//   F12 requests a capture; both are host-side effects that must not consume the
//   key, so applications still see them exactly as they do on native/sdl_gpu.
// Returns true when the host consumed the key.
sdl3_diagnostics_key :: proc(
	diagnostics: ^SDL3_Diagnostics,
	key: sdl3.Keycode,
	modifiers: sdl3.Keymod,
	repeat: bool,
) -> bool {
	if diagnostics == nil || repeat { return false }
	switch key {
	case sdl3.K_F10:
		if input_modifier_is_set(modifiers, sdl3.KMOD_SHIFT) { return false }
		diag.hud_toggle(&diagnostics.hud)
		sdl3_diagnostics_request_paint(diagnostics, "performance HUD toggled")
		return true
	case sdl3.K_F11:
		diagnostics.debug_bounds = !diagnostics.debug_bounds
		diagnostics.options.debug_bounds = diagnostics.debug_bounds
		sdl3_diagnostics_request_paint(diagnostics, "retained bounds inspection toggled")
		fmt.println("alicorn_diagnostics", "debug_bounds", diagnostics.debug_bounds)
		return false
	case sdl3.K_F12:
		diagnostics.options.capture_requested = true
		sdl3_diagnostics_request_paint(diagnostics, "diagnostic capture requested")
		fmt.println("alicorn_diagnostics", "capture_requested", "F12")
		return false
	case:
		return false
	}
}

sdl3_diagnostics_note_input :: proc(diagnostics: ^SDL3_Diagnostics, timestamp_ns: u64) {
	if diagnostics == nil { return }
	diag.note_input_event(&diagnostics.telemetry, timestamp_ns, sdl3_diagnostics_monotonic_now())
}

sdl3_diagnostics_note_event_pump :: proc(diagnostics: ^SDL3_Diagnostics, elapsed_ns: u64) {
	if diagnostics == nil { return }
	diagnostics.event_pump_ns_this_loop += elapsed_ns
}

// sdl3_diagnostics_note_pointer records one pointer sample with the retained
// dispatch state a later investigation needs. It reads the Runtime only after
// the event has been applied.
sdl3_diagnostics_note_pointer :: proc(
	diagnostics: ^SDL3_Diagnostics,
	rt: ^alicorn.Runtime,
	pointer: alicorn.Pointer_Event,
	inside_application, dispatched: bool,
) {
	if diagnostics == nil || rt == nil { return }
	sample := diag.Pointer_Sample{
		timestamp_ns=sdl3_diagnostics_monotonic_now(),
		kind=pointer.kind,
		x=pointer.x, y=pointer.y,
		inside_application=inside_application,
		button=pointer.button,
		target=rt.last_hovered,
		pointer_dispatched=dispatched,
		captured_before=rt.captured_node,
		captured_after=rt.captured_node,
		invalidated=rt.invalidated,
		layout_pending=alicorn.layout_is_pending(rt),
		presentation_pending=alicorn.presentation_needs_frame(rt),
		presentation_revision=rt.presentation_revision,
		submitted_revision=rt.submitted_revision,
	}
	if info, ok := alicorn.node_info(rt, sample.target); ok {
		sample.target_kind, sample.target_valid = info.kind, true
	}
	if info, ok := alicorn.node_info(rt, sample.captured_after); ok {
		sample.captured_after_kind, sample.captured_after_valid = info.kind, true
	}
	diag.pointer_record(&diagnostics.recorder, sample)
}

@(private)
sdl3_diagnostics_aggregate_timing :: proc(diagnostics: ^SDL3_Diagnostics) {
	if diagnostics == nil || diagnostics.application == nil { return }
	samples: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]presentation_host.Hosted_Surface_Timing_Sample
	count := presentation_host.hosted_surface_presenter_copy_timing_samples(
		&diagnostics.application.presenter, samples[:],
	)
	for i in 0..<count {
		sample := samples[i]
		if sample.submission_serial <= diagnostics.last_timing_serial { continue }
		diagnostics.last_timing_serial = sample.submission_serial
		diag.timing_accumulate(&diagnostics.timing.application_build_ns, &diagnostics.timing.application_build_max_ns, sample.runtime_step_ns)
		diag.timing_accumulate(&diagnostics.timing.application_gpu_encode_ns, &diagnostics.timing.gpu_encode_max_ns, sample.renderer_encode_ns)
		diag.timing_accumulate(&diagnostics.timing.gpu_encode_ns, &diagnostics.timing.gpu_encode_max_ns, sample.renderer_encode_ns)
		diag.add_sample(&diagnostics.timing.gpu_encode_samples, sample.renderer_encode_ns)
		diag.timing_accumulate(&diagnostics.timing.gpu_submit_ns, &diagnostics.timing.gpu_submit_max_ns, sample.queue_submit_ns)
		diag.add_sample(&diagnostics.timing.gpu_submit_samples, sample.queue_submit_ns)
		diagnostics.timing.gpu_submissions += 1
		if sample.input_to_submit_ns != 0 {
			diag.add_sample(&diagnostics.telemetry.input_to_submit_samples, sample.input_to_submit_ns)
			diagnostics.telemetry.input_to_submit_sequence += 1
			if sample.input_to_submit_ns > diagnostics.telemetry.input_to_submit_max_ns {
				diagnostics.telemetry.input_to_submit_max_ns = sample.input_to_submit_ns
			}
		}
	}
}

// sdl3_diagnostics_after_step records the host-wake sample, updates HUD
// deadlines, and services pending captures. It runs after each application
// step, before the next event wait.
sdl3_diagnostics_after_step :: proc(
	diagnostics: ^SDL3_Diagnostics,
	application: ^SDL3_WebGPU_Application,
	now_ns, iteration_start_ns: u64,
	presented: bool,
	host_wake: bool,
	host_only_frame := false,
) {
	if diagnostics == nil || application == nil || !diagnostics.initialized { return }
	// The previous iteration's requested overlay frame has now been attempted.
	diagnostics.hud_redraw_pending = false
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return }
	diagnostics.timing.event_pump_ns += diagnostics.event_pump_ns_this_loop
	if diagnostics.event_pump_ns_this_loop > diagnostics.timing.event_pump_max_ns {
		diagnostics.timing.event_pump_max_ns = diagnostics.event_pump_ns_this_loop
	}
	diagnostics.event_pump_ns_this_loop = 0
	sdl3_diagnostics_aggregate_timing(diagnostics)
	if presented {
		diag.timing_add_frame(&diagnostics.timing, now_ns-iteration_start_ns)
	}
	if host_only_frame {
		// This frame existed only to composite host overlays. It is not
		// application activity: keep it out of the recorder so overlay costs
		// cannot feed a redraw feedback loop.
		diagnostics.preview_valid = false
		diagnostics.hud_deadline_ns = 0
		_ = sdl3_diagnostics_capture(diagnostics, "")
		return
	}
	cause := diagnostics.last_cause
	if cause.kind == .None { cause = rt.frame_cause }
	if rt.pending_work_seen {
		cause = rt.pending_work_cause if !rt.pending_work_mixed else alicorn.Cause_Context{}
	}
	if cause.kind == .None { cause = rt.submission_cause if !rt.submission_cause_mixed else alicorn.Cause_Context{} }
	if cause.kind == .None { cause = alicorn.Cause_Context{kind=.Host_Event} }
	preview := diag.make_sample(
		&diagnostics.cursor, rt, &diagnostics.timing, &diagnostics.telemetry,
		cause, now_ns, host_wakes=1 if host_wake else 0,
	)
	preview.gpu_submissions = rt.stats.gpu_submits-diagnostics.cursor.stats.gpu_submits
	diagnostics.preview, diagnostics.preview_valid = preview, diagnostics.hud.visible
	wake_observed := diag.observed_wake(&diagnostics.cursor, preview, &diagnostics.timing, &diagnostics.telemetry)
	diag.record_wake(
		&diagnostics.recorder, &diagnostics.cursor, rt, &diagnostics.timing,
		&diagnostics.telemetry, cause, now_ns, preview.host_wakes,
	)
	diagnostics.last_cause = {}
	diagnostics.hud_deadline_ns = 0
	if diagnostics.hud.visible {
		diagnostics.hud_deadline_ns = diag.next_wake_ns(&diagnostics.recorder, now_ns)
		if wake_observed || (diagnostics.hud_deadline_ns != 0 && now_ns >= diagnostics.hud_deadline_ns) {
			sdl3_diagnostics_request_paint(diagnostics, "performance HUD activity")
		}
	}
	// A capture is attempted every step; the shared writer returns immediately
	// unless a manual request or the automatic deadline is due.
	_ = sdl3_diagnostics_capture(diagnostics, "")
}

@(private)
SDL3_Diagnostics_Paint_Target :: struct {
	commands: ^[dynamic]alicorn.Paint_Command,
	clip:     alicorn.Rect,
	scale_x:  f32,
	scale_y:  f32,
	offset_y: f32,
}

@(private)
sdl3_diagnostics_quad :: proc(data: rawptr, quad: diag.Quad) -> bool {
	target := cast(^SDL3_Diagnostics_Paint_Target)data
	if target == nil || target.commands == nil || target.scale_x <= 0 || target.scale_y <= 0 { return false }
	x := quad.x/target.scale_x
	y := quad.y/target.scale_y+target.offset_y
	w := quad.w/target.scale_x
	h := quad.h/target.scale_y
	command := alicorn.paint_surface_command(
		0,
		alicorn.Rect{x, y, w, h},
		target.clip,
		alicorn.Color{quad.color[0], quad.color[1], quad.color[2], quad.color[3]},
	)
	append(target.commands, command)
	return true
}

// sdl3_diagnostics_paint appends retained-bounds inspection and the performance
// HUD after application paint and host chrome. It is installed on the hosted
// runtime config so every ui/webgpu.run consumer gets it automatically.
sdl3_diagnostics_paint :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	width, height: f32,
	allocator: mem.Allocator,
) -> []alicorn.Paint_Command {
	diagnostics := cast(^SDL3_Diagnostics)data
	if diagnostics == nil || rt == nil || (!diagnostics.debug_bounds && !diagnostics.hud.visible) {
		return nil
	}
	// Host overlay geometry is transient. Reuse one host-owned command buffer so
	// showing the HUD cannot allocate (or look like application work) per frame.
	clear(&diagnostics.paint_commands)
	commands := &diagnostics.paint_commands
	if 256 > cap(commands^) { reserve(commands, 256) }
	target := SDL3_Diagnostics_Paint_Target{
		commands=commands,
		clip=alicorn.Rect{0, 0, width, height},
		scale_x=1, scale_y=1,
	}
	if diagnostics.application != nil {
		target.offset_y = sdl3_webgpu_application_content_inset(diagnostics.application)
	}
	quad_target := diag.Quad_Target{data=rawptr(&target), emit=sdl3_diagnostics_quad}
	if diagnostics.debug_bounds {
		diag.emit_bounds(quad_target, rt.display[:], 1, 1, int(width), int(height)-int(target.offset_y))
	}
	if diagnostics.hud.visible {
		scale_x, scale_y: f32 = 1, 1
		pixel_width, pixel_height := int(width), int(height)
		if diagnostics.application != nil {
			lw := diagnostics.application.last_logical_width
			lh := diagnostics.application.last_logical_height
			if lw > 0 && lh > 0 {
				scale_x = f32(diagnostics.application.last_pixel_width)/f32(lw)
				scale_y = f32(diagnostics.application.last_pixel_height)/f32(lh)
				pixel_width = diagnostics.application.last_pixel_width
				pixel_height = diagnostics.application.last_pixel_height
			}
		}
		hud_target := target
		hud_target.scale_x, hud_target.scale_y = scale_x, scale_y
		// The HUD's own top margin is relative to the window; keep it out of the
		// application content inset so it stays pinned to the window corner.
		hud_target.offset_y = 0
		diag.emit_quads(
			diag.Quad_Target{data=rawptr(&hud_target), emit=sdl3_diagnostics_quad},
			&diagnostics.recorder, sdl3_diagnostics_monotonic_now(),
			diagnostics.preview, diagnostics.preview_valid,
			pixel_width, pixel_height, scale_x, scale_y, rt.last_invalidation_reason,
		)
	}
	if len(commands^) == 0 { return nil }
	return commands^[:]
}

@(private)
sdl3_diagnostics_counter_group :: proc(
	name: string,
	pass: webgpu_renderer.WebGPU_Pass_Stats,
	buffer: ^[14]diag.Counter,
) -> diag.Counter_Group {
	buffer[0] = diag.Counter{"mesh_rebuilds", pass.mesh_rebuilds}
	buffer[1] = diag.Counter{"mesh_cache_hits", pass.mesh_cache_hits}
	buffer[2] = diag.Counter{"vertex_uploads", pass.vertex_uploads}
	buffer[3] = diag.Counter{"vertex_upload_bytes", pass.vertex_upload_bytes}
	buffer[4] = diag.Counter{"transform_uploads", pass.transform_uploads}
	buffer[5] = diag.Counter{"transform_upload_bytes", pass.transform_upload_bytes}
	buffer[6] = diag.Counter{"viewport_uploads", pass.viewport_uploads}
	buffer[7] = diag.Counter{"atlas_uploads", pass.atlas_uploads}
	buffer[8] = diag.Counter{"atlas_upload_bytes", pass.atlas_upload_bytes}
	buffer[9] = diag.Counter{"texture_uploads", pass.texture_uploads}
	buffer[10] = diag.Counter{"texture_upload_bytes", pass.texture_upload_bytes}
	buffer[11] = diag.Counter{"instance_uploads", pass.instance_uploads}
	buffer[12] = diag.Counter{"instance_cache_hits", pass.instance_cache_hits}
	buffer[13] = diag.Counter{"resident_bytes", pass.resident_bytes}
	return diag.Counter_Group{name=name, counters=buffer[:]}
}

// sdl3_diagnostics_capture writes one capture bundle. A non-empty
// failure_reason marks an encode/presentation failure and bypasses the
// presented-frame gate, so a broken frame still produces retained state,
// pending commands, and counters.
sdl3_diagnostics_capture :: proc(diagnostics: ^SDL3_Diagnostics, failure_reason: string) -> bool {
	if diagnostics == nil || !diagnostics.initialized || diagnostics.application == nil { return false }
	application := diagnostics.application
	sdl3_diagnostics_aggregate_timing(diagnostics)
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return false }
	stats, stats_ok := presentation_host.hosted_surface_presenter_renderer_stats(&application.presenter)

	groups: [6]diag.Counter_Group
	group_count := 0
	group_buffers: [5][14]diag.Counter
	if stats_ok {
		groups[group_count] = sdl3_diagnostics_counter_group("solid", stats.solid, &group_buffers[0]); group_count += 1
		groups[group_count] = sdl3_diagnostics_counter_group("text", stats.text, &group_buffers[1]); group_count += 1
		groups[group_count] = sdl3_diagnostics_counter_group("icons", stats.icons, &group_buffers[2]); group_count += 1
		groups[group_count] = sdl3_diagnostics_counter_group("images", stats.images, &group_buffers[3]); group_count += 1
		groups[group_count] = sdl3_diagnostics_counter_group("surfaces", stats.surfaces, &group_buffers[4]); group_count += 1
	}
	extra: [1]diag.Counter
	if stats_ok {
		extra[0] = diag.Counter{"prepared_commands", u64(max(stats.prepared_commands, 0))}
		groups[group_count] = diag.Counter_Group{name="webgpu", counters=extra[:]}
		group_count += 1
	}

	counters := diag.Counters{
		text_shape_calls=rt.text_engine.shape_calls,
		text_glyph_cache_hits=rt.text_engine.glyph_cache_hits,
		text_glyph_cache_misses=rt.text_engine.glyph_cache_misses,
		text_rasterizations=rt.text_engine.glyph_rasterizations,
	}
	if stats_ok {
		counters.text_mesh_rebuilds = stats.text.mesh_rebuilds
		counters.text_vertex_uploads = stats.text.vertex_uploads
		counters.icon_mesh_rebuilds = stats.icons.mesh_rebuilds
		counters.icon_mesh_cache_hits = stats.icons.mesh_cache_hits
		counters.icon_vertex_uploads = stats.icons.vertex_uploads
		counters.icon_atlas_uploads = stats.icons.atlas_uploads
		counters.icon_atlas_upload_bytes = stats.icons.atlas_upload_bytes
	}

	report := diag.Report{
		window_role="primary",
		backend=diagnostics.backend,
		window=diag.Window_Info{
			logical_width=application.last_logical_width,
			logical_height=application.last_logical_height,
			window_logical_height=application.last_logical_height,
			pixel_width=application.last_pixel_width,
			pixel_height=application.last_pixel_height,
			pixel_density=application.dpi_scale,
			display_scale=application.dpi_scale,
		},
		timing=&diagnostics.timing,
		telemetry=&diagnostics.telemetry,
		rt=rt,
		counters=counters,
		groups=groups[:group_count],
		failure_reason=failure_reason,
		notes=[]string{
			"hosted WebGPU: application_build is the whole hosted runtime step (description, layout, paint, and finalization)",
			"hosted WebGPU: backend_counters are per-pass retained-work counters from the shared compositor",
		},
	}
	if !diag.write_capture(&diagnostics.options, diagnostics.started, report, &diagnostics.recorder) {
		return false
	}
	windows_path := fmt.tprintf("%s/windows.json", diagnostics.options.last_capture_dir)
	if diag.write_windows_json(windows_path, report) {
		fmt.println("alicorn_diagnostics", "windows", windows_path)
	} else {
		fmt.println("alicorn_diagnostics", "windows_failed", windows_path)
	}
	screenshot_path := fmt.tprintf("%s/screenshot.ppm", diagnostics.options.last_capture_dir)
	if presentation_host.hosted_surface_presenter_capture_ppm(&application.presenter, screenshot_path) {
		fmt.println("alicorn_diagnostics", "screenshot", screenshot_path)
	} else {
		fmt.println("alicorn_diagnostics", "screenshot_failed", screenshot_path)
	}
	if len(failure_reason) > 0 {
		fmt.println("alicorn_diagnostics", "capture_on_failure", failure_reason)
	}
	return true
}
