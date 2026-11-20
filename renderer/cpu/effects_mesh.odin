package cpu_renderer

import "core:math"

// Backdrop effects use one six-vertex quad per bilinear-paired Gaussian tap in
// each filter direction, followed by one quad that composites the filtered
// texture over the original logical location.
BACKDROP_EFFECT_MAX_MESH_VERTICES :: BACKDROP_EFFECT_MAX_FILTER_TAPS*12 + 6

// Backdrop_Effect_Build_Mesh creates the backend-neutral vertex product used
// by both horizontal/vertical filtering and final composition. Texture binding,
// sampler state, render targets, upload, and residency remain backend-owned.
Backdrop_Effect_Build_Mesh :: proc(
	plan: Backdrop_Effect_Plan,
	vertices: ^[BACKDROP_EFFECT_MAX_MESH_VERTICES]Vertex,
) -> (vertex_count, composite_first_vertex: int, ok: bool) {
	if vertices == nil || !plan.active || !Backdrop_Effect_Plan_Valid(plan) { return }
	taps, tap_count, taps_ok := Backdrop_Effect_Gaussian_Taps(plan.sigma_pixels)
	if !taps_ok || tap_count != plan.filter_tap_count { return }

	w, h := f32(plan.width), f32(plan.height)
	for tap in 0..<tap_count {
		sample := taps[tap]
		du, dv := sample.offset_pixels/w, sample.offset_pixels/h
		backdrop_effect_mesh_quad(vertices, tap*6, 0, 0, w, h, du, 0, 1+du, 1, sample.weight)
		backdrop_effect_mesh_quad(vertices, tap_count*6+tap*6, 0, 0, w, h, 0, dv, 1, 1+dv, sample.weight)
	}

	// Snap the composite origin in physical pixels to avoid resampling the
	// captured texture at a fractional location. The filter quads remain in the
	// capture's pixel-local coordinate system.
	x := f32(math.round(f64(plan.source_bounds.x)*f64(plan.scale)))
	y := f32(math.round(f64(plan.source_bounds.y)*f64(plan.scale)))
	composite_first_vertex = tap_count*12
	backdrop_effect_mesh_quad(vertices, composite_first_vertex, x, y, x+w, y+h, 0, 0, 1, 1, 1)
	vertex_count = composite_first_vertex+6
	return vertex_count, composite_first_vertex, true
}

backdrop_effect_mesh_quad :: proc(
	vertices: ^[BACKDROP_EFFECT_MAX_MESH_VERTICES]Vertex,
	first: int,
	x0, y0, x1, y1,
	u0, v0, u1, v1,
	weight: f32,
) {
	color := [4]f32{weight, weight, weight, weight}
	a := Vertex{{x0, y0, 0}, color, {u0, v0}}
	b := Vertex{{x1, y0, 0}, color, {u1, v0}}
	c := Vertex{{x1, y1, 0}, color, {u1, v1}}
	d := Vertex{{x0, y1, 0}, color, {u0, v1}}
	vertices[first+0], vertices[first+1], vertices[first+2] = a, b, c
	vertices[first+3], vertices[first+4], vertices[first+5] = a, c, d
}
