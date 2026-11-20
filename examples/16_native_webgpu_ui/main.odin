package main

import "core:fmt"
import "core:os"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"
import webgpu "alicorn:ui/webgpu"

Child_App :: struct {
	windows: ui.UI_Window_Service,
	close_requested: bool,
	open_failed: bool,
}

App :: struct {
	count: int,
	wake_deliveries: int,
	waker: ui.Application_Waker,
	name: ui.Text_Buffer,
	timing_motion: bool,
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
		if ui.button(ctx, "Queue application wake") { ui.wake(app.waker) }
		ui.text(ctx, fmt.tprintf("Application wake callbacks: %d", app.wake_deliveries))
		ui.text_field(ctx, "Try native text input", &app.name)
		if ui.button(ctx, "Open auxiliary window") {
			app.child_open_accepted = open_auxiliary_window(app)
		}
		if app.child_open_accepted { ui.text(ctx, "Auxiliary window request accepted") }
		if app.child.open_failed { ui.text(ctx, "Auxiliary window could not be created") }
		if app.timing_motion {
			if ui.row(ctx, height=24, label="timing-motion-probe") {
				marker := alicorn.container_begin(
					ctx,
					.Container,
					label="retained-motion-timing-probe",
					key="retained-motion-timing-probe",
					style=ui.layout_style(.Row, width=24, height=16),
					color=ui.rgb(0x4EA6C7),
				)
				_ = ui.motion(
					ctx,
					marker,
					ui.Motion_Target{translation=ui.Motion_Vector2{180, 0}, has_translation=true},
					.Reveal,
					ui.Motion_Vector2{-180, 0},
				)
				alicorn.container_end(ctx)
			}
		}
	}
}

start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
}

wake :: proc(app: ^App, ctx: ui.Application_Context) {
	if app == nil || ctx == nil { return }
	app.wake_deliveries += 1
	ui.invalidate(ctx, "native WebGPU application wake delivered")
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
	sdl_gpu_reference := false
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
		if argument == "--backend=sdl-gpu" { sdl_gpu_reference = true }
		if argument == "--timing-motion" { app.timing_motion = true }
		if argument == "--child-smoke" {
			smoke = true
			app.open_child_on_services = true
		}
	}
	if sdl_gpu_reference {
		ui.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services)
	} else {
		webgpu.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services)
	}
}
