#+build !js

package alicorn

import "core:mem"
import "core:testing"

Hosted_Chrome_Test_App :: struct {
	descriptions: int,
	pointer_events: int,
	last_pointer: Pointer_Event,
	chrome_paints: int,
}

hosted_chrome_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Chrome_Test_App)data
	app.descriptions += 1
	if container_begin(
		ui,
		.Root,
		label="hosted-chrome-test",
		key="hosted-chrome-test-root",
		style=layout_style(.Column, grow=1, padding=8),
		color=Color{0.1, 0.1, 0.1, 1},
	) != 0 {
		_, _ = button_ex(ui, "Body", key="hosted-chrome-body", style=layout_style(width=120, height=36))
		container_end(ui)
	}
}

hosted_chrome_test_init :: proc(_data: rawptr, rt: ^Runtime) {
	_ = text_engine_load_default_fonts(rt)
}

hosted_chrome_test_pointer :: proc(data: rawptr, _rt: ^Runtime, event: Pointer_Event, _target: Node_ID) {
	app := cast(^Hosted_Chrome_Test_App)data
	app.pointer_events += 1
	app.last_pointer = event
}

hosted_chrome_test_post :: proc(_data: rawptr) -> bool {
	return true
}

HOSTED_CHROME_TEST_MARKER :: Node_ID(0xFFFF_FFFF_FFFF_FF00)

hosted_chrome_test_paint :: proc(
	data: rawptr,
	_rt: ^Runtime,
	width, height: f32,
	allocator: mem.Allocator,
) -> []Paint_Command {
	app := cast(^Hosted_Chrome_Test_App)data
	if app != nil { app.chrome_paints += 1 }
	commands := make([dynamic]Paint_Command, 0, 1, allocator=allocator)
	if commands == nil { return nil }
	full := Rect{0, 0, width, 32}
	_ = append(&commands, paint_surface_command(HOSTED_CHROME_TEST_MARKER, full, full, Color{0.2, 0.2, 0.2, 1}))
	_ = height
	return commands[:]
}

hosted_chrome_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Chrome_Test_App,
	config: Hosted_Runtime_Config,
) -> Hosted_Runtime_Status {
	full := config
	full.state = rawptr(app)
	full.post_wake_data = rawptr(app)
	full.post_wake = hosted_chrome_test_post
	full.render = hosted_chrome_test_render
	full.on_initialize = hosted_chrome_test_init
	full.on_pointer = hosted_chrome_test_pointer
	return hosted_runtime_init(host, full)
}

@(test)
test_hosted_content_inset_reduces_viewport_and_translates_pointer :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Chrome_Test_App
	config := Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
		content_inset_top=32,
	}
	if hosted_chrome_test_open(&host, &app, config) != .Ok {
		testing.expect(t, false, "hosted chrome fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	rt, rt_status := hosted_runtime_borrow(&host)
	if rt_status != .Ok { testing.expect(t, false, "runtime should be borrowed"); return }
	testing.expect_value(t, rt.viewport.h, f32(268))
	step := hosted_runtime_step(&host, 1)
	testing.expect(t, step.status == .Ok && app.descriptions == 1, "description should run once")

	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=10, y=10})
	testing.expect(t, app.pointer_events == 0,
		"pointer input over host-owned chrome must not reach the application")

	target, _ := hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=10, y=40})
	testing.expect(t, app.pointer_events == 1 && app.last_pointer.y == 8,
		"application pointer coordinates subtract the chrome inset exactly once")
	_ = target

	handled, _ := hosted_runtime_scroll(&host, Scroll_Event{delta_y=-1, y=12})
	testing.expect(t, !handled, "wheel input over host-owned chrome is withheld")
	testing.expect(t, hosted_runtime_resize(&host, 400, 320, 800, 640, 2) == .Ok)
	testing.expect_value(t, rt.viewport.h, f32(288))
}

@(test)
test_hosted_presentation_shifts_app_paint_and_appends_chrome :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Chrome_Test_App
	config := Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
		content_inset_top=32,
		window_decorations=.Integrated_Title_Bar,
		chrome_paint=hosted_chrome_test_paint,
	}
	if hosted_chrome_test_open(&host, &app, config) != .Ok {
		testing.expect(t, false, "hosted chrome fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1)
	view, status := hosted_runtime_presentation_list(&host)
	if status != .Ok || len(view.commands) == 0 {
		testing.expect(t, false, "presentation list should contain app and chrome paint")
		return
	}
	chrome_index := -1
	for command, index in view.commands {
		if command.owner == HOSTED_CHROME_TEST_MARKER {
			chrome_index = index
			continue
		}
		testing.expect(t, command.bounds.y >= 32,
			"application paint is translated below the host chrome band")
	}
	testing.expect(t, chrome_index == len(view.commands)-1,
		"host chrome paint is appended after application paint")
	testing.expect(t, app.chrome_paints == 1, "the chrome paint provider runs once per presentation")

	// Without chrome or inset the retained list is borrowed unchanged.
	plain_host: Hosted_Runtime
	plain_app: Hosted_Chrome_Test_App
	if hosted_chrome_test_open(&plain_host, &plain_app, Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
	}) != .Ok { testing.expect(t, false, "plain fixture should initialize"); return }
	defer hosted_runtime_destroy(&plain_host)
	_ = hosted_runtime_step(&plain_host, 1)
	plain_view, _ := hosted_runtime_presentation_list(&plain_host)
	retained, _ := hosted_runtime_borrow(&plain_host)
	testing.expect(t, len(plain_view.commands) == len(retained.display),
		"a system-decorated surface returns the retained display list without staging")
}

@(test)
test_hosted_host_text_runs_resolve_and_release :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Chrome_Test_App
	if hosted_chrome_test_open(&host, &app, Hosted_Runtime_Config{
		logical_width=400, logical_height=300, pixel_width=800, pixel_height=600, dpi_scale=2,
	}) != .Ok { testing.expect(t, false, "fixture should initialize"); return }
	defer hosted_runtime_destroy(&host)
	rt, _ := hosted_runtime_borrow(&host)
	handle, ok := runtime_host_text_run_set(rt, 7, "File", 14)
	if !ok { testing.expect(t, false, "host text run should shape"); return }
	resolved, found := paint_text_run_resolve(rt, handle)
	testing.expect(t, found && resolved != nil && resolved.value == "File",
		"host paint can resolve a shaped host text resource")
	runtime_host_text_run_release(rt, 7)
	_, found = paint_text_run_resolve(rt, handle)
	testing.expect(t, !found, "released host text runs cannot be resolved")
}
