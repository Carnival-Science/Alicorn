package main

// GO/NO-GO measurement fixture for issue 218. Run with:
//   odin test examples/18_composable_select_parts -define:ODIN_TEST_THREADS=1
// and filter for PILOT lines. The same scripted input turns are applied to the
// stock select_control and the userland select_parts package.

import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import alicorn "alicorn:runtime"
import parts "./select_parts"
import testui "alicorn:testui"
import theme "alicorn:theme"

PILOT_COUNT :: 12

Pilot_Option :: struct {
	key: u64,
	label: string,
	disabled: bool,
}

pilot_options :: proc() -> [PILOT_COUNT]Pilot_Option {
	options: [PILOT_COUNT]Pilot_Option
	for index in 0..<PILOT_COUNT {
		options[index] = Pilot_Option{key=u64(index+1), label=fmt.tprintf("Option %02d", index+1)}
	}
	options[8].disabled = true
	options[11].label = "Target"
	return options
}

Pilot_Stock_App :: struct {
	selected: u64,
	options: [PILOT_COUNT]alicorn.Select_Option,
}

pilot_stock_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Pilot_Stock_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="pilot-stock-root", key="pilot-stock-root",
		style=alicorn.layout_style(.Column, width=300, height=260, padding=12))
	result := alicorn.select_control(&ctx, alicorn.key_string("pilot-stock"), "Pilot", app.options[:], app.selected)
	if result.changed { app.selected = result.selected_key }
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return root
}

Pilot_Parts_App :: struct {
	selected: u64,
	state: parts.Select_Parts_State,
	recipe: parts.Select_Parts_Recipe,
	theme: alicorn.Style_Theme_ID,
	options: [PILOT_COUNT]parts.Select_Parts_Option,
	groups: [1]parts.Select_Parts_Group,
}

pilot_parts_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Pilot_Parts_App)state
	registration := theme.theme_json_register(rt, string(parts.DEFAULT_THEME_JSON), "examples/18_composable_select_parts/select_parts/theme.json")
	defer theme.theme_json_register_result_destroy(&registration)
	app.theme = registration.theme_id
	for option, index in pilot_options() {
		app.options[index] = parts.Select_Parts_Option{key=option.key, label=option.label, disabled=option.disabled}
	}
	app.groups[0] = parts.Select_Parts_Group{options=app.options[:]}
	app.state.selected_key = app.selected
}

pilot_parts_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Pilot_Parts_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="pilot-parts-root", key="pilot-parts-root",
		style=alicorn.layout_style(.Column, width=320, height=260, padding=12))
	scope := alicorn.style_environment_push(&ctx, alicorn.Style_Environment{theme=app.theme})
	if parts.select_parts(&ctx, "Pilot", &app.state, app.groups[:], app.recipe, key=alicorn.key_string("pilot-parts"), instance_id=8801) {
		app.selected = app.state.selected_key
	}
	alicorn.style_environment_pop(&ctx, scope)
	alicorn.container_end(&ctx)
	_ = parts.select_parts_overlay(&ctx, "Pilot", &app.state, app.groups[:], app.recipe, 8801)
	alicorn.end_frame(&ctx)
	return root
}

Pilot_Allocation_Site :: struct {
	procedure: string,
	line: i32,
	allocations: u64,
	bytes: u64,
}

Pilot_Allocation_State :: struct {
	backing: mem.Allocator,
	sites: [dynamic]Pilot_Allocation_Site,
	allocations: u64,
	bytes: u64,
}

pilot_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := cast(^Pilot_Allocation_State)data
	result, err := state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		state.allocations += 1
		state.bytes += u64(size)
		for &site in state.sites {
			if site.procedure == loc.procedure && site.line == loc.line {
				site.allocations += 1
				site.bytes += u64(size)
				return result, err
			}
		}
		if len(state.sites) < 512 {
			append(&state.sites, Pilot_Allocation_Site{procedure=loc.procedure, line=i32(loc.line), allocations=1, bytes=u64(size)})
		}
	}
	return result, err
}

Pilot_Metrics :: struct {
	turns: int,
	descriptions: u64,
	descriptions_reused: u64,
	reconcile: u64,
	measure: u64,
	layout: u64,
	paint: u64,
	composition: u64,
	text_shape_requests: u64,
	semantic_structure: u64,
	semantic_properties: u64,
	allocations: u64,
	allocated_bytes: u64,
	latencies: [64]u64,
	idle_wakes: int,
}

pilot_measure_step :: proc(metrics: ^Pilot_Metrics, handle: ^testui.Test_Handle($T), input: testui.Input) -> testui.Status {
	start := time.now()
	status := testui.step(handle, input)
	elapsed := u64(time.duration_nanoseconds(time.since(start)))
	pilot_record_work(metrics, handle.last_turn.work, elapsed)
	return status
}

pilot_record_work :: proc(metrics: ^Pilot_Metrics, work: testui.Turn_Work, elapsed: u64) {
	metrics.turns += 1
	metrics.descriptions += work.descriptions_emitted
	metrics.descriptions_reused += work.descriptions_reused
	metrics.reconcile += work.reconcile_nodes_visited
	metrics.measure += work.measure_nodes_examined
	metrics.layout += work.layout_nodes_visited
	metrics.paint += work.paint_nodes_visited
	metrics.composition += work.composition_nodes_visited
	metrics.text_shape_requests += work.text_shape_requests
	metrics.semantic_structure += work.semantic_structure_changes
	metrics.semantic_properties += work.semantic_property_changes
	if metrics.turns-1 < len(metrics.latencies) { metrics.latencies[metrics.turns-1] = elapsed }
}

pilot_measure_click :: proc(metrics: ^Pilot_Metrics, handle: ^testui.Test_Handle($T), name: string) -> testui.Status {
	trigger := testui.find(handle, testui.Query{role=.Combo_Box, name=name, match_role=true, match_name=true})
	if trigger.match != .Unique { testui.destroy_find_result(&trigger); return .Not_Realized }
	start := time.now()
	status := testui.click(handle, &trigger.element)
	elapsed := u64(time.duration_nanoseconds(time.since(start)))
	testui.destroy_find_result(&trigger)
	if status != .Ok { return status }
	pilot_record_work(metrics, handle.last_turn.work, elapsed)
	return .Ok
}

pilot_percentile :: proc(values: []u64, fraction: f64) -> u64 {
	if len(values) == 0 { return 0 }
	for index in 1..<len(values) {
		value := values[index]
		cursor := index
		for cursor > 0 && value < values[cursor-1] {
			values[cursor] = values[cursor-1]
			cursor -= 1
		}
		values[cursor] = value
	}
	index := int(fraction*f64(len(values)-1)+0.5)
	return values[clamp(index, 0, len(values)-1)]
}

pilot_run_stock :: proc(metrics: ^Pilot_Metrics, allocation: ^Pilot_Allocation_State) -> bool {
	app := Pilot_Stock_App{selected=2}
	options := pilot_options()
	for option, index in options { app.options[index] = alicorn.Select_Option{key=option.key, label=option.label, disabled=option.disabled} }
	allocator := mem.Allocator{procedure=pilot_allocator_proc, data=allocation}
	handle, status := testui.open(&app, width=300, height=260, allocator=allocator, build_application=pilot_stock_build)
	defer if handle.runtime != nil { testui.close(&handle) }
	if status != .Ok { return false }
	if pilot_measure_click(metrics, &handle, "Pilot") != .Ok { return false }
	inputs := [6]testui.Input{
		{kind=.Text_Commit, text="t"},
		{kind=.Key, key=.Down},
		{kind=.Key, key=.Home},
		{kind=.Key, key=.End},
		{kind=.Key, key=.Return},
		{kind=.Key, key=.Escape},
	}
	for input in inputs { if pilot_measure_step(metrics, &handle, input) != .Ok { return false } }
	if testui.advance_time(&handle, 16_000_000) != .Ok { return false }
	if handle.runtime.invalidated || alicorn.presentation_needs_frame(handle.runtime) { metrics.idle_wakes += 1 }
	return true
}

pilot_parts_text_input :: proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Input_Event) {
	app := cast(^Pilot_Parts_App)state
	if event.kind == .Commit && len(event.text) > 0 {
		_ = parts.select_parts_text(rt, &app.state, app.groups[:], event.text)
	}
}

pilot_parts_text_key :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app := cast(^Pilot_Parts_App)state
	return parts.select_parts_text_key(rt, &app.state, app.groups[:], event)
}

pilot_run_parts :: proc(metrics: ^Pilot_Metrics, allocation: ^Pilot_Allocation_State) -> bool {
	app := Pilot_Parts_App{selected=2, recipe=parts.recipe_default(.Compact)}
	app.state.selected_key = 2
	allocator := mem.Allocator{procedure=pilot_allocator_proc, data=allocation}
	handle, status := testui.open(&app, width=320, height=260, allocator=allocator,
		initialize=pilot_parts_initialize, build_application=pilot_parts_build,
		on_text_input=pilot_parts_text_input, on_text_key=pilot_parts_text_key)
	defer if handle.runtime != nil { testui.close(&handle) }
	if status != .Ok { return false }
	if pilot_measure_click(metrics, &handle, "Pilot") != .Ok { return false }
	inputs := [6]testui.Input{
		{kind=.Text_Commit, text="t"},
		{kind=.Key, key=.Down},
		{kind=.Key, key=.Home},
		{kind=.Key, key=.End},
		{kind=.Key, key=.Return},
		{kind=.Key, key=.Escape},
	}
	for input in inputs { if pilot_measure_step(metrics, &handle, input) != .Ok { return false } }
	if testui.advance_time(&handle, 16_000_000) != .Ok { return false }
	if handle.runtime.invalidated || alicorn.presentation_needs_frame(handle.runtime) { metrics.idle_wakes += 1 }
	return true
}

pilot_print :: proc(label: string, metrics: Pilot_Metrics, allocation: Pilot_Allocation_State) {
	fmt.println("PILOT", label, "turns", metrics.turns,
		"descriptions", metrics.descriptions, "descriptions_reused", metrics.descriptions_reused,
		"reconcile", metrics.reconcile, "measure", metrics.measure, "layout", metrics.layout,
		"paint", metrics.paint, "composition", metrics.composition,
		"text_shape_requests", metrics.text_shape_requests,
		"semantic_structure", metrics.semantic_structure, "semantic_properties", metrics.semantic_properties)
	latency_values := metrics.latencies
	latencies := latency_values[:]
	count := min(metrics.turns, len(latencies))
	fmt.println("PILOT", label, "allocations", allocation.allocations, "allocated_bytes", allocation.bytes,
		"p50_turn_ns", pilot_percentile(latencies[:count], 0.50),
		"p95_turn_ns", pilot_percentile(latencies[:count], 0.95),
		"idle_wakes", metrics.idle_wakes)
	order := make([]int, len(allocation.sites))
	defer delete(order)
	for index in 0..<len(order) { order[index] = index }
	for index in 1..<len(order) {
		value := order[index]
		cursor := index
		for cursor > 0 && allocation.sites[value].bytes > allocation.sites[order[cursor-1]].bytes {
			order[cursor] = order[cursor-1]
			cursor -= 1
		}
		order[cursor] = value
	}
	for rank in 0..<min(5, len(order)) {
		site := allocation.sites[order[rank]]
		fmt.println("PILOT", label, "site", site.procedure, "line", site.line,
			"allocations", site.allocations, "bytes", site.bytes)
	}
}

@(test)
test_select_parts_pilot_measure_stock_against_parts :: proc(t: ^testing.T) {
	stock_allocation := Pilot_Allocation_State{backing=context.allocator}
	stock_allocation.sites = make([dynamic]Pilot_Allocation_Site, 0, 256, allocator=context.allocator)
	defer delete(stock_allocation.sites)
	stock_metrics := Pilot_Metrics{}
	if !testing.expect(t, pilot_run_stock(&stock_metrics, &stock_allocation), "the stock pilot script should complete") { return }

	parts_allocation := Pilot_Allocation_State{backing=context.allocator}
	parts_allocation.sites = make([dynamic]Pilot_Allocation_Site, 0, 256, allocator=context.allocator)
	defer delete(parts_allocation.sites)
	parts_metrics := Pilot_Metrics{}
	if !testing.expect(t, pilot_run_parts(&parts_metrics, &parts_allocation), "the parts pilot script should complete") { return }

	pilot_print("stock", stock_metrics, stock_allocation)
	pilot_print("parts", parts_metrics, parts_allocation)
	testing.expect(t, parts_metrics.turns == stock_metrics.turns,
		"both implementations should complete the same scripted turn count")
}
