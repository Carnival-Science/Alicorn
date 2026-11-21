package alicorn_sdl_gpu

// The DevTools HUD model, text, colors, and layout live in
// alicorn:host/diagnostics. This host supplies only the SDL_GPU solid-quad
// sink, so the same overlay is available to every Alicorn host.

import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
import diag "alicorn:host/diagnostics"
import "vendor:sdl3"

NATIVE_DEVTOOLS_HUD_REFRESH_INTERVAL_NS :: diag.HUD_REFRESH_INTERVAL_NS
NATIVE_DEVTOOLS_HUD_IDLE_AFTER_NS       :: diag.HUD_IDLE_AFTER_NS
NATIVE_DEVTOOLS_HUD_MAX_RECENT_SAMPLES  :: diag.HUD_MAX_RECENT_SAMPLES
NATIVE_DEVTOOLS_HUD_RESERVE_VERTICES    :: diag.HUD_RESERVE_VERTICES

Native_DevTools_HUD :: diag.HUD
Native_DevTools_HUD_Recent :: diag.Recent

native_devtools_sample_has_activity :: proc(sample: Native_DevTools_Sample) -> bool {
	return diag.sample_has_activity(sample)
}

native_devtools_activity_class :: proc(sample: Native_DevTools_Sample) -> Native_DevTools_Activity_Class {
	return diag.activity_class(sample)
}

native_devtools_activity_class_name :: proc(class: Native_DevTools_Activity_Class) -> string {
	return diag.activity_class_name(class)
}

native_devtools_activity_class_label :: proc(class: Native_DevTools_Activity_Class) -> string {
	return diag.activity_class_label(class)
}

native_devtools_hud_latest_activity :: proc(
	recorder: ^Native_Flight_Recorder,
	now_ns: u64,
	preview: Native_DevTools_Sample = {},
	preview_valid := false,
) -> (latest: Native_DevTools_Sample, found: bool) {
	return diag.latest_activity(recorder, now_ns, preview, preview_valid)
}

native_devtools_hud_activity_class :: proc(
	recorder: ^Native_Flight_Recorder,
	now_ns: u64,
	preview: Native_DevTools_Sample = {},
	preview_valid := false,
) -> Native_DevTools_Activity_Class {
	return diag.hud_activity_class(recorder, now_ns, preview, preview_valid)
}

native_devtools_hud_toggle :: proc(hud: ^Native_DevTools_HUD) {
	diag.hud_toggle(hud)
}

native_devtools_hud_recent :: proc(
	recorder: ^Native_Flight_Recorder,
	now_ns: u64,
	preview: Native_DevTools_Sample = {},
	preview_valid := false,
) -> (recent: Native_DevTools_HUD_Recent, last: Native_DevTools_Sample, has_last: bool) {
	return diag.recent(recorder, now_ns, preview, preview_valid)
}

native_devtools_hud_next_wake_ns :: proc(recorder: ^Native_Flight_Recorder, now_ns: u64) -> u64 {
	return diag.next_wake_ns(recorder, now_ns)
}

@(private)
native_hud_solid_target :: proc(renderer: ^Native_Solid_Renderer) -> diag.Quad_Target {
	return diag.Quad_Target{
		data=rawptr(renderer),
		emit=native_hud_solid_emit,
	}
}

@(private)
native_hud_solid_emit :: proc(data: rawptr, quad: diag.Quad) -> bool {
	renderer := cast(^Native_Solid_Renderer)data
	if renderer == nil { return false }
	// The HUD appends after application render commands already reference this
	// buffer, so it may use spare capacity but must not replace the GPU buffer.
	if len(renderer.vertices)+6 > renderer.vertex_capacity { return false }
	cpu_renderer.Append_Quad(
		&renderer.vertices, quad.x, quad.y, quad.x+quad.w, quad.y+quad.h, quad.color,
	)
	return true
}

native_devtools_hud_render :: proc(
	hud: ^Native_DevTools_HUD,
	renderer: ^Native_Solid_Renderer,
	command: ^sdl3.GPUCommandBuffer,
	target: ^sdl3.GPUTexture,
	target_w, target_h: sdl3.Uint32,
	scale_x, scale_y: f32,
	recorder: ^Native_Flight_Recorder,
	now_ns: u64,
	preview: Native_DevTools_Sample = {},
	preview_valid := false,
	last_invalidation: string = "",
) -> bool {
	if hud == nil || !hud.visible || renderer == nil || command == nil || target == nil || target_w == 0 || target_h == 0 {
		return true
	}
	// Preserve renderer aggregates: host-only HUD geometry must not appear as
	// application solid batches or uploads in the regular diagnostics report.
	previous_batches := renderer.batches
	previous_vertices_uploaded := renderer.vertices_uploaded
	defer {
		renderer.batches = previous_batches
		renderer.vertices_uploaded = previous_vertices_uploaded
	}

	vertex_start := len(renderer.vertices)
	draw_start := len(renderer.draws)
	diag.emit_quads(
		native_hud_solid_target(renderer), recorder, now_ns, preview, preview_valid,
		int(target_w), int(target_h), scale_x, scale_y, last_invalidation,
	)

	if len(renderer.vertices)-vertex_start == 0 { return true }
	append(&renderer.draws, Native_Solid_Draw{first_vertex=sdl3.Uint32(vertex_start), vertex_count=sdl3.Uint32(len(renderer.vertices)-vertex_start)})
	renderer.upload_pending = true
	if !native_white_texture_initialize(renderer.device, renderer.white_texture, &renderer.white_initialized, command) { return false }
	if !native_vertex_buffer_upload(
		renderer.device, renderer.vertex_buffer, renderer.vertex_transfer, renderer.vertices[:],
		renderer.vertex_capacity, renderer.upload_pending, &renderer.vertices_uploaded, command,
	) { return false }
	if !native_solid_render_batch(renderer, command, target, target_w, target_h, renderer.draws[draw_start:]) { return false }
	return true
}

@(private)
Native_Bounds_Target_State :: struct {
	renderer: ^Native_Solid_Renderer,
	first:    int,
	active:   bool,
}

// native_solid_append_debug_bounds appends the shared retained-bounds overlay
// geometry into this host's solid mesh, one draw run per inspected command.
native_solid_append_debug_bounds :: proc(
	renderer: ^Native_Solid_Renderer,
	display: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_w, target_h: sdl3.Uint32,
) {
	if renderer == nil { return }
	state: Native_Bounds_Target_State
	state.renderer = renderer
	target := diag.Quad_Target{
		data=rawptr(&state),
		begin_group=native_bounds_begin,
		emit=native_bounds_emit,
		end_group=native_bounds_end,
	}
	diag.emit_bounds(target, display, scale_x, scale_y, int(target_w), int(target_h))
	renderer.upload_pending = len(renderer.vertices) > 0
}

@(private)
native_bounds_begin :: proc(data: rawptr) -> bool {
	state := cast(^Native_Bounds_Target_State)data
	if state == nil || state.renderer == nil { return false }
	state.first = len(state.renderer.vertices)
	state.active = true
	return true
}

@(private)
native_bounds_emit :: proc(data: rawptr, quad: diag.Quad) -> bool {
	state := cast(^Native_Bounds_Target_State)data
	if state == nil || state.renderer == nil { return false }
	renderer := state.renderer
	if len(renderer.vertices)+6 > renderer.vertex_capacity &&
	   !native_vertex_buffer_ensure_capacity(
		   renderer.device, &renderer.vertex_buffer, &renderer.vertex_transfer,
		   &renderer.vertex_capacity, len(renderer.vertices)+24,
	   ) {
		// Bounds are optional diagnostics; preserve the app frame and draw any
		// overlay geometry accumulated so far if the extra allocation fails.
		return false
	}
	cpu_renderer.Append_Quad(&renderer.vertices, quad.x, quad.y, quad.x+quad.w, quad.y+quad.h, quad.color)
	return true
}

@(private)
native_bounds_end :: proc(data: rawptr) {
	state := cast(^Native_Bounds_Target_State)data
	if state == nil || state.renderer == nil || !state.active { return }
	renderer := state.renderer
	count := len(renderer.vertices)-state.first
	if count > 0 {
		append(&renderer.draws, Native_Solid_Draw{
			first_vertex=sdl3.Uint32(state.first),
			vertex_count=sdl3.Uint32(count),
		})
	}
	state.active = false
}
