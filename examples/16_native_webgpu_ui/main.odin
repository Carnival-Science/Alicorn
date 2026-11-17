package main

import "core:fmt"
import "core:os"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

Child_App :: struct {
	windows: ui.UI_Window_Service,
	close_requested: bool,
	open_failed: bool,
}

App :: struct {
	count: int,
	name: ui.Text_Buffer,
	windows: ui.UI_Window_Service,
	child: Child_App,
	open_child_on_services: bool,
	child_open_accepted: bool,
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Native WebGPU UI", size=24)
		ui.text(ctx, "The retained runtime and surface presenter are shared with the browser host.")
		if ui.button(ctx, "Increment") { app.count += 1 }
		ui.text(ctx, fmt.tprintf("Button activations: %d", app.count))
		ui.text_field(ctx, "Try native text input", &app.name)
		if ui.button(ctx, "Open auxiliary window") {
			app.child_open_accepted = open_auxiliary_window(app)
		}
		if app.child_open_accepted { ui.text(ctx, "Auxiliary window request accepted") }
		if app.child.open_failed { ui.text(ctx, "Auxiliary window could not be created") }
	}
}

auxiliary_render :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	child := cast(^Child_App)data
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Independent retained surface", size=22)
		ui.text(ctx, "This window has its own focus, input state, and Runtime on the shared WebGPU device.")
		if ui.button(ctx, "Close auxiliary window") {
			child.close_requested = true
			ui.ui_window_close(child.windows)
		}
	}
}

auxiliary_post_wake :: proc(_data: rawptr) -> bool {
	// The SDL3 host replaces this placeholder with its per-window wake event.
	return true
}

auxiliary_initialize :: proc(_data: rawptr, rt: ^alicorn.Runtime) {
	if !alicorn.text_engine_load_default_fonts(rt) { panic("could not initialize auxiliary text fonts") }
}

auxiliary_host_services :: proc(data: rawptr, services: alicorn.Hosted_Host_Services) {
	child := cast(^Child_App)data
	child.windows = services.windows
}

auxiliary_open_failed :: proc(data: rawptr) {
	child := cast(^Child_App)data
	child.open_failed = true
}

open_auxiliary_window :: proc(app: ^App) -> bool {
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&app.child),
		post_wake_data=rawptr(&app.child),
		post_wake=auxiliary_post_wake,
		render=auxiliary_render,
		on_initialize=auxiliary_initialize,
		on_host_services=auxiliary_host_services,
	}
	return ui.ui_window_open(app.windows, ui.UI_Window_Description{
		title="Alicorn auxiliary window",
		width=560,
		height=320,
		config=config,
		on_open_failed=auxiliary_open_failed,
	})
}

services :: proc(app: ^App, value: ui.UI_Host_Services) {
	app.windows = value.windows
	if app.open_child_on_services {
		app.child_open_accepted = open_auxiliary_window(app)
	}
}

stop :: proc(app: ^App) {
	ui.text_buffer_destroy(&app.name)
}

main :: proc() {
	name, ok := ui.text_buffer("Type here")
	if !ok { panic("could not allocate example text buffer") }
	app := App{name=name}
	smoke := false
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
		if argument == "--child-smoke" {
			smoke = true
			app.open_child_on_services = true
		}
	}
	ui.run_webgpu(&app, render, title="Alicorn · Native WebGPU", on_stop=stop, smoke=smoke, on_services=services)
}
