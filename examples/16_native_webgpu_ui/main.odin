package main

import "core:fmt"
import "core:os"
import ui "alicorn:ui"

App :: struct {
	count: int,
	name: ui.Text_Buffer,
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Native WebGPU UI", size=24)
		ui.text(ctx, "The retained runtime and surface presenter are shared with the browser host.")
		if ui.button(ctx, "Increment") { app.count += 1 }
		ui.text(ctx, fmt.tprintf("Button activations: %d", app.count))
		ui.text_field(ctx, "Try native text input", &app.name)
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
	}
	ui.run_webgpu(&app, render, title="Alicorn · Native WebGPU", on_stop=stop, smoke=smoke)
}
