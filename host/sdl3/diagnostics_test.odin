#+build !js

package sdl3_host

import "core:testing"
import alicorn "alicorn:runtime"
import diag "alicorn:host/diagnostics"
import "vendor:sdl3"

@(test)
test_diagnostics_keys_match_reference_precedence :: proc(t: ^testing.T) {
	diagnostics := SDL3_Diagnostics{}
	testing.expect(t, !diagnostics.hud.visible, "the performance HUD starts hidden")
	testing.expect(t, sdl3_diagnostics_key(&diagnostics, sdl3.K_F10, {}, false),
		"bare F10 toggles the HUD and is consumed before application key routing")
	testing.expect(t, diagnostics.hud.visible, "first F10 shows the HUD")
	testing.expect(t, !sdl3_diagnostics_key(&diagnostics, sdl3.K_F10, {.LSHIFT}, false),
		"Shift+F10 stays available to the application context menu")
	testing.expect(t, !sdl3_diagnostics_key(&diagnostics, sdl3.K_F10, {}, true),
		"a held F10 does not retoggle the HUD")
	testing.expect(t, diagnostics.hud.visible, "the HUD stays visible after ignored F10 variants")

	testing.expect(t, !sdl3_diagnostics_key(&diagnostics, sdl3.K_F11, {}, false),
		"F11 is a host effect that does not consume the application key")
	testing.expect(t, diagnostics.debug_bounds, "F11 enables retained-bounds inspection")
	testing.expect(t, !sdl3_diagnostics_key(&diagnostics, sdl3.K_F11, {}, false),
		"F11 remains non-consuming")
	testing.expect(t, !diagnostics.debug_bounds, "second F11 disables bounds inspection")

	testing.expect(t, !sdl3_diagnostics_key(&diagnostics, sdl3.K_F12, {}, false),
		"F12 is a host effect that does not consume the application key")
	testing.expect(t, diagnostics.options.capture_requested,
		"F12 requests one diagnostic capture")
}

@(test)
test_diagnostics_paint_is_empty_until_an_overlay_is_enabled :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	diagnostics := SDL3_Diagnostics{}
	commands := sdl3_diagnostics_paint(rawptr(&diagnostics), &rt, 800, 600, context.temp_allocator)
	testing.expect(t, len(commands) == 0,
		"a hidden HUD and disabled bounds inspection contribute no paint")

	diagnostics.debug_bounds = true
	commands = sdl3_diagnostics_paint(rawptr(&diagnostics), &rt, 800, 600, context.temp_allocator)
	testing.expect(t, len(commands) == 0,
		"an empty retained display has no bounds to outline")
}

@(test)
test_diagnostics_paint_emits_hud_surface_commands :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	diagnostics := SDL3_Diagnostics{}
	diagnostics.hud.visible = true
	diag.record(&diagnostics.recorder, diag.Sample{
		timestamp_ns=u64(sdl3.GetTicksNS()), app_builds=1, gpu_submissions=1,
	})
	commands := sdl3_diagnostics_paint(rawptr(&diagnostics), &rt, 800, 600, context.temp_allocator)
	testing.expect(t, len(commands) > 100,
		"a visible HUD contributes its panel, text, and activity strip")
	all_host_owned := true
	for command in commands {
		if command.owner != 0 { all_host_owned = false }
	}
	testing.expect(t, all_host_owned,
		"HUD geometry is host-owned and never claims an application node")
}

@(test)
test_diagnostics_paint_bounds_follow_retained_commands :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 200, 200})
	defer alicorn.destroy_runtime(&rt)
	ui, ready := alicorn.begin_frame(&rt)
	if !ready { testing.expect(t, false, "runtime frame should open"); return }
	if alicorn.container_begin(&ui, .Root, label="root", style=alicorn.layout_style(.Column, grow=1)) != 0 {
		if alicorn.container_begin(
			&ui, .Container, label="panel", key="panel",
			style=alicorn.layout_style(width=80, height=40),
			color=alicorn.Color{1, 1, 1, 1},
		) != 0 {
			alicorn.container_end(&ui)
		}
		alicorn.container_end(&ui)
	}
	alicorn.end_frame(&ui)
	diagnostics := SDL3_Diagnostics{}
	diagnostics.debug_bounds = true
	commands := sdl3_diagnostics_paint(rawptr(&diagnostics), &rt, 200, 200, context.temp_allocator)
	testing.expect(t, len(commands) > 0,
		"retained bounds produce outline paint for the visible command")
	for command in commands {
		testing.expect(t, alicorn.paint_command_is_surface(command),
			"bounds outlines use ordinary surface paint")
	}
}
