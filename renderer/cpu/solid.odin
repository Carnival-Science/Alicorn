package cpu_renderer

import "core:math"
import alicorn "../../runtime"

Pixel_Rect :: struct {
	x, y, w, h: int,
}

Solid_Draw :: struct {
	first_vertex: int,
	vertex_count: int,
	scissor: Pixel_Rect,
	has_scissor: bool,
}

Solid_Pixel_Bounds :: proc(
	draw: alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_w, target_h: int,
) -> (x0, y0, x1, y1: int, visible: bool) {
	left := draw.bounds.x + draw.translation[0]
	top := draw.bounds.y + draw.translation[1]
	right := draw.bounds.x + draw.bounds.w + draw.translation[0]
	bottom := draw.bounds.y + draw.bounds.h + draw.translation[1]
	if draw.clip.x > left { left = draw.clip.x }
	if draw.clip.y > top { top = draw.clip.y }
	if draw.clip.x + draw.clip.w < right { right = draw.clip.x + draw.clip.w }
	if draw.clip.y + draw.clip.h < bottom { bottom = draw.clip.y + draw.clip.h }
	if right < left { right = left }
	if bottom < top { bottom = top }
	x0, y0, x1, y1 = Logical_To_Pixel_Bounds(
		alicorn.Rect{left, top, right-left, bottom-top}, scale_x, scale_y,
	)
	if x0 < 0 { x0 = 0 }
	if y0 < 0 { y0 = 0 }
	if x1 > target_w { x1 = target_w }
	if y1 > target_h { y1 = target_h }
	visible = x1 > x0 && y1 > y0
	return
}

Solid_Stroke_Outside :: proc(stroke: alicorn.Paint_Stroke, placement: alicorn.Paint_Stroke_Placement) -> f32 {
	if stroke.width <= 0 { return 0 }
	if placement == .Inside { return 0 }
	if placement == .Outside { return stroke.width }
	return stroke.width*0.5
}

Solid_Visible_Command :: proc(
	draw: alicorn.Paint_Command,
	surface: alicorn.Surface_Paint,
	material: alicorn.Style_Material,
	scale_x, scale_y: f32,
	resolved_shape := alicorn.Surface_Shape{},
) -> alicorn.Paint_Command {
	visible := draw
	shape := resolved_shape
	if shape.kind == .Rectangle && surface.shape.kind != .Rounded_Rectangle_Per_Corner {
		shape = alicorn.Surface_Shape{kind=surface.shape.kind, corner_radius=surface.shape.corner_radius}
	}
	if shape.kind == .Arc {
		arc := shape.arc
		radius := arc.radius*min(draw.bounds.w, draw.bounds.h)
		left := max(radius-arc.center[0]*draw.bounds.w, 0)
		top := max(radius-arc.center[1]*draw.bounds.h, 0)
		right := max(radius-(1-arc.center[0])*draw.bounds.w, 0)
		bottom := max(radius-(1-arc.center[1])*draw.bounds.h, 0)
		visible.bounds.x -= left
		visible.bounds.y -= top
		visible.bounds.w += left+right
		visible.bounds.h += top+bottom
	}
	maximum_scale := max(scale_x, scale_y)
	outset_pixels := Solid_Stroke_Outside(surface.stroke, draw.stroke_placement) * maximum_scale
	if material.kind == .Analytic_Relief && surface.physical_height > 0 &&
	   material.outer_shadow_radius > 0 && material.outer_shadow_strength > 0 {
		outset_pixels = max(outset_pixels, material.outer_shadow_radius*maximum_scale)
	}
	// Rounded fill/stroke meshes include a transparent antialias fringe even
	// without a visible stroke; culling must include that emitted footprint.
	if Shape_Is_Rounded(shape) {
		outset_pixels += ROUNDED_ANTIALIAS_FRINGE
	} else if shape.kind == .Circle || shape.kind == .Arc || shape.kind == .Cubic_Bezier {
		outset_pixels += VECTOR_ANTIALIAS_FRINGE
	}
	if outset_pixels > 0 {
		visible.bounds.x -= outset_pixels / max(scale_x, 0.001)
		visible.bounds.y -= outset_pixels / max(scale_y, 0.001)
		visible.bounds.w += outset_pixels / max(scale_x, 0.001) * 2
		visible.bounds.h += outset_pixels / max(scale_y, 0.001) * 2
	}
	return visible
}

Solid_Pixel_Scissor :: proc(draw: alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: int) -> Pixel_Rect {
	x0, y0, x1, y1 := Logical_To_Pixel_Bounds(draw.clip, scale_x, scale_y)
	if x0 < 0 { x0 = 0 }
	if y0 < 0 { y0 = 0 }
	if x1 > target_w { x1 = target_w }
	if y1 > target_h { y1 = target_h }
	if x1 < x0 { x1 = x0 }
	if y1 < y0 { y1 = y0 }
	return Pixel_Rect{x0, y0, x1-x0, y1-y0}
}

Solid_Unclipped_Pixel_Bounds :: proc(draw: alicorn.Paint_Command, scale_x, scale_y: f32) -> alicorn.Rect {
	bounds := draw.bounds
	bounds.x += draw.translation[0]
	bounds.y += draw.translation[1]
	x0, y0, x1, y1 := Logical_To_Pixel_Bounds(bounds, scale_x, scale_y)
	return alicorn.Rect{f32(x0), f32(y0), f32(x1-x0), f32(y1-y0)}
}

Solid_Material_For_Command :: proc(rt: ^alicorn.Runtime, command: alicorn.Paint_Command) -> (
	material: alicorn.Style_Material,
	surface: alicorn.Surface_Paint,
	shape: alicorn.Surface_Shape,
	gradient: alicorn.Surface_Gradient,
	valid: bool,
) {
	surface, valid = command.payload.(alicorn.Surface_Paint)
	if !valid { return }
	shape, valid = alicorn.surface_paint_shape_resolve(rt, command.owner, surface.shape)
	if !valid { return }
	if command.semantic_surface_gradient {
		gradient = alicorn.semantic_surface_gradient_for_paint_owner(rt, command.owner)
		if !alicorn.Surface_Gradient_Is_Valid(surface.fill, gradient) {
			// Invalid low-level gradient data falls back to the ordinary fill.
			gradient = alicorn.SURFACE_GRADIENT_NONE
		}
	}
	if surface.material == alicorn.MATERIAL_FLAT {
		return alicorn.STYLE_MATERIAL_FLAT, surface, shape, gradient, true
	}
	material, valid = alicorn.style_material_resolve(rt, surface.material)
	if !valid {
		// Unknown handles retain the established flat fallback.
		material = alicorn.STYLE_MATERIAL_FLAT
		valid = true
	}
	return material, surface, shape, gradient, valid
}

Solid_Surface_Vertex_Count :: proc(
	rt: ^alicorn.Runtime,
	draw: alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_w, target_h: int,
) -> (count: int, visible: bool) {
	if !alicorn.paint_command_is_surface(draw) { return }
	material, surface, shape, _, valid := Solid_Material_For_Command(rt, draw)
	if !valid { return }
	visible_command := Solid_Visible_Command(draw, surface, material, scale_x, scale_y, shape)
	_, _, _, _, visible = Solid_Pixel_Bounds(visible_command, scale_x, scale_y, target_w, target_h)
	if visible {
		count = Material_Vertex_Count(
			material, surface.physical_height, shape, surface.stroke, surface.top_edge_gap,
			bounds=draw.bounds, scale_x=scale_x, scale_y=scale_y, fill=surface.fill,
		)
	}
	return
}

Append_Surface_Mesh :: proc(
	vertices: ^[dynamic]Vertex,
	rt: ^alicorn.Runtime,
	draw: alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_w, target_h: int,
) -> (result: Solid_Draw) {
	if !alicorn.paint_command_is_surface(draw) { return }
	material, surface, shape, gradient, valid := Solid_Material_For_Command(rt, draw)
	if !valid { return }
	visible_command := Solid_Visible_Command(draw, surface, material, scale_x, scale_y, shape)
	x0, y0, x1, y1, visible := Solid_Pixel_Bounds(visible_command, scale_x, scale_y, target_w, target_h)
	if !visible { return }
	first := len(vertices^)
	rounded := Shape_Is_Rounded(shape)
	scissor := Solid_Pixel_Scissor(draw, scale_x, scale_y, target_w, target_h)
	if shape.kind == .Circle {
		base := Solid_Unclipped_Pixel_Bounds(draw, scale_x, scale_y)
		stroke := surface.stroke
		stroke.width *= max(scale_x, scale_y)
		segments := Vector_Segments(shape, draw.bounds, scale_x, scale_y)
		Append_Circle_Surface(vertices, base, surface.fill, stroke, draw.stroke_placement, draw.opacity, 1, 1, segments)
		return Solid_Draw{first, len(vertices^)-first, scissor, true}
	} else if shape.kind == .Arc || shape.kind == .Cubic_Bezier {
		segments := Vector_Segments(shape, draw.bounds, scale_x, scale_y)
		points: [VECTOR_CURVE_MAX_SEGMENTS+1][2]f32
		point_count := segments+1
		origin_x := (draw.bounds.x+draw.translation[0])*scale_x
		origin_y := (draw.bounds.y+draw.translation[1])*scale_y
		if shape.kind == .Arc {
			arc := shape.arc
			center_x := origin_x+arc.center[0]*draw.bounds.w*scale_x
			center_y := origin_y+arc.center[1]*draw.bounds.h*scale_y
			radius := arc.radius*min(draw.bounds.w, draw.bounds.h)
			for point_index in 0..<point_count {
				parameter := f32(point_index)/f32(segments)
				angle := arc.start_angle+arc.sweep_angle*parameter
				points[point_index] = {
					center_x+math.cos(angle)*radius*scale_x,
					center_y+math.sin(angle)*radius*scale_y,
				}
			}
		} else {
			control := shape.bezier.points
			for point_index in 0..<point_count {
				t := f32(point_index)/f32(segments)
				u := 1-t
				x := control[0][0]*u*u*u + 3*control[1][0]*u*u*t + 3*control[2][0]*u*t*t + control[3][0]*t*t*t
				y := control[0][1]*u*u*u + 3*control[1][1]*u*u*t + 3*control[2][1]*u*t*t + control[3][1]*t*t*t
				points[point_index] = {origin_x+x*draw.bounds.w*scale_x, origin_y+y*draw.bounds.h*scale_y}
			}
		}
		stroke := surface.stroke
		stroke.width *= max(scale_x, scale_y)
		Append_Stroked_Path(vertices, points[:point_count], stroke, draw.opacity)
		return Solid_Draw{first, len(vertices^)-first, scissor, true}
	} else if shape.kind == .Connected_Tab {
		base := Solid_Unclipped_Pixel_Bounds(draw, scale_x, scale_y)
		Append_Connected_Tab(vertices, base, surface.fill, draw.opacity, max(scale_x, scale_y))
		return Solid_Draw{first, len(vertices^)-first, scissor, true}
	} else if rounded {
		base := Solid_Unclipped_Pixel_Bounds(draw, scale_x, scale_y)
		pixel_shape := shape
		logical_radii := alicorn.surface_shape_normalized_corner_radii(shape, draw.bounds.w, draw.bounds.h)
		if pixel_shape.kind == .Rounded_Rectangle {
			pixel_shape.corner_radius = logical_radii.top_left*max(scale_x, scale_y)
		} else {
			pixel_shape.corner_radii.top_left = logical_radii.top_left*max(scale_x, scale_y)
			pixel_shape.corner_radii.top_right = logical_radii.top_right*max(scale_x, scale_y)
			pixel_shape.corner_radii.bottom_right = logical_radii.bottom_right*max(scale_x, scale_y)
			pixel_shape.corner_radii.bottom_left = logical_radii.bottom_left*max(scale_x, scale_y)
		}
		pixel_material := material
		pixel_material.bevel_width *= max(scale_x, scale_y)
		pixel_material.outer_shadow_radius *= max(scale_x, scale_y)
		shadow := base
		if material.kind == .Analytic_Relief && surface.physical_height > 0 && material.outer_shadow_radius > 0 && material.outer_shadow_strength > 0 {
			expand := material.outer_shadow_radius*max(scale_x, scale_y)
			shadow = alicorn.Rect{base.x-expand, base.y-expand, base.w+expand*2, base.h+expand*2}
		}
		stroke := surface.stroke
		stroke.width *= max(scale_x, scale_y)
		Append_Rounded_Material_Surface(
			vertices, base, shadow, surface.fill, pixel_material,
			surface.physical_height, draw.opacity, pixel_shape, stroke, draw.stroke_placement, gradient,
		)
		return Solid_Draw{first, len(vertices^)-first, scissor, true}
	} else {
		base := alicorn.Rect{f32(x0), f32(y0), f32(x1-x0), f32(y1-y0)}
		surface_scissor := gradient.axis != .None || surface.stroke.width > 0 ||
			(material.kind == .Analytic_Relief && surface.physical_height > 0 &&
			 material.outer_shadow_radius > 0 && material.outer_shadow_strength > 0)
		if surface_scissor {
			base = Solid_Unclipped_Pixel_Bounds(draw, scale_x, scale_y)
		}
		shadow := base
		if material.kind == .Analytic_Relief && surface.physical_height > 0 && material.outer_shadow_radius > 0 && material.outer_shadow_strength > 0 {
			expand := material.outer_shadow_radius * max(scale_x, scale_y)
			shadow_command := draw
			shadow_command.bounds = alicorn.Rect{
				draw.bounds.x-expand,
				draw.bounds.y-expand,
				draw.bounds.w+expand*2,
				draw.bounds.h+expand*2,
			}
			sx0, sy0, sx1, sy1, shadow_visible := Solid_Pixel_Bounds(shadow_command, scale_x, scale_y, target_w, target_h)
			if shadow_visible { shadow = alicorn.Rect{f32(sx0), f32(sy0), f32(sx1-sx0), f32(sy1-sy0)} }
		}
		stroke := surface.stroke
		stroke.width *= max(scale_x, scale_y)
		gap := [2]f32{}
		if surface.top_edge_gap[1] > surface.top_edge_gap[0] {
			gap = {
				f32(Pixel_Edge(surface.top_edge_gap[0]+draw.translation[0], scale_x)),
				f32(Pixel_Edge(surface.top_edge_gap[1]+draw.translation[0], scale_x)),
			}
		}
		if gradient.axis == .None &&
		   (material.kind != .Analytic_Relief || surface.physical_height == 0) {
			// Preserve byte-for-byte geometry for ordinary flat surfaces.
			Append_Quad(vertices, base.x, base.y, base.x+base.w, base.y+base.h,
				[4]f32{surface.fill.r, surface.fill.g, surface.fill.b, surface.fill.a*draw.opacity})
			Append_Rect_Stroke(vertices, base, stroke, draw.opacity, draw.stroke_placement, gap)
		} else {
			Append_Material_Surface(vertices, base, shadow, surface.fill, material, surface.physical_height, draw.opacity, stroke, draw.stroke_placement, gap, gradient)
		}
		return Solid_Draw{first, len(vertices^)-first, scissor, surface_scissor}
	}
}
