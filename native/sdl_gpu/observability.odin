package alicorn_sdl_gpu

// Diagnostics options, timing, telemetry, and capture are shared with every
// Alicorn host through alicorn:host/diagnostics. This file adapts the
// reference SDL_GPU renderer counters and the SDL preference path into the
// shared schema.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import alicorn "../../runtime"
import diag "alicorn:host/diagnostics"
import "vendor:sdl3"

NATIVE_DIAGNOSTIC_FRAME_SAMPLES :: diag.FRAME_SAMPLES
NATIVE_DIAGNOSTICS_ORGANIZATION :: diag.ORGANIZATION
NATIVE_DIAGNOSTICS_APPLICATION :: diag.APPLICATION

Native_Diagnostics_Options :: diag.Options
Native_Host_Timing :: diag.Timing
Native_Startup_Timing :: diag.Startup_Timing
Native_Text_Event_Telemetry :: diag.Text_Event_Telemetry

native_diagnostics_default_capture_dir :: proc() -> (directory, failure: string) {
	// SDL_GetPrefPath is the platform-supported writable location for
	// application data. Its path is already dedicated to diagnostics, so the
	// returned SDL-owned allocation is copied into Odin storage before it is
	// released. The caller controls the copied string's lifetime.
	native_path := sdl3.GetPrefPath(
		NATIVE_DIAGNOSTICS_ORGANIZATION,
		NATIVE_DIAGNOSTICS_APPLICATION,
	)
	if native_path != nil {
		defer sdl3.free(rawptr(native_path))
		directory, clone_err := strings.clone_from_cstring(cstring(native_path), context.allocator)
		if clone_err != nil {
			return "", fmt.tprintf("copy SDL_GetPrefPath result: %v", clone_err)
		}
		return directory, ""
	}
	sdl_failure := "unknown SDL error"
	if error_cstring := sdl3.GetError(); error_cstring != nil {
		sdl_failure = string(error_cstring)
	}
	return "", fmt.tprintf("SDL_GetPrefPath failed: %s", sdl_failure)
}

native_note_input_event :: proc(telemetry: ^Native_Text_Event_Telemetry, timestamp: u64) {
	diag.note_input_event(telemetry, timestamp, u64(sdl3.GetTicksNS()))
}

native_finish_input_pump :: proc(telemetry: ^Native_Text_Event_Telemetry) {
	diag.finish_input_pump(telemetry)
}

native_note_input_submission :: proc(telemetry: ^Native_Text_Event_Telemetry) {
	diag.note_input_submission(telemetry, u64(sdl3.GetTicksNS()))
}

native_timing_accumulate :: proc(total, maximum: ^u64, elapsed: u64) {
	diag.timing_accumulate(total, maximum, elapsed)
}

native_timing_add_frame :: proc(timing: ^Native_Host_Timing, frame_ns: u64) {
	diag.timing_add_frame(timing, frame_ns)
}

native_timing_add_build :: proc(timing: ^Native_Host_Timing, build_ns: u64) {
	diag.timing_add_build(timing, build_ns)
}

native_timing_add_sample :: proc(samples: ^[dynamic; NATIVE_DIAGNOSTIC_FRAME_SAMPLES]u64, value: u64) {
	diag.add_sample(samples, value)
}

native_timing_percentile :: proc(samples: []u64, fraction: f64) -> u64 {
	return diag.timing_percentile(samples, fraction)
}

// native_startup_elapsed_ns reports elapsed time from the startup origin using
// the monotonic tick clock (QueryPerformanceCounter on Windows). The host must
// not use wall-clock differences for startup markers: system-time adjustments
// can step by tens of seconds during a launch. The zero Tick guard keeps test
// call sites from reporting garbage.
native_startup_elapsed_ns :: proc(origin: time.Tick) -> u64 {
	if origin == (time.Tick{}) { return 0 }
	return u64(time.duration_nanoseconds(time.tick_since(origin)))
}

// native_tick_elapsed_ns reports the elapsed nanoseconds from origin to a
// recorded monotonic moment. A zero moment means "not observed" and reports 0,
// even if the clock happens to be monotonic since process start.
native_tick_elapsed_ns :: proc(origin, moment: time.Tick) -> u64 {
	if origin == (time.Tick{}) || moment == (time.Tick{}) { return 0 }
	elapsed := time.duration_nanoseconds(time.tick_diff(origin, moment))
	if elapsed <= 0 { return 0 }
	return u64(elapsed)
}

// runtime_live_bytes reports the runtime's persistent requested bytes while the
// process is alive. It is the allocator-requested view, not resident memory.
runtime_live_bytes :: proc(rt: ^alicorn.Runtime) -> i64 {
	if rt == nil || rt.allocation_stats == nil { return 0 }
	return rt.allocation_stats.persistent_requested_bytes_live
}

// native_print_startup_attribution reports the eager host-owned resources that
// Alicorn creates before the first frame. SDL_GPU does not expose allocation
// sizes for device resources, so these are the host-declared sizes: buffer and
// transfer-buffer create sizes plus the known icon-atlas upload. Pipeline
// backends, driver heaps and shader caches remain unattributable here.
//
// This is measurement-only output. It deliberately prints declared bytes, not
// working set, private bytes or GPU residency. The runtime's requested-byte
// counters are logical allocator requests, not resident memory.
native_print_startup_attribution :: proc(rt: ^alicorn.Runtime) {
	vertex_stride := u64(size_of(Native_Text_Vertex))
	text_vertex_bytes := u64(NATIVE_TEXT_INITIAL_VERTICES) * vertex_stride
	solid_vertex_bytes := u64(NATIVE_SOLID_INITIAL_VERTICES) * vertex_stride
	surface_vertex_bytes := u64(MAX_SURFACE_VERTICES) * vertex_stride
	icon_vertex_bytes := u64(NATIVE_ICON_INITIAL_VERTICES) * vertex_stride
	image_vertex_bytes := u64(NATIVE_IMAGE_INITIAL_VERTICES) * vertex_stride
	atlas_transfer_bytes: u64 = 4 * 1024 * 1024
	icon_atlas_bytes: u64 = 0
	for page in alicorn.ICON_ATLAS_PAGES { icon_atlas_bytes += u64(len(page.pixels)) }
	font_bytes := u64(len(alicorn.DEFAULT_UI_FONT_DATA)) +
		u64(len(alicorn.DEFAULT_UI_ITALIC_FONT_DATA)) +
		u64(len(alicorn.DEFAULT_MONO_FONT_DATA)) +
		u64(len(alicorn.DEFAULT_MONO_ITALIC_FONT_DATA))
	// Vertex buffers and their upload staging buffers are created together.
	declared_gpu_bytes := 2*text_vertex_bytes + atlas_transfer_bytes +
		solid_vertex_bytes*2 + surface_vertex_bytes*2 +
		icon_vertex_bytes*2 + icon_atlas_bytes + image_vertex_bytes*2
	runtime_live: i64 = 0
	runtime_peak: i64 = 0
	scratch_peak: u64 = 0
	if rt != nil && rt.allocation_stats != nil {
		runtime_live = rt.allocation_stats.persistent_requested_bytes_live
		runtime_peak = rt.allocation_stats.persistent_requested_bytes_peak
		scratch_peak = rt.allocation_stats.scratch_requested_bytes_peak
	}
	fmt.println(
		"alicorn_startup_attribution",
		"basis", "host_declared_resource_sizes_not_measured_residency",
		"gpu_pipelines", 5,
		"vertex_stride_bytes", vertex_stride,
		"text_vertex_buffer_bytes", text_vertex_bytes,
		"text_vertex_transfer_bytes", text_vertex_bytes,
		"text_atlas_transfer_bytes", atlas_transfer_bytes,
		"solid_vertex_buffer_bytes", solid_vertex_bytes,
		"solid_vertex_transfer_bytes", solid_vertex_bytes,
		"surface_vertex_buffer_bytes", surface_vertex_bytes,
		"surface_vertex_transfer_bytes", surface_vertex_bytes,
		"icon_vertex_buffer_bytes", icon_vertex_bytes,
		"icon_vertex_transfer_bytes", icon_vertex_bytes,
		"icon_atlas_gpu_bytes", icon_atlas_bytes,
		"image_vertex_buffer_bytes", image_vertex_bytes,
		"image_vertex_transfer_bytes", image_vertex_bytes,
		"font_embedded_bytes", font_bytes,
		"host_declared_gpu_bytes", declared_gpu_bytes,
		"host_declared_total_bytes", declared_gpu_bytes + font_bytes,
		"runtime_persistent_requested_live_bytes", runtime_live,
		"runtime_persistent_requested_peak_bytes", runtime_peak,
		"runtime_scratch_requested_peak_bytes", scratch_peak,
	)
}

// native_smoke_hold_ns reads an optional idle hold for bounded smoke runs.
// When nonzero, --smoke still requires the usual startup wait, but exits only
// after no application primary submission has occurred for the hold duration.
native_smoke_hold_ns :: proc() -> u64 {
	prefix := "--smoke-hold-ms="
	for argument in os.args {
		if len(argument) <= len(prefix) || argument[:len(prefix)] != prefix { continue }
		milliseconds, ok := strconv.parse_u64(argument[len(prefix):])
		if !ok || milliseconds > 60_000 { return 0 }
		return milliseconds*1_000_000
	}
	return 0
}

native_parse_diagnostics_options :: proc() -> Native_Diagnostics_Options {
	options := diag.parse_options(os.args)
	options.default_capture_root = native_diagnostics_default_capture_dir
	return options
}

native_diagnostics_capture_dir_override :: proc(args: []string, default_dir: string) -> (directory: string, overridden: bool) {
	return diag.capture_dir_override(args, default_dir)
}

native_diagnostics_timestamp :: proc(moment: time.Time) -> (stamp, iso: string, ok: bool) {
	return diag.timestamp(moment)
}

native_diagnostics_path_join :: proc(parent, child: string) -> string {
	return diag.path_join(parent, child)
}

native_diagnostics_create_bundle :: proc(root, stamp: string, first_sequence: u64) -> (directory: string, sequence: u64, ok: bool, failure: string) {
	return diag.create_bundle(root, stamp, first_sequence)
}

native_diagnostics_capture_failed :: proc(
	options: ^Native_Diagnostics_Options,
	attempted_path, failure: string,
	automatic_due: bool,
) {
	diag.capture_failed(options, attempted_path, failure, automatic_due)
}

native_renderer_counters :: proc(
	rt: ^alicorn.Runtime,
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
) -> diag.Counters {
	counters := diag.Counters{}
	if rt != nil {
		counters.text_shape_calls = rt.text_engine.shape_calls
		counters.text_glyph_cache_hits = rt.text_engine.glyph_cache_hits
		counters.text_glyph_cache_misses = rt.text_engine.glyph_cache_misses
		counters.text_rasterizations = rt.text_engine.glyph_rasterizations
	}
	if text_renderer != nil {
		counters.text_atlas_pages = u64(len(text_renderer.pages))
		counters.text_mesh_rebuilds = text_renderer.mesh_rebuilds
		counters.text_mesh_cache_hits = text_renderer.mesh_cache_hits
		counters.text_fingerprint_ns = text_renderer.fingerprint_ns
		counters.text_fingerprint_bytes = text_renderer.fingerprint_bytes
		counters.text_mesh_rebuild_ns = text_renderer.mesh_rebuild_ns
		counters.text_mesh_commands = text_renderer.mesh_text_commands
		counters.text_vertex_uploads = text_renderer.vertex_uploads
	}
	if surface_renderer != nil {
		counters.surface_encodes = surface_renderer.encodes
		counters.surface_vertex_uploads = surface_renderer.vertex_uploads
	}
	if solid_renderer != nil {
		counters.solid_batches = solid_renderer.batches
		counters.solid_vertices_uploaded = solid_renderer.vertices_uploaded
		counters.solid_draw_calls = solid_renderer.draw_calls
		counters.solid_build_calls = solid_renderer.build_calls
		counters.solid_build_ns = solid_renderer.build_ns
		counters.solid_build_p50_ns = diag.timing_percentile(solid_renderer.build_samples[:solid_renderer.build_sample_count], 0.50)
		counters.solid_build_p95_ns = diag.timing_percentile(solid_renderer.build_samples[:solid_renderer.build_sample_count], 0.95)
		counters.solid_build_p99_ns = diag.timing_percentile(solid_renderer.build_samples[:solid_renderer.build_sample_count], 0.99)
		counters.solid_visibility_ns = solid_renderer.visibility_ns
		counters.solid_expand_ns = solid_renderer.expand_ns
		counters.solid_vertex_capacity = u64(solid_renderer.vertex_capacity)
		counters.solid_vertex_capacity_peak = u64(solid_renderer.capacity.peak_capacity)
		counters.solid_vertex_growth_events = solid_renderer.capacity.growth_events
		counters.solid_vertex_growth_ns = solid_renderer.capacity.growth_ns
		counters.solid_device_idle_waits = solid_renderer.capacity.idle_waits
		counters.solid_device_idle_ns = solid_renderer.capacity.idle_wait_ns
		counters.icon_vertex_growth_events = solid_renderer.icons.capacity.growth_events
		counters.icon_device_idle_waits = solid_renderer.icons.capacity.idle_waits
		counters.image_vertex_growth_events = solid_renderer.images.capacity.growth_events
		counters.image_device_idle_waits = solid_renderer.images.capacity.idle_waits
		counters.icon_atlas_uploads = solid_renderer.icons.atlas_uploads
		counters.icon_atlas_upload_bytes = solid_renderer.icons.atlas_upload_bytes
		counters.icon_mesh_rebuilds = solid_renderer.icons.mesh_rebuilds
		counters.icon_mesh_cache_hits = solid_renderer.icons.mesh_cache_hits
		counters.icon_vertex_uploads = solid_renderer.icons.vertices_uploaded
	}
	if text_renderer != nil {
		counters.text_vertex_capacity_peak = u64(text_renderer.capacity.peak_capacity)
		counters.text_vertex_growth_events = text_renderer.capacity.growth_events
		counters.text_vertex_growth_ns = text_renderer.capacity.growth_ns
		counters.text_device_idle_waits = text_renderer.capacity.idle_waits
		counters.text_device_idle_ns = text_renderer.capacity.idle_wait_ns
	}
	return counters
}

native_write_diagnostics :: proc(
	options: ^Native_Diagnostics_Options,
	started: time.Time,
	gpu_driver: string,
	metrics: Window_Metrics,
	rt: ^alicorn.Runtime,
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
	timing: ^Native_Host_Timing,
	text_events: ^Native_Text_Event_Telemetry = nil,
	recorder: ^Native_Flight_Recorder = nil,
) -> bool {
	report := diag.Report{
		window_role="primary",
		backend=diag.Backend_Info{name=gpu_driver, detail=gpu_driver},
		window=diag.Window_Info{
			logical_width=metrics.logical_width,
			logical_height=metrics.logical_height,
			window_logical_height=metrics.window_logical_height,
			pixel_width=metrics.pixel_width,
			pixel_height=metrics.pixel_height,
			pixel_density=metrics.pixel_density,
			display_scale=metrics.display_scale,
		},
		timing=timing,
		telemetry=text_events,
		rt=rt,
		counters=native_renderer_counters(rt, text_renderer, surface_renderer, solid_renderer),
		inspector_submissions=timing.inspector_submissions,
	}
	return diag.write_capture(options, started, report, recorder)
}
