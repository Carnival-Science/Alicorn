package main

import "core:fmt"
import ui "alicorn:ui"

App :: struct {
	activations: int,
	name: ui.Text_Buffer,
}

app: App

render :: proc(state: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Alicorn WebGPU in the browser", size=26)
		ui.text(ctx, "The same retained UI API runs through the shared browser host.")
		if ui.button(ctx, "Increment") { state.activations += 1 }
		ui.text(ctx, fmt.tprintf("Button activations: %d", state.activations))
		ui.text_field(ctx, "Type here to exercise browser text input", &state.name)
	}
}

on_stop :: proc(state: ^App) {
	ui.text_buffer_destroy(&state.name)
}

main :: proc() {
	name, ok := ui.text_buffer("Browser input, composition, and selection")
	if !ok { panic("could not allocate browser example text buffer") }
	app.name = name
	ui.run(&app, render, title="Alicorn · WebGPU Browser", on_stop=on_stop)
}
