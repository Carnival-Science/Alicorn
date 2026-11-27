package main

import "core:fmt"
import "core:time"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"

SURFACE_COUNT :: 4096
ITERATIONS    :: 80
SAMPLES       :: 3
SHAPE_SURFACE_COUNT :: 256
SHAPE_SAMPLES       :: 101

BENCHMARK_GRADIENT :: alicorn.Surface_Gradient{
	axis=.Horizontal,
	end=alicorn.Color{0.72, 0.56, 0.28, 1},
}

run_batch :: proc(vertices: ^[dynamic]cpu_renderer.Vertex, material_path: bool) -> (elapsed_ns: i64, checksum: f64) {
	start := time.now()
	for _ in 0..<ITERATIONS {
		clear(vertices)
		for i in 0..<SURFACE_COUNT {
			x := f32(i % 128)
			if material_path {
				cpu_renderer.Append_Material_Surface(
					vertices,
					alicorn.Rect{x, 10, 48, 24},
					alicorn.Rect{x, 10, 48, 24},
					alicorn.Color{0.3, 0.4, 0.5, 1},
					alicorn.STYLE_MATERIAL_FLAT,
					0,
					1,
				)
			} else {
				cpu_renderer.Append_Quad(vertices, x, 10, x+48, 34, [4]f32{0.3, 0.4, 0.5, 1})
			}
		}
	}
	elapsed_ns = time.duration_nanoseconds(time.since(start))
	for vertex in vertices^ {
		checksum += f64(vertex.position[0]) + f64(vertex.position[1]) + f64(vertex.position[2])
		checksum += f64(vertex.color[0]) + f64(vertex.color[1]) + f64(vertex.color[2]) + f64(vertex.color[3])
	}
	return
}

build_shape_geometry :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	shape: alicorn.Surface_Shape,
	gradient: bool,
) {
	clear(vertices)
	for i in 0..<SHAPE_SURFACE_COUNT {
		bounds := alicorn.Rect{f32(i%16)*52, f32(i/16)*30, 48, 24}
		fill := alicorn.Color{0.3, 0.4, 0.5, 1}
		resolved_gradient := alicorn.SURFACE_GRADIENT_NONE
		if gradient { resolved_gradient = BENCHMARK_GRADIENT }
		if cpu_renderer.Shape_Is_Rounded(shape) {
			cpu_renderer.Append_Rounded_Material_Surface(
				vertices, bounds, bounds, fill,
				alicorn.STYLE_MATERIAL_FLAT, 0, 1, shape, gradient=resolved_gradient,
			)
		} else if gradient {
			cpu_renderer.Append_Gradient_Quad(vertices, bounds, fill, resolved_gradient, 1)
		} else {
			cpu_renderer.Append_Quad(vertices, bounds.x, bounds.y, bounds.x+bounds.w, bounds.y+bounds.h,
				[4]f32{fill.r, fill.g, fill.b, fill.a})
		}
	}
}

sort_durations :: proc(samples: []i64) {
	for i in 1..<len(samples) {
		value := samples[i]
		j := i
		for j > 0 && samples[j-1] > value {
			samples[j] = samples[j-1]
			j -= 1
		}
		samples[j] = value
	}
}

benchmark_shape_geometry_print :: proc(name, fill_kind: string, samples: []i64, vertices_per_surface: int) {
	p50_index := SHAPE_SAMPLES/2
	p95_index := (SHAPE_SAMPLES*95+99)/100-1
	fmt.println("native_shape_geometry", name, "fill", fill_kind,
		"surfaces", SHAPE_SURFACE_COUNT,
		"vertices_per_surface", vertices_per_surface,
		"uploaded_bytes", SHAPE_SURFACE_COUNT*vertices_per_surface*size_of(cpu_renderer.Vertex),
		"surface_commands", SHAPE_SURFACE_COUNT, "draw_slots", SHAPE_SURFACE_COUNT, "additional_passes", 0,
		"p50_batch_ns", samples[p50_index],
		"p95_batch_ns", samples[p95_index],
		"p50_ns_per_surface", f64(samples[p50_index])/f64(SHAPE_SURFACE_COUNT),
		"p95_ns_per_surface", f64(samples[p95_index])/f64(SHAPE_SURFACE_COUNT),
	)
}

benchmark_shape_geometry :: proc(name: string, shape: alicorn.Surface_Shape) {
	vertices := make([dynamic]cpu_renderer.Vertex, 0,
		SHAPE_SURFACE_COUNT*cpu_renderer.ROUNDED_FILL_VERTICES, allocator=context.temp_allocator)
	defer delete(vertices)
	solid_samples: [SHAPE_SAMPLES]i64
	gradient_samples: [SHAPE_SAMPLES]i64
	for _ in 0..<3 {
		build_shape_geometry(&vertices, shape, false)
		build_shape_geometry(&vertices, shape, true)
	}
	for sample in 0..<SHAPE_SAMPLES {
		if sample%2 == 0 {
			started := time.now()
			build_shape_geometry(&vertices, shape, false)
			solid_samples[sample] = time.duration_nanoseconds(time.since(started))
			started = time.now()
			build_shape_geometry(&vertices, shape, true)
			gradient_samples[sample] = time.duration_nanoseconds(time.since(started))
		} else {
			started := time.now()
			build_shape_geometry(&vertices, shape, true)
			gradient_samples[sample] = time.duration_nanoseconds(time.since(started))
			started = time.now()
			build_shape_geometry(&vertices, shape, false)
			solid_samples[sample] = time.duration_nanoseconds(time.since(started))
		}
	}
	sort_durations(solid_samples[:])
	sort_durations(gradient_samples[:])
	vertices_per_surface := len(vertices)/SHAPE_SURFACE_COUNT
	benchmark_shape_geometry_print(name, "solid", solid_samples[:], vertices_per_surface)
	benchmark_shape_geometry_print(name, "gradient", gradient_samples[:], vertices_per_surface)
}

build_vector_shape_geometry :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	rt: ^alicorn.Runtime,
	command: alicorn.Paint_Command,
) {
	clear(vertices)
	for i in 0..<SHAPE_SURFACE_COUNT {
		surface := command
		surface.bounds = alicorn.Rect{f32(i%16)*4, f32(i/16)*4, 4, 4}
		surface.clip = {0, 0, 64, 64}
		surface.translation = {}
		_ = cpu_renderer.Append_Surface_Mesh(vertices, rt, surface, 2, 2, 128, 128)
	}
}

benchmark_vector_shape :: proc(name: string, rt: ^alicorn.Runtime, command: alicorn.Paint_Command) {
	vertices := make([dynamic]cpu_renderer.Vertex, 0,
		SHAPE_SURFACE_COUNT*cpu_renderer.VECTOR_CURVE_MAX_SEGMENTS*18, allocator=context.temp_allocator)
	defer delete(vertices)
	samples: [SHAPE_SAMPLES]i64
	for _ in 0..<3 { build_vector_shape_geometry(&vertices, rt, command) }
	for sample in 0..<SHAPE_SAMPLES {
		started := time.now()
		build_vector_shape_geometry(&vertices, rt, command)
		samples[sample] = time.duration_nanoseconds(time.since(started))
	}
	sort_durations(samples[:])
	vertices_per_surface := len(vertices)/SHAPE_SURFACE_COUNT
	benchmark_shape_geometry_print(name, "solid", samples[:], vertices_per_surface)
}

VECTOR_LARGE_SURFACES :: 64
VECTOR_LARGE_SIZE     :: 64
VECTOR_LARGE_TARGET   :: 1024

build_vector_shape_geometry_large :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	rt: ^alicorn.Runtime,
	command: alicorn.Paint_Command,
) {
	clear(vertices)
	for i in 0..<VECTOR_LARGE_SURFACES {
		surface := command
		surface.bounds = alicorn.Rect{f32(i%8)*VECTOR_LARGE_SIZE, f32(i/8)*VECTOR_LARGE_SIZE,
			VECTOR_LARGE_SIZE, VECTOR_LARGE_SIZE}
		surface.clip = {0, 0, VECTOR_LARGE_TARGET, VECTOR_LARGE_TARGET}
		surface.translation = {}
		_ = cpu_renderer.Append_Surface_Mesh(vertices, rt, surface, 2, 2, VECTOR_LARGE_TARGET, VECTOR_LARGE_TARGET)
	}
}

benchmark_vector_shape_large :: proc(name: string, rt: ^alicorn.Runtime, command: alicorn.Paint_Command) {
	vertices := make([dynamic]cpu_renderer.Vertex, 0,
		VECTOR_LARGE_SURFACES*cpu_renderer.VECTOR_CURVE_MAX_SEGMENTS*27, allocator=context.temp_allocator)
	defer delete(vertices)
	samples: [SHAPE_SAMPLES]i64
	for _ in 0..<3 { build_vector_shape_geometry_large(&vertices, rt, command) }
	for sample in 0..<SHAPE_SAMPLES {
		started := time.now()
		build_vector_shape_geometry_large(&vertices, rt, command)
		samples[sample] = time.duration_nanoseconds(time.since(started))
	}
	sort_durations(samples[:])
	p50_index := SHAPE_SAMPLES/2
	p95_index := (SHAPE_SAMPLES*95+99)/100-1
	vertices_per_surface := len(vertices)/VECTOR_LARGE_SURFACES
	fmt.println("native_shape_geometry_large", name, "fill", "solid",
		"surfaces", VECTOR_LARGE_SURFACES, "surface_size", VECTOR_LARGE_SIZE, "scale", 2,
		"vertices_per_surface", vertices_per_surface,
		"uploaded_bytes", VECTOR_LARGE_SURFACES*vertices_per_surface*size_of(cpu_renderer.Vertex),
		"surface_commands", VECTOR_LARGE_SURFACES, "draw_slots", VECTOR_LARGE_SURFACES, "additional_passes", 0,
		"p50_batch_ns", samples[p50_index], "p95_batch_ns", samples[p95_index],
		"p50_ns_per_surface", f64(samples[p50_index])/f64(VECTOR_LARGE_SURFACES),
		"p95_ns_per_surface", f64(samples[p95_index])/f64(VECTOR_LARGE_SURFACES))
}

main :: proc() {
	vertices := make([dynamic]cpu_renderer.Vertex, 0, SURFACE_COUNT*6, allocator=context.temp_allocator)
	defer delete(vertices)

	// Warm the same preallocated storage before reporting. Both cases create the
	// same vertex stream and perform no buffer allocation inside the timed loop.
	_, _ = run_batch(&vertices, false)
	_, _ = run_batch(&vertices, true)
	fmt.println("Alicorn native material flat-path benchmark; CPU vertex expansion only")
	fmt.println("surfaces_per_sample", SURFACE_COUNT, "iterations", ITERATIONS, "vertices_per_batch", SURFACE_COUNT*6)
	for sample in 0..<SAMPLES {
		direct_ns, direct_checksum := run_batch(&vertices, false)
		flat_ns, flat_checksum := run_batch(&vertices, true)
		fmt.println(
			"sample", sample+1,
			"direct_quad_ns", direct_ns,
			"flat_material_ns", flat_ns,
			"direct_ns_per_surface", f64(direct_ns)/f64(SURFACE_COUNT*ITERATIONS),
			"flat_ns_per_surface", f64(flat_ns)/f64(SURFACE_COUNT*ITERATIONS),
			"vertices", len(vertices),
			"capacity", cap(vertices),
			"same_output", direct_checksum == flat_checksum,
		)
	}

	// Compare the unchanged six-vertex rectangle path with legacy uniform
	// rounding and asymmetric per-corner tessellation at a realistic control
	// group size. These CPU timings exclude layout, command composition, GPU
	// upload, and presentation; raw batches report p50 and p95 to expose tails.
	fmt.println("Alicorn native surface geometry benchmark; 256 surfaces per batch; CPU vertex expansion only")
	benchmark_shape_geometry("rectangle", alicorn.Surface_Shape{kind=.Rectangle})
	benchmark_shape_geometry("uniform-rounded", alicorn.surface_shape_uniform_corner_radius(10))
	benchmark_shape_geometry("per-corner-rounded", alicorn.surface_shape_rounded_corners(
		alicorn.Surface_Corner_Radii{top_left=4, top_right=14, bottom_right=8, bottom_left=2},
	))

	// Curved shapes resolve their normalized geometry through the retained
	// semantic-surface sidecar and expand through the same production mesh path
	// used by SDL_GPU. These are CPU geometry costs at 2x scale for 256 controls.
	fmt.println("Alicorn vector shape benchmark; 256 surfaces per batch; CPU vertex expansion only; scale 2")
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 128, 128})
	defer alicorn.destroy_runtime(&rt)
	arc_shape := alicorn.surface_shape_arc(3.1415927, 3.1415927, radius=0.4, center={0.5, 0.5})
	bezier_shape := alicorn.surface_shape_cubic_bezier({
		{0.02, 0.80}, {0.25, 0.05}, {0.75, 0.95}, {0.98, 0.20},
	})
	rt.semantic_surfaces[61] = alicorn.Semantic_Surface_Style{
		defined=true, role=alicorn.surface_core_color_role(.Surface), shape=arc_shape,
	}
	rt.semantic_surfaces[62] = alicorn.Semantic_Surface_Style{
		defined=true, role=alicorn.surface_core_color_role(.Surface), shape=bezier_shape,
	}
	full_clip := alicorn.Rect{0, 0, 64, 64}
	benchmark_vector_shape("rectangle", &rt, alicorn.paint_surface_command(60, {}, full_clip,
		alicorn.Color{0.30, 0.45, 0.60, 1}))
	benchmark_vector_shape("circle-fill-stroke", &rt, alicorn.paint_surface_command(64, {}, full_clip,
		alicorn.Color{0.20, 0.72, 0.38, 1}, shape=alicorn.surface_shape_circle(),
		stroke=alicorn.Paint_Stroke{color={0.95, 0.32, 0.12, 1}, width=1}, stroke_placement=.Outside))
	benchmark_vector_shape("arc-stroke", &rt, alicorn.paint_surface_command(61, {}, full_clip,
		alicorn.Color{0, 0, 0, 0}, shape=arc_shape,
		stroke=alicorn.Paint_Stroke{color={0.25, 0.80, 0.95, 1}, width=2}, stroke_placement=.Centered))
	benchmark_vector_shape("bezier-stroke", &rt, alicorn.paint_surface_command(62, {}, full_clip,
		alicorn.Color{0, 0, 0, 0}, shape=bezier_shape,
		stroke=alicorn.Paint_Stroke{color={0.95, 0.60, 0.20, 1}, width=2}, stroke_placement=.Centered))

	// Realistic 64x64 logical controls at 2x: 64 surfaces per batch. A control
	// of this size reaches the 96-segment cap, so this row captures the bounded
	// worst-case curved mesh rather than the minimum envelope.
	fmt.println("Alicorn vector shape benchmark; 64 controls per batch; 64x64 logical; scale 2; CPU vertex expansion only")
	large_clip := alicorn.Rect{0, 0, VECTOR_LARGE_TARGET, VECTOR_LARGE_TARGET}
	benchmark_vector_shape_large("rectangle", &rt, alicorn.paint_surface_command(70, {}, large_clip,
		alicorn.Color{0.30, 0.45, 0.60, 1}))
	benchmark_vector_shape_large("circle-fill-stroke", &rt, alicorn.paint_surface_command(71, {}, large_clip,
		alicorn.Color{0.20, 0.72, 0.38, 1}, shape=alicorn.surface_shape_circle(),
		stroke=alicorn.Paint_Stroke{color={0.95, 0.32, 0.12, 1}, width=2}, stroke_placement=.Outside))
	benchmark_vector_shape_large("arc-stroke", &rt, alicorn.paint_surface_command(61, {}, large_clip,
		alicorn.Color{0, 0, 0, 0}, shape=arc_shape,
		stroke=alicorn.Paint_Stroke{color={0.25, 0.80, 0.95, 1}, width=6}, stroke_placement=.Centered))
	benchmark_vector_shape_large("bezier-stroke", &rt, alicorn.paint_surface_command(62, {}, large_clip,
		alicorn.Color{0, 0, 0, 0}, shape=bezier_shape,
		stroke=alicorn.Paint_Stroke{color={0.95, 0.60, 0.20, 1}, width=5}, stroke_placement=.Centered))

	// Issue #248 phase A: compare explicit direct layer composition with a
	// benchmark-only ordered descriptor list lowered through the same existing
	// surface mesh path. This is a renderer baseline, not retained-node or GPU
	// evidence and does not introduce a runtime effect-stack API.
	benchmark_effect_stack_prototype(&rt)
}
