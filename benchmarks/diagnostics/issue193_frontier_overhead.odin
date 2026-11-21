// Issue #193 release zero-overhead proof.
//
// One deterministic scene, one source, two release builds that differ only in
// `-define:ALICORN_INVALIDATION_FRONTIER` (the gate is additionally short-
// circuited by ODIN_DEBUG, so release code is identical). The fixture prints
// exact Frame_Stats, global retained-work reasons, allocation statistics, and
// structure sizes, then a separate timing line that is compared by median.
//
//   odin build benchmarks\diagnostics\issue193_frontier_overhead.odin -file `
//       -collection:alicorn=. -o:speed -define:ALICORN_INVALIDATION_FRONTIER=false `
//       -out:out\issue193_frontier_off.exe
//   odin build benchmarks\diagnostics\issue193_frontier_overhead.odin -file `
//       -collection:alicorn=. -o:speed -define:ALICORN_INVALIDATION_FRONTIER=true `
//       -out:out\issue193_frontier_on.exe
package main

import "core:fmt"
import "core:slice"
import "core:time"
import alicorn "alicorn:runtime"

OVERHEAD_ROW_COUNT :: 256
OVERHEAD_ACTIVE_UPDATES :: 64
OVERHEAD_IDLE_FRAMES :: 512
OVERHEAD_FONT :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

Overhead_App :: struct {
	revisions: [OVERHEAD_ROW_COUNT]u64,
	values: [OVERHEAD_ROW_COUNT]string,
}

overhead_describe :: proc(ui: ^alicorn.UI, app: ^Overhead_App) {
	alicorn.container_begin(ui, .Root, key=alicorn.key_string("overhead-root"),
		style=alicorn.layout_style(.Column, gap=2))
	panel, reused := alicorn.region_begin(ui, "overhead-panel", 1,
		style=alicorn.layout_style(.Column, width=300))
	if panel != 0 && !reused {
		for index in 0..<OVERHEAD_ROW_COUNT {
			id, cached := alicorn.region_begin(ui, fmt.tprintf("overhead-row-%d", index), app.revisions[index],
				style=alicorn.layout_style(.Row, width=280, height=20))
			if id == 0 || cached { continue }
			alicorn.text(ui, app.values[index], key=alicorn.key_u64(u64(index)),
				style=alicorn.layout_style(.Row, height=20))
			alicorn.region_end(ui, id, false, 0)
		}
		alicorn.region_end(ui, panel, false, 0)
	}
	alicorn.container_end(ui)
}

overhead_settle :: proc(rt: ^alicorn.Runtime, app: ^Overhead_App) -> int {
	for pass in 0..<4 {
		ui, build := alicorn.begin_frame(rt)
		if !build { return pass }
		overhead_describe(&ui, app)
		alicorn.end_frame(&ui)
	}
	fmt.println("HARD: description did not settle")
	return 4
}

main :: proc() {
	app: Overhead_App
	for index in 0..<OVERHEAD_ROW_COUNT {
		app.revisions[index] = 1
		app.values[index] = fmt.tprintf("Row %03d", index)
	}
	allocation: alicorn.Runtime_Allocation_Stats
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 600}, alicorn.Runtime_Config{
		trace_capacity=256,
		allocation_stats=&allocation,
	})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.font_load_bytes(&rt, .UI, OVERHEAD_FONT) {
		fmt.println("HARD: fixture font did not load")
		return
	}
	_ = overhead_settle(&rt, &app)
	for index in 0..<8 {
		app.values[index] = fmt.tprintf("Warmup %03d", index)
		app.revisions[index] += 1
		alicorn.invalidate_region(&rt, fmt.tprintf("overhead-row-%d", index), app.revisions[index], "warmup")
		_ = overhead_settle(&rt, &app)
	}

	samples: [OVERHEAD_ACTIVE_UPDATES]u64
	for index in 0..<OVERHEAD_ACTIVE_UPDATES {
		row := index%OVERHEAD_ROW_COUNT
		app.values[row] = fmt.tprintf("Row %03d updated %d", row, index)
		app.revisions[row] += 1
		start := time.now()
		alicorn.invalidate_region(&rt, fmt.tprintf("overhead-row-%d", row), app.revisions[row], "active update")
		_ = overhead_settle(&rt, &app)
		samples[index] = u64(time.duration_nanoseconds(time.since(start)))
	}
	active_allocation := allocation
	idle_frames := 0
	for _ in 0..<OVERHEAD_IDLE_FRAMES {
		_, build := alicorn.begin_frame(&rt)
		if !build { idle_frames += 1 }
	}
	ordered := slice.clone(samples[:])
	defer delete(ordered)
	slice.sort(ordered)
	p50 := ordered[len(ordered)/2]

	stats := rt.stats
	fmt.println("ISSUE193_AB_BEGIN")
	fmt.println("  size_of_runtime=", size_of(alicorn.Runtime),
		" size_of_frame_stats=", size_of(alicorn.Frame_Stats),
		" size_of_trace_event=", size_of(alicorn.Trace_Event),
		" size_of_inspector_cause=", size_of(alicorn.Inspector_Cause),
		" gate_enabled=", alicorn.frontier_capture_enabled())
	fmt.println("  frames_built=", stats.frames_built, " idle_frames=", stats.idle_frames,
		" observed_idle=", idle_frames)
	fmt.println("  descriptions_emitted=", stats.descriptions_emitted,
		" reused=", stats.descriptions_reused,
		" retained_match=", stats.descriptions_retained_match,
		" structure_sequence_matches=", stats.structure_sequence_matches)
	fmt.println("  reconcile=", stats.reconcile_nodes_visited, " layout=", stats.layout_nodes_visited,
		" paint=", stats.paint_nodes_visited, " composite=", stats.composition_nodes_visited)
	fmt.println("  measure_requests=", stats.measure_requests, " hits=", stats.measure_cache_hits,
		" misses=", stats.measure_cache_misses, " executed=", stats.measure_nodes_executed)
	fmt.println("  layout_updates=", stats.layout_updates, " paint_updates=", stats.paint_updates,
		" composite_updates=", stats.composite_updates,
		" text_shapes=", stats.text_shape_requests)
	fmt.println("  created=", stats.nodes_created, " retired=", stats.nodes_retired,
		" regions_skipped=", stats.regions_skipped,
		" subtrees_reused=", stats.retained_subtrees_reused,
		" adjacency_rebuilds=", stats.adjacency_rebuilds)
	fmt.println("  global_fallbacks=", stats.global_fallbacks,
		" semantic_changes=", stats.semantic_structure_changes+stats.semantic_property_changes)
	fmt.print("  global_work_by_reason=")
	first := true
	for reason in alicorn.Retained_Global_Work_Reason {
		if !first { fmt.print(",") }
		fmt.print(alicorn.frontier_work_reason_name(reason), ":", stats.global_work_by_reason[reason])
		first = false
	}
	fmt.println()
	fmt.println("  persistent_requested_bytes_live=", allocation.persistent_requested_bytes_live,
		" peak=", allocation.persistent_requested_bytes_peak,
		" alloc_calls=", allocation.persistent_alloc_calls,
		" free_calls=", allocation.persistent_free_calls)
	fmt.println("  scratch_requested_bytes_epoch=", allocation.scratch_requested_bytes_epoch,
		" peak=", allocation.scratch_requested_bytes_peak,
		" alloc_calls=", allocation.scratch_alloc_calls,
		" resets=", allocation.scratch_resets)
	fmt.println("  idle_persistent_alloc_call_delta=", allocation.persistent_alloc_calls-active_allocation.persistent_alloc_calls,
		" idle_scratch_alloc_call_delta=", allocation.scratch_alloc_calls-active_allocation.scratch_alloc_calls,
		" idle_persistent_byte_delta=", allocation.persistent_requested_bytes_live-active_allocation.persistent_requested_bytes_live)
	fmt.println("  active_update_p50_ns=", p50)
	fmt.println("ISSUE193_AB_END")
}
