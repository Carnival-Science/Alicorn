#+build !js

package alicorn

import "core:mem"
import "core:testing"

// Diagnostics overlays are host paint, like chrome. They must be appended after
// application paint and chrome so an unmodified ui/webgpu.run consumer gets F10
// and F11 without any application-side composition.

HOSTED_DIAGNOSTICS_TEST_MARKER :: Node_ID(0xFFFF_FFFF_FFFF_FF01)

Hosted_Diagnostics_Test_App :: struct {
	diagnostics_paints: int,
	scratch_allocator_used: bool,
}

hosted_diagnostics_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Diagnostics_Test_App)data
	if app != nil { _ = app }
	if container_begin(
		ui,
		.Root,
		label="hosted-diagnostics-test",
		key="hosted-diagnostics-test-root",
		style=layout_style(.Column, grow=1, padding=0),
		color=Color{0.1, 0.1, 0.1, 1},
	) != 0 {
		container_end(ui)
	}
}

hosted_diagnostics_test_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_diagnostics_test_paint :: proc(
	data: rawptr,
	rt: ^Runtime,
	width, height: f32,
	allocator: mem.Allocator,
) -> []Paint_Command {
	app := cast(^Hosted_Diagnostics_Test_App)data
	if app != nil {
		app.diagnostics_paints += 1
		if rt != nil { app.scratch_allocator_used = allocator.data == rawptr(rt.scratch_allocator_state) }
	}
	commands := make([dynamic]Paint_Command, 0, 1, allocator=allocator)
	if commands == nil { return nil }
	_ = append(&commands, paint_surface_command(
		HOSTED_DIAGNOSTICS_TEST_MARKER,
		Rect{width-40, 0, 40, f32(height)},
		Rect{0, 0, width, height},
		Color{1, 0.78, 0.16, 0.72},
	))
	return commands[:]
}

hosted_diagnostics_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Diagnostics_Test_App,
	config: Hosted_Runtime_Config,
) -> Hosted_Runtime_Status {
	full := config
	full.state = rawptr(app)
	full.post_wake_data = rawptr(app)
	full.post_wake = hosted_diagnostics_test_post
	full.render = hosted_diagnostics_test_render
	full.diagnostics_paint = hosted_diagnostics_test_paint
	full.diagnostics_paint_data = rawptr(app)
	return hosted_runtime_init(host, full)
}

hosted_diagnostics_test_chrome :: proc(
	_data: rawptr,
	_rt: ^Runtime,
	width, _height: f32,
	allocator: mem.Allocator,
) -> []Paint_Command {
	commands := make([dynamic]Paint_Command, 0, 1, allocator=allocator)
	if commands == nil { return nil }
	_ = append(&commands, paint_surface_command(
		HOSTED_CHROME_TEST_MARKER,
		Rect{0, 0, width, 32},
		Rect{0, 0, width, 32},
		Color{0.2, 0.2, 0.2, 1},
	))
	return commands[:]
}

@(test)
test_hosted_diagnostics_paint_is_appended_after_application_and_chrome :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Diagnostics_Test_App
	config := Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
		content_inset_top=32,
		window_decorations=.Integrated_Title_Bar,
		chrome_paint=hosted_diagnostics_test_chrome,
		chrome_paint_data=rawptr(&app),
	}
	if hosted_diagnostics_test_open(&host, &app, config) != .Ok {
		testing.expect(t, false, "hosted diagnostics fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	view, status := hosted_runtime_presentation_list(&host)
	if status != .Ok || len(view.commands) == 0 {
		testing.expect(t, false, "presentation list should include diagnostic overlays")
		return
	}
	diagnostics_index := -1
	for command, index in view.commands {
		if command.owner == HOSTED_DIAGNOSTICS_TEST_MARKER {
			diagnostics_index = index
		}
	}
	testing.expect(t, diagnostics_index == len(view.commands)-1,
		"diagnostics paint is last so bounds and the HUD stay above chrome")
	testing.expect(t, app.diagnostics_paints == 1,
		"the diagnostics provider runs once per presentation")
	testing.expect(t, app.scratch_allocator_used,
		"host overlay paint is staged in the Runtime scratch arena, never persistent storage")
}

@(test)
test_hosted_diagnostics_absent_keeps_borrowed_fast_path :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Diagnostics_Test_App
	if hosted_diagnostics_test_open(&host, &app, Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
	}) != .Ok { testing.expect(t, false, "plain diagnostics fixture should initialize"); return }
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	view, _ := hosted_runtime_presentation_list(&host)
	testing.expect(t, len(view.commands) >= 1 &&
		view.commands[len(view.commands)-1].owner == HOSTED_DIAGNOSTICS_TEST_MARKER,
		"an installed diagnostics provider contributes the final overlay paint")
	testing.expect(t, app.diagnostics_paints == 1,
		"the provider is consulted once per presentation")
}
