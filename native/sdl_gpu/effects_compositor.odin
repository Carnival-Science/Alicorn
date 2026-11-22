package alicorn_sdl_gpu

// Application compositor integration for bounded backdrop blur.
// The request is a paint-stream boundary: the host captures only commands
// before it, then composites the cached result immediately before the owning
// surface. Applications never see textures, command buffers, or fences.

import "core:mem"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
import "vendor:sdl3"

NATIVE_EFFECT_PREFIX_CLEAR :: sdl3.FColor{0.035, 0.045, 0.065, 1}

native_effect_prefix_generation_for_runtime :: proc(
	rt: ^alicorn.Runtime,
	display: []alicorn.Paint_Command,
	region, clip: alicorn.Rect,
	scale_x, scale_y, sigma: f32,
) -> u64 {
	return cpu_renderer.Backdrop_Effect_Prefix_Generation_For_Runtime(
		rt, display, region, clip, scale_x, scale_y, sigma,
	)
}

native_effect_prefix_generation :: proc(
	display: []alicorn.Paint_Command,
	region, clip: alicorn.Rect,
	scale_x, scale_y, sigma: f32,
) -> u64 {
	return cpu_renderer.Backdrop_Effect_Prefix_Generation(display, region, clip, scale_x, scale_y, sigma)
}

native_effect_prefix_before_first_marker :: proc(display: []alicorn.Paint_Command) -> (prefix: []alicorn.Paint_Command, marker: alicorn.Paint_Command, marker_index: int, found: bool) {
	return cpu_renderer.Effects_Prefix_Before_First_Boundary(display)
}

native_effect_local_prefix :: proc(display: []alicorn.Paint_Command, origin: alicorn.Rect, allocator: mem.Allocator) -> []alicorn.Paint_Command {
	return cpu_renderer.Backdrop_Effect_Local_Prefix(display, origin, allocator)
}

// native_effect_prime_capture_text builds and uploads the text mesh for the
// cropped prefix before the capture pass draws it. draw_display_list normally
// rebuilds text after a prefix capture has been prepared, so without this the
// captured glyphs would be one frame behind the command list that generated
// them. The immediate capture draw then reuses this mesh by fingerprint.
@(private)
native_effect_prime_capture_text :: proc(
	command: ^sdl3.GPUCommandBuffer,
	text_renderer: ^Native_Text_Renderer,
	local: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	scratch_allocator: mem.Allocator,
) -> bool {
	if !native_text_rebuild_mesh(text_renderer, local, scale_x, scale_y, scratch_allocator) { return false }
	if !native_text_sync_atlas(text_renderer, command, scratch_allocator) { return false }
	return native_text_upload_vertices(text_renderer, command)
}

native_effect_capture_clear :: proc(command: ^sdl3.GPUCommandBuffer, texture: ^sdl3.GPUTexture) -> bool {
	if command == nil || texture == nil { return false }
	info := make_color_target(texture, NATIVE_EFFECT_PREFIX_CLEAR, false)
	pass := sdl3.BeginGPURenderPass(command, &info, 1, nil)
	if pass == nil { return false }
	sdl3.EndGPURenderPass(pass)
	return true
}
native_effects_prepare_display_prefix :: proc(
	command: ^sdl3.GPUCommandBuffer,
	swap_w, swap_h: sdl3.Uint32,
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
	display: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	effects: ^Native_Retained_Effects,
	scratch_allocator: mem.Allocator,
) -> bool {
	if effects == nil { return true }
	effects.retry_pending = false
	prefix, marker, marker_index, found := native_effect_prefix_before_first_marker(display)
	if !found { return true }
	// A second boundary would imply nested sampling semantics that this narrow
	// API intentionally does not define. Keep the ordinary paint instead.
	for draw in display[marker_index+1:] {
		if alicorn.paint_command_is_effects_boundary(draw) { return true }
	}
	if alicorn.paint_command_is_lighting_group(marker) {
		return native_lighting_prepare_prefix(
			command, text_renderer, surface_renderer, solid_renderer,
			prefix, marker, scale_x, scale_y, effects, scratch_allocator,
		)
	}
	payload, is_effect := marker.payload.(alicorn.Backdrop_Effect_Paint)
	if !is_effect || marker.owner == 0 || abs(scale_x-scale_y) > 0.001 { return true }
	key := u64(marker.owner)
	generation := native_effect_prefix_generation_for_runtime(surface_renderer.runtime, prefix, marker.bounds, marker.clip, scale_x, scale_y, payload.sigma)
	request := Native_Effect_Request{
		enabled=true,
		key=key,
		source_generation=generation,
		region=marker.bounds,
		clip=marker.clip,
		scale=scale_x,
		sigma=payload.sigma,
		depth=1,
	}
	plan, valid := native_effect_plan(request)
	if !valid || !plan.active { return true }
	status := native_retained_effects_prepare(effects, plan)
	if status != .Render { return true }
	slot := &effects.slots[effects.pending_slot]
	if !native_effect_capture_clear(command, slot.source) {
		native_retained_effects_abort(effects)
		return false
	}
	local := native_effect_local_prefix(prefix, plan.source_bounds, scratch_allocator)
	if local == nil && len(prefix) > 0 {
		native_retained_effects_abort(effects)
		return false
	}
	if !native_effect_prime_capture_text(command, text_renderer, local, scale_x, scale_y, scratch_allocator) {
		native_retained_effects_abort(effects)
		return false
	}
	if !draw_display_list(
		command, slot.source, plan.width, plan.height,
		text_renderer, surface_renderer, solid_renderer,
		local, scale_x, scale_y,
		clear_background=false,
		scratch_allocator=scratch_allocator,
	) {
		native_retained_effects_abort(effects)
		return false
	}
	if !native_retained_effects_encode(effects, command) {
		native_retained_effects_abort(effects)
		// Filtering is optional: preserve the ordinary panel path if an
		// effect pipeline cannot be encoded on this host.
		return true
	}
	return true
}

// native_lighting_group_surface_radius resolves the authored corner radius of
// one group surface. Per-corner radii collapse to their maximum for the
// prototype's analytic slab; the compositor never sees the authored sidecar.
@(private)
native_lighting_group_surface_radius :: proc(rt: ^alicorn.Runtime, draw: alicorn.Paint_Command, surface: alicorn.Surface_Paint) -> f32 {
	shape, ok := alicorn.surface_paint_shape_resolve(rt, draw.owner, surface.shape)
	if !ok { return surface.shape.corner_radius }
	radii := alicorn.surface_shape_corner_radii(shape)
	return max(max(radii.top_left, radii.top_right), max(radii.bottom_right, radii.bottom_left))
}

// native_lighting_prepare_prefix captures the paint prefix once and encodes the
// lighting composite. The group's surface geometry comes from the same prefix
// that the generation hashes, so a moved or resized surface always produces a
// new generation. Returns true on every optional-fallback path; only a failed
// command encoding aborts the frame.
native_lighting_prepare_prefix :: proc(
	command: ^sdl3.GPUCommandBuffer,
	text_renderer: ^Native_Text_Renderer,
	surface_renderer: ^Native_Surface_Renderer,
	solid_renderer: ^Native_Solid_Renderer,
	prefix: []alicorn.Paint_Command,
	marker: alicorn.Paint_Command,
	scale_x, scale_y: f32,
	effects: ^Native_Retained_Effects,
	scratch_allocator: mem.Allocator,
) -> bool {
	if effects == nil || marker.owner != alicorn.LIGHTING_MARKER_OWNER || abs(scale_x-scale_y) > 0.001 { return true }
	payload, is_lighting := marker.payload.(alicorn.Lighting_Group_Paint)
	if !is_lighting { return true }
	rt := surface_renderer.runtime
	params, params_ok := alicorn.lighting_paint_params(rt, marker)
	if !params_ok || params.group != payload.group { return true }

	request := cpu_renderer.Lighting_Request{
		enabled=true,
		key=u64(marker.owner),
		region=marker.bounds,
		clip=marker.clip,
		scale=scale_x,
		params=params,
	}
	for draw in prefix {
		surface, is_surface := draw.payload.(alicorn.Surface_Paint)
		if !is_surface || surface.material_group != params.group || surface.physical_height == 0 { continue }
		if request.surface_count >= cpu_renderer.LIGHTING_MAX_SURFACES { break }
		bounds := alicorn.Rect{
			draw.bounds.x+draw.translation[0],
			draw.bounds.y+draw.translation[1],
			draw.bounds.w,
			draw.bounds.h,
		}
		if bounds.w <= 0 || bounds.h <= 0 { continue }
		request.surfaces[request.surface_count] = cpu_renderer.Lighting_Surface{
			bounds=bounds,
			corner_radius=native_lighting_group_surface_radius(rt, draw, surface),
			physical_height=surface.physical_height,
		}
		request.surface_count += 1
	}
	if request.surface_count == 0 { return true }
	generation := native_effect_prefix_generation_for_runtime(
		rt, prefix, marker.bounds, marker.clip, scale_x, scale_y, 0,
	)
	generation = alicorn.hash_mix(generation, payload.generation)
	if generation == 0 { generation = 1 }
	request.source_generation = generation
	cpu_plan, plan_ok := cpu_renderer.Lighting_Plan_Make(request)
	if !plan_ok || !cpu_plan.active { return true }
	plan, native_plan_ok := native_lighting_plan_from_cpu(cpu_plan)
	if !native_plan_ok || !plan.active { return true }
	status := native_retained_effects_prepare(effects, plan)
	if status != .Render { return true }
	slot := &effects.slots[effects.pending_slot]
	if !native_effect_capture_clear(command, slot.source) {
		native_retained_effects_abort(effects)
		return false
	}
	slot.lighting_captures += 1
	local := native_effect_local_prefix(prefix, plan.source_bounds, scratch_allocator)
	if local == nil && len(prefix) > 0 {
		native_retained_effects_abort(effects)
		return false
	}
	if !native_effect_prime_capture_text(command, text_renderer, local, scale_x, scale_y, scratch_allocator) {
		native_retained_effects_abort(effects)
		return false
	}
	if !draw_display_list(
		command, slot.source, plan.width, plan.height,
		text_renderer, surface_renderer, solid_renderer,
		local, scale_x, scale_y,
		clear_background=false,
		scratch_allocator=scratch_allocator,
	) {
		native_retained_effects_abort(effects)
		return false
	}
	if !native_retained_effects_encode(effects, command) {
		native_retained_effects_abort(effects)
		return true
	}
	return true
}
