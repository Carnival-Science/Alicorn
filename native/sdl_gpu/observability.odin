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
		counters.icon_atlas_uploads = solid_renderer.icons.atlas_uploads
		counters.icon_atlas_upload_bytes = solid_renderer.icons.atlas_upload_bytes
		counters.icon_mesh_rebuilds = solid_renderer.icons.mesh_rebuilds
		counters.icon_mesh_cache_hits = solid_renderer.icons.mesh_cache_hits
		counters.icon_vertex_uploads = solid_renderer.icons.vertices_uploaded
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
