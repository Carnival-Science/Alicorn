package main

import "core:fmt"
import "core:os"
import "core:time"
import alicorn "../../runtime"

EFFECT_RETENTION_COUNTS :: [4]int{1, 100, 1000, 3000}
EFFECT_RETENTION_OWNER_WIDTH :: 280
EFFECT_RETENTION_OWNER_HEIGHT :: 44

Effect_Retention_Mode :: enum { Direct_Children, Sparse_Owner }

Effect_Retention_State :: struct {
	target: int,
	color_variant: bool,
	inset_variant: bool,
	layer_count: int,
	resize_variant: bool,
}

Effect_Retention_Metrics :: struct {
	reconcile: u64,
	measure: u64,
	layout: u64,
	shape: u64,
	paint: u64,
	finalized: u64,
	created: u64,
	retired: u64,
	allocations: u64,
	live_bytes: i64,
}

effect_retention_metrics :: proc(rt: ^alicorn.Runtime, before: alicorn.Frame_Stats, alloc_before: alicorn.Runtime_Allocation_Stats) -> Effect_Retention_Metrics {
	return Effect_Retention_Metrics{
		reconcile=rt.stats.reconcile_nodes_visited-before.reconcile_nodes_visited,
		measure=rt.stats.measure_nodes_executed-before.measure_nodes_executed,
		layout=rt.stats.layout_nodes_visited-before.layout_nodes_visited,
		shape=rt.stats.text_shape_requests-before.text_shape_requests,
		paint=rt.stats.paint_nodes_visited-before.paint_nodes_visited,
		finalized=rt.stats.display_commands_finalized-before.display_commands_finalized,
		created=rt.stats.nodes_created-before.nodes_created,
		retired=rt.stats.nodes_retired-before.nodes_retired,
		allocations=rt.allocation_stats.persistent_alloc_calls-alloc_before.persistent_alloc_calls,
		live_bytes=rt.allocation_stats.persistent_requested_bytes_live-alloc_before.persistent_requested_bytes_live,
	}
}

effect_retention_live_nodes :: proc(rt: ^alicorn.Runtime) -> int {
	result := 0
	for _, node in rt.nodes {
		if node != nil && node.active && node.present { result += 1 }
	}
	return result
}

effect_retention_stack :: proc(state: Effect_Retention_State, index: int) -> Effect_Stack {
	count := 2
	inset := f32(1)
	highlight := alicorn.Color{1, 1, 1, 0.055}
	if index == state.target {
		count = state.layer_count
		if state.inset_variant { inset = 2 }
		if state.color_variant { highlight = {0.92, 0.57, 0.24, 0.14} }
	}
	inner := alicorn.Color{0.72, 0.49, 0.24, 0.58}
	// surface_begin reserves the exact all-zero color as "use the role". This
	// alpha-zero value keeps the ordinary retained surface semantically
	// transparent while matching the low-level command's transparent fill.
	transparent_fill := alicorn.Color{0.001, 0, 0, 0}
	return Effect_Stack{count=u8(count), layers=[4]Effect_Layer{
		{kind=.Inset_Fill, inset=inset, color=highlight},
		{kind=.Stroke, inset=inset, stroke_fill=transparent_fill,
			stroke=alicorn.Paint_Stroke{color=inner, width=1}, stroke_placement=.Inside},
		{}, {},
	}}
}

effect_retention_shape :: proc() -> alicorn.Surface_Shape {
	return alicorn.surface_shape_rounded_corners(
		alicorn.Surface_Corner_Radii{top_left=7, top_right=11, bottom_right=5, bottom_left=3},
	)
}

effect_retention_dimensions :: proc(state: Effect_Retention_State, index: int) -> (width, height: f32) {
	width, height = EFFECT_RETENTION_OWNER_WIDTH, EFFECT_RETENTION_OWNER_HEIGHT
	if index == state.target && state.resize_variant { width, height = 304, 52 }
	return
}

effect_retention_describe :: proc(
	rt: ^alicorn.Runtime,
	state: Effect_Retention_State,
	mode: Effect_Retention_Mode,
	owners: []alicorn.Node_ID,
) -> bool {
	alicorn.invalidate_root(rt, "issue 248 retained effect benchmark")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root,
		key=alicorn.key_string("effect-retention-root"),
		style=alicorn.layout_style(.Column, width=-1, height=-1))
	base_shape := effect_retention_shape()
	for index in 0..<len(owners) {
		width, height := effect_retention_dimensions(state, index)
		owner_key := u64(index+1)
		owner := alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Surface),
			key=alicorn.key_u64(owner_key),
			style=alicorn.layout_style(.Column, width=width, height=height, clip=true),
			shape=base_shape,
			fill=alicorn.Color{0.105, 0.135, 0.185, 1},
			stroke=alicorn.Paint_Stroke{color={0.24, 0.29, 0.37, 1}, width=1},
			stroke_placement=.Inside,
			label="effect benchmark surface")
		owners[index] = owner
		stack := effect_retention_stack(state, index)
		if mode == .Sparse_Owner {
			if !alicorn.issue248_surface_effect_stack_set(rt, owner, stack) {
				fmt.eprintln("retained surface effect declaration failed", index)
				os.exit(1)
			}
		} else if mode == .Direct_Children {
			for layer_index in 0..<int(stack.count) {
				layer := stack.layers[layer_index]
				bounds_width := width-2*layer.inset
				bounds_height := height-2*layer.inset
				if bounds_width <= 0 || bounds_height <= 0 { continue }
				layer_shape := effect_layer_shape(base_shape, layer.inset)
				layer_fill := layer.color
				if layer.kind == .Stroke { layer_fill = layer.stroke_fill }
				decoration := alicorn.surface_begin(&ui,
					alicorn.surface_core_color_role(.Accent),
					key=alicorn.key_pair(owner_key, u64(0xD000+layer_index)),
					style=alicorn.layout_style(.Column, width=bounds_width, height=bounds_height, clip=true),
					shape=layer_shape,
					fill=layer_fill,
					stroke=layer.stroke,
					stroke_placement=layer.stroke_placement,
					label="directly composed effect layer")
				alicorn.surface_end(&ui)
				if decoration == 0 || !alicorn.position_child(&ui, decoration,
					alicorn.positioned(layer.inset, layer.inset, clip=true)) {
					fmt.eprintln("direct effect layer description failed", index, layer_index)
					os.exit(1)
				}
			}
		}
		_ = alicorn.text(&ui, "Retained surface", key=alicorn.key_string("effect-caption"),
			style=alicorn.layout_style(.Row, height=20), color=alicorn.Color{0.82, 0.85, 0.9, 1})
		alicorn.surface_end(&ui)
	}
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return rt.diagnostic == ""
}

effect_retention_text_runs_equal :: proc(
	left_rt, right_rt: ^alicorn.Runtime,
	left, right: alicorn.Text_Paint,
) -> bool {
	left_run, left_ok := alicorn.paint_text_run_resolve(left_rt, left.run)
	right_run, right_ok := alicorn.paint_text_run_resolve(right_rt, right.run)
	if !left_ok || !right_ok || left_run == nil || right_run == nil { return false }
	if left_run.value != right_run.value || left_run.source_value != right_run.source_value ||
	   left_run.source_value_override != right_run.source_value_override ||
	   left_run.width != right_run.width || left_run.height != right_run.height ||
	   left_run.size != right_run.size || left_run.max_width != right_run.max_width ||
	   left_run.font_generation != right_run.font_generation || left_run.font != right_run.font ||
	   left_run.font_source != right_run.font_source || left_run.font_weight != right_run.font_weight ||
	   left_run.style_hash != right_run.style_hash || left_run.overflow != right_run.overflow ||
	   left_run.ligatures_disabled != right_run.ligatures_disabled ||
	   len(left_run.glyphs) != len(right_run.glyphs) || len(left_run.lines) != len(right_run.lines) ||
	   left.color != right.color || len(left.spans) != len(right.spans) {
		return false
	}
	for glyph, index in left_run.glyphs {
		if glyph != right_run.glyphs[index] { return false }
	}
	for line, index in left_run.lines {
		if line != right_run.lines[index] { return false }
	}
	for span, index in left.spans {
		if span != right.spans[index] { return false }
	}
	return true
}

// Compare the complete ordered renderer command stream. Node/resource owners
// are runtime-local. semantic_surface_fill is an owner-side animation hook:
// direct decoration nodes carry it, while lowered layers already contain the
// resolved fill. Compare that resolved payload instead. Paint order, geometry,
// clipping, transforms, resolved shapes, and shaped text must all agree.
effect_retention_commands_equal :: proc(
	left_rt, right_rt: ^alicorn.Runtime,
	left, right: alicorn.Paint_Command,
) -> bool {
	if left.bounds != right.bounds || left.clip != right.clip || left.opacity != right.opacity ||
	   left.translation != right.translation || left.stroke_placement != right.stroke_placement ||
	   left.semantic_surface_gradient != right.semantic_surface_gradient {
		return false
	}
	switch left_payload in left.payload {
	case alicorn.Surface_Paint:
		right_payload, ok := right.payload.(alicorn.Surface_Paint)
		if !ok || left_payload != right_payload { return false }
		left_shape, left_ok := alicorn.surface_paint_shape_resolve(left_rt, left.owner, left_payload.shape)
		right_shape, right_ok := alicorn.surface_paint_shape_resolve(right_rt, right.owner, right_payload.shape)
		return left_ok && right_ok && left_shape == right_shape
	case alicorn.Text_Paint:
		right_payload, ok := right.payload.(alicorn.Text_Paint)
		return ok && effect_retention_text_runs_equal(left_rt, right_rt, left_payload, right_payload)
	case alicorn.Icon_Paint:
		right_payload, ok := right.payload.(alicorn.Icon_Paint)
		return ok && left_payload == right_payload
	case alicorn.Image_Paint:
		right_payload, ok := right.payload.(alicorn.Image_Paint)
		return ok && left_payload == right_payload
	case alicorn.Geometry_Paint:
		right_payload, ok := right.payload.(alicorn.Geometry_Paint)
		return ok && left_payload == right_payload
	case alicorn.Backdrop_Effect_Paint:
		right_payload, ok := right.payload.(alicorn.Backdrop_Effect_Paint)
		return ok && left_payload == right_payload
	case alicorn.Lighting_Group_Paint:
		right_payload, ok := right.payload.(alicorn.Lighting_Group_Paint)
		return ok && left_payload == right_payload
	}
	return false
}

effect_retention_outputs_equal :: proc(
	left_rt, right_rt: ^alicorn.Runtime,
	left, right: []alicorn.Paint_Command,
) -> bool {
	if len(left) != len(right) {
		fmt.eprintln("paint command count mismatch", "direct", len(left), "sparse", len(right))
		return false
	}
	for command, index in left {
		if !effect_retention_commands_equal(left_rt, right_rt, command, right[index]) {
			fmt.eprintln("paint command mismatch", index, "direct", command, "sparse", right[index])
			return false
		}
	}
	return true
}

effect_retention_emit :: proc(
	mode: Effect_Retention_Mode,
	count: int,
	label: string,
	ns: i64,
	rt: ^alicorn.Runtime,
	metrics: Effect_Retention_Metrics,
	entry_count: int,
	lowerings, cache_hits: u64,
) {
	mode_name := "direct_children"
	if mode == .Sparse_Owner { mode_name = "sparse_owner" }
	fmt.println("retained_effect_workload",
		"mode", mode_name, "surfaces", count, "operation", label,
		"elapsed_ns", ns, "live_nodes", effect_retention_live_nodes(rt),
		"entries", entry_count, "geometry_lowerings", lowerings, "geometry_cache_hits", cache_hits,
		"retained_commands", len(rt.display),
		"reconcile_visits", metrics.reconcile, "measure_exec", metrics.measure,
		"layout_visits", metrics.layout, "text_shapes", metrics.shape,
		"paint_visits", metrics.paint, "finalized_commands", metrics.finalized,
		"nodes_created", metrics.created, "nodes_retired", metrics.retired,
		"persistent_allocations", metrics.allocations, "live_bytes_delta", metrics.live_bytes,
		"persistent_live_bytes", rt.allocation_stats.persistent_requested_bytes_live)
}

effect_retention_run_description :: proc(
	rt: ^alicorn.Runtime,
	state: Effect_Retention_State,
	mode: Effect_Retention_Mode,
	owners: []alicorn.Node_ID,
	label: string,
) -> (elapsed_ns: i64, lowerings, hits: u64, metrics: Effect_Retention_Metrics) {
	stats_before := rt.stats
	alloc_before := rt.allocation_stats^
	effects_before := alicorn.issue248_surface_effect_stats(rt)
	started := time.now()
	if !effect_retention_describe(rt, state, mode, owners) {
		fmt.eprintln("effect retained workload description failed", label, "mode", mode, "surfaces", len(owners))
		os.exit(1)
	}
	effects_after := alicorn.issue248_surface_effect_stats(rt)
	lowerings = effects_after.geometry_lowerings-effects_before.geometry_lowerings
	hits = effects_after.geometry_cache_hits-effects_before.geometry_cache_hits
	elapsed_ns = time.duration_nanoseconds(time.since(started))
	metrics = effect_retention_metrics(rt, stats_before, alloc_before)
	return
}

effect_retention_start_motion :: proc(rt: ^alicorn.Runtime, owner: alicorn.Node_ID) {
	_ = alicorn.motion_clock_set_time(rt, 0)
	handle, status := alicorn.motion_owner_begin(rt, owner)
	if status != .Ok || alicorn.motion_target_translation(rt, handle,
		alicorn.Motion_Vector2{18, 0}, alicorn.Motion_Config{omega=20, position_tolerance=0.01, velocity_tolerance=0.05},
		.Settle, 0) != .Ok {
		fmt.eprintln("effect retained owner motion setup failed", owner)
		os.exit(1)
	}
}

effect_retention_settle_motion :: proc(rt: ^alicorn.Runtime) {
	_ = alicorn.motion_tick(rt, 20_000_000_000)
	presentation, ready := alicorn.begin_presentation_frame(rt)
	if ready { alicorn.end_presentation_frame(&presentation) }
}

effect_retention_benchmark_case :: proc(count: int) {
	allocation_direct: alicorn.Runtime_Allocation_Stats
	allocation_sidecar: alicorn.Runtime_Allocation_Stats
	direct_rt := alicorn.new_runtime({0, 0, 1280, 900}, alicorn.Runtime_Config{trace_capacity=4, allocation_stats=&allocation_direct})
	sidecar_rt := alicorn.new_runtime({0, 0, 1280, 900}, alicorn.Runtime_Config{trace_capacity=4, allocation_stats=&allocation_sidecar})
	defer alicorn.destroy_runtime(&direct_rt)
	defer alicorn.destroy_runtime(&sidecar_rt)
	if !alicorn.text_engine_load_default_fonts(&direct_rt) || !alicorn.text_engine_load_default_fonts(&sidecar_rt) {
		fmt.eprintln("effect retained benchmark font setup failed")
		os.exit(1)
	}
	owners_direct := make([]alicorn.Node_ID, count)
	owners_sidecar := make([]alicorn.Node_ID, count)
	defer delete(owners_direct)
	defer delete(owners_sidecar)
	state := Effect_Retention_State{target=count/2, layer_count=2}
	start := time.now()
	if !effect_retention_describe(&direct_rt, state, .Direct_Children, owners_direct) {
		fmt.eprintln("direct retained effect construction failed", count)
		os.exit(1)
	}
	direct_initial_ns := time.duration_nanoseconds(time.since(start))
	start = time.now()
	if !effect_retention_describe(&sidecar_rt, state, .Sparse_Owner, owners_sidecar) {
		fmt.eprintln("sparse retained effect construction failed", count)
		os.exit(1)
	}
	sidecar_initial_ns := time.duration_nanoseconds(time.since(start))
	if !effect_retention_outputs_equal(&direct_rt, &sidecar_rt, direct_rt.display[:], sidecar_rt.display[:]) {
		fmt.eprintln("direct and sparse initial surface commands differ", count)
		os.exit(1)
	}
	sidecar_entries := 0
	if sidecar_rt.issue248_surface_effects != nil {
		sidecar_entries = len(sidecar_rt.issue248_surface_effects.entries)
	}
	fmt.println("retained_effect_scene",
		"surfaces", count,
		"direct_nodes", effect_retention_live_nodes(&direct_rt),
		"sidecar_nodes", effect_retention_live_nodes(&sidecar_rt),
		"direct_commands", len(direct_rt.display),
		"sidecar_commands", len(sidecar_rt.display),
		"sidecar_entries", sidecar_entries,
		"direct_initial_ns", direct_initial_ns,
		"sidecar_initial_ns", sidecar_initial_ns,
		"direct_live_bytes", allocation_direct.persistent_requested_bytes_live,
		"sidecar_live_bytes", allocation_sidecar.persistent_requested_bytes_live,
		"equivalent_ordered_paint_output", true)

	operations := [?]string{"identical_redescription", "one_layer_color", "one_layer_inset", "remove_layer", "add_layer", "resize_owner"}
	for operation in operations {
		baseline := Effect_Retention_State{target=count/2, layer_count=2}
		restore := baseline
		state = baseline
		switch operation {
		case "identical_redescription":
		case "one_layer_color": state.color_variant = true
		case "one_layer_inset": state.inset_variant = true
		case "remove_layer": state.layer_count = 1
		case "add_layer": restore.layer_count = 1
		case "resize_owner": state.resize_variant = true
		}
		// Isolate each recorded operation from the previous one. In particular,
		// the inset and size cases must not also reverse the prior color/layer
		// change while their timing is being captured.
		_, _, _, _ = effect_retention_run_description(
			&direct_rt, restore, .Direct_Children, owners_direct, "restore_workload_baseline")
		_, _, _, _ = effect_retention_run_description(
			&sidecar_rt, restore, .Sparse_Owner, owners_sidecar, "restore_workload_baseline")
		if !effect_retention_outputs_equal(&direct_rt, &sidecar_rt, direct_rt.display[:], sidecar_rt.display[:]) {
			fmt.eprintln("direct and sparse output differ after workload baseline restore", operation, "surfaces", count)
			os.exit(1)
		}
		direct_ns, direct_lowerings, direct_hits, direct_metrics := effect_retention_run_description(
			&direct_rt, state, .Direct_Children, owners_direct, operation)
		sidecar_ns, lowerings, hits, sidecar_metrics := effect_retention_run_description(
			&sidecar_rt, state, .Sparse_Owner, owners_sidecar, operation)
		if !effect_retention_outputs_equal(&direct_rt, &sidecar_rt, direct_rt.display[:], sidecar_rt.display[:]) {
			fmt.eprintln("direct and sparse output diverged after", operation, "surfaces", count)
			os.exit(1)
		}
		effect_retention_emit(.Direct_Children, count, operation, direct_ns, &direct_rt, direct_metrics,
			0, direct_lowerings, direct_hits)
		effect_retention_emit(.Sparse_Owner, count, operation, sidecar_ns, &sidecar_rt, sidecar_metrics,
			sidecar_entries, lowerings, hits)
	}

	// Exercise a moving retained owner independently of application descriptions.
	effect_retention_start_motion(&direct_rt, owners_direct[state.target])
	effect_retention_start_motion(&sidecar_rt, owners_sidecar[state.target])
	for sample in 0..<5 {
		at := alicorn.Motion_Time(i64(sample+1)*25_000_000)
		before_direct, before_sidecar := direct_rt.stats, sidecar_rt.stats
		start = time.now()
		_ = alicorn.motion_tick(&direct_rt, at)
		presentation_direct, ready_direct := alicorn.begin_presentation_frame(&direct_rt)
		if ready_direct { alicorn.end_presentation_frame(&presentation_direct) }
		direct_motion_ns := time.duration_nanoseconds(time.since(start))
		start = time.now()
		_ = alicorn.motion_tick(&sidecar_rt, at)
		presentation_sidecar, ready_sidecar := alicorn.begin_presentation_frame(&sidecar_rt)
		if ready_sidecar { alicorn.end_presentation_frame(&presentation_sidecar) }
		sidecar_motion_ns := time.duration_nanoseconds(time.since(start))
		if !effect_retention_outputs_equal(&direct_rt, &sidecar_rt, direct_rt.display[:], sidecar_rt.display[:]) {
			fmt.eprintln("animated owner effect output diverged", count, sample)
			os.exit(1)
		}
		fmt.println("retained_effect_motion", "surfaces", count, "sample", sample+1,
			"direct_ns", direct_motion_ns, "sidecar_ns", sidecar_motion_ns,
			"direct_layout_delta", direct_rt.stats.layout_nodes_visited-before_direct.layout_nodes_visited,
			"sidecar_layout_delta", sidecar_rt.stats.layout_nodes_visited-before_sidecar.layout_nodes_visited,
			"ordered_output_equal", true)
	}

	// Fast-forward to a settled state, then prove that another frame opportunity
	// does not re-describe, relayout, reshape, lower effects, or submit output.
	effect_retention_settle_motion(&direct_rt)
	effect_retention_settle_motion(&sidecar_rt)
	idle_before_direct, idle_before_sidecar := direct_rt.stats, sidecar_rt.stats
	_, direct_build := alicorn.begin_frame(&direct_rt)
	_, sidecar_build := alicorn.begin_frame(&sidecar_rt)
	fmt.println("retained_effect_idle", "surfaces", count,
		"direct_build_requested", direct_build, "sidecar_build_requested", sidecar_build,
		"direct_layout_delta", direct_rt.stats.layout_nodes_visited-idle_before_direct.layout_nodes_visited,
		"sidecar_layout_delta", sidecar_rt.stats.layout_nodes_visited-idle_before_sidecar.layout_nodes_visited,
		"direct_shape_delta", direct_rt.stats.text_shape_requests-idle_before_direct.text_shape_requests,
		"sidecar_shape_delta", sidecar_rt.stats.text_shape_requests-idle_before_sidecar.text_shape_requests,
		"direct_display_commands", len(direct_rt.display), "sidecar_cached_entries", sidecar_entries)
}

benchmark_effect_retained_owners :: proc() {
	fmt.println("Alicorn retained effect ownership prototype: direct positioned decoration nodes versus integrated issue-248 retained paint sidecar")
	fmt.println("Each surface also contains one unchanged text child; local visual edits are isolated to one middle surface. Output comparison ignores internal owner IDs but checks full resolved shapes and every surface paint field.")
	for count in EFFECT_RETENTION_COUNTS { effect_retention_benchmark_case(count) }
}
