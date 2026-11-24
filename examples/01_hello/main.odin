package main

// The first application needs only typed state, a render procedure, and
// ordinary Odin control flow. ui.run owns routine native host and frame setup.

import "core:fmt"
import ui "alicorn:ui"

App :: struct {
	count: int,
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Hello, Alicorn", size=24)
		ui.text(ctx, fmt.tprintf("Count: %d", app.count))
		if ui.button(ctx, "Increment", key=ui.key_string("hello.increment")) {
			app.count += 1
		}
	}
}

on_key :: proc(app: ^App, _rt: ^ui.Runtime, key: ui.Application_Key) -> bool {
	if key == .Return {
		app.count += 1
		return true
	}
	return false
}

main :: proc() {
	app := App{}
	ui.run(&app, render, title="Alicorn starter", width=720, height=480, on_key=on_key)
}
