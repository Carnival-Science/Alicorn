package cpu_renderer

import "core:math"
import alicorn "../../runtime"

// Backdrop-effect planning and Gaussian sampling are CPU policy shared by the
// SDL_GPU reference and WebGPU renderers. GPU resource formats and budgets stay
// with each backend.
BACKDROP_EFFECT_MAX_DIMENSION :: 2048
BACKDROP_EFFECT_MAX_COORD :: 1_048_576
BACKDROP_EFFECT_MAX_SCALE :: 64
BACKDROP_EFFECT_MAX_SIGMA_PIXELS :: 32.0
BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS :: 96
BACKDROP_EFFECT_MAX_GAUSSIAN_KERNEL_WIDTH :: 2*BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS+1
BACKDROP_EFFECT_MAX_FILTER_TAPS :: 97

Backdrop_Effect_Tap :: struct {
	offset_pixels: f32,
	weight: f32,
}

Backdrop_Effect_Request :: struct {
	enabled: bool,
	key, source_generation: u64,
	region, clip: alicorn.Rect,
	scale: f32,
	sigma: f32, // Gaussian standard deviation in logical pixels, [0,8]; zero bypasses
	depth: int, // exactly one; nesting is unsupported
}

Backdrop_Effect_Plan :: struct {
	active: bool,
	source_bounds: alicorn.Rect,
	output_clip: alicorn.Rect,
	width, height: u32,
	scale, sigma_pixels: f32,
	filter_tap_count: int,
	key, source_generation: u64,
}

Backdrop_Effect_Gaussian_Radius :: proc(sigma_pixels: f32) -> (radius: int, ok: bool) {
	if !alicorn.number_is_finite(sigma_pixels) || sigma_pixels <= 0 || sigma_pixels > BACKDROP_EFFECT_MAX_SIGMA_PIXELS {
		return 0, false
	}
	radius_f64 := math.ceil(3*f64(sigma_pixels))
	if radius_f64 < 1 || radius_f64 > BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS { return 0, false }
	return int(radius_f64), true
}

Backdrop_Effect_Gaussian_Tap_Count :: proc(sigma_pixels: f32) -> (count: int, ok: bool) {
	radius, valid := Backdrop_Effect_Gaussian_Radius(sigma_pixels)
	if !valid { return 0, false }
	// Pair adjacent positive and negative texel weights into one bilinear
	// sample per side, retaining the center sample and any unpaired edge tap.
	return 1+2*((radius+1)/2), true
}

Backdrop_Effect_Gaussian_Weights :: proc(
	sigma_pixels: f32,
) -> (weights: [BACKDROP_EFFECT_MAX_GAUSSIAN_KERNEL_WIDTH]f32, radius: int, ok: bool) {
	computed_radius, valid := Backdrop_Effect_Gaussian_Radius(sigma_pixels)
	if !valid { return weights, 0, false }

	radius = computed_radius
	count := radius*2+1
	center := BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS
	unnormalized: [BACKDROP_EFFECT_MAX_GAUSSIAN_KERNEL_WIDTH]f64
	total := f64(0)
	denominator := 2*f64(sigma_pixels)*f64(sigma_pixels)
	for index in 0..<count {
		offset := index-radius
		x := f64(offset)
		weight := math.exp(-(x*x)/denominator)
		unnormalized[center+offset] = weight
		total += weight
	}
	for index in 0..<count {
		offset := index-radius
		weights[center+offset] = f32(unnormalized[center+offset]/total)
	}
	return weights, radius, true
}

Backdrop_Effect_Gaussian_Taps :: proc(
	sigma_pixels: f32,
) -> (taps: [BACKDROP_EFFECT_MAX_FILTER_TAPS]Backdrop_Effect_Tap, count: int, ok: bool) {
	weights, radius, valid := Backdrop_Effect_Gaussian_Weights(sigma_pixels)
	if !valid { return taps, 0, false }
	center := BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS
	taps[0] = Backdrop_Effect_Tap{0, weights[center]}
	count = 1
	for distance := 1; distance <= radius; distance += 2 {
		near_weight := f64(weights[center+distance])
		far_weight := f64(0)
		if distance < radius { far_weight = f64(weights[center+distance+1]) }
		combined := near_weight+far_weight
		offset := f64(distance)
		if combined > 0 { offset = (f64(distance)*near_weight+f64(distance+1)*far_weight)/combined }
		weight := f32(combined)
		taps[count] = Backdrop_Effect_Tap{-f32(offset), weight}
		taps[count+1] = Backdrop_Effect_Tap{f32(offset), weight}
		count += 2
	}
	return taps, count, true
}

Backdrop_Effect_Plan_Make :: proc(request: Backdrop_Effect_Request) -> (plan: Backdrop_Effect_Plan, ok: bool) {
	// A zero-initialized disabled request needs no key, source generation,
	// scale, or depth. Enabled requests are validated before integer casts.
	if !request.enabled { return plan, true }
	if !alicorn.number_is_finite(request.scale) || request.scale <= 0 || request.scale > BACKDROP_EFFECT_MAX_SCALE ||
	   !alicorn.number_is_finite(request.sigma) || request.sigma < 0 || request.sigma > 8 ||
	   !backdrop_effect_rect_bounded(request.region) || !backdrop_effect_rect_bounded(request.clip) ||
	   request.depth != 1 || request.key == 0 || request.source_generation == 0 {
		return plan, false
	}
	output_clip := alicorn.rect_intersection(request.region, request.clip)
	if request.sigma == 0 || request.region.w <= 0 || request.region.h <= 0 ||
	   request.clip.w <= 0 || request.clip.h <= 0 || output_clip.w <= 0 || output_clip.h <= 0 {
		return plan, true
	}
	sigma_pixels := request.sigma*request.scale
	radius, radius_ok := Backdrop_Effect_Gaussian_Radius(sigma_pixels)
	tap_count, tap_count_ok := Backdrop_Effect_Gaussian_Tap_Count(sigma_pixels)
	if !radius_ok || !tap_count_ok { return Backdrop_Effect_Plan{}, false }
	// Capture the complete finite 3-sigma Gaussian support and round outward in
	// physical pixels before converting back to logical layout coordinates.
	scale, halo := f64(request.scale), f64(radius)/f64(request.scale)
	left := math.floor((f64(request.region.x)-halo)*scale)
	top := math.floor((f64(request.region.y)-halo)*scale)
	right := math.ceil((f64(request.region.x)+f64(request.region.w)+halo)*scale)
	bottom := math.ceil((f64(request.region.y)+f64(request.region.h)+halo)*scale)
	w, h := right-left, bottom-top
	if abs(left) > BACKDROP_EFFECT_MAX_COORD || abs(top) > BACKDROP_EFFECT_MAX_COORD ||
	   abs(right) > BACKDROP_EFFECT_MAX_COORD || abs(bottom) > BACKDROP_EFFECT_MAX_COORD ||
	   w < 1 || h < 1 || w > BACKDROP_EFFECT_MAX_DIMENSION || h > BACKDROP_EFFECT_MAX_DIMENSION {
		return Backdrop_Effect_Plan{}, false
	}
	source := alicorn.Rect{f32(left/scale), f32(top/scale), f32(w/scale), f32(h/scale)}
	if !backdrop_effect_rect_bounded(source) { return Backdrop_Effect_Plan{}, false }
	plan = Backdrop_Effect_Plan{
		active=true,
		source_bounds=source,
		output_clip=output_clip,
		width=u32(w),
		height=u32(h),
		scale=request.scale,
		sigma_pixels=sigma_pixels,
		filter_tap_count=tap_count,
		key=request.key,
		source_generation=request.source_generation,
	}
	if !Backdrop_Effect_Plan_Valid(plan) { return Backdrop_Effect_Plan{}, false }
	return plan, true
}

Backdrop_Effect_Plan_Valid :: proc(plan: Backdrop_Effect_Plan) -> bool {
	if !plan.active { return true }
	if plan.key == 0 || plan.source_generation == 0 ||
	   plan.width == 0 || plan.height == 0 || plan.width > BACKDROP_EFFECT_MAX_DIMENSION ||
	   plan.height > BACKDROP_EFFECT_MAX_DIMENSION ||
	   !alicorn.number_is_finite(plan.scale) || plan.scale <= 0 || plan.scale > BACKDROP_EFFECT_MAX_SCALE ||
	   !alicorn.number_is_finite(plan.sigma_pixels) || plan.sigma_pixels <= 0 ||
	   plan.sigma_pixels > BACKDROP_EFFECT_MAX_SIGMA_PIXELS ||
	   !backdrop_effect_rect_bounded(plan.source_bounds) || !backdrop_effect_rect_bounded(plan.output_clip) ||
	   plan.source_bounds.w <= 0 || plan.source_bounds.h <= 0 ||
	   plan.output_clip.w <= 0 || plan.output_clip.h <= 0 {
		return false
	}
	expected_taps, taps_ok := Backdrop_Effect_Gaussian_Tap_Count(plan.sigma_pixels)
	if !taps_ok || plan.filter_tap_count != expected_taps { return false }
	left, top := f64(plan.source_bounds.x)*f64(plan.scale), f64(plan.source_bounds.y)*f64(plan.scale)
	w, h := f64(plan.source_bounds.w)*f64(plan.scale), f64(plan.source_bounds.h)*f64(plan.scale)
	if abs(left) > BACKDROP_EFFECT_MAX_COORD || abs(top) > BACKDROP_EFFECT_MAX_COORD ||
	   abs(left+w) > BACKDROP_EFFECT_MAX_COORD || abs(top+h) > BACKDROP_EFFECT_MAX_COORD ||
	   abs(left-math.round(left)) > 0.125 || abs(top-math.round(top)) > 0.125 ||
	   abs(w-f64(plan.width)) > 0.001 || abs(h-f64(plan.height)) > 0.001 {
		return false
	}
	// Allow only the f32 round-trip tolerance at the logical source boundary.
	epsilon := f32(0.25)/plan.scale
	return plan.output_clip.x >= plan.source_bounds.x-epsilon && plan.output_clip.y >= plan.source_bounds.y-epsilon &&
	       f64(plan.output_clip.x)+f64(plan.output_clip.w) <= f64(plan.source_bounds.x)+f64(plan.source_bounds.w)+f64(epsilon) &&
	       f64(plan.output_clip.y)+f64(plan.output_clip.h) <= f64(plan.source_bounds.y)+f64(plan.source_bounds.h)+f64(epsilon)
}

backdrop_effect_rect_bounded :: proc(rect: alicorn.Rect) -> bool {
	for value in ([4]f32{rect.x, rect.y, rect.w, rect.h}) {
		if !alicorn.number_is_finite(value) || abs(value) > BACKDROP_EFFECT_MAX_COORD { return false }
	}
	return abs(f64(rect.x)+f64(rect.w)) <= BACKDROP_EFFECT_MAX_COORD &&
	       abs(f64(rect.y)+f64(rect.h)) <= BACKDROP_EFFECT_MAX_COORD
}
