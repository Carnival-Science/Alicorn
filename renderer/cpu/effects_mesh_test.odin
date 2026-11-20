#+build !js
package cpu_renderer

import "core:math"
import "core:testing"

cpu_effect_mesh_test_request :: proc() -> Backdrop_Effect_Request {
	return {
		enabled=true,
		key=31,
		source_generation=9,
		region={10.25, 20.25, 100, 50},
		clip={0, 0, 200, 200},
		scale=1.5,
		sigma=2,
		depth=1,
	}
}

@(test)
test_backdrop_effect_mesh_preserves_filter_uvs_weights_and_snapped_composite :: proc(t: ^testing.T) {
	plan, plan_ok := Backdrop_Effect_Plan_Make(cpu_effect_mesh_test_request())
	vertices: [BACKDROP_EFFECT_MAX_MESH_VERTICES]Vertex
	vertex_count, composite_first, mesh_ok := Backdrop_Effect_Build_Mesh(plan, &vertices)
	testing.expect(t, plan_ok && mesh_ok && plan.filter_tap_count == 11 &&
		vertex_count == 11*12+6 && composite_first == 11*12,
		"the mesh should contain ordered horizontal taps, vertical taps, and one composite quad")
	if !mesh_ok { return }

	taps, tap_count, taps_ok := Backdrop_Effect_Gaussian_Taps(plan.sigma_pixels)
	testing.expect(t, taps_ok && tap_count == plan.filter_tap_count,
		"the mesh samples should use the exact plan's paired Gaussian taps")
	if !taps_ok { return }
	w, h := f32(plan.width), f32(plan.height)
	du, dv := taps[0].offset_pixels/w, taps[0].offset_pixels/h
	testing.expect(t, vertices[0].position == [3]f32{0, 0, 0} &&
		vertices[2].position == [3]f32{w, h, 0} &&
		vertices[0].uv == [2]f32{du, 0} && vertices[2].uv == [2]f32{1+du, 1} &&
		vertices[0].color == [4]f32{taps[0].weight, taps[0].weight, taps[0].weight, taps[0].weight},
		"horizontal filtering should preserve the paired tap UV halo and weight in all channels")
	vertical_first := tap_count*6
	testing.expect(t, vertices[vertical_first].uv == [2]f32{0, dv} &&
		vertices[vertical_first+2].uv == [2]f32{1, 1+dv},
		"vertical filtering should offset only the V sampling coordinates")

	composite := vertices[composite_first]
	composite_last := vertices[vertex_count-1]
	x := f32(math.round(f64(plan.source_bounds.x)*f64(plan.scale)))
	y := f32(math.round(f64(plan.source_bounds.y)*f64(plan.scale)))
	testing.expect(t, composite.position == [3]f32{x, y, 0} &&
		vertices[composite_first+2].position == [3]f32{x+w, y+h, 0} &&
		composite.uv == [2]f32{0, 0} && composite_last.uv == [2]f32{0, 1} &&
		composite.color == [4]f32{1, 1, 1, 1},
		"the final quad should composite at the snapped physical source origin with full weight")
}

@(test)
test_backdrop_effect_mesh_uses_full_bounded_vertex_capacity :: proc(t: ^testing.T) {
	request := cpu_effect_mesh_test_request()
	request.region = {100, 100, 1, 1}
	request.clip = {0, 0, 1000, 1000}
	request.scale = 4
	request.sigma = 8
	plan, plan_ok := Backdrop_Effect_Plan_Make(request)
	vertices: [BACKDROP_EFFECT_MAX_MESH_VERTICES]Vertex
	vertex_count, composite_first, mesh_ok := Backdrop_Effect_Build_Mesh(plan, &vertices)
	testing.expect(t, plan_ok && mesh_ok && plan.filter_tap_count == BACKDROP_EFFECT_MAX_FILTER_TAPS &&
		vertex_count == BACKDROP_EFFECT_MAX_MESH_VERTICES && composite_first == vertex_count-6,
		"the maximum supported blur kernel should fit the fixed, bounded CPU mesh")
}

@(test)
test_backdrop_effect_mesh_rejects_invalid_plan_before_writing :: proc(t: ^testing.T) {
	plan, plan_ok := Backdrop_Effect_Plan_Make(cpu_effect_mesh_test_request())
	vertices: [BACKDROP_EFFECT_MAX_MESH_VERTICES]Vertex
	vertices[0] = Vertex{{7, 8, 9}, {0.1, 0.2, 0.3, 0.4}, {0.5, 0.6}}
	plan.filter_tap_count += 1
	vertex_count, composite_first, mesh_ok := Backdrop_Effect_Build_Mesh(plan, &vertices)
	testing.expect(t, plan_ok && !mesh_ok && vertex_count == 0 && composite_first == 0 &&
		vertices[0] == Vertex{{7, 8, 9}, {0.1, 0.2, 0.3, 0.4}, {0.5, 0.6}},
		"an invalid mesh plan should fail without partially overwriting the retained vertex product")
}
