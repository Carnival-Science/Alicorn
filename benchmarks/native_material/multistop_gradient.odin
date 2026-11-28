package main

import "core:fmt"
import "core:time"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"

MULTISTOP_GRADIENT_MAX_STOPS :: 8
MULTISTOP_GRADIENT_SURFACES :: 256
MULTISTOP_GRADIENT_SAMPLES :: 101

Multi_Stop_Gradient_Stop :: struct {
	position: f32,
	color: alicorn.Color,
}

Multi_Stop_Gradient_Prototype :: struct {
	axis: alicorn.Surface_Gradient_Axis,
	count: u8,
	stops: [MULTISTOP_GRADIENT_MAX_STOPS]Multi_Stop_Gradient_Stop,
}

multistop_gradient_color_near :: proc(a, b: [4]f32, tolerance: f32 = 0.0001) -> bool {
	for index in 0..<4 {
		if abs(a[index]-b[index]) > tolerance { return false }
	}
	return true
}

multistop_gradient_valid :: proc(gradient: Multi_Stop_Gradient_Prototype) -> bool {
	if gradient.count < 2 || gradient.count > MULTISTOP_GRADIENT_MAX_STOPS ||
	   (gradient.axis != .Horizontal && gradient.axis != .Vertical) {
		return false
	}
	if gradient.stops[0].position != 0 || gradient.stops[int(gradient.count)-1].position != 1 { return false }
	alpha := gradient.stops[0].color.a
	for index in 0..<int(gradient.count) {
		stop := gradient.stops[index]
		if !alicorn.number_is_finite(stop.position) || stop.position < 0 || stop.position > 1 ||
		   !alicorn.semantic_surface_color_is_valid(stop.color) || stop.color.a != alpha {
			return false
		}
		if index > 0 && stop.position <= gradient.stops[index-1].position { return false }
	}
	return true
}

multistop_gradient_fixture :: proc(count: int, axis: alicorn.Surface_Gradient_Axis) -> Multi_Stop_Gradient_Prototype {
	palette := [MULTISTOP_GRADIENT_MAX_STOPS]alicorn.Color{
		{0.88, 0.31, 0.22, 1}, {0.95, 0.60, 0.25, 1}, {0.96, 0.83, 0.37, 1},
		{0.38, 0.72, 0.42, 1}, {0.17, 0.65, 0.58, 1}, {0.20, 0.51, 0.78, 1},
		{0.45, 0.39, 0.78, 1}, {0.82, 0.36, 0.61, 1},
	}
	gradient := Multi_Stop_Gradient_Prototype{axis=axis, count=u8(count)}
	for index in 0..<count {
		gradient.stops[index] = Multi_Stop_Gradient_Stop{
			position=f32(index)/f32(count-1), color=palette[index],
		}
	}
	return gradient
}

multistop_gradient_sample :: proc(gradient: Multi_Stop_Gradient_Prototype, position: f32) -> [4]f32 {
	if gradient.count < 2 { return {} }
	t := clamp(position, 0, 1)
	for index in 0..<int(gradient.count)-1 {
		left := gradient.stops[index]
		right := gradient.stops[index+1]
		if t <= right.position || index == int(gradient.count)-2 {
			local_t := (t-left.position)/(right.position-left.position)
			return [4]f32{
				left.color.r+(right.color.r-left.color.r)*local_t,
				left.color.g+(right.color.g-left.color.g)*local_t,
				left.color.b+(right.color.b-left.color.b)*local_t,
				left.color.a+(right.color.a-left.color.a)*local_t,
			}
		}
	}
	return {}
}

// CPU tessellation keeps the existing two-stop path intact. Additional stops
// split a rectangular surface into adjacent two-stop quads so each stop is an
// exact boundary in the vertex-color mesh.
multistop_gradient_append_cpu :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	bounds: alicorn.Rect,
	gradient: Multi_Stop_Gradient_Prototype,
) -> bool {
	if vertices == nil || !multistop_gradient_valid(gradient) || bounds.w <= 0 || bounds.h <= 0 { return false }
	if gradient.count == 2 {
		start, end := gradient.stops[0].color, gradient.stops[1].color
		cpu_renderer.Append_Gradient_Quad(vertices, bounds, start,
			alicorn.Surface_Gradient{axis=gradient.axis, end=end}, 1)
		return true
	}
	for index in 0..<int(gradient.count)-1 {
		left, right := gradient.stops[index], gradient.stops[index+1]
		band := bounds
		if gradient.axis == .Horizontal {
			band.x = bounds.x+bounds.w*left.position
			band.w = bounds.w*(right.position-left.position)
		} else {
			band.y = bounds.y+bounds.h*left.position
			band.h = bounds.h*(right.position-left.position)
		}
		cpu_renderer.Append_Gradient_Quad(vertices, band, left.color,
			alicorn.Surface_Gradient{axis=gradient.axis, end=right.color}, 1)
	}
	return true
}

multistop_gradient_append_shader_model :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	bounds: alicorn.Rect,
	gradient: Multi_Stop_Gradient_Prototype,
) -> bool {
	if vertices == nil || !multistop_gradient_valid(gradient) || bounds.w <= 0 || bounds.h <= 0 { return false }
	// A shader-evaluated implementation can keep the same rectangle topology.
	// This model records normalized axis coordinates in UV and leaves stop
	// interpolation to a fragment shader; it does not submit GPU work.
	x0, y0 := bounds.x, bounds.y
	x1, y1 := bounds.x+bounds.w, bounds.y+bounds.h
	t0, t1 := f32(0), f32(1)
	if gradient.axis == .Vertical { t0, t1 = 0, 1 }
	white := [4]f32{1, 1, 1, 1}
	append(vertices,
		cpu_renderer.Vertex{[3]f32{x0, y0, 0}, white, {t0, t0}},
		cpu_renderer.Vertex{[3]f32{x1, y0, 0}, white, {t1, t0}},
		cpu_renderer.Vertex{[3]f32{x1, y1, 0}, white, {t1, t1}},
		cpu_renderer.Vertex{[3]f32{x0, y0, 0}, white, {t0, t0}},
		cpu_renderer.Vertex{[3]f32{x1, y1, 0}, white, {t1, t1}},
		cpu_renderer.Vertex{[3]f32{x0, y1, 0}, white, {t0, t1}},
	)
	return true
}

multistop_gradient_build_cpu_batch :: proc(vertices: ^[dynamic]cpu_renderer.Vertex, gradient: Multi_Stop_Gradient_Prototype) -> bool {
	clear(vertices)
	for index in 0..<MULTISTOP_GRADIENT_SURFACES {
		bounds := alicorn.Rect{f32(index%16)*68, f32(index/16)*30, 64, 24}
		if !multistop_gradient_append_cpu(vertices, bounds, gradient) { return false }
	}
	return true
}

multistop_gradient_build_shader_model_batch :: proc(vertices: ^[dynamic]cpu_renderer.Vertex, gradient: Multi_Stop_Gradient_Prototype) -> bool {
	clear(vertices)
	for index in 0..<MULTISTOP_GRADIENT_SURFACES {
		bounds := alicorn.Rect{f32(index%16)*68, f32(index/16)*30, 64, 24}
		if !multistop_gradient_append_shader_model(vertices, bounds, gradient) { return false }
	}
	return true
}

multistop_gradient_benchmark :: proc(stop_count: int) {
	gradient := multistop_gradient_fixture(stop_count, .Horizontal)
	if !multistop_gradient_valid(gradient) {
		fmt.eprintln("multi-stop gradient fixture invalid", stop_count)
		panic("invalid multi-stop gradient fixture")
	}
	cpu_vertices := make([dynamic]cpu_renderer.Vertex, 0,
		MULTISTOP_GRADIENT_SURFACES*6*(stop_count-1), allocator=context.temp_allocator)
	defer delete(cpu_vertices)
	shader_vertices := make([dynamic]cpu_renderer.Vertex, 0,
		MULTISTOP_GRADIENT_SURFACES*6, allocator=context.temp_allocator)
	defer delete(shader_vertices)
	for _ in 0..<5 {
		if !multistop_gradient_build_cpu_batch(&cpu_vertices, gradient) ||
		   !multistop_gradient_build_shader_model_batch(&shader_vertices, gradient) {
			panic("multi-stop gradient batch build failed")
		}
	}
	// Confirm the CPU mesh preserves each stop at its actual band boundary.
	for index in 0..<stop_count {
		expected := gradient.stops[index].color
		position := gradient.stops[index].position
		actual := multistop_gradient_sample(gradient, position)
		if !multistop_gradient_color_near(actual, [4]f32{expected.r, expected.g, expected.b, expected.a}) {
			panic("multi-stop gradient stop interpolation mismatch")
		}
	}
	for band_index in 0..<stop_count-1 {
		start_color := gradient.stops[band_index].color
		end_color := gradient.stops[band_index+1].color
		end_vertex_index := band_index*6+1 if gradient.axis == .Horizontal else band_index*6+2
		if !multistop_gradient_color_near(cpu_vertices[band_index*6].color,
			[4]f32{start_color.r, start_color.g, start_color.b, start_color.a}) ||
		   !multistop_gradient_color_near(cpu_vertices[end_vertex_index].color,
			[4]f32{end_color.r, end_color.g, end_color.b, end_color.a}) {
			panic("CPU tessellation omitted an exact gradient stop boundary")
		}
	}

	cpu_samples: [MULTISTOP_GRADIENT_SAMPLES]i64
	shader_model_samples: [MULTISTOP_GRADIENT_SAMPLES]i64
	for sample in 0..<MULTISTOP_GRADIENT_SAMPLES {
		started := time.now()
		if !multistop_gradient_build_cpu_batch(&cpu_vertices, gradient) { panic("CPU gradient lowering failed") }
		cpu_samples[sample] = time.duration_nanoseconds(time.since(started))
		started = time.now()
		if !multistop_gradient_build_shader_model_batch(&shader_vertices, gradient) { panic("shader-model mesh build failed") }
		shader_model_samples[sample] = time.duration_nanoseconds(time.since(started))
	}
	for index in 1..<MULTISTOP_GRADIENT_SAMPLES {
		cpu_value := cpu_samples[index]
		cursor := index
		for cursor > 0 && cpu_samples[cursor-1] > cpu_value {
			cpu_samples[cursor] = cpu_samples[cursor-1]
			cursor -= 1
		}
		cpu_samples[cursor] = cpu_value
		shader_value := shader_model_samples[index]
		cursor = index
		for cursor > 0 && shader_model_samples[cursor-1] > shader_value {
			shader_model_samples[cursor] = shader_model_samples[cursor-1]
			cursor -= 1
		}
		shader_model_samples[cursor] = shader_value
	}
	shader_stop_record_bytes := stop_count*size_of(Multi_Stop_Gradient_Stop)
	fmt.println("multistop_gradient_prototype",
		"surfaces", MULTISTOP_GRADIENT_SURFACES,
		"stops", stop_count,
		"cpu_vertices", len(cpu_vertices),
		"cpu_vertex_bytes", len(cpu_vertices)*size_of(cpu_renderer.Vertex),
		"cpu_build_p50_ns", cpu_samples[MULTISTOP_GRADIENT_SAMPLES/2],
		"cpu_build_p95_ns", cpu_samples[(MULTISTOP_GRADIENT_SAMPLES*95+99)/100-1],
		"shader_model_vertices", len(shader_vertices),
		"shader_model_vertex_bytes", len(shader_vertices)*size_of(cpu_renderer.Vertex),
		"shader_stop_record_bytes_per_surface", shader_stop_record_bytes,
		"shader_model_build_p50_ns", shader_model_samples[MULTISTOP_GRADIENT_SAMPLES/2],
		"shader_model_build_p95_ns", shader_model_samples[(MULTISTOP_GRADIENT_SAMPLES*95+99)/100-1],
		"exact_stop_samples", true,
		"gpu_execution", "not_measured")
}

benchmark_multistop_gradients :: proc() {
	fmt.println("Alicorn multi-stop gradient research prototype; CPU band tessellation versus shader-evaluation mesh model; not production rendering")
	stop_counts := [4]int{2, 3, 4, 8}
	for stop_count in stop_counts { multistop_gradient_benchmark(stop_count) }
}
