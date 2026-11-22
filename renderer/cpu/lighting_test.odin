#+build !js
package cpu_renderer

import "core:testing"
import alicorn "../../runtime"

lighting_test_request :: proc() -> Lighting_Request {
	request := Lighting_Request{
		enabled=true,
		key=9,
		source_generation=17,
		region=alidon_lighting_test_rect(10, 20, 300, 160),
		clip=alidon_lighting_test_rect(0, 0, 384, 256),
		scale=1,
		surface_count=2,
	}
	request.params = alicorn.Lighting_Params{
		group=alicorn.Material_Group_ID(7),
		generation=5,
		light_count=1,
		ambient=0.4,
		flags={.Shadows},
	}
	request.params.lights[0] = alicorn.Lighting_Light{
		position={120, 90}, height=2, color={1, 1, 1, 1}, intensity=1, radius=6,
	}
	request.surfaces[0] = Lighting_Surface{
		bounds=alidon_lighting_test_rect(40, 50, 120, 80), corner_radius=12, physical_height=1,
	}
	request.surfaces[1] = Lighting_Surface{
		bounds=alidon_lighting_test_rect(180, 70, 100, 60), corner_radius=8, physical_height=-0.5,
	}
	return request
}

alidon_lighting_test_rect :: proc(x, y, w, h: f32) -> alicorn.Rect {
	return alicorn.Rect{x, y, w, h}
}

@(test)
test_lighting_plan_requires_geometry_lights_and_bounded_region :: proc(t: ^testing.T) {
	request := lighting_test_request()
	plan, ok := Lighting_Plan_Make(request)
	testing.expect(t, ok && plan.active && plan.source_bounds == request.region &&
		plan.output_clip == request.region && plan.width == 300 && plan.height == 160,
		"a bounded lighting request should capture its region at the requested scale")

	// Disabled requests cost nothing and carry no plan.
	disabled := request
	disabled.enabled = false
	plan, ok = Lighting_Plan_Make(disabled)
	testing.expect(t, ok && !plan.active, "a disabled request must produce an inactive plan")

	// Zero-height or out-of-group surfaces cannot form a plan.
	empty := request
	empty.surface_count = 0
	_, ok = Lighting_Plan_Make(empty)
	testing.expect(t, !ok, "a lighting plan without a surface must be rejected")
	flat := request
	flat.surfaces[0].physical_height = 0
	_, ok = Lighting_Plan_Make(flat)
	testing.expect(t, !ok, "a flat surface must not enter the shading plan")
	no_light := request
	no_light.params.light_count = 0
	_, ok = Lighting_Plan_Make(no_light)
	testing.expect(t, !ok, "a lighting plan needs at least one light")

	// A forged plan cannot bypass validation.
	generated, generated_ok := Lighting_Plan_Make(request)
	testing.expect(t, generated_ok && Lighting_Plan_Valid(generated), "generated plans must validate")
	forged := generated
	forged.width += 1
	testing.expect(t, !Lighting_Plan_Valid(forged), "hand-edited capture extents must be rejected")
	forged = generated
	forged.surfaces[0].physical_height = 0
	testing.expect(t, !Lighting_Plan_Valid(forged), "hand-edited flat surfaces must be rejected")
	forged = generated
	forged.output_clip = alidon_lighting_test_rect(0, 0, 1, 1)
	testing.expect(t, !Lighting_Plan_Valid(forged), "composition must stay inside the captured extent")

	// Pixel-grid capture: fractional regions round outward.
	fractional := request
	fractional.region = alidon_lighting_test_rect(10.25, 20.5, 100.5, 80.25)
	plan, ok = Lighting_Plan_Make(fractional)
	testing.expect(t, ok && plan.source_bounds.x <= 10.25 && plan.source_bounds.y <= 20.5 &&
		plan.source_bounds.x+plan.source_bounds.w >= 110.75 &&
		plan.source_bounds.y+plan.source_bounds.h >= 100.75,
		"a fractional region must round outward to whole physical pixels")
}

@(test)
test_lighting_uniforms_and_mesh_are_deterministic :: proc(t: ^testing.T) {
	request := lighting_test_request()
	plan, ok := Lighting_Plan_Make(request)
	testing.expect(t, ok, "lighting plan fixture should validate")

	first, first_ok := Lighting_Uniforms_Pack(plan, 384, 256)
	second, second_ok := Lighting_Uniforms_Pack(plan, 384, 256)
	testing.expect(t, first_ok && second_ok && first == second,
		"identical plans must pack identical shader uniforms")
	testing.expect(t, first.region.x == plan.source_bounds.x && first.region.y == plan.source_bounds.y &&
		first.region.z == f32(plan.surface_count) && first.params.x == 1 && first.params.y == 0.4,
		"the uniform header should carry the capture origin, surface count, light count, and ambient")
	testing.expect(t, int(first.region.z) == request.surface_count,
		"the shader's surface-count field must never alias a target dimension")
	testing.expect(t, first.surfaces[0].x > 0 && first.surfaces[0].z > 0 &&
		first.surface_params[0].y == 1*LIGHTING_HEIGHT_PIXELS &&
		first.surface_params[1].y == -0.5*LIGHTING_HEIGHT_PIXELS &&
		first.surface_params[1].w == -1,
		"surface rows should carry region-local pixel centers, signed heights, and raised/recessed signs")
	testing.expect(t, first.lights[0].w == 1 && first.light_colors[0].w == 6,
		"light rows should carry intensity and the physical source radius")

	moved := request
	moved.params.lights[0].position[0] += 4
	moved_plan, moved_ok := Lighting_Plan_Make(moved)
	testing.expect(t, moved_ok, "a moved light should still plan")
	moved_uniforms, moved_uniforms_ok := Lighting_Uniforms_Pack(moved_plan, 384, 256)
	testing.expect(t, moved_uniforms_ok && moved_uniforms.lights[0].x == first.lights[0].x+4 &&
		moved_uniforms.surfaces == first.surfaces,
		"moving a light must change only its uniform row")

	mesh: [LIGHTING_MESH_VERTICES]Vertex
	testing.expect(t, Lighting_Build_Mesh(plan, &mesh) && mesh[0].position == [3]f32{10, 20, 0} &&
		mesh[2].position == [3]f32{310, 180, 0} && mesh[0].uv == [2]f32{0, 0} && mesh[2].uv == [2]f32{1, 1},
		"the composite mesh should cover exactly the snapped capture region with unit UVs")
}
