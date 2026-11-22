package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import alicorn "alicorn:runtime"
import scratchpad "alicorn:benchmarks/scratchpad_scene"
import ui "alicorn:ui"
import webgpu "alicorn:ui/webgpu"

// material_stream drives one treatment and one condition through the ordinary
// retained description path. The identical stream is also used by the
// offscreen GPU sweep (offscreen.odin) and the dogfood probe (dogfood.odin).
//
// Window runs deliberately do not emulate scales by resizing the window:
// Windows reports one display scale per monitor, so the scale dimension is
// measured on the same GPU through the offscreen target sweep.

App :: struct {
	scene:            Material_Scene,
	condition:        Condition,
	frame_budget:     u64,
	passes:           u64,
	driver:           ^thread.Thread,
	frame_done:       sync.Sema,
	driver_stop:      int,
	waker:            ui.Application_Waker,
	wake_deliveries:  u64,
	rt:               ^alicorn.Runtime,
	backend:          string,
	description_ns:   [MATERIAL_STREAM_PASSES]u64,
	description_count: int,
	start_tick:       time.Tick,
	// use_scratchpad swaps the synthetic stream for the representative
	// Scratchpad scene from the issue #229 workload. The material measurements
	// stay on the synthetic stream; this variant checks the same conditions on
	// an ordinary retained application composition.
	use_scratchpad:   bool,
	interaction:      scratchpad.Interaction,
	scratch:          scratchpad.Scene,
	scratch_step:     u64,
}

describe_pass :: proc(app: ^App, ctx: ^ui.UI) {
	before := time.tick_now()
	if app.use_scratchpad {
		scratchpad.scene_describe(&app.scratch, ctx)
	} else {
		material_scene_describe(&app.scene, ctx)
	}
	elapsed := u64(time.duration_nanoseconds(time.tick_since(before)))
	if app.description_count < MATERIAL_STREAM_PASSES {
		app.description_ns[app.description_count] = elapsed
	}
	app.description_count += 1
	app.passes += 1
	sync.atomic_store(&app.passes, app.passes)
	if app.driver != nil { sync.sema_post(&app.frame_done) }
}

run_render :: proc(app: ^App, ctx: ^ui.UI) {
	// ui.run owns the Root scope for the SDL_GPU path.
	describe_pass(app, ctx)
}

hosted_render :: proc(app: ^App, ctx: ^ui.UI) {
	// ui/webgpu.run gives root ownership to the application.
	if alicorn.container_begin(
		ctx, .Root, label="material-stream-hosted-root", key="material.stream.hosted.root",
		style=alicorn.layout_style(.Column, grow=1),
	) == 0 { return }
	describe_pass(app, ctx)
	alicorn.container_end(ctx)
}

application_initialize :: proc(app: ^App, rt: ^alicorn.Runtime) {
	app.rt = rt
	if app.use_scratchpad {
		if !scratchpad.register_theme(&app.scratch, rt) {
			fmt.eprintln("scratchpad variant theme registration failed")
		}
	} else {
		material_scene_register(&app.scene, rt)
	}
	if !alicorn.text_engine_load_default_fonts(rt) {
		fmt.eprintln("material stream fonts could not initialize")
	}
}

application_start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	if app.frame_budget <= 1 { return }
	app.start_tick = time.tick_now()
	app.driver = thread.create_and_start_with_data(rawptr(app), condition_driver, name="material-stream-driver")
}

application_wake :: proc(app: ^App, ctx: ui.Application_Context) {
	app.wake_deliveries += 1
	rt := cast(^alicorn.Runtime)ctx
	if rt == nil || app.scene.condition == .Idle || app.passes >= app.frame_budget { return }
	if app.use_scratchpad {
		if app.passes <= 1 {
			_ = scratchpad.scene_focus_field(&app.scratch, rt)
		} else {
			app.scratch_step += 1
			_ = scratchpad.scene_apply_step(&app.scratch, rt, app.scratch_step)
		}
		return
	}
	_ = material_scene_advance(&app.scene, rt)
}

application_stop :: proc(app: ^App) {
	if app.driver != nil {
		sync.atomic_store(&app.driver_stop, 1)
		sync.sema_post(&app.frame_done)
		thread.join(app.driver)
		thread.destroy(app.driver)
		app.driver = nil
	}
	print_summary(app)
}

condition_driver :: proc(data: rawptr) {
	app := cast(^App)data
	if app == nil { return }
	for {
		if !sync.sema_wait_with_timeout(&app.frame_done, 10*time.Second) { return }
		if sync.atomic_load(&app.driver_stop) != 0 { return }
		if sync.atomic_load(&app.passes) >= app.frame_budget { return }
		// Let the host finish presenting the previous frame so every planned
		// description is also a presented frame.
		time.sleep(20*time.Millisecond)
		if sync.atomic_load(&app.driver_stop) != 0 { return }
		ui.wake(app.waker)
	}
}

percentile_from_sorted :: proc(sorted: []u64, fraction: f64) -> u64 {
	if len(sorted) == 0 { return 0 }
	index := int(fraction*f64(len(sorted)-1))
	return sorted[index]
}

sort_samples :: proc(values: []u64) {
	for index in 1..<len(values) {
		value := values[index]
		position := index
		for position > 0 && values[position-1] > value {
			values[position] = values[position-1]
			position -= 1
		}
		values[position] = value
	}
}

print_summary :: proc(app: ^App) {
	if app == nil { return }
	measured := min(app.description_count, MATERIAL_STREAM_PASSES)
	values := app.description_ns
	sort_samples(values[:measured])
	span := u64(0)
	if app.start_tick != (time.Tick{}) {
		span = u64(time.duration_nanoseconds(time.tick_since(app.start_tick)))
	}
	if app.use_scratchpad {
		fmt.printf(
			"[alicorn-material-stream] role=primary backend=%s scene=scratchpad interaction=%s "+
			"passes=%d planned=%d wake_deliveries=%d display_commands=%d nodes=%d "+
			"description_span_ns=%d description_p50_ns=%d description_p95_ns=%d description_p99_ns=%d\n",
			app.backend, scratchpad.interaction_name(app.interaction),
			app.passes, app.frame_budget, app.wake_deliveries,
			len(app.rt.display) if app.rt != nil else 0,
			len(app.rt.nodes) if app.rt != nil else 0,
			span,
			percentile_from_sorted(values[:measured], 0.50),
			percentile_from_sorted(values[:measured], 0.95),
			percentile_from_sorted(values[:measured], 0.99),
		)
		return
	}
	fmt.printf(
		"[alicorn-material-stream] role=primary backend=%s treatment=%s condition=%s "+
		"passes=%d planned=%d wake_deliveries=%d commands=%d cards=%d rows=%d realized_rows=%d "+
		"display_commands=%d nodes=%d "+
		"description_span_ns=%d description_p50_ns=%d description_p95_ns=%d description_p99_ns=%d\n",
		app.backend, app.scene.treatment.name, condition_name(app.condition),
		app.passes, app.frame_budget, app.wake_deliveries,
		MATERIAL_STREAM_CARDS+MATERIAL_STREAM_ROWS, MATERIAL_STREAM_CARDS,
		MATERIAL_STREAM_ROWS, app.scene.realized_rows,
		len(app.rt.display) if app.rt != nil else 0,
		len(app.rt.nodes) if app.rt != nil else 0,
		span,
		percentile_from_sorted(values[:measured], 0.50),
		percentile_from_sorted(values[:measured], 0.95),
		percentile_from_sorted(values[:measured], 0.99),
	)
}

parse_arg :: proc(prefix: string) -> (string, bool) {
	for argument in os.args {
		if strings.has_prefix(argument, prefix) {
			return strings.trim_prefix(argument, prefix), true
		}
	}
	return "", false
}

main :: proc() {
	mode := "window"
	if value, ok := parse_arg("--mode="); ok { mode = value }
	if mode == "offscreen" {
		os.exit(run_offscreen() ? 0 : 1)
	}
	if mode == "dogfood" {
		os.exit(run_dogfood() ? 0 : 1)
	}

	backend := "sdl-gpu"
	if value, ok := parse_arg("--backend="); ok { backend = value }
	scene_name := "material"
	if value, ok := parse_arg("--scene="); ok { scene_name = value }
	use_scratchpad := scene_name == "scratchpad"
	interaction := scratchpad.Interaction.Typing
	if value, ok := parse_arg("--interaction="); ok {
		parsed, parsed_ok := scratchpad.interaction_from_name(value)
		if !parsed_ok {
			fmt.eprintf("unknown scratchpad interaction %q\n", value)
			os.exit(2)
		}
		interaction = parsed
	}
	treatment_name := TREATMENTS[0].name
	if value, ok := parse_arg("--treatment="); ok { treatment_name = value }
	treatment, treatment_ok := treatment_from_name(treatment_name)
	if !treatment_ok {
		fmt.eprintf("unknown treatment %q\n", treatment_name)
		os.exit(2)
	}
	condition := Condition.Warm_Steady
	if value, ok := parse_arg("--condition="); ok {
		parsed, parsed_ok := condition_from_name(value)
		if !parsed_ok {
			fmt.eprintf("unknown condition %q\n", value)
			os.exit(2)
		}
		condition = parsed
	}
	passes := condition_passes(condition)
	if value, ok := parse_arg("--passes="); ok {
		if parsed, parsed_ok := strconv.parse_int(value); parsed_ok && parsed > 0 { passes = parsed }
	}
	smoke := false
	for argument in os.args { if argument == "--smoke" { smoke = true } }

	app := App{
		condition=condition,
		frame_budget=u64(passes),
		backend=backend,
		use_scratchpad=use_scratchpad,
		interaction=interaction,
	}
	app.scene.treatment = treatment
	app.scene.condition = condition
	if use_scratchpad {
		if !scratchpad.scene_init(&app.scratch, interaction, context.allocator) {
			fmt.eprintln("scratchpad variant scene initialization failed")
			os.exit(1)
		}
	}

	if backend == "sdl-gpu" {
		ui.run(
			state=&app,
			render=run_render,
			title="Alicorn material stream",
			width=MATERIAL_STREAM_WIDTH,
			height=MATERIAL_STREAM_HEIGHT,
			smoke=smoke,
			on_initialize=application_initialize,
			on_start=application_start,
			on_wake=application_wake,
			on_stop=application_stop,
		)
		if use_scratchpad { scratchpad.scene_destroy(&app.scratch) }
		return
	}
	if backend == "d3d12" || backend == "vulkan" {
		// ui/webgpu.run reads the backend flag from os.args.
		webgpu.run(
			state=&app,
			render=hosted_render,
			title="Alicorn material stream",
			width=MATERIAL_STREAM_WIDTH,
			height=MATERIAL_STREAM_HEIGHT,
			smoke=smoke,
			on_initialize=application_initialize,
			on_start=application_start,
			on_wake=application_wake,
			on_stop=application_stop,
		)
		if use_scratchpad { scratchpad.scene_destroy(&app.scratch) }
		return
	}
	fmt.eprintf("unknown backend %q\n", backend)
	os.exit(2)
}
