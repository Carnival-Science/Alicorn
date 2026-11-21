// Issue #158 consumer-shaped validation benchmark.
//
// The scene mirrors Scratchpad's editor font picker: a viewport-sized modal
// overlay with 24-unit padding, a paint-bearing panel that requests 100% of the
// overlay's padded inner width capped at 900, and enough text/button rows to
// exercise retained measurement and paint. Two authoring variants produce the
// same behavior:
//
//   percentage - panel sizing width=percent(1), max_width=900
//   manual     - panel width=min(viewport.w-48, 900)
//
// Both variants rebuild the same application description on every measured
// frame so a resize trace includes equivalent description and layout work.
// This is not the Scratchpad executable; it is the same composition expressed
// with the consumer's API and measured with the runtime's own counters.
//
// Build with -o:speed and run fresh processes:
//
//   odin build benchmarks\diagnostics\issue158_percent_width_benchmark.odin -file -o:speed -collection:alicorn=. -out:out\issue158_percent_width_benchmark.exe
//   1..5 | ForEach-Object { .\out\issue158_percent_width_benchmark.exe }
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"

FONT_DATA :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

PICKER_ROWS :: 12
WARMUP_FRAMES :: 100
SAMPLE_FRAMES :: 2000
VIEWPORT_HEIGHT :: f32(800)
OVERLAY_PADDING :: f32(24)
PANEL_MAX_WIDTH :: f32(900)
NARROW_WIDTH :: f32(800)
WIDE_WIDTH :: f32(1200)

Picker_Mode :: enum {
	Percentage,
	Manual,
}

mode_name :: proc(mode: Picker_Mode) -> string {
	switch mode {
	case .Percentage: return "percentage"
	case .Manual:     return "manual"
	}
	return "unknown"
}

Frame_Sample :: struct {
	total_ns, describe_ns, layout_ns: i64,
}

Bench_Scene :: struct {
	mode: Picker_Mode,
	width: f32,
	deps: int,
	panel: alicorn.Node_ID,
}

bench_panel_declaration :: proc(mode: Picker_Mode, viewport_width: f32) -> gui.Sizing {
	max_height := gui.logical(min(700, max(VIEWPORT_HEIGHT-48, 1)))
	if mode == .Percentage {
		return gui.sizing(
			width=gui.percent(1),
			min_width=gui.logical(1),
			max_width=gui.logical(PANEL_MAX_WIDTH),
			max_height=max_height,
		)
	}
	width := min(viewport_width-2*OVERLAY_PADDING, PANEL_MAX_WIDTH)
	return gui.sizing(
		width=gui.logical(max(width, 1)),
		min_width=gui.logical(1),
		max_width=gui.logical(PANEL_MAX_WIDTH),
		max_height=max_height,
	)
}

bench_describe_picker :: proc(ctx: ^gui.UI, scene: ^Bench_Scene) {
	overlay := alicorn.modal_overlay_begin(ctx, alicorn.key_u64(2),
		style=alicorn.layout_style(.Column, grow=1, padding=OVERLAY_PADDING, align=.Center, justify=.Center))
	if overlay == 0 { return }
	if gui.panel(ctx,
		key=alicorn.key_u64(3),
		padding=16,
		gap=8,
		clip=true,
		sizing=bench_panel_declaration(scene.mode, scene.width),
		label="issue158-picker-panel",
	) {
		scene.panel = ctx.runtime.pending[len(ctx.runtime.pending)-1].description.id
		_ = gui.text(ctx, "Choose editor font", key=alicorn.key_u64(4),
			text_style=alicorn.Text_Style{font_size=20, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
		_ = gui.button(ctx, "Atkinson Hyperlegible Mono  ·  Monospaced  ·  bundled default",
			key=alicorn.key_u64(5), height=36, state=alicorn.Button_State{selected=true}, variant=.Quiet,
			text_style=alicorn.Text_Style{overflow=.Ellipsis})
		for index in 0..<PICKER_ROWS {
			label := fmt.tprintf("Font family %02d  ·  Monospaced", index)
			_ = gui.button(ctx, label, key=alicorn.key_u64(100+u64(index)), height=36,
				state=alicorn.Button_State{selected=index == 3}, variant=.Quiet,
				text_style=alicorn.Text_Style{overflow=.Ellipsis})
		}
		_ = gui.text(ctx, "12 monospaced · 128 proportional  ·  ↑/↓ navigate  ·  Enter select  ·  Esc close",
			key=alicorn.key_u64(6), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	}
	alicorn.modal_overlay_end(ctx)
}

// bench_measure_frame rebuilds the picker description and completes the frame,
// returning wall times for the application description and retained layout.
bench_measure_frame :: proc(rt: ^alicorn.Runtime, scene: ^Bench_Scene, width: f32) -> Frame_Sample {
	scene.width = width
	rt.viewport = alicorn.Rect{0, 0, width, VIEWPORT_HEIGHT}
	alicorn.invalidate_root(rt, "issue158 percentage validation frame")
	start := time.now()
	ctx, build := alicorn.begin_frame(rt)
	if !build { return {} }
	bench_describe_picker(&ctx, scene)
	describe_ns := time.duration_nanoseconds(time.since(start))
	alicorn.end_frame(&ctx)
	total_ns := time.duration_nanoseconds(time.since(start))
	return Frame_Sample{
		total_ns=total_ns,
		describe_ns=describe_ns,
		layout_ns=total_ns-describe_ns,
	}
}

bench_settle :: proc(rt: ^alicorn.Runtime, scene: ^Bench_Scene, width: f32) {
	for _ in 0..<4 {
		_ = bench_measure_frame(rt, scene, width)
		if !rt.invalidated { return }
	}
}

percentile95 :: proc(values: []i64) -> i64 {
	if len(values) == 0 { return 0 }
	sorted := make([]i64, len(values), context.temp_allocator)
	copy(sorted, values)
	slice.sort(sorted)
	index := int(math.ceil(f64(len(sorted))*0.95))-1
	return sorted[clamp(index, 0, len(sorted)-1)]
}

median :: proc(values: []i64) -> i64 {
	if len(values) == 0 { return 0 }
	sorted := make([]i64, len(values), context.temp_allocator)
	copy(sorted, values)
	slice.sort(sorted)
	return sorted[len(sorted)/2]
}

Bench_Report :: struct {
	case_name: string,
	mode: Picker_Mode,
	p50_total: i64,
	p95_total: i64,
	p50_describe: i64,
	p95_describe: i64,
	p50_layout: i64,
	p95_layout: i64,
	allocation_calls, allocation_bytes: u64,
	layout_updates, measure_hits, measure_misses: u64,
	descriptions_emitted, regions_skipped: u64,
	deps: int,
}

print_report :: proc(report: Bench_Report) {
	fmt.printf(
		"case=%s mode=%s p50_total_ns=%d p95_total_ns=%d p50_describe_ns=%d p95_describe_ns=%d p50_layout_ns=%d p95_layout_ns=%d persistent_alloc_calls=%d persistent_requested_bytes=%d layout_updates=%d measure_hits=%d measure_misses=%d descriptions_emitted=%d regions_skipped=%d percentage_dependencies=%d\n",
		report.case_name, mode_name(report.mode),
		report.p50_total, report.p95_total,
		report.p50_describe, report.p95_describe,
		report.p50_layout, report.p95_layout,
		report.allocation_calls, report.allocation_bytes,
		report.layout_updates, report.measure_hits, report.measure_misses,
		report.descriptions_emitted, report.regions_skipped, report.deps,
	)
}

run_description_case :: proc(mode: Picker_Mode, case_name: string, widths: []f32) -> Bench_Report {
	stats := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, WIDE_WIDTH, VIEWPORT_HEIGHT},
		alicorn.Runtime_Config{allocation_stats=&stats})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, FONT_DATA) {
		fmt.println("BENCHMARK FAILURE: fixture font did not load")
		os.exit(1)
	}
	scene := Bench_Scene{mode=mode, width=WIDE_WIDTH}
	bench_settle(&rt, &scene, WIDE_WIDTH)

	for _ in 0..<WARMUP_FRAMES {
		for width in widths {
			_ = bench_measure_frame(&rt, &scene, width)
		}
	}

	alloc_before := stats.persistent_alloc_calls
	bytes_before := stats.persistent_requested_bytes_live
	layout_before := rt.stats.layout_updates
	hits_before := rt.stats.measure_cache_hits
	misses_before := rt.stats.measure_cache_misses
	emitted_before := rt.stats.descriptions_emitted
	skipped_before := rt.stats.regions_skipped

	totals := make([dynamic]i64, 0, SAMPLE_FRAMES*len(widths), context.temp_allocator)
	describes := make([dynamic]i64, 0, SAMPLE_FRAMES*len(widths), context.temp_allocator)
	layouts := make([dynamic]i64, 0, SAMPLE_FRAMES*len(widths), context.temp_allocator)
	for _ in 0..<SAMPLE_FRAMES {
		for width in widths {
			sample := bench_measure_frame(&rt, &scene, width)
			append(&totals, sample.total_ns)
			append(&describes, sample.describe_ns)
			append(&layouts, sample.layout_ns)
		}
	}
	return Bench_Report{
		case_name=case_name,
		mode=mode,
		p50_total=median(totals[:]),
		p95_total=percentile95(totals[:]),
		p50_describe=median(describes[:]),
		p95_describe=percentile95(describes[:]),
		p50_layout=median(layouts[:]),
		p95_layout=percentile95(layouts[:]),
		allocation_calls=stats.persistent_alloc_calls-alloc_before,
		allocation_bytes=u64(max(stats.persistent_requested_bytes_live-bytes_before, 0)),
		layout_updates=rt.stats.layout_updates-layout_before,
		measure_hits=rt.stats.measure_cache_hits-hits_before,
		measure_misses=rt.stats.measure_cache_misses-misses_before,
		descriptions_emitted=rt.stats.descriptions_emitted-emitted_before,
		regions_skipped=rt.stats.regions_skipped-skipped_before,
		deps=len(rt.percent_width_dependencies),
	}
}

// run_idle_case measures settled single-thread host polls. A settled retained
// tree should reject every begin_frame without describing, laying out, or
// waking recurring work in either authoring variant.
run_idle_case :: proc(mode: Picker_Mode) -> Bench_Report {
	stats := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, WIDE_WIDTH, VIEWPORT_HEIGHT},
		alicorn.Runtime_Config{allocation_stats=&stats})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_font(&rt.text_engine, FONT_DATA) {
		fmt.println("BENCHMARK FAILURE: fixture font did not load")
		os.exit(1)
	}
	scene := Bench_Scene{mode=mode, width=WIDE_WIDTH}
	bench_settle(&rt, &scene, WIDE_WIDTH)
	// Drain any pending description request before timing idle polls.
	if rt.invalidated {
		_ = bench_measure_frame(&rt, &scene, WIDE_WIDTH)
	}

	alloc_before := stats.persistent_alloc_calls
	bytes_before := stats.persistent_requested_bytes_live
	layout_before := rt.stats.layout_updates
	idle_before := rt.stats.idle_frames
	totals := make([dynamic]i64, 0, SAMPLE_FRAMES, context.temp_allocator)
	for _ in 0..<SAMPLE_FRAMES {
		start := time.now()
		_, build := alicorn.begin_frame(&rt)
		elapsed := time.duration_nanoseconds(time.since(start))
		if build {
			fmt.println("BENCHMARK FAILURE: settled picker requested a description")
			os.exit(1)
		}
		append(&totals, elapsed)
	}
	if rt.stats.idle_frames-idle_before != SAMPLE_FRAMES {
		fmt.printf("BENCHMARK FAILURE: expected %d idle frames, saw %d\n",
			SAMPLE_FRAMES, rt.stats.idle_frames-idle_before)
		os.exit(1)
	}
	return Bench_Report{
		case_name="idle",
		mode=mode,
		p50_total=median(totals[:]),
		p95_total=percentile95(totals[:]),
		p50_describe=0, p95_describe=0, p50_layout=0, p95_layout=0,
		allocation_calls=stats.persistent_alloc_calls-alloc_before,
		allocation_bytes=u64(max(stats.persistent_requested_bytes_live-bytes_before, 0)),
		layout_updates=rt.stats.layout_updates-layout_before,
		measure_hits=0, measure_misses=0, descriptions_emitted=0, regions_skipped=0,
		deps=len(rt.percent_width_dependencies),
	}
}

// assert_geometry_parity compares the two authoring variants at the narrow and
// capped widths using fresh runtimes. Both must produce identical panel and row
// geometry for the same neighborhood of inputs.
assert_geometry_parity :: proc() {
	widths := [2]f32{NARROW_WIDTH, WIDE_WIDTH}
	for width in widths {
		percentage_stats := alicorn.Runtime_Allocation_Stats{}
		percentage := alicorn.new_runtime(alicorn.Rect{0, 0, width, VIEWPORT_HEIGHT},
			alicorn.Runtime_Config{allocation_stats=&percentage_stats})
		manual_stats := alicorn.Runtime_Allocation_Stats{}
		manual := alicorn.new_runtime(alicorn.Rect{0, 0, width, VIEWPORT_HEIGHT},
			alicorn.Runtime_Config{allocation_stats=&manual_stats})
		if !alicorn.text_engine_load_font(&percentage.text_engine, FONT_DATA) ||
			!alicorn.text_engine_load_font(&manual.text_engine, FONT_DATA) {
			fmt.println("BENCHMARK FAILURE: parity fixture font did not load")
			os.exit(1)
		}
		percentage_scene := Bench_Scene{mode=.Percentage, width=width}
		manual_scene := Bench_Scene{mode=.Manual, width=width}
		bench_settle(&percentage, &percentage_scene, width)
		bench_settle(&manual, &manual_scene, width)
		percentage_panel, percentage_ok := alicorn.node_by_key(&percentage, alicorn.key_u64(3), .Container)
		manual_panel, manual_ok := alicorn.node_by_key(&manual, alicorn.key_u64(3), .Container)
		if !percentage_ok || !manual_ok ||
			percentage.nodes[percentage_panel].bounds != manual.nodes[manual_panel].bounds {
			fmt.printf("BENCHMARK FAILURE: panel geometry differs at width %.0f: percentage=%v manual=%v\n",
				width, percentage.nodes[percentage_panel].bounds, manual.nodes[manual_panel].bounds)
			os.exit(1)
		}
		for index in 0..<PICKER_ROWS {
			percentage_row, row_ok := alicorn.node_by_key(&percentage, alicorn.key_u64(100+u64(index)), .Button)
			manual_row, manual_row_ok := alicorn.node_by_key(&manual, alicorn.key_u64(100+u64(index)), .Button)
			if !row_ok || !manual_row_ok ||
				percentage.nodes[percentage_row].bounds != manual.nodes[manual_row].bounds {
				fmt.printf("BENCHMARK FAILURE: row %d geometry differs at width %.0f\n", index, width)
				os.exit(1)
			}
		}
		if len(manual.percent_width_dependencies) != 0 || manual.percent_width_sidecar_initialized {
			fmt.println("BENCHMARK FAILURE: manual-width baseline allocated percentage sidecar state")
			os.exit(1)
		}
		fmt.printf("parity width=%.0f panel_w=%.3f percentage_dependencies=%d manual_dependencies=%d PASS\n",
			width, percentage.nodes[percentage_panel].bounds.w,
			len(percentage.percent_width_dependencies), len(manual.percent_width_dependencies))

		alicorn.destroy_runtime(&percentage)
		alicorn.destroy_runtime(&manual)
	}
}

main :: proc() {
	fmt.println("Alicorn #158 consumer-shaped percentage-width validation benchmark")
	build_kind := "debug"
	when !ODIN_DEBUG { build_kind = "release" }
	fmt.printf("build=%s sample_frames=%d warmup_frames=%d rows=%d widths=%.0f,%.0f cap=%.0f\n",
		build_kind, SAMPLE_FRAMES, WARMUP_FRAMES, PICKER_ROWS, NARROW_WIDTH, WIDE_WIDTH, PANEL_MAX_WIDTH)

	assert_geometry_parity()

	same_width := []f32{WIDE_WIDTH}
	resize := []f32{NARROW_WIDTH, WIDE_WIDTH}
	for mode in ([]Picker_Mode{.Percentage, .Manual}) {
		print_report(run_description_case(mode, "same_width", same_width))
		print_report(run_description_case(mode, "resize_cap_release", resize))
		print_report(run_idle_case(mode))
	}
	fmt.println("desc=correctness rows=12 show=direction footer=ellipsis text=ellipsis")
}
