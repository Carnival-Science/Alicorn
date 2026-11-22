package cpu_renderer

// Backend-neutral planning and GPU-uniform packing for the experimental
// scene-local lighting compositor (issue #105).
//
// The compositor does not build a height buffer. Each pixel evaluates the
// rounded-slab signed distance function of every surface in the declared group
// directly, derives bevel normals from its gradient, and evaluates the declared
// point lights plus their cross-surface occlusion. That keeps the pass bounded
// by O(group surfaces) per pixel and makes two surfaces a trivial case.

import "core:math"
import alicorn "../../runtime"

LIGHTING_MAX_LIGHTS :: alicorn.LIGHTING_MAX_LIGHTS
LIGHTING_MAX_SURFACES :: alicorn.LIGHTING_MAX_SURFACES
LIGHTING_MAX_DIMENSION :: 2048
LIGHTING_MAX_COORD :: 1_048_576
LIGHTING_MAX_SCALE :: 64
// Logical optical height units are mapped to physical pixels at this ratio so
// raised/recessed surfaces and light heights share one scene scale.
LIGHTING_HEIGHT_PIXELS :: f32(24)
// Shadow darkening on ordinary paint outside a surface, and the bounded
// luminance modulation applied inside a surface. The bound keeps captured text
// and icons legible while preserving their hue.
LIGHTING_SHADOW_DARKNESS :: f32(0.42)
LIGHTING_SHADE_MIN :: f32(0.45)
LIGHTING_SHADE_MAX :: f32(1.4)
LIGHTING_SHADOW_STEPS :: 8

Lighting_Surface :: struct {
	bounds:          alicorn.Rect,
	corner_radius:   f32,
	physical_height: f32,
}

Lighting_Request :: struct {
	enabled: bool,
	key, source_generation: u64,
	region, clip: alicorn.Rect,
	scale: f32,
	params: alicorn.Lighting_Params,
	surfaces: [LIGHTING_MAX_SURFACES]Lighting_Surface,
	surface_count: int,
}

Lighting_Plan :: struct {
	active: bool,
	source_bounds: alicorn.Rect,
	output_clip: alicorn.Rect,
	width, height: u32,
	scale: f32,
	params: alicorn.Lighting_Params,
	surfaces: [LIGHTING_MAX_SURFACES]Lighting_Surface,
	surface_count: int,
	key, source_generation: u64,
}

// Lighting_GPU_Uniforms is the fragment-shader block. It is laid out in
// float4 rows so the HLSL, GLSL, MSL, and Odin declarations agree exactly.
Lighting_GPU_Uniforms :: struct {
	// origin_px.xy, target_px.xy
	region: [4]f32,
	// light_count, ambient, flags, shadow_darkness
	params: [4]f32,
	// surface center.xy, half_extent.xy (region-local px)
	surfaces: [LIGHTING_MAX_SURFACES][4]f32,
	// corner_radius, top_z, bevel_width, sign
	surface_params: [LIGHTING_MAX_SURFACES][4]f32,
	// position.xy, z, intensity
	lights: [LIGHTING_MAX_LIGHTS][4]f32,
	// color.rgb, source_radius_px
	light_colors: [LIGHTING_MAX_LIGHTS][4]f32,
}

lighting_rect_bounded :: proc(rect: alicorn.Rect) -> bool {
	for value in ([4]f32{rect.x, rect.y, rect.w, rect.h}) {
		if !alicorn.number_is_finite(value) || abs(value) > LIGHTING_MAX_COORD { return false }
	}
	return abs(f64(rect.x)+f64(rect.w)) <= LIGHTING_MAX_COORD &&
	       abs(f64(rect.y)+f64(rect.h)) <= LIGHTING_MAX_COORD
}

lighting_params_valid :: proc(params: alicorn.Lighting_Params) -> bool {
	if params.group == alicorn.MATERIAL_GROUP_NONE || params.generation == 0 { return false }
	if params.light_count <= 0 || params.light_count > LIGHTING_MAX_LIGHTS { return false }
	if !alicorn.number_is_finite(params.ambient) || params.ambient < 0 || params.ambient > 1 { return false }
	for index in 0..<params.light_count {
		if !alicorn.lighting_light_is_valid(params.lights[index]) { return false }
	}
	return true
}

Lighting_Plan_Make :: proc(request: Lighting_Request) -> (plan: Lighting_Plan, ok: bool) {
	if !request.enabled { return plan, true }
	if !alicorn.number_is_finite(request.scale) || request.scale <= 0 || request.scale > LIGHTING_MAX_SCALE ||
	   !lighting_rect_bounded(request.region) || !lighting_rect_bounded(request.clip) ||
	   request.key == 0 || request.source_generation == 0 ||
	   request.surface_count <= 0 || request.surface_count > LIGHTING_MAX_SURFACES ||
	   !lighting_params_valid(request.params) {
		return plan, false
	}
	output_clip := alicorn.rect_intersection(request.region, request.clip)
	if request.region.w <= 0 || request.region.h <= 0 || request.clip.w <= 0 || request.clip.h <= 0 ||
	   output_clip.w <= 0 || output_clip.h <= 0 {
		return plan, true
	}
	scale := f64(request.scale)
	left := math.floor(f64(request.region.x)*scale)
	top := math.floor(f64(request.region.y)*scale)
	right := math.ceil((f64(request.region.x)+f64(request.region.w))*scale)
	bottom := math.ceil((f64(request.region.y)+f64(request.region.h))*scale)
	w, h := right-left, bottom-top
	if abs(left) > LIGHTING_MAX_COORD || abs(top) > LIGHTING_MAX_COORD ||
	   abs(right) > LIGHTING_MAX_COORD || abs(bottom) > LIGHTING_MAX_COORD ||
	   w < 1 || h < 1 || w > LIGHTING_MAX_DIMENSION || h > LIGHTING_MAX_DIMENSION {
		return Lighting_Plan{}, false
	}
	source := alicorn.Rect{f32(left/scale), f32(top/scale), f32(w/scale), f32(h/scale)}
	if !lighting_rect_bounded(source) { return Lighting_Plan{}, false }
	plan = Lighting_Plan{
		active=true,
		source_bounds=source,
		output_clip=output_clip,
		width=u32(w),
		height=u32(h),
		scale=request.scale,
		params=request.params,
		surface_count=request.surface_count,
		key=request.key,
		source_generation=request.source_generation,
	}
	for index in 0..<request.surface_count {
		surface := request.surfaces[index]
		if !lighting_rect_bounded(surface.bounds) || surface.bounds.w <= 0 || surface.bounds.h <= 0 ||
		   surface.physical_height == 0 ||
		   !alicorn.number_is_finite(surface.corner_radius) || surface.corner_radius < 0 { return Lighting_Plan{}, false }
		plan.surfaces[index] = surface
	}
	if !Lighting_Plan_Valid(plan) { return Lighting_Plan{}, false }
	return plan, true
}

Lighting_Plan_Valid :: proc(plan: Lighting_Plan) -> bool {
	if !plan.active { return true }
	if plan.key == 0 || plan.source_generation == 0 ||
	   plan.width == 0 || plan.height == 0 || plan.width > LIGHTING_MAX_DIMENSION || plan.height > LIGHTING_MAX_DIMENSION ||
	   !alicorn.number_is_finite(plan.scale) || plan.scale <= 0 || plan.scale > LIGHTING_MAX_SCALE ||
	   plan.surface_count <= 0 || plan.surface_count > LIGHTING_MAX_SURFACES ||
	   !lighting_params_valid(plan.params) ||
	   !lighting_rect_bounded(plan.source_bounds) || !lighting_rect_bounded(plan.output_clip) ||
	   plan.source_bounds.w <= 0 || plan.source_bounds.h <= 0 ||
	   plan.output_clip.w <= 0 || plan.output_clip.h <= 0 {
		return false
	}
	left, top := f64(plan.source_bounds.x)*f64(plan.scale), f64(plan.source_bounds.y)*f64(plan.scale)
	w, h := f64(plan.source_bounds.w)*f64(plan.scale), f64(plan.source_bounds.h)*f64(plan.scale)
	if abs(left) > LIGHTING_MAX_COORD || abs(top) > LIGHTING_MAX_COORD ||
	   abs(left+w) > LIGHTING_MAX_COORD || abs(top+h) > LIGHTING_MAX_COORD ||
	   abs(left-math.round(left)) > 0.125 || abs(top-math.round(top)) > 0.125 ||
	   abs(w-f64(plan.width)) > 0.001 || abs(h-f64(plan.height)) > 0.001 {
		return false
	}
	epsilon := f32(0.25)/plan.scale
	if plan.output_clip.x < plan.source_bounds.x-epsilon || plan.output_clip.y < plan.source_bounds.y-epsilon ||
	   f64(plan.output_clip.x)+f64(plan.output_clip.w) > f64(plan.source_bounds.x)+f64(plan.source_bounds.w)+f64(epsilon) ||
	   f64(plan.output_clip.y)+f64(plan.output_clip.h) > f64(plan.source_bounds.y)+f64(plan.source_bounds.h)+f64(epsilon) {
		return false
	}
	for index in 0..<plan.surface_count {
		surface := plan.surfaces[index]
		if !lighting_rect_bounded(surface.bounds) || surface.bounds.w <= 0 || surface.bounds.h <= 0 ||
		   surface.physical_height == 0 || !alicorn.number_is_finite(surface.corner_radius) || surface.corner_radius < 0 {
			return false
		}
	}
	return true
}

// Lighting_Build_Mesh emits one textured quad covering the captured source
// region at its snapped physical location. The composite shader evaluates every
// surface and light per pixel, so no per-surface geometry is submitted.
LIGHTING_MESH_VERTICES :: 6
Lighting_Build_Mesh :: proc(plan: Lighting_Plan, vertices: ^[LIGHTING_MESH_VERTICES]Vertex) -> bool {
	if vertices == nil || !plan.active || !Lighting_Plan_Valid(plan) { return false }
	x := f32(math.round(f64(plan.source_bounds.x)*f64(plan.scale)))
	y := f32(math.round(f64(plan.source_bounds.y)*f64(plan.scale)))
	w, h := f32(plan.width), f32(plan.height)
	color := [4]f32{1, 1, 1, 1}
	a := Vertex{{x, y, 0}, color, {0, 0}}
	b := Vertex{{x+w, y, 0}, color, {1, 0}}
	c := Vertex{{x+w, y+h, 0}, color, {1, 1}}
	d := Vertex{{x, y+h, 0}, color, {0, 1}}
	vertices[0], vertices[1], vertices[2] = a, b, c
	vertices[3], vertices[4], vertices[5] = a, c, d
	return true
}

// Lighting_Uniforms_Pack converts the logical plan into the shader block.
// Everything is a pure function of the plan: no clock, no random source.
Lighting_Uniforms_Pack :: proc(plan: Lighting_Plan, target_w, target_h: u32) -> (uniforms: Lighting_GPU_Uniforms, ok: bool) {
	if !Lighting_Plan_Valid(plan) { return uniforms, false }
	_ = target_w
	_ = target_h
	scale := plan.scale
	origin_x := plan.source_bounds.x*scale
	origin_y := plan.source_bounds.y*scale
	// region.z is the shader's bounded surface count; the shader derives the
	// rest of its frame from gl_FragCoord and the capture UVs.
	uniforms.region = [4]f32{origin_x, origin_y, f32(plan.surface_count), 0}
	flags := f32(0)
	if .Shadows in plan.params.flags { flags += 1 }
	if .Hard_Shadows in plan.params.flags { flags += 2 }
	if .High_Contrast in plan.params.flags { flags += 4 }
	uniforms.params = [4]f32{f32(plan.params.light_count), plan.params.ambient, flags, LIGHTING_SHADOW_DARKNESS}
	for index in 0..<plan.surface_count {
		surface := plan.surfaces[index]
		center_x := (surface.bounds.x+surface.bounds.w*0.5-origin_x)*scale
		center_y := (surface.bounds.y+surface.bounds.h*0.5-origin_y)*scale
		half_x := surface.bounds.w*scale*0.5
		half_y := surface.bounds.h*scale*0.5
		radius := min(surface.corner_radius*scale, min(half_x, half_y))
		bevel := clamp(min(half_x, half_y)*0.25, 2, 10)
		uniforms.surfaces[index] = [4]f32{center_x, center_y, half_x, half_y}
		uniforms.surface_params[index] = [4]f32{
			radius,
			surface.physical_height*LIGHTING_HEIGHT_PIXELS*scale,
			bevel,
			1 if surface.physical_height > 0 else -1,
		}
	}
	for index in 0..<plan.params.light_count {
		light := plan.params.lights[index]
		uniforms.lights[index] = [4]f32{
			(light.position[0]-origin_x)*scale,
			(light.position[1]-origin_y)*scale,
			max(light.height, 0.05)*LIGHTING_HEIGHT_PIXELS*scale,
			light.intensity,
		}
		uniforms.light_colors[index] = [4]f32{light.color.r, light.color.g, light.color.b, light.radius*scale}
	}
	return uniforms, true
}
