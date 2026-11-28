package main

import "core:fmt"
import "core:os"
import "core:time"
import alicorn "alicorn:runtime"

OWNER_COUNT :: 3000
SAMPLES     :: 21

Benchmark_State :: struct {
	styled_count: int,
	color_variant: bool,
}

Benchmark_Metrics :: struct {
	reconcile: u64,
	measure: u64,
	layout: u64,
	paint: u64,
	finalized: u64,
}

benchmark_describe :: proc(
	rt: ^alicorn.Runtime,
	state: Benchmark_State,
	owners: []alicorn.Node_ID,
) -> bool {
	alicorn.invalidate_root(rt, "issue 248 flat-scene overhead benchmark")
	ui, build := alicorn.begin_frame(rt)
	if !build { return false }
	alicorn.container_begin(&ui, .Root,
		key=alicorn.key_string("issue248-overhead-root"),
		style=alicorn.layout_style(.Column, width=-1, height=-1))
	for index in 0..<OWNER_COUNT {
		owner_key := u64(index+1)
		owner := alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Surface),
			key=alicorn.key_u64(owner_key),
			style=alicorn.layout_style(.Column, width=280, height=44, clip=true),
			fill=alicorn.Color{0.105, 0.135, 0.185, 1},
			stroke=alicorn.Paint_Stroke{color={0.24, 0.29, 0.37, 1}, width=1},
			stroke_placement=.Inside,
			label="overhead benchmark surface")
		owners[index] = owner
		if index < state.styled_count {
			accent := alicorn.Color{0.92, 0.57, 0.24, 0.14}
			if index == state.styled_count/2 && state.color_variant {
				accent = alicorn.Color{0.20, 0.70, 0.96, 0.20}
			}
			for layer_index in 0..<2 {
				inset := f32(layer_index+1)
				decoration := alicorn.surface_begin(&ui, alicorn.surface_core_color_role(.Accent),
					key=alicorn.key_pair(owner_key, u64(0xD000+layer_index)),
					style=alicorn.layout_style(.Column, width=280-2*inset, height=44-2*inset, clip=true),
					fill=accent,
					stroke=alicorn.Paint_Stroke{color={0.72, 0.49, 0.24, 0.58}, width=1},
					stroke_placement=.Inside,
					label="direct issue 248 effect layer")
				alicorn.surface_end(&ui)
			if decoration == 0 || !alicorn.position_child(&ui, decoration,
				alicorn.positioned(inset, inset, clip=true)) {
				fmt.eprintln("issue 248 overhead decoration setup failed", index, layer_index)
				return false
			}
			}
		}
		alicorn.surface_end(&ui)
	}
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return rt.diagnostic == ""
}

benchmark_sort :: proc(values: []i64) {
	for index in 1..<len(values) {
		value := values[index]
		cursor := index
		for cursor > 0 && values[cursor-1] > value {
			values[cursor] = values[cursor-1]
			cursor -= 1
		}
		values[cursor] = value
	}
}

benchmark_metrics :: proc(rt: ^alicorn.Runtime, before: alicorn.Frame_Stats) -> Benchmark_Metrics {
	return Benchmark_Metrics{
		reconcile=rt.stats.reconcile_nodes_visited-before.reconcile_nodes_visited,
		measure=rt.stats.measure_nodes_executed-before.measure_nodes_executed,
		layout=rt.stats.layout_nodes_visited-before.layout_nodes_visited,
		paint=rt.stats.paint_nodes_visited-before.paint_nodes_visited,
		finalized=rt.stats.display_commands_finalized-before.display_commands_finalized,
	}
}

benchmark_case :: proc(name: string, styled_count: int) {
	allocation_stats: alicorn.Runtime_Allocation_Stats
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1280, 900},
		alicorn.Runtime_Config{allocation_stats=&allocation_stats})
	owners := make([]alicorn.Node_ID, OWNER_COUNT)
	state := Benchmark_State{styled_count=styled_count}
	started := time.now()
	if !benchmark_describe(&rt, state, owners) {
		fmt.eprintln("issue 248 overhead initial description failed", name)
		os.exit(1)
	}
	initial_ns := time.duration_nanoseconds(time.since(started))

	redescribe_samples: [SAMPLES]i64
	last_metrics: Benchmark_Metrics
	for sample in 0..<SAMPLES {
		before := rt.stats
		started = time.now()
		if !benchmark_describe(&rt, state, owners) {
			fmt.eprintln("issue 248 overhead re-description failed", name, sample)
			os.exit(1)
		}
		redescribe_samples[sample] = time.duration_nanoseconds(time.since(started))
		last_metrics = benchmark_metrics(&rt, before)
	}
	benchmark_sort(redescribe_samples[:])

	local_state := state
	local_state.color_variant = true
	before := rt.stats
	started = time.now()
	if !benchmark_describe(&rt, local_state, owners) {
		fmt.eprintln("issue 248 overhead local edit failed", name)
		os.exit(1)
	}
	local_change_ns := time.duration_nanoseconds(time.since(started))
	local_metrics := benchmark_metrics(&rt, before)

	motion_owner_index := 0
	if styled_count > 0 { motion_owner_index = styled_count/2 }
	motion_owner := owners[motion_owner_index]
	_ = alicorn.motion_clock_set_time(&rt, 0)
	motion_handle, motion_status := alicorn.motion_owner_begin(&rt, motion_owner)
	if motion_status != .Ok || alicorn.motion_target_translation(&rt, motion_handle,
		alicorn.Motion_Vector2{18, 0},
		alicorn.Motion_Config{omega=20, position_tolerance=0.01, velocity_tolerance=0.05},
		.Settle, 0) != .Ok {
		fmt.eprintln("issue 248 overhead motion setup failed", name)
		os.exit(1)
	}
	motion_samples: [SAMPLES]i64
	motion_layout_visits := u64(0)
	for sample in 0..<SAMPLES {
		before_layout := rt.stats.layout_nodes_visited
		started = time.now()
		_ = alicorn.motion_tick(&rt, alicorn.Motion_Time(i64(sample+1)*25_000_000))
		presentation, ready := alicorn.begin_presentation_frame(&rt)
		if ready { alicorn.end_presentation_frame(&presentation) }
		motion_samples[sample] = time.duration_nanoseconds(time.since(started))
		motion_layout_visits += rt.stats.layout_nodes_visited-before_layout
	}
	benchmark_sort(motion_samples[:])

	fmt.println("issue248_overhead",
		"workload", name,
		"surfaces", OWNER_COUNT,
		"styled_surfaces", styled_count,
		"initial_ns", initial_ns,
		"identical_redescription_p50_ns", redescribe_samples[SAMPLES/2],
		"identical_redescription_p95_ns", redescribe_samples[(SAMPLES*95+99)/100-1],
		"identical_reconcile_visits", last_metrics.reconcile,
		"identical_layout_visits", last_metrics.layout,
		"identical_paint_visits", last_metrics.paint,
		"local_change_ns", local_change_ns,
		"local_reconcile_visits", local_metrics.reconcile,
		"local_layout_visits", local_metrics.layout,
		"local_paint_visits", local_metrics.paint,
		"local_finalized_commands", local_metrics.finalized,
		"motion_p50_ns", motion_samples[SAMPLES/2],
		"motion_p95_ns", motion_samples[(SAMPLES*95+99)/100-1],
		"motion_layout_visits_total", motion_layout_visits,
		"live_nodes", len(rt.nodes),
		"display_commands", len(rt.display),
		"persistent_live_bytes", allocation_stats.persistent_requested_bytes_live)
	alicorn.destroy_runtime(&rt)
	delete(owners)
}

main :: proc() {
	fmt.println("issue248_overhead_protocol", "owner_count", OWNER_COUNT,
		"redescription_samples", SAMPLES,
		"boundary", "runtime description/layout/paint; no native GPU submission or process RSS")
	benchmark_case("flat", 0)
	benchmark_case("mixed_5_percent", OWNER_COUNT/20)
	benchmark_case("fully_styled", OWNER_COUNT)
}
