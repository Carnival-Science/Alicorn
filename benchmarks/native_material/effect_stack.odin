package main

import "core:fmt"
import "core:mem"
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
EFFECT_STACK_LOWER_ITERATIONS :: 100
EFFECT_STACK_TARGET_SIZE :: 1024

Effect_Lowering_Allocator_State :: struct {
	backing: mem.Allocator,
	allocations: u64,
	allocated_bytes: u64,
}

effect_lowering_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^Effect_Lowering_Allocator_State)(data)
	result, err := state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		state.allocations += 1
		state.allocated_bytes += u64(size)
	}
	return result, err
}

Effect_Layer_Kind :: enum u8 {
	Inset_Fill,
	Stroke,
}

Effect_Layer :: struct {
	kind: Effect_Layer_Kind,
	inset: f32,
	color: alicorn.Color,
	stroke_fill: alicorn.Color,
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

effect_owner_clip :: proc(base: alicorn.Paint_Command) -> alicorn.Rect {
	left := max(base.clip.x, base.bounds.x)
	top := max(base.clip.y, base.bounds.y)
	right := min(base.clip.x+base.clip.w, base.bounds.x+base.bounds.w)
	bottom := min(base.clip.y+base.clip.h, base.bounds.y+base.bounds.h)
	if right <= left || bottom <= top { return alicorn.Rect{left, top, 0, 0} }
	return alicorn.Rect{left, top, max(0, right-left), max(0, bottom-top)}
}

effect_layer_shape :: proc(shape: alicorn.Surface_Shape, inset: f32) -> alicorn.Surface_Shape {
	result := shape
	#partial switch result.kind {
	case .Rounded_Rectangle:
		result.corner_radius = max(0, result.corner_radius-inset)
	case .Rounded_Rectangle_Per_Corner:
		result.corner_radii.top_left = max(0, result.corner_radii.top_left-inset)
		result.corner_radii.top_right = max(0, result.corner_radii.top_right-inset)
		result.corner_radii.bottom_right = max(0, result.corner_radii.bottom_right-inset)
		result.corner_radii.bottom_left = max(0, result.corner_radii.bottom_left-inset)
	}
	return result
}

effect_stack_lower :: proc(
	rt: ^alicorn.Runtime,
	base: alicorn.Paint_Command,
	stack: Effect_Stack,
) -> (commands: [EFFECT_STACK_MAX_LAYERS+1]alicorn.Paint_Command, count: int, ok: bool) {
	if stack.count > EFFECT_STACK_MAX_LAYERS || !alicorn.paint_command_is_surface(base) { return }
	commands[0] = base
	count = 1
	base_surface, base_surface_ok := base.payload.(alicorn.Surface_Paint)
	if !base_surface_ok { return {}, 0, false }
	if base_surface.shape.kind != .Rectangle && base_surface.shape.kind != .Rounded_Rectangle &&
	   base_surface.shape.kind != .Rounded_Rectangle_Per_Corner {
		return {}, 0, false
	}
	// Preserve the complete shape payload. Reconstructing only kind and the
	// legacy uniform radius silently squares per-corner surfaces.
	base_shape, base_shape_ok := alicorn.surface_paint_shape_resolve(rt, base.owner, base_surface.shape)
	if !base_shape_ok { return {}, 0, false }
	owner_clip := effect_owner_clip(base)
	for layer_index in 0..<int(stack.count) {
		layer := stack.layers[layer_index]
		if layer.kind != .Inset_Fill && layer.kind != .Stroke { return {}, 0, false }
		bounds, bounds_ok := effect_layer_bounds(base.bounds, layer.inset)
		if !bounds_ok { return {}, 0, false }
		shape := effect_layer_shape(base_shape, layer.inset)
		// The renderer's public Paint_Command remains compact and resolves
		// retained per-corner geometry by owner. The private prototype gives each
		// lowered layer a deterministic paint owner and stores its full shape in
		// the existing sparse semantic-surface sidecar.
		layer_owner := alicorn.Node_ID((u64(base.owner)<<4) | (u64(layer_index)+1) | 0x8000_0000_0000_0000)
		rt.semantic_surfaces[layer_owner] = alicorn.Semantic_Surface_Style{
			defined=true,
			role=alicorn.surface_core_color_role(.Surface),
			shape=shape,
		}
		command: alicorn.Paint_Command
		switch layer.kind {
		case .Inset_Fill:
			if !alicorn.semantic_surface_color_is_valid(layer.color) { return {}, 0, false }
			command = alicorn.paint_surface_command(
				layer_owner, bounds, owner_clip, layer.color,
				opacity=base.opacity, translation=base.translation, shape=shape,
			)
		case .Stroke:
			if layer.stroke.width != layer.stroke.width || layer.stroke.width <= 0 || layer.stroke.width > 4096 ||
			   !alicorn.semantic_surface_color_is_valid(layer.stroke.color) ||
			   !alicorn.semantic_surface_color_is_valid(layer.stroke_fill) ||
			   layer.stroke_placement < .Centered || layer.stroke_placement >= .Count {
				return {}, 0, false
			}
			command = alicorn.paint_surface_command(
				layer_owner, bounds, owner_clip, layer.stroke_fill,
				opacity=base.opacity, translation=base.translation, shape=shape,
				stroke=layer.stroke, stroke_placement=layer.stroke_placement,
			)
		}
		commands[count] = command
		count += 1
	}
	return commands, count, true
}

effect_stack_prototype_contract_valid :: proc(rt: ^alicorn.Runtime, base: alicorn.Paint_Command, stack: Effect_Stack) -> bool {
	empty, empty_count, empty_ok := effect_stack_lower(rt, base, {})
	empty_surface, empty_surface_ok := empty[0].payload.(alicorn.Surface_Paint)
	base_surface, base_surface_ok := base.payload.(alicorn.Surface_Paint)
	if !empty_ok || !empty_surface_ok || !base_surface_ok || empty_count != 1 ||
	   empty[0].owner != base.owner || empty[0].bounds != base.bounds || empty_surface != base_surface {
		return false
	}
	overflow, _, overflow_ok := effect_stack_lower(rt, base, Effect_Stack{count=EFFECT_STACK_MAX_LAYERS+1})
	_ = overflow
	if overflow_ok { return false }
	invalid_inset := stack
	invalid_inset.layers[0].inset = -1
	_, _, inset_ok := effect_stack_lower(rt, base, invalid_inset)
	if inset_ok { return false }
	if base_surface.shape.kind != .Rounded_Rectangle_Per_Corner { return true }
	lowered, count, ok := effect_stack_lower(rt, base, stack)
	if !ok || count < 2 { return false }
	layer_surface, layer_ok := lowered[1].payload.(alicorn.Surface_Paint)
	if !layer_ok { return false }
	base_shape, base_shape_ok := alicorn.surface_paint_shape_resolve(rt, base.owner, base_surface.shape)
	if !base_shape_ok { return false }
	base_radii := base_shape.corner_radii
	layer_shape, layer_shape_ok := alicorn.surface_paint_shape_resolve(rt, lowered[1].owner, layer_surface.shape)
	if !layer_shape_ok { return false }
	expected := alicorn.Surface_Corner_Radii{
		top_left=max(0, base_radii.top_left-stack.layers[0].inset),
		top_right=max(0, base_radii.top_right-stack.layers[0].inset),
		bottom_right=max(0, base_radii.bottom_right-stack.layers[0].inset),
		bottom_left=max(0, base_radii.bottom_left-stack.layers[0].inset),
	}
	return layer_shape.kind == .Rounded_Rectangle_Per_Corner && layer_shape.corner_radii == expected
}

effect_stack_fixture :: proc(rt: ^alicorn.Runtime, name: string) -> (
	base: alicorn.Paint_Command,
	direct: [3]alicorn.Paint_Command,
	stack: Effect_Stack,
) {
	bounds := alicorn.Rect{0, 0, 280, 112}
	clip := alicorn.Rect{0, 0, EFFECT_STACK_TARGET_SIZE, EFFECT_STACK_TARGET_SIZE}
	shape := alicorn.surface_shape_rounded_corners(
		alicorn.Surface_Corner_Radii{top_left=6, top_right=10, bottom_right=4, bottom_left=2},
	)
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
	rt.semantic_surfaces[100] = alicorn.Semantic_Surface_Style{
		defined=true, role=alicorn.surface_core_color_role(.Surface), shape=shape,
	}

	// The direct baseline authors the two extra surface commands explicitly,
	// like ordinary positioned surfaces. The owner IDs model separate visual
	// owners; no layout nodes are included in this geometry-only experiment.
	highlight_color := alicorn.Color{1, 1, 1, 0.055}
	inner_color := alicorn.Color{0.72, 0.49, 0.24, 0.58}
	highlight_bounds := alicorn.Rect{bounds.x+1, bounds.y+1, bounds.w-2, bounds.h-2}
	inner_bounds := alicorn.Rect{bounds.x+1, bounds.y+1, bounds.w-2, bounds.h-2}
	inner_shape := effect_layer_shape(shape, 1)
	owner_clip := effect_owner_clip(base)
	rt.semantic_surfaces[101] = alicorn.Semantic_Surface_Style{
		defined=true, role=alicorn.surface_core_color_role(.Surface), shape=inner_shape,
	}
	rt.semantic_surfaces[102] = alicorn.Semantic_Surface_Style{
		defined=true, role=alicorn.surface_core_color_role(.Surface), shape=inner_shape,
	}
	direct[0] = base
	direct[1] = alicorn.paint_surface_command(
		101, highlight_bounds, owner_clip, highlight_color,
		shape=inner_shape,
	)
	direct[2] = alicorn.paint_surface_command(
		102, inner_bounds, owner_clip, alicorn.Color{0, 0, 0, 0},
		shape=inner_shape,
		stroke=alicorn.Paint_Stroke{color=inner_color, width=1}, stroke_placement=.Inside,
	)
	stack = Effect_Stack{count=2, layers=[4]Effect_Layer{
		{kind=.Inset_Fill, inset=1, color=highlight_color},
		{kind=.Stroke, inset=1, stroke=alicorn.Paint_Stroke{color=inner_color, width=1}, stroke_placement=.Inside},
		{}, {},
	}}
	return
}

benchmark_effect_stack_lowering :: proc(
	rt: ^alicorn.Runtime,
	name: string,
	base: alicorn.Paint_Command,
	stack: Effect_Stack,
) {
	for _ in 0..<3 {
		_, _, ok := effect_stack_lower(rt, base, stack)
		if !ok { fmt.eprintln("ordered-effect lowering warmup failed", name); os.exit(1) }
	}
	samples: [EFFECT_STACK_BENCH_SAMPLES]i64
	backing := context.allocator
	allocator_state := Effect_Lowering_Allocator_State{backing=backing}
	context.allocator = mem.Allocator{procedure=effect_lowering_allocator_proc, data=rawptr(&allocator_state)}
	persistent_allocations_before := rt.allocation_stats.persistent_alloc_calls
	checksum: u64
	for sample in 0..<EFFECT_STACK_BENCH_SAMPLES {
		started := time.now()
		for _ in 0..<EFFECT_STACK_LOWER_ITERATIONS {
			lowered, count, ok := effect_stack_lower(rt, base, stack)
			if !ok || count != int(stack.count)+1 {
				context.allocator = backing
				fmt.eprintln("ordered-effect lowering failed during timed sample", name)
				os.exit(1)
			}
			checksum += u64(count)+u64(lowered[count-1].owner)
		}
		samples[sample] = time.duration_nanoseconds(time.since(started))/EFFECT_STACK_LOWER_ITERATIONS
	}
	context.allocator = backing
	persistent_allocations := rt.allocation_stats.persistent_alloc_calls-persistent_allocations_before
	sort_durations(samples[:])
	p95 := (EFFECT_STACK_BENCH_SAMPLES*95+99)/100-1
	p99 := (EFFECT_STACK_BENCH_SAMPLES*99+99)/100-1
	fmt.println(
		"ordered_effect_lowering", name,
		"iterations_per_sample", EFFECT_STACK_LOWER_ITERATIONS,
		"p50_ns", samples[EFFECT_STACK_BENCH_SAMPLES/2],
		"p95_ns", samples[p95],
		"p99_ns", samples[p99],
		"context_allocations", allocator_state.allocations,
		"context_allocated_bytes", allocator_state.allocated_bytes,
		"persistent_allocations_after_warmup", persistent_allocations,
		"checksum", checksum,
	)
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
	lowered, lowered_count, lower_ok := effect_stack_lower(rt, base, stack)
	if !lower_ok || lowered_count != len(direct) {
		fmt.eprintln("effect-stack prototype invalid lowering", name, "lowered", lowered_count, "expected", len(direct))
		os.exit(1)
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
		if !effect_stack_prototype_contract_valid(rt, base, stack) {
			fmt.eprintln("ordered-effect prototype contract failed", name)
			os.exit(1)
		}
		benchmark_effect_stack_lowering(rt, name, base, stack)
		for scale in ([4]f32{1, 1.25, 1.5, 2}) {
			benchmark_effect_stack_case(rt, name, base, direct[:], stack, scale)
		}
	}
}
