#+build !js
package cpu_renderer

import "core:math"
import "core:testing"
import alicorn "../../runtime"

cpu_effect_test_request :: proc() -> Backdrop_Effect_Request {
	return {
		enabled=true,
		key=17,
		source_generation=4,
		region={10.25, 20.25, 100, 50},
		clip={0, 0, 200, 200},
		scale=1.5,
		sigma=2,
		depth=1,
	}
}

@(test)
test_backdrop_effect_plan_keeps_physical_halo_and_output_clip :: proc(t: ^testing.T) {
	request := cpu_effect_test_request()
	plan, ok := Backdrop_Effect_Plan_Make(request)
	testing.expect(t, ok && plan.active, "bounded opted-in regions should produce an active effect plan")
	if !ok { return }
	testing.expect(t, plan.source_bounds.x <= 4.25 && plan.source_bounds.y <= 14.25 &&
		plan.source_bounds.x+plan.source_bounds.w >= 116.25 && plan.source_bounds.y+plan.source_bounds.h >= 76.25,
		"the complete three-sigma support halo must survive outward rounding at fractional DPI")
	testing.expect(t, abs(plan.source_bounds.x*plan.scale-math.round(plan.source_bounds.x*plan.scale)) < 0.001 &&
		abs(plan.source_bounds.y*plan.scale-math.round(plan.source_bounds.y*plan.scale)) < 0.001,
		"the captured source origin must be snapped to physical pixels")
	testing.expect(t, plan.output_clip == request.region,
		"the filter halo must not enlarge the composed region or override ancestor clipping")
	request.clip = {20, 30, 20, 10}
	clipped, clipped_ok := Backdrop_Effect_Plan_Make(request)
	testing.expect(t, clipped_ok && clipped.output_clip == request.clip,
		"the resolved ancestor clip must remain authoritative for output composition")
}

@(test)
test_backdrop_effect_gaussian_pairing_reconstructs_dense_kernel :: proc(t: ^testing.T) {
	sigma := f32(12)
	dense, radius, dense_ok := Backdrop_Effect_Gaussian_Weights(sigma)
	taps, tap_count, taps_ok := Backdrop_Effect_Gaussian_Taps(sigma)
	testing.expect(t, dense_ok && taps_ok && radius == 36 && tap_count == 37,
		"sigma 12 should use a normalized three-sigma kernel and 37 bilinear-paired samples")
	if !dense_ok || !taps_ok { return }
	center := BACKDROP_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS
	dense_sum, variance := f64(0), f64(0)
	for offset in -radius..<(radius+1) {
		weight := f64(dense[center+offset])
		dense_sum += weight
		variance += f64(offset*offset)*weight
		if offset > 0 {
			testing.expect(t, abs(dense[center+offset]-dense[center-offset]) < 0.000001,
				"the dense kernel must be symmetric")
			testing.expect(t, dense[center+offset] <= dense[center+offset-1],
				"the truncated Gaussian must decay away from the center")
		}
	}
	sigma_squared := f64(sigma)*f64(sigma)
	testing.expect(t, abs(dense_sum-1) < 0.00001 && variance > sigma_squared*0.9 && variance < sigma_squared*1.01,
		"the normalized kernel must preserve the requested blur scale")
	reconstructed: [BACKDROP_EFFECT_MAX_GAUSSIAN_KERNEL_WIDTH]f32
	for tap in taps[:tap_count] {
		low := int(math.floor(f64(tap.offset_pixels)))
		fraction := f32(f64(tap.offset_pixels)-f64(low))
		reconstructed[center+low] += tap.weight*(1-fraction)
		reconstructed[center+low+1] += tap.weight*fraction
	}
	for offset in -radius..<(radius+1) {
		testing.expect(t, abs(reconstructed[center+offset]-dense[center+offset]) < 0.00001,
			"bilinear tap pairing must reconstruct each dense Gaussian coefficient")
	}
}

@(test)
test_backdrop_effect_tiny_sigma_has_finite_identity_taps :: proc(t: ^testing.T) {
	taps, count, ok := Backdrop_Effect_Gaussian_Taps(1e-20)
	testing.expect(t, ok && count == 3, "positive tiny sigma should still return a bounded kernel")
	if !ok { return }
	for tap in taps[:count] {
		testing.expect(t, alicorn.number_is_finite(tap.offset_pixels) && alicorn.number_is_finite(tap.weight) && tap.weight >= 0,
			"underflowed tail taps must remain finite and nonnegative")
	}
	testing.expect(t, taps[0].offset_pixels == 0 && taps[0].weight == 1 && taps[1].weight == 0 && taps[2].weight == 0,
		"an underflowed sampled Gaussian should reduce to a safe identity kernel")
}

@(test)
test_backdrop_effect_plan_rejects_limits_and_accepts_inactive_requests :: proc(t: ^testing.T) {
	for index in 0..<9 {
		request := cpu_effect_test_request()
		switch index {
		case 0: request.scale = transmute(f32)u32(0x7FC00000)
		case 1: request.region.x = transmute(f32)u32(0x7F800000)
		case 2: request.depth = 2
		case 3: request.source_generation = 0
		case 4: request.key = 0
		case 5: request.region.w = 1_000_000
		case 6: request.sigma = 9
		case 7: request.scale = 0
		case 8: request.sigma = 8; request.scale = 64
		}
		_, ok := Backdrop_Effect_Plan_Make(request)
		testing.expect(t, !ok, "invalid effect plans must fail before unsafe casts or GPU allocation")
	}
	request := cpu_effect_test_request()
	request.enabled = false
	plan, ok := Backdrop_Effect_Plan_Make(request)
	testing.expect(t, ok && !plan.active, "disabled effects require no valid key, generation, scale, or depth")
	request = cpu_effect_test_request()
	request.clip = {500, 500, 10, 10}
	plan, ok = Backdrop_Effect_Plan_Make(request)
	testing.expect(t, ok && !plan.active, "fully clipped effects should take the direct path")
	request = cpu_effect_test_request()
	request.sigma = 0
	plan, ok = Backdrop_Effect_Plan_Make(request)
	testing.expect(t, ok && !plan.active, "zero blur should take the direct path")
}

@(test)
test_backdrop_effect_plan_valid_rejects_forged_geometry :: proc(t: ^testing.T) {
	plan, ok := Backdrop_Effect_Plan_Make(cpu_effect_test_request())
	testing.expect(t, ok && Backdrop_Effect_Plan_Valid(plan), "generated plans must pass backend allocation validation")
	if !ok { return }
	forged := plan
	forged.width = 0xFFFFFFFF
	testing.expect(t, !Backdrop_Effect_Plan_Valid(forged), "hand-authored plans cannot bypass dimension limits")
	forged = plan
	forged.filter_tap_count -= 1
	testing.expect(t, !Backdrop_Effect_Plan_Valid(forged), "plans must match the kernel tap count")
	forged = plan
	forged.output_clip = {-1000, -1000, 4000, 4000}
	testing.expect(t, !Backdrop_Effect_Plan_Valid(forged), "composition cannot sample outside its captured input extent")
}
