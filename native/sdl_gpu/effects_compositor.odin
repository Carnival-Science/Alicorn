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
	return cpu_renderer.Backdrop_Effect_Prefix_Before_First_Marker(display)
}

native_effect_local_prefix :: proc(display: []alicorn.Paint_Command, origin: alicorn.Rect, allocator: mem.Allocator) -> []alicorn.Paint_Command {
	return cpu_renderer.Backdrop_Effect_Local_Prefix(display, origin, allocator)
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
	// API intentionally does not define. Keep the ordinary panel draw instead.
	for draw in display[marker_index+1:] {
		if alicorn.paint_command_is_backdrop_effect(draw) { return true }
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
