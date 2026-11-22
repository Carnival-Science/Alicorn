package cpu_renderer

import "core:mem"
import alicorn "../../runtime"

// The generation hashes only the paint prefix captured behind one backdrop
// marker. Commands rendered after the marker cannot invalidate its pixels.
Backdrop_Effect_Prefix_Generation_For_Runtime :: proc(
	rt: ^alicorn.Runtime,
	display: []alicorn.Paint_Command,
	region, clip: alicorn.Rect,
	scale_x, scale_y, sigma: f32,
) -> u64 {
	hash := u64(1469598103934665603)
	hash = backdrop_effect_hash_rect(hash, region)
	hash = backdrop_effect_hash_rect(hash, clip)
	hash = backdrop_effect_hash_f32(hash, scale_x)
	hash = backdrop_effect_hash_f32(hash, scale_y)
	hash = backdrop_effect_hash_f32(hash, sigma)
	hash = alicorn.hash_mix(hash, u64(len(display)))
	for draw in display { hash = backdrop_effect_hash_command(hash, draw, rt) }
	if hash == 0 { return 1 }
	return hash
}

Backdrop_Effect_Prefix_Generation :: proc(
	display: []alicorn.Paint_Command,
	region, clip: alicorn.Rect,
	scale_x, scale_y, sigma: f32,
) -> u64 {
	return Backdrop_Effect_Prefix_Generation_For_Runtime(nil, display, region, clip, scale_x, scale_y, sigma)
}

Backdrop_Effect_Prefix_Before_First_Marker :: proc(
	display: []alicorn.Paint_Command,
) -> (prefix: []alicorn.Paint_Command, marker: alicorn.Paint_Command, marker_index: int, found: bool) {
	for draw, index in display {
		if alicorn.paint_command_is_backdrop_effect(draw) {
			return display[:index], draw, index, true
		}
	}
	return nil, {}, -1, false
}

// Effects_Prefix_Before_First_Boundary finds the frame's single effects
// boundary, whichever kind it is. Callers enforce the one-boundary rule.
Effects_Prefix_Before_First_Boundary :: proc(
	display: []alicorn.Paint_Command,
) -> (prefix: []alicorn.Paint_Command, marker: alicorn.Paint_Command, marker_index: int, found: bool) {
	for draw, index in display {
		if alicorn.paint_command_is_effects_boundary(draw) {
			return display[:index], draw, index, true
		}
	}
	return nil, {}, -1, false
}

// Localized prefix copies keep source paints intact while shifting geometry
// and clips into the offscreen capture's logical origin.
Backdrop_Effect_Local_Prefix :: proc(
	display: []alicorn.Paint_Command,
	origin: alicorn.Rect,
	allocator: mem.Allocator,
) -> []alicorn.Paint_Command {
	result := make([]alicorn.Paint_Command, len(display), allocator=allocator)
	for draw, index in display {
		result[index] = draw
		result[index].bounds.x -= origin.x
		result[index].bounds.y -= origin.y
		result[index].clip.x -= origin.x
		result[index].clip.y -= origin.y
	}
	return result
}

backdrop_effect_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	return alicorn.hash_mix(hash, u64(transmute(u32)value))
}

backdrop_effect_hash_rect :: proc(hash: u64, rect: alicorn.Rect) -> u64 {
	result := hash
	for value in ([4]f32{rect.x, rect.y, rect.w, rect.h}) {
		result = backdrop_effect_hash_f32(result, value)
	}
	return result
}

backdrop_effect_hash_color :: proc(hash: u64, color: alicorn.Color) -> u64 {
	result := hash
	for value in ([4]f32{color.r, color.g, color.b, color.a}) {
		result = backdrop_effect_hash_f32(result, value)
	}
	return result
}

backdrop_effect_hash_command :: proc(hash: u64, draw: alicorn.Paint_Command, rt: ^alicorn.Runtime) -> u64 {
	result := alicorn.hash_mix(hash, u64(draw.owner))
	result = backdrop_effect_hash_rect(result, draw.bounds)
	result = backdrop_effect_hash_rect(result, draw.clip)
	result = alicorn.hash_mix(result, u64(draw.stroke_placement))
	result = backdrop_effect_hash_f32(result, draw.opacity)
	result = backdrop_effect_hash_f32(result, draw.translation[0])
	result = backdrop_effect_hash_f32(result, draw.translation[1])
	switch payload in draw.payload {
	case alicorn.Surface_Paint:
		result = alicorn.hash_mix(result, 1)
		result = alicorn.hash_mix(result, u64(payload.shape.kind))
		result = backdrop_effect_hash_f32(result, payload.shape.corner_radius)
		resolved_shape, shape_ok := alicorn.surface_paint_shape_resolve(rt, draw.owner, payload.shape)
		result = alicorn.hash_mix(result, u64(shape_ok))
		if shape_ok {
			radii := alicorn.surface_shape_corner_radii(resolved_shape)
			result = backdrop_effect_hash_f32(result, radii.top_left)
			result = backdrop_effect_hash_f32(result, radii.top_right)
			result = backdrop_effect_hash_f32(result, radii.bottom_right)
			result = backdrop_effect_hash_f32(result, radii.bottom_left)
		}
		result = backdrop_effect_hash_color(result, payload.fill)
		result = alicorn.hash_mix(result, u64(draw.semantic_surface_gradient))
		if draw.semantic_surface_gradient {
			gradient := alicorn.semantic_surface_gradient_for_paint_owner(rt, draw.owner)
			result = alicorn.hash_mix(result, u64(gradient.axis))
			result = backdrop_effect_hash_color(result, gradient.end)
		}
		result = backdrop_effect_hash_color(result, payload.stroke.color)
		result = backdrop_effect_hash_f32(result, payload.stroke.width)
		result = alicorn.hash_mix(result, u64(payload.material))
		result = backdrop_effect_hash_f32(result, payload.physical_height)
		result = alicorn.hash_mix(result, u64(payload.material_group))
		result = backdrop_effect_hash_f32(result, payload.top_edge_gap[0])
		result = backdrop_effect_hash_f32(result, payload.top_edge_gap[1])
	case alicorn.Backdrop_Effect_Paint:
		result = alicorn.hash_mix(result, 2)
		result = backdrop_effect_hash_f32(result, payload.sigma)
		result = alicorn.hash_mix(result, u64(payload.fallback))
	case alicorn.Lighting_Group_Paint:
		result = alicorn.hash_mix(result, 7)
		result = alicorn.hash_mix(result, u64(payload.group))
		result = alicorn.hash_mix(result, payload.generation)
	case alicorn.Icon_Paint:
		result = alicorn.hash_mix(result, 3)
		result = alicorn.hash_mix(result, u64(payload.id))
		result = backdrop_effect_hash_color(result, payload.color)
	case alicorn.Image_Paint:
		result = alicorn.hash_mix(result, 4)
		result = alicorn.hash_mix(result, u64(payload.image))
	case alicorn.Text_Paint:
		result = alicorn.hash_mix(result, 5)
		result = alicorn.hash_mix(result, u64(payload.run.source))
		result = alicorn.hash_mix(result, payload.run.resource)
		result = alicorn.hash_mix(result, payload.run.generation)
		result = backdrop_effect_hash_color(result, payload.color)
		for span in payload.spans {
			result = alicorn.hash_mix(result, u64(span.start))
			result = alicorn.hash_mix(result, u64(span.end))
			result = backdrop_effect_hash_color(result, span.color)
			result = alicorn.hash_mix(result, u64(span.color_set))
			result = alicorn.hash_mix(result, u64(span.underline))
			result = alicorn.hash_mix(result, u64(span.strikethrough))
			result = backdrop_effect_hash_color(result, span.background)
			result = alicorn.hash_mix(result, u64(span.background_set))
		}
	case alicorn.Geometry_Paint:
		result = alicorn.hash_mix(result, 6)
		result = alicorn.hash_mix(result, u64(payload.geometry.resource))
		result = alicorn.hash_mix(result, payload.geometry.generation)
		if rt != nil {
			payload_view, valid := alicorn.gpu_surface_payload_resolve(rt, payload.geometry)
			result = alicorn.hash_mix(result, u64(valid))
			if valid { result = alicorn.hash_mix(result, u64(payload_view.revision)) }
		}
	}
	return result
}
