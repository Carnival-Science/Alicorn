package webgpu_renderer

// WebGPU_Pass_Stats is a read-only snapshot of one compositor pass's retained
// work. Counters are cumulative for the renderer's lifetime and are sampled
// between frames by the host, never incremented on a per-command hot path.
// Zero means "not counted by this pass", not "no work"; see the validation
// matrix for per-metric availability.
WebGPU_Pass_Stats :: struct {
	mesh_rebuilds:          u64,
	mesh_cache_hits:        u64,
	vertex_uploads:         u64,
	vertex_upload_bytes:    u64,
	transform_uploads:      u64,
	transform_upload_bytes: u64,
	viewport_uploads:       u64,
	atlas_uploads:          u64,
	atlas_upload_bytes:     u64,
	texture_uploads:        u64,
	texture_upload_bytes:   u64,
	instance_uploads:       u64,
	instance_cache_hits:    u64,
	resource_evictions:     u64,
	resource_retirements:   u64,
	resource_releases:      u64,
	resident_bytes:         u64,
}

// WebGPU_Renderer_Stats aggregates the compositor's per-pass counters plus the
// number of paint commands in the last prepared display list.
WebGPU_Renderer_Stats :: struct {
	solid:            WebGPU_Pass_Stats,
	text:             WebGPU_Pass_Stats,
	icons:            WebGPU_Pass_Stats,
	images:           WebGPU_Pass_Stats,
	surfaces:         WebGPU_Pass_Stats,
	prepared_commands: int,
}

// Compositor_Stats samples retained-work counters. It performs no allocation,
// synchronization, or GPU work and is safe to call after any prepared frame.
Compositor_Stats :: proc(compositor: ^WebGPU_Compositor) -> (stats: WebGPU_Renderer_Stats) {
	if compositor == nil { return }
	stats.solid = WebGPU_Pass_Stats{
		mesh_rebuilds=compositor.solid.mesh_rebuild_count,
		vertex_uploads=compositor.solid.vertex_upload_count,
		vertex_upload_bytes=compositor.solid.vertex_upload_bytes,
		transform_uploads=compositor.solid.translation_upload_count,
		transform_upload_bytes=compositor.solid.translation_upload_bytes,
		viewport_uploads=compositor.solid.viewport_upload_count,
	}
	stats.text = WebGPU_Pass_Stats{
		mesh_rebuilds=compositor.text.mesh_rebuild_count,
		vertex_uploads=compositor.text.vertex_upload_count,
		vertex_upload_bytes=compositor.text.vertex_upload_bytes,
		transform_uploads=compositor.text.translation_upload_count,
		viewport_uploads=compositor.text.viewport_upload_count,
		atlas_uploads=compositor.text.atlas_upload_count,
		atlas_upload_bytes=compositor.text.atlas_upload_bytes,
	}
	stats.icons = WebGPU_Pass_Stats{
		mesh_rebuilds=compositor.icons.mesh_rebuild_count,
		mesh_cache_hits=compositor.icons.mesh_cache_hits,
		vertex_uploads=compositor.icons.vertex_upload_count,
		vertex_upload_bytes=compositor.icons.vertex_upload_bytes,
		viewport_uploads=compositor.icons.viewport_upload_count,
		atlas_uploads=compositor.icons.atlas_page_upload_count,
		atlas_upload_bytes=compositor.icons.atlas_upload_bytes,
	}
	stats.images = WebGPU_Pass_Stats{
		mesh_rebuilds=compositor.images.mesh_rebuild_count,
		mesh_cache_hits=compositor.images.mesh_cache_hits,
		vertex_uploads=compositor.images.vertex_upload_count,
		vertex_upload_bytes=compositor.images.vertex_upload_bytes,
		viewport_uploads=compositor.images.viewport_upload_count,
		texture_uploads=compositor.images.texture_upload_count,
		texture_upload_bytes=compositor.images.texture_upload_bytes,
		resource_evictions=compositor.images.resource_eviction_count,
		resource_retirements=compositor.images.resource_retirement_count,
		resource_releases=compositor.images.resource_release_count,
		resident_bytes=compositor.images.resident_bytes,
	}
	stats.surfaces = WebGPU_Pass_Stats{
		mesh_rebuilds=compositor.surfaces.mesh_rebuild_count,
		mesh_cache_hits=compositor.surfaces.mesh_cache_hits,
		vertex_uploads=compositor.surfaces.vertex_upload_count,
		vertex_upload_bytes=compositor.surfaces.vertex_upload_bytes,
		viewport_uploads=compositor.surfaces.viewport_upload_count,
		instance_uploads=compositor.surfaces.instance_upload_count,
		instance_cache_hits=compositor.surfaces.instance_cache_hits,
		resource_evictions=compositor.surfaces.resource_eviction_count,
		resource_retirements=compositor.surfaces.resource_retirement_count,
		resource_releases=compositor.surfaces.resource_release_count,
		resident_bytes=compositor.surfaces.resident_bytes,
	}
	stats.prepared_commands = compositor.prepared_command_count
	return
}
