package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:host/sdl3"
import sdl_gpu "alicorn:native/sdl_gpu"
import ui "alicorn:ui"
import webgpu "alicorn:ui/webgpu"

// The workload matrix drives SDL_GPU and WebGPU through identical description
// and retained-motion sequences. One scene file is compiled into both host
// paths so backend differences are not application differences.
//
// Description scenarios use one worker wake per planned frame: the driver waits
// for the previous description, then posts one waker request. The host answers
// by invalidating and describing exactly once. This keeps the sequence
// identical on both renderers and makes description/wake counts assertable.
//
// Transform and multi-window scenarios declare the same retained motion and do
// not re-describe; each host's scheduler presents retained frames.

WORKLOAD_WINDOW_WIDTH :: 720
WORKLOAD_WINDOW_HEIGHT :: 480
WORKLOAD_CHILD_WIDTH :: 560
WORKLOAD_CHILD_HEIGHT :: 320
WORKLOAD_ROW_HEIGHT :: 24
WORKLOAD_VISIBLE_ROWS :: 8
WORKLOAD_SCROLL_STEP :: 12

Scenario :: enum {
	Demo,
	Identical,
	Transform,
	Color,
	Layout,
	Scroll,
	Multiwindow,
	Settled,
}

scenario_from_name :: proc(name: string) -> (Scenario, bool) {
	switch name {
	case "demo": return .Demo, true
	case "identical": return .Identical, true
	case "transform": return .Transform, true
	case "color": return .Color, true
	case "layout": return .Layout, true
	case "scroll": return .Scroll, true
	case "multiwindow": return .Multiwindow, true
	case "settled": return .Settled, true
	}
	return .Demo, false
}

scenario_name :: proc(scenario: Scenario) -> string {
	switch scenario {
	case .Demo: return "demo"
	case .Identical: return "identical"
	case .Transform: return "transform"
	case .Color: return "color"
	case .Layout: return "layout"
	case .Scroll: return "scroll"
	case .Multiwindow: return "multiwindow"
	case .Settled: return "settled"
	}
	return "unknown"
}

// Scene_State is the shared, backend-neutral workload state. Each window owns
// one so scroll identity and control animation stay per-window.
Scene_State :: struct {
	scenario:     Scenario,
	frame_index:  u64,
	item_count:   int,
	scroll_id:    alicorn.Node_ID,
	scroll_offset: f32,
}

App :: struct {
	scene: Scene_State,
	// Planned description frames. Motion scenarios use 1 because retained motion
	// presents without a description.
	frame_budget: u64,
	driver:       ^thread.Thread,
	frame_done:   sync.Sema,
	// frames_described is written on the UI thread and read by the driver.
	frames_described: u64,
	driver_stop:      int,
	waker:            ui.Application_Waker,
	wake_deliveries:  u64,
	rt:               ^alicorn.Runtime,
	start_tick:       time.Tick,
	first_describe_ns: u64,
	last_describe_ns:  u64,
	// Allocations are sampled at the first description and again at stop so the
	// report covers the scenario phase, not host startup.
	alloc_start: alicorn.Runtime_Allocation_Stats,
	alloc_valid: bool,
	child:       Child_App,
	child_requested: bool,
	close_child:  int,
	windows:     ui.UI_Window_Service,
	sdl_windows: sdl_gpu.Application_Window_Service,
	hosted_waker: alicorn.Hosted_Waker,
}

Child_App :: struct {
	scene: Scene_State,
	frames_described: u64,
	wake_deliveries:  u64,
	rt:               ^alicorn.Runtime,
	waker:            ui.Application_Waker,
	start_tick:       time.Tick,
	alloc_start:      alicorn.Runtime_Allocation_Stats,
	alloc_valid:      bool,
	stopped:          bool,
}

SURFACE_PRIMARY :: ui.Color{0.31, 0.65, 0.78, 1}
SURFACE_SECONDARY :: ui.Color{0.84, 0.53, 0.32, 1}
SURFACE_ACCENT :: ui.Color{0.46, 0.78, 0.52, 1}
SURFACE_MOVING :: ui.Color{0.36, 0.43, 0.86, 1}

// solid_box emits one retained solid paint without opening a deferred scope,
// so its begin/end pair stays inside this helper and the caller's layout scope
// is unaffected.
solid_box :: proc(ctx: ^ui.UI, key: ui.UI_Key, width, height: f32, color: ui.Color) -> alicorn.Node_ID {
	id := alicorn.container_begin(
		ctx,
		.Container,
		label="workload-solid",
		key=key,
		style=ui.layout_style(.Row, width=width, height=height),
		color=color,
	)
	alicorn.container_end(ctx)
	return id
}

// workload_content describes the shared scene. Callers own the Root scope so
// ui.run, raw host.Run, and hosted child windows all use one description.
workload_content :: proc(scene: ^Scene_State, ctx: ^ui.UI) {
	boxes := [3]ui.Color{SURFACE_PRIMARY, SURFACE_SECONDARY, SURFACE_ACCENT}
	animated := boxes[int(scene.frame_index % 3)]
	if ui.column(ctx, grow=1, padding=16, gap=8, clip=true, label="workload-root") {
		ui.text(ctx, "Alicorn workload matrix", size=22)
		ui.text(ctx, "Identical description and retained-motion sequences across renderers.")
		if ui.row(ctx, height=32, gap=8, label="static-swatches") {
			solid_box(ctx, ui.key_u64(1), 32, 24, boxes[0])
			solid_box(ctx, ui.key_u64(2), 32, 24, boxes[1])
			solid_box(ctx, ui.key_u64(3), 32, 24, boxes[2])
		}
		if ui.row(ctx, height=32, gap=8, label="moving-marker-row") {
			marker_color := SURFACE_MOVING
			if scene.scenario == .Color { marker_color = animated }
			marker := solid_box(ctx, ui.key_u64(10), 40, 24, marker_color)
			if scene.scenario == .Transform || scene.scenario == .Multiwindow {
				_ = ui.motion(
					ctx,
					marker,
					ui.Motion_Target{translation=ui.Motion_Vector2{160, 0}, has_translation=true},
					.Reveal,
					ui.Motion_Vector2{-160, 0},
				)
			}
		}
		if scene.scenario == .Layout {
			width := 40 + f32((scene.frame_index*13) % 120)
			if ui.row(ctx, height=24, gap=8, label="resized-row") {
				solid_box(ctx, ui.key_u64(11), width, 16, animated)
			}
		}
		ui.text(ctx, "Footer text is stationary across transform, color, and layout updates.")
		if scene.scenario == .Scroll {
			if list, ok := ui.virtual_list(
				ctx,
				scene.item_count,
				WORKLOAD_ROW_HEIGHT,
				key=ui.key_u64(20),
				height=WORKLOAD_ROW_HEIGHT*WORKLOAD_VISIBLE_ROWS,
				label="workload-virtual-list",
			); ok {
				scene.scroll_id = list.scroll.id
				for index in list.first..<list.last {
					ui.text(
						ctx,
						fmt.tprintf("Row %06d - retained item", index),
						key=ui.key_u64(1000+u64(index)),
						style=ui.layout_style(height=WORKLOAD_ROW_HEIGHT),
						decorative=true,
					)
				}
			}
		}
	}
}

describe_frame :: proc(app: ^App, ctx: ^ui.UI) {
	if app.rt == nil {
		app.rt = ctx.runtime
		app.start_tick = time.tick_now()
		if app.rt != nil && app.rt.allocation_stats != nil {
			app.alloc_start = app.rt.allocation_stats^
			app.alloc_valid = true
		}
	}
	app.frames_described += 1
	sync.atomic_store(&app.frames_described, app.frames_described)
	now_ns := u64(time.duration_nanoseconds(time.tick_diff(app.start_tick, time.tick_now())))
	if app.first_describe_ns == 0 { app.first_describe_ns = now_ns }
	app.last_describe_ns = now_ns
	workload_content(&app.scene, ctx)
	if app.driver != nil { sync.sema_post(&app.frame_done) }
}

// workload_wake advances one scenario step and requests exactly one new
// description. Scroll updates the retained scroll region directly, which
// invalidates the root itself.
workload_wake :: proc(app: ^App, ctx: ui.Application_Context) {
	app.wake_deliveries += 1
	if app.driver == nil { return }
	if app.scene.scenario == .Multiwindow {
		if sync.atomic_load(&app.close_child) != 0 {
			if app.sdl_windows.close != nil {
				sdl_gpu.application_close_window(app.sdl_windows)
			} else if app.windows.close != nil {
				alicorn.hosted_window_close(app.windows)
			}
		}
		return
	}
	rt := cast(^alicorn.Runtime)ctx
	if rt == nil { return }
	app.scene.frame_index += 1
	if app.scene.scenario == .Scroll {
		max_offset := (app.scene.item_count*WORKLOAD_ROW_HEIGHT)-(WORKLOAD_ROW_HEIGHT*WORKLOAD_VISIBLE_ROWS)
		if max_offset < 1 { max_offset = 1 }
		offset := (int(app.scene.frame_index)*WORKLOAD_SCROLL_STEP) % max_offset
		app.scene.scroll_offset = f32(offset)
		if app.scene.scroll_id == 0 ||
		   !alicorn.scroll_region_set_offset(rt, app.scene.scroll_id, app.scene.scroll_offset, "workload scroll step") {
			ui.invalidate(ctx, "workload scroll frame")
		}
		return
	}
	if app.scene.scenario == .Settled { return }
	ui.invalidate(ctx, "workload matrix frame")
}

workload_start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	if !scenario_has_driver(app.scene.scenario) && app.scene.scenario != .Multiwindow { return }
	app.driver = thread.create_and_start_with_data(rawptr(app), workload_driver, name="alicorn-workload-driver")
}

scenario_has_driver :: proc(scenario: Scenario) -> bool {
	return scenario == .Identical || scenario == .Color || scenario == .Layout ||
		scenario == .Scroll
}

workload_driver :: proc(data: rawptr) {
	app := cast(^App)data
	if app == nil { return }
	if app.scene.scenario == .Multiwindow {
		// Let both windows animate retained motion, then close the auxiliary
		// window from the owner thread. Closing before the primary smoke exit
		// avoids shutdown-time GPU fences spanning two windows.
		if !sync.sema_wait_with_timeout(&app.frame_done, 10*time.Second) { return }
		time.sleep(1500*time.Millisecond)
		if sync.atomic_load(&app.driver_stop) != 0 { return }
		sync.atomic_store(&app.close_child, 1)
		ui.wake(app.waker)
		return
	}
	for {
		if !sync.sema_wait_with_timeout(&app.frame_done, 10*time.Second) { return }
		if sync.atomic_load(&app.driver_stop) != 0 { return }
		if sync.atomic_load(&app.frames_described) >= app.frame_budget { return }
		// The sema is posted at the end of the description, before the host
		// submits that frame. A short pause lets the host complete submission so
		// each planned description is also a presented frame.
		time.sleep(25*time.Millisecond)
		if sync.atomic_load(&app.driver_stop) != 0 { return }
		ui.wake(app.waker)
	}
}

workload_stop :: proc(app: ^App) {
	workload_join_driver(app)
	workload_print_summary(app, "primary")
}

workload_join_driver :: proc(app: ^App) {
	if app.driver == nil { return }
	sync.atomic_store(&app.driver_stop, 1)
	sync.sema_post(&app.frame_done)
	thread.join(app.driver)
	thread.destroy(app.driver)
	app.driver = nil
}

allocation_calls_since :: proc(
	current, start: alicorn.Runtime_Allocation_Stats,
) -> (persistent_calls, scratch_calls: u64) {
	if current.persistent_alloc_calls >= start.persistent_alloc_calls {
		persistent_calls = current.persistent_alloc_calls-start.persistent_alloc_calls
	}
	if current.scratch_alloc_calls >= start.scratch_alloc_calls {
		scratch_calls = current.scratch_alloc_calls-start.scratch_alloc_calls
	}
	return
}

print_runtime_summary :: proc(role: string, rt: ^alicorn.Runtime, alloc_start: alicorn.Runtime_Allocation_Stats, alloc_valid: bool) {
	stats := alicorn.frame_stats_snapshot(rt)
	allocs := alicorn.Runtime_Allocation_Stats{}
	if rt.allocation_stats != nil { allocs = rt.allocation_stats^ }
	persistent_calls, scratch_calls := allocation_calls_since(allocs, alloc_start)
	if !alloc_valid {
		persistent_calls = 0
		scratch_calls = 0
	}
	fmt.printf(
		"[alicorn-workload-runtime] role=%s frames_built=%d idle_frames=%d descriptions_emitted=%d descriptions_reused=%d regions_skipped=%d retained_subtrees_reused=%d nodes_created=%d nodes_retired=%d layout_nodes_visited=%d paint_nodes_visited=%d display_commands_finalized=%d text_shape_requests=%d paint_updates=%d composite_updates=%d\n",
		role, stats.frames_built, stats.idle_frames, stats.descriptions_emitted,
		stats.descriptions_reused, stats.regions_skipped, stats.retained_subtrees_reused,
		stats.nodes_created, stats.nodes_retired, stats.layout_nodes_visited,
		stats.paint_nodes_visited, stats.display_commands_finalized,
		stats.text_shape_requests, stats.paint_updates, stats.composite_updates,
	)
	fmt.printf(
		"[alicorn-workload-alloc] role=%s persistent_alloc_calls=%d scratch_alloc_calls=%d persistent_bytes_live=%d\n",
		role, persistent_calls, scratch_calls, allocs.persistent_requested_bytes_live,
	)
}

workload_print_summary :: proc(app: ^App, role: string) {
	if app == nil || app.rt == nil { return }
	span := u64(0)
	if app.last_describe_ns >= app.first_describe_ns {
		span = app.last_describe_ns-app.first_describe_ns
	}
	fmt.printf(
		"[alicorn-workload] role=%s scenario=%s describe_calls=%d wake_deliveries=%d frames_planned=%d description_span_ns=%d\n",
		role, scenario_name(app.scene.scenario), app.frames_described, app.wake_deliveries,
		app.frame_budget, span,
	)
	print_runtime_summary(role, app.rt, app.alloc_start, app.alloc_valid)
}

workload_print_child_summary :: proc(child: ^Child_App) {
	if child == nil || child.rt == nil || child.stopped { return }
	child.stopped = true
	fmt.printf(
		"[alicorn-workload] role=auxiliary scenario=%s describe_calls=%d wake_deliveries=%d frames_planned=1 description_span_ns=0\n",
		scenario_name(child.scene.scenario), child.frames_described, child.wake_deliveries,
	)
	print_runtime_summary("auxiliary", child.rt, child.alloc_start, child.alloc_valid)
}

// ---- ui.run path (description scenarios and settled) ----------------------

run_render :: proc(app: ^App, ctx: ^ui.UI) {
	describe_frame(app, ctx)
}

// ---- raw SDL_GPU host path (multi-window scenario) -----------------------

raw_build :: proc(state: rawptr, rt: ^alicorn.Runtime, _width, _height: int, _dpi: f32) -> alicorn.Node_ID {
	app := cast(^App)state
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ctx,
		.Root,
		label="ui-root",
		key="alicorn.workload.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root != 0 {
		describe_frame(app, &ctx)
		alicorn.container_end(&ctx)
	}
	alicorn.end_frame(&ctx)
	return root
}

raw_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	workload_wake(app, ui.Application_Context(rt))
}

raw_start :: proc(state: rawptr, waker: sdl_gpu.Application_Waker) {
	app := cast(^App)state
	app.waker = ui.Application_Waker{data=waker.data, wake=waker.wake}
	if app.scene.scenario == .Multiwindow {
		app.driver = thread.create_and_start_with_data(rawptr(app), workload_driver, name="alicorn-workload-timer")
	}
}

raw_stop :: proc(state: rawptr) {
	app := cast(^App)state
	workload_join_driver(app)
	workload_print_summary(app, "primary")
}

raw_services :: proc(state: rawptr, services: sdl_gpu.Application_Services) {
	app := cast(^App)state
	app.sdl_windows = services.windows
	if app.scene.scenario != .Multiwindow || app.child_requested { return }
	app.child_requested = true
	child_application := sdl_gpu.Application{
		state=rawptr(&app.child),
		title="Alicorn workload child",
		width=WORKLOAD_CHILD_WIDTH,
		height=WORKLOAD_CHILD_HEIGHT,
		build=raw_child_build,
		on_start=raw_child_start,
		on_wake=raw_child_wake,
		on_stop=raw_child_stop,
		interaction_update_policy=.Explicit,
	}
	_ = sdl_gpu.application_open_window(services.windows, sdl_gpu.Application_Window_Description{
		application=child_application,
		width=WORKLOAD_CHILD_WIDTH,
		height=WORKLOAD_CHILD_HEIGHT,
	})
}

raw_child_build :: proc(state: rawptr, rt: ^alicorn.Runtime, _width, _height: int, _dpi: f32) -> alicorn.Node_ID {
	child := cast(^Child_App)state
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ctx,
		.Root,
		label="ui-root",
		key="alicorn.workload.child.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root != 0 {
		child.frames_described += 1
		sync.atomic_store(&child.frames_described, child.frames_described)
		if child.rt == nil {
			child.rt = rt
			child.start_tick = time.tick_now()
			if rt.allocation_stats != nil {
				child.alloc_start = rt.allocation_stats^
				child.alloc_valid = true
			}
		}
		workload_content(&child.scene, &ctx)
		alicorn.container_end(&ctx)
	}
	alicorn.end_frame(&ctx)
	return root
}

raw_child_start :: proc(state: rawptr, waker: sdl_gpu.Application_Waker) {
	child := cast(^Child_App)state
	child.waker = ui.Application_Waker{data=waker.data, wake=waker.wake}
}

raw_child_wake :: proc(state: rawptr, _rt: ^alicorn.Runtime) {
	child := cast(^Child_App)state
	child.wake_deliveries += 1
}

raw_child_stop :: proc(state: rawptr) {
	child := cast(^Child_App)state
	workload_print_child_summary(child)
}

// ---- hosted WebGPU multi-window path -------------------------------------

hosted_render :: proc(state: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	app := cast(^App)state
	if alicorn.container_begin(
		ctx, .Root, label="alicorn.workload.hosted.root", key="alicorn.workload.hosted.root",
		style=alicorn.layout_style(.Column, grow=1),
	) == 0 { return }
	describe_frame(app, ctx)
	alicorn.container_end(ctx)
}

hosted_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	workload_wake(app, ui.Application_Context(rt))
}

primary_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if !alicorn.text_engine_load_default_fonts(rt) { panic("workload fonts could not initialize") }
}

hosted_start :: proc(state: rawptr, waker: alicorn.Hosted_Waker) {
	app := cast(^App)state
	app.hosted_waker = waker
	app.waker = ui.Application_Waker{data=rawptr(&app.hosted_waker), wake=hosted_notify}
	if app.scene.scenario == .Multiwindow {
		app.driver = thread.create_and_start_with_data(rawptr(app), workload_driver, name="alicorn-workload-timer")
	}
}

hosted_notify :: proc(data: rawptr) {
	waker := cast(^alicorn.Hosted_Waker)data
	if waker != nil { _ = alicorn.hosted_waker_notify(waker^) }
}

hosted_stop :: proc(state: rawptr) {
	app := cast(^App)state
	workload_join_driver(app)
	workload_print_summary(app, "primary")
}

hosted_services :: proc(state: rawptr, services: alicorn.Hosted_Host_Services) {
	app := cast(^App)state
	app.windows = services.windows
	if app.scene.scenario != .Multiwindow || app.child_requested { return }
	app.child_requested = true
	child_config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&app.child),
		post_wake_data=rawptr(&app.child),
		post_wake=child_post_wake,
		render=hosted_child_render,
		on_wake=hosted_child_wake,
		on_stop=hosted_child_stop,
		on_initialize=child_initialize,
	}
	_ = alicorn.hosted_window_open(services.windows, alicorn.Hosted_Window_Description{
		title="Alicorn workload child",
		width=WORKLOAD_CHILD_WIDTH,
		height=WORKLOAD_CHILD_HEIGHT,
		config=child_config,
	})
}

child_post_wake :: proc(_data: rawptr) -> bool { return true }

child_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	child := cast(^Child_App)state
	if !alicorn.text_engine_load_default_fonts(rt) { panic("workload child fonts could not initialize") }
	child.rt = rt
	if rt.allocation_stats != nil {
		child.alloc_start = rt.allocation_stats^
		child.alloc_valid = true
	}
}

hosted_child_render :: proc(state: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	child := cast(^Child_App)state
	child.frames_described += 1
	sync.atomic_store(&child.frames_described, child.frames_described)
	if child.rt == nil { child.rt = ctx.runtime }
	if alicorn.container_begin(
		ctx, .Root, label="alicorn.workload.hosted.child.root", key="alicorn.workload.hosted.child.root",
		style=alicorn.layout_style(.Column, grow=1),
	) == 0 { return }
	workload_content(&child.scene, ctx)
	alicorn.container_end(ctx)
}

hosted_child_wake :: proc(state: rawptr, _rt: ^alicorn.Runtime) {
	child := cast(^Child_App)state
	child.wake_deliveries += 1
}

hosted_child_stop :: proc(state: rawptr) {
	child := cast(^Child_App)state
	workload_print_child_summary(child)
}

// ---- entry point ---------------------------------------------------------

parse_u64_arg :: proc(prefix: string, default: u64) -> u64 {
	for argument in os.args {
		if !strings.has_prefix(argument, prefix) { continue }
		value, ok := strconv.parse_u64(strings.trim_prefix(argument, prefix))
		if ok { return value }
	}
	return default
}

main :: proc() {
	scenario := Scenario.Identical
	smoke := false
	sdl_reference := false
	items := 1000
	frames := parse_u64_arg("--frames=", 32)
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
		if argument == "--backend=sdl-gpu" { sdl_reference = true }
		if strings.has_prefix(argument, "--workload=") {
			name := strings.trim_prefix(argument, "--workload=")
			parsed, ok := scenario_from_name(name)
			if !ok {
				fmt.eprintf("unknown workload %q\n", name)
				os.exit(2)
			}
			scenario = parsed
		}
		if strings.has_prefix(argument, "--items=") {
			value, ok := strconv.parse_int(strings.trim_prefix(argument, "--items="))
			if ok && value > 0 { items = value }
		}
	}
	if scenario == .Settled { frames = 1 }

	app := App{
		scene=Scene_State{scenario=scenario, item_count=items},
		frame_budget=frames,
	}
	app.child.scene = Scene_State{scenario=scenario, item_count=items}

	if scenario == .Multiwindow {
		app.frame_budget = 1
		if sdl_reference {
			application := sdl_gpu.Application{
				state=rawptr(&app),
				title="Alicorn workload matrix",
				width=WORKLOAD_WINDOW_WIDTH,
				height=WORKLOAD_WINDOW_HEIGHT,
				build=raw_build,
				on_start=raw_start,
				on_wake=raw_wake,
				on_services=raw_services,
				on_stop=raw_stop,
				interaction_update_policy=.Explicit,
			}
			sdl_gpu.Run(application, smoke=smoke)
			return
		}
		config := alicorn.Hosted_Runtime_Config{
			state=rawptr(&app),
			logical_width=WORKLOAD_WINDOW_WIDTH,
			logical_height=WORKLOAD_WINDOW_HEIGHT,
			pixel_width=WORKLOAD_WINDOW_WIDTH,
			pixel_height=WORKLOAD_WINDOW_HEIGHT,
			dpi_scale=1,
			post_wake_data=rawptr(&app),
			post_wake=hosted_post_wake,
			render=hosted_render,
			on_initialize=primary_initialize,
			on_host_services=hosted_services,
			on_start=hosted_start,
			on_wake=hosted_wake,
			on_stop=hosted_stop,
		}
		if result := host.sdl3_webgpu_run(
			config, "Alicorn workload matrix", WORKLOAD_WINDOW_WIDTH, WORKLOAD_WINDOW_HEIGHT,
			smoke=smoke,
		); result != .Ok {
			fmt.eprintf("workload WebGPU host exited with %v\n", result)
			os.exit(1)
		}
		return
	}

	if sdl_reference {
		ui.run(
			state=&app,
			render=run_render,
			title="Alicorn workload matrix",
			width=WORKLOAD_WINDOW_WIDTH,
			height=WORKLOAD_WINDOW_HEIGHT,
			on_start=workload_start,
			on_wake=workload_wake,
			on_stop=workload_stop,
			smoke=smoke,
		)
		return
	}
	webgpu.run(
		state=&app,
		render=run_render,
		title="Alicorn workload matrix",
		width=WORKLOAD_WINDOW_WIDTH,
		height=WORKLOAD_WINDOW_HEIGHT,
		on_start=workload_start,
		on_wake=workload_wake,
		on_stop=workload_stop,
		smoke=smoke,
	)
}

hosted_post_wake :: proc(_data: rawptr) -> bool { return true }
