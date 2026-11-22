package main

// Dogfood trace for issue #104 phase A. It describes the representative
// Scratchpad workload headlessly through the ordinary retained runtime, then
// counts the resolved display commands by shape and material. The Acetate
// host-spike is a flat rectangle scene with GPU geometry surfaces; its source
// survey is recorded by the runner because the application needs its C++
// backend library and cannot be described headlessly here.

import "core:fmt"
import alicorn "alicorn:runtime"
import scratchpad "alicorn:benchmarks/scratchpad_scene"
import ui "alicorn:ui"
import testui "alicorn:testui"

Dogfood_Counts :: struct {
	surfaces:        int,
	rounded:         int,
	flat:            int,
	relief:          int,
	heights_nonzero: int,
	other_commands:  int,
}

dogfood_count_display :: proc(rt: ^alicorn.Runtime, counts: ^Dogfood_Counts) {
	counts^ = {}
	if rt == nil { return }
	for command in rt.display {
		surface, is_surface := command.payload.(alicorn.Surface_Paint)
		if !is_surface {
			counts.other_commands += 1
			continue
		}
		counts.surfaces += 1
		if surface.shape.kind == .Rounded_Rectangle || surface.shape.kind == .Rounded_Rectangle_Per_Corner {
			counts.rounded += 1
		}
		if surface.physical_height != 0 { counts.heights_nonzero += 1 }
		material, ok := alicorn.style_material_resolve(rt, surface.material)
		if !ok || material.kind == .Flat {
			counts.flat += 1
		} else {
			counts.relief += 1
		}
	}
}

dogfood_print :: proc(name: string, counts: ^Dogfood_Counts, note: string) {
	fmt.printf(
		"[alicorn-material-dogfood] scene=%s surfaces=%d rounded=%d flat=%d relief=%d "+
		"heights_nonzero=%d other_commands=%d note=%s\n",
		name, counts.surfaces, counts.rounded, counts.flat, counts.relief,
		counts.heights_nonzero, counts.other_commands, note,
	)
}

Dogfood_Scratchpad_App :: struct {
	scene: scratchpad.Scene,
}

dogfood_scratchpad_render :: proc(app: ^Dogfood_Scratchpad_App, ctx: ^ui.UI) {
	scratchpad.scene_describe(&app.scene, ctx)
}

dogfood_scratchpad_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Dogfood_Scratchpad_App)state
	_ = scratchpad.register_theme(&app.scene, rt)
}

// A flat control scene reproduces the Acetate-shaped composition: square
// structural panels, a few rounded controls, and no relief material.
Dogfood_Flat_App :: struct {
	unused: u8,
}

dogfood_flat_render :: proc(app: ^Dogfood_Flat_App, ctx: ^ui.UI) {
	if ui.column(ctx, grow=1, padding=8, gap=6, clip=true, label="acetate-style-root") {
		if ui.row(ctx, height=32, gap=6, label="acetate-style-toolbar") {
			for index in 0..<6 {
				_ = ui.box(ctx, key=ui.key_u64(u64(index)), width=28, height=24,
					fill=alicorn.Color{0.22, 0.26, 0.32, 1}, radius=4)
			}
		}
		if ui.panel(ctx, width=-1, grow=1, padding=8, gap=4, fill=alicorn.Color{0.12, 0.15, 0.20, 1},
			label="acetate-style-waveform-panel") {
			for track in 0..<12 {
				if ui.row(ctx, key=ui.key_u64(100+u64(track)), height=24, gap=4, label="acetate-style-track") {
					for cell in 0..<20 {
						_ = ui.box(ctx, key=ui.key_u64(1000+u64(track*20+cell)), width=12, height=18,
							fill=alicorn.Color{0.30, 0.36, 0.44, 1})
					}
				}
			}
		}
	}
}

run_dogfood :: proc() -> bool {
	scratch_app := Dogfood_Scratchpad_App{}
	if !scratchpad.scene_init(&scratch_app.scene, .Typing, context.allocator) {
		fmt.eprintln("dogfood Scratchpad scene initialization failed")
		return false
	}
	defer scratchpad.scene_destroy(&scratch_app.scene)
	handle, status := testui.open(
		&scratch_app,
		dogfood_scratchpad_render,
		width=scratchpad.SCRATCHPAD_WIDTH,
		height=scratchpad.SCRATCHPAD_HEIGHT,
		initialize=dogfood_scratchpad_initialize,
	)
	if status != .Ok {
		fmt.eprintf("dogfood Scratchpad description failed: %v\n", status)
		return false
	}
	counts := Dogfood_Counts{}
	dogfood_count_display(handle.runtime, &counts)
	dogfood_print("scratchpad_scene", &counts, "scratchpad_scene_representative")
	testui.close(&handle)

	flat_app := Dogfood_Flat_App{}
	flat_handle, flat_status := testui.open(
		&flat_app,
		dogfood_flat_render,
		width=960,
		height=640,
	)
	if flat_status != .Ok {
		fmt.eprintf("dogfood flat scene description failed: %v\n", flat_status)
		return false
	}
	flat_counts := Dogfood_Counts{}
	dogfood_count_display(flat_handle.runtime, &flat_counts)
	dogfood_print("dogfood_flat_control", &flat_counts, "acetate_style_flat_control")
	testui.close(&flat_handle)
	return true
}
