package main

import "core:fmt"
import "core:os"
import "core:time"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"

// This is a benchmark-only representation. It deliberately does not add a
// runtime API or retain descriptors on Alicorn nodes. Lowering it to ordinary
// surface commands tests whether an ordered vocabulary can use today's paint
// and renderer paths before any production abstraction is considered.
EFFECT_STACK_MAX_LAYERS :: 4
EFFECT_STACK_BENCH_SURFACES :: 256
EFFECT_STACK_BENCH_SAMPLES :: 101
EFFECT_STACK_TARGET_SIZE :: 1024

Effect_Layer_Kind :: enum u8 {
	Inset_Fill,
	Stroke,
}

Effect_Layer :: struct {
	kind: Effect_Layer_Kind,
	inset: f32,
	color: alicorn.Color,
	stroke: alicorn.Paint_Stroke,
	stroke_placement: alicorn.Paint_Stroke_Placement,
}

Effect_Stack :: struct {
	count: u8,
	layers: [EFFECT_STACK_MAX_LAYERS]Effect_Layer,
}

effect_layer_bounds :: proc(bounds: alicorn.Rect, inset: f32) -> (result: alicorn.Rect, ok: bool) {
	if inset < 0 || inset != inset || bounds.w <= inset*2 || bounds.h <= inset*2 { return }
	return alicorn.Rect{bounds.x+inset, bounds.y+inset, bounds.w-2*inset, bounds.h-2*inset}, true
}

effect_layer_shape :: proc(shape: alicorn.Surface_Shape, inset: f32) -> alicorn.Surface_Shape {
	result := shape
	if result.kind == .Rounded_Rectangle {
		result.corner_radius = max(0, result.corner_radius-inset)
	}
	return result
}

effect_stack_lower :: proc(
	base: alicorn.Paint_Command,
	stack: Effect_Stack,
) -> (commands: [EFFECT_STACK_MAX_LAYERS+1]alicorn.Paint_Command, count: int, ok: bool) {
	if stack.count > EFFECT_STACK_MAX_LAYERS || !alicorn.paint_command_is_surface(base) { return }
	commands[0] = base
	count = 1
	base_surface, base_surface_ok := base.payload.(alicorn.Surface_Paint)
	if !base_surface_ok { return {}, 0, false }
	if base_surface.shape.kind != .Rectangle && base_surface.shape.kind != .Rounded_Rectangle {
		return {}, 0, false
	}
	base_shape := alicorn.Surface_Shape{
		kind=base_surface.shape.kind,
		corner_radius=base_surface.shape.corner_radius,
	}
	for layer_index in 0..<int(stack.count) {
		layer := stack.layers[layer_index]
		if layer.kind != .Inset_Fill && layer.kind != .Stroke { return {}, 0, false }
		bounds, bounds_ok := effect_layer_bounds(base.bounds, layer.inset)
		if !bounds_ok { return {}, 0, false }
		shape := effect_layer_shape(base_shape, layer.inset)
		command: alicorn.Paint_Command
		switch layer.kind {
		case .Inset_Fill:
			if !alicorn.semantic_surface_color_is_valid(layer.color) { return {}, 0, false }
			command = alicorn.paint_surface_command(
				base.owner, bounds, base.clip, layer.color,
				opacity=base.opacity, translation=base.translation, shape=shape,
			)
		case .Stroke:
			if layer.stroke.width != layer.stroke.width || layer.stroke.width <= 0 || layer.stroke.width > 4096 ||
			   !alicorn.semantic_surface_color_is_valid(layer.stroke.color) ||
			   layer.stroke_placement < .Centered || layer.stroke_placement >= .Count {
				return {}, 0, false
			}
			command = alicorn.paint_surface_command(
				base.owner, bounds, base.clip, alicorn.Color{0, 0, 0, 0},
				opacity=base.opacity, translation=base.translation, shape=shape,
				stroke=layer.stroke, stroke_placement=layer.stroke_placement,
			)
		}
		commands[count] = command
		count += 1
	}
	return commands, count, true
}

effect_stack_prototype_contract_valid :: proc(base: alicorn.Paint_Command, stack: Effect_Stack) -> bool {
	empty, empty_count, empty_ok := effect_stack_lower(base, {})
	empty_surface, empty_surface_ok := empty[0].payload.(alicorn.Surface_Paint)
	base_surface, base_surface_ok := base.payload.(alicorn.Surface_Paint)
	if !empty_ok || !empty_surface_ok || !base_surface_ok || empty_count != 1 ||
	   empty[0].owner != base.owner || empty[0].bounds != base.bounds || empty_surface != base_surface {
		return false
	}
	overflow, _, overflow_ok := effect_stack_lower(base, Effect_Stack{count=EFFECT_STACK_MAX_LAYERS+1})
	_ = overflow
	if overflow_ok { return false }
	invalid_inset := stack
	invalid_inset.layers[0].inset = -1
	_, _, inset_ok := effect_stack_lower(base, invalid_inset)
	return !inset_ok
}

effect_stack_fixture :: proc(rt: ^alicorn.Runtime, name: string) -> (
	base: alicorn.Paint_Command,
	direct: [3]alicorn.Paint_Command,
	stack: Effect_Stack,
) {
	bounds := alicorn.Rect{0, 0, 280, 112}
	clip := alicorn.Rect{0, 0, EFFECT_STACK_TARGET_SIZE, EFFECT_STACK_TARGET_SIZE}
	shape := alicorn.surface_shape_uniform_corner_radius(6)
	fill := alicorn.Color{0.105, 0.135, 0.185, 1}
	border := alicorn.Paint_Stroke{color={0.24, 0.29, 0.37, 1}, width=1}
	material := alicorn.MATERIAL_FLAT
	height: f32
	if name == "punks-audition-deck" {
		fill = {0.13, 0.16, 0.17, 1}
		border = alicorn.Paint_Stroke{color={0.23, 0.27, 0.28, 1}, width=1}
		material = alicorn.style_material_register(rt, alicorn.Style_Material{
			kind=.Analytic_Relief, bevel_width=2, bevel_strength=0.95,
			inner_shadow_strength=0.5, outer_shadow_strength=0.65, outer_shadow_radius=4,
		})
		height = 1.5
	}
	base = alicorn.paint_surface_command(
		100, bounds, clip, fill, shape=shape, material=material, physical_height=height,
		stroke=border, stroke_placement=.Inside,
	)

	// The direct baseline authors the two extra surface commands explicitly,
	// like ordinary positioned surfaces. The owner IDs model separate visual
	// owners; no layout nodes are included in this geometry-only experiment.
	highlight_color := alicorn.Color{1, 1, 1, 0.055}
	inner_color := alicorn.Color{0.72, 0.49, 0.24, 0.58}
	highlight_bounds := alicorn.Rect{bounds.x+1, bounds.y+1, bounds.w-2, bounds.h-2}
	inner_bounds := alicorn.Rect{bounds.x+1, bounds.y+1, bounds.w-2, bounds.h-2}
	direct[0] = base
	direct[1] = alicorn.paint_surface_command(
		101, highlight_bounds, clip, highlight_color,
		shape=alicorn.surface_shape_uniform_corner_radius(5),
	)
	direct[2] = alicorn.paint_surface_command(
		102, inner_bounds, clip, alicorn.Color{0, 0, 0, 0},
		shape=alicorn.surface_shape_uniform_corner_radius(5),
		stroke=alicorn.Paint_Stroke{color=inner_color, width=1}, stroke_placement=.Inside,
	)
	stack = Effect_Stack{count=2, layers=[4]Effect_Layer{
		{kind=.Inset_Fill, inset=1, color=highlight_color},
		{kind=.Stroke, inset=1, stroke=alicorn.Paint_Stroke{color=inner_color, width=1}, stroke_placement=.Inside},
		{}, {},
	}}
	return
}

effect_mesh_build :: proc(
	vertices: ^[dynamic]cpu_renderer.Vertex,
	rt: ^alicorn.Runtime,
	commands: []alicorn.Paint_Command,
	scale: f32,
) {
	clear(vertices)
	clip := alicorn.Rect{0, 0, EFFECT_STACK_TARGET_SIZE, EFFECT_STACK_TARGET_SIZE}
	for index in 0..<EFFECT_STACK_BENCH_SURFACES {
		x := f32(index%8)*128
		y := f32(index/8)*32
		for source in commands {
			command := source
			command.bounds.x += x
			command.bounds.y += y
			command.clip = clip
			_ = cpu_renderer.Append_Surface_Mesh(
				vertices, rt, command, scale, scale,
				int(f32(EFFECT_STACK_TARGET_SIZE)*scale),
				int(f32(EFFECT_STACK_TARGET_SIZE)*scale),
			)
		}
	}
}

benchmark_effect_stack_case :: proc(
	rt: ^alicorn.Runtime,
	name: string,
	base: alicorn.Paint_Command,
	direct: []alicorn.Paint_Command,
	stack: Effect_Stack,
	scale: f32,
) {
	lowered, lowered_count, lower_ok := effect_stack_lower(base, stack)
	if !lower_ok || lowered_count != len(direct) {
		fmt.eprintln("effect-stack prototype invalid lowering", name)
		return
	}
	vertices := make([dynamic]cpu_renderer.Vertex, 0,
		EFFECT_STACK_BENCH_SURFACES*3*cpu_renderer.ROUNDED_FILL_VERTICES,
		allocator=context.allocator)
	defer delete(vertices)

	direct_samples: [EFFECT_STACK_BENCH_SAMPLES]i64
	stack_samples: [EFFECT_STACK_BENCH_SAMPLES]i64
	effect_mesh_build(&vertices, rt, direct, scale)
	direct_count := len(vertices)
	direct_copy := make([]cpu_renderer.Vertex, direct_count, allocator=context.allocator)
	defer delete(direct_copy)
	copy(direct_copy, vertices[:])
	effect_mesh_build(&vertices, rt, lowered[:lowered_count], scale)
	mesh_equal := len(vertices) == direct_count
	if mesh_equal {
		for index in 0..<direct_count {
			if vertices[index] != direct_copy[index] { mesh_equal = false; break }
		}
	}
	if !mesh_equal {
		fmt.eprintln("ordered-effect prototype mismatch", name, "scale", scale)
		os.exit(1)
	}

	for _ in 0..<3 {
		effect_mesh_build(&vertices, rt, direct, scale)
		effect_mesh_build(&vertices, rt, lowered[:lowered_count], scale)
	}
	for sample in 0..<EFFECT_STACK_BENCH_SAMPLES {
		if sample%2 == 0 {
			started := time.now()
			effect_mesh_build(&vertices, rt, direct, scale)
			direct_samples[sample] = time.duration_nanoseconds(time.since(started))
			started = time.now()
			effect_mesh_build(&vertices, rt, lowered[:lowered_count], scale)
			stack_samples[sample] = time.duration_nanoseconds(time.since(started))
		} else {
			started := time.now()
			effect_mesh_build(&vertices, rt, lowered[:lowered_count], scale)
			stack_samples[sample] = time.duration_nanoseconds(time.since(started))
			started = time.now()
			effect_mesh_build(&vertices, rt, direct, scale)
			direct_samples[sample] = time.duration_nanoseconds(time.since(started))
		}
	}
	sort_durations(direct_samples[:])
	sort_durations(stack_samples[:])
	p95 := (EFFECT_STACK_BENCH_SAMPLES*95+99)/100-1
	p99 := (EFFECT_STACK_BENCH_SAMPLES*99+99)/100-1
	fmt.println(
		"ordered_effect_geometry", name,
		"scale", scale,
		"surfaces", EFFECT_STACK_BENCH_SURFACES,
		"direct_commands", len(direct),
		"stack_commands", lowered_count,
		"vertices", direct_count,
		"upload_bytes", direct_count*size_of(cpu_renderer.Vertex),
		"extra_passes", 0,
		"mesh_equal", mesh_equal,
		"direct_p50_ns", direct_samples[EFFECT_STACK_BENCH_SAMPLES/2],
		"direct_p95_ns", direct_samples[p95],
		"direct_p99_ns", direct_samples[p99],
		"stack_p50_ns", stack_samples[EFFECT_STACK_BENCH_SAMPLES/2],
		"stack_p95_ns", stack_samples[p95],
		"stack_p99_ns", stack_samples[p99],
	)
}

benchmark_effect_stack_prototype :: proc(rt: ^alicorn.Runtime) {
	fmt.println("Alicorn ordered-effect prototype: benchmark-only descriptors lowered to existing surface commands")
	for name in ([2]string{"alikit-menu-popup", "punks-audition-deck"}) {
		base, direct, stack := effect_stack_fixture(rt, name)
		if !effect_stack_prototype_contract_valid(base, stack) {
			fmt.eprintln("ordered-effect prototype contract failed", name)
			os.exit(1)
		}
		for scale in ([4]f32{1, 1.25, 1.5, 2}) {
			benchmark_effect_stack_case(rt, name, base, direct[:], stack, scale)
		}
	}
}
