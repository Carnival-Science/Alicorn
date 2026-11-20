package alicorn_sdl_gpu

// Renderer-specific metric capture stays here because it reads SDL_GPU
// renderer structures. The cursor/sample/record model is shared.

import alicorn "../../runtime"
import diag "alicorn:host/diagnostics"

Native_DevTools_Renderer_Metrics :: struct {
	text_atlas_uploads, text_atlas_upload_bytes, text_mesh_rebuilds, text_mesh_cache_hits, text_vertex_uploads: u64,
	// Mirrors the cumulative Native_Text_Renderer fields fingerprint_ns,
	// fingerprint_bytes, and mesh_rebuild_ns; the renderer owns their updates.
	text_fingerprint_ns, text_fingerprint_bytes, text_mesh_rebuild_ns: u64,
	surface_resource_creations, surface_vertex_uploads, surface_encodes: u64,
	solid_batches, solid_vertices_uploaded: u64,
	icon_mesh_rebuilds, icon_mesh_cache_hits, icon_vertices_uploaded: u64,
}

native_devtools_renderer_metrics_capture :: proc(
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
) -> Native_DevTools_Renderer_Metrics {
	if text_renderer == nil || surface_renderer == nil || solid_renderer == nil { return {} }
	return Native_DevTools_Renderer_Metrics{
		text_atlas_uploads=text_renderer.atlas_uploads,
		text_atlas_upload_bytes=text_renderer.atlas_upload_bytes,
		text_mesh_rebuilds=text_renderer.mesh_rebuilds,
		text_mesh_cache_hits=text_renderer.mesh_cache_hits,
		text_fingerprint_ns=text_renderer.fingerprint_ns,
		text_fingerprint_bytes=text_renderer.fingerprint_bytes,
		text_mesh_rebuild_ns=text_renderer.mesh_rebuild_ns,
		text_vertex_uploads=text_renderer.vertex_uploads,
		surface_resource_creations=surface_renderer.resource_creations,
		surface_vertex_uploads=surface_renderer.vertex_uploads,
		surface_encodes=surface_renderer.encodes,
		solid_batches=solid_renderer.batches,
		solid_vertices_uploaded=solid_renderer.vertices_uploaded,
		icon_mesh_rebuilds=solid_renderer.icons.mesh_rebuilds,
		icon_mesh_cache_hits=solid_renderer.icons.mesh_cache_hits,
		icon_vertices_uploaded=solid_renderer.icons.vertices_uploaded,
	}
}

native_devtools_renderer_metrics_restore :: proc(
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
	metrics: Native_DevTools_Renderer_Metrics,
) {
	if text_renderer == nil || surface_renderer == nil || solid_renderer == nil { return }
	text_renderer.atlas_uploads = metrics.text_atlas_uploads
	text_renderer.atlas_upload_bytes = metrics.text_atlas_upload_bytes
	text_renderer.mesh_rebuilds = metrics.text_mesh_rebuilds
	text_renderer.mesh_cache_hits = metrics.text_mesh_cache_hits
	text_renderer.fingerprint_ns = metrics.text_fingerprint_ns
	text_renderer.fingerprint_bytes = metrics.text_fingerprint_bytes
	text_renderer.mesh_rebuild_ns = metrics.text_mesh_rebuild_ns
	text_renderer.vertex_uploads = metrics.text_vertex_uploads
	surface_renderer.resource_creations = metrics.surface_resource_creations
	surface_renderer.vertex_uploads = metrics.surface_vertex_uploads
	surface_renderer.encodes = metrics.surface_encodes
	solid_renderer.batches = metrics.solid_batches
	solid_renderer.vertices_uploaded = metrics.solid_vertices_uploaded
	solid_renderer.icons.mesh_rebuilds = metrics.icon_mesh_rebuilds
	solid_renderer.icons.mesh_cache_hits = metrics.icon_mesh_cache_hits
	solid_renderer.icons.vertices_uploaded = metrics.icon_vertices_uploaded
}

Native_DevTools_Cursor :: diag.Cursor

native_devtools_cursor_init :: proc(
	rt: ^alicorn.Runtime,
	timing: ^Native_Host_Timing,
	text_events: ^Native_Text_Event_Telemetry,
) -> Native_DevTools_Cursor {
	return diag.cursor_init(rt, timing, text_events)
}

native_devtools_make_sample :: proc(
	cursor: ^Native_DevTools_Cursor,
	rt: ^alicorn.Runtime,
	timing: ^Native_Host_Timing,
	text_events: ^Native_Text_Event_Telemetry,
	cause: alicorn.Cause_Context,
	timestamp_ns: u64,
	host_wakes: u64 = 0,
) -> Native_DevTools_Sample {
	return diag.make_sample(cursor, rt, timing, text_events, cause, timestamp_ns, host_wakes)
}

native_devtools_observed_wake :: proc(
	cursor: ^Native_DevTools_Cursor,
	sample: Native_DevTools_Sample,
	timing: ^Native_Host_Timing,
	text_events: ^Native_Text_Event_Telemetry,
) -> bool {
	return diag.observed_wake(cursor, sample, timing, text_events)
}

native_devtools_record_wake :: proc(
	recorder: ^Native_Flight_Recorder,
	cursor: ^Native_DevTools_Cursor,
	rt: ^alicorn.Runtime,
	timing: ^Native_Host_Timing,
	text_events: ^Native_Text_Event_Telemetry,
	cause: alicorn.Cause_Context,
	timestamp_ns: u64,
	host_wakes: u64 = 0,
) {
	diag.record_wake(recorder, cursor, rt, timing, text_events, cause, timestamp_ns, host_wakes)
}
