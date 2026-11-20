package main

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

App :: struct {
	activations: int,
	wake_deliveries: int,
	waker: ui.Application_Waker,
	name: ui.Text_Buffer,
	host_services: ui.UI_Host_Services,
	clipboard_text: string,
	clipboard_status: string,
	clipboard_sequence: u64,
	input_semantic_id: alicorn.Semantic_ID,
}

app: App

render :: proc(state: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Alicorn WebGPU in the browser", size=26)
		ui.text(ctx, "The same retained UI API runs through the shared browser host.")
		if ui.button(ctx, "Increment") { state.activations += 1 }
		ui.text(ctx, fmt.tprintf("Button activations: %d", state.activations))
		if ui.button(ctx, "Queue application wake") { ui.wake(state.waker) }
		ui.text(ctx, fmt.tprintf("Application wake callbacks: %d", state.wake_deliveries))
		input := ui.text_field(
			ctx,
			"Type here to exercise browser text input",
			&state.name,
			key="browser-example-text-input",
		)
		state.input_semantic_id = alicorn.semantic_visual_id(input.node)
		ui.text(ctx, "Clipboard access is permission-gated by the browser.")
		if ui.button(ctx, "Read clipboard") {
			state.clipboard_sequence += 1
			request_id := ui.UI_Clipboard_Request_ID(state.clipboard_sequence)
			if !ui.ui_clipboard_read_text(state.host_services.clipboard, request_id, rawptr(state), on_clipboard_complete) {
				state.clipboard_status = "Clipboard read could not be queued."
			}
		}
		if ui.button(ctx, "Copy sample text") {
			state.clipboard_sequence += 1
			request_id := ui.UI_Clipboard_Request_ID(state.clipboard_sequence | (u64(1) << 63))
			if !ui.ui_clipboard_write_text(
				state.host_services.clipboard,
				request_id,
				"Alicorn browser clipboard sample",
				rawptr(state),
				on_clipboard_complete,
			) {
				state.clipboard_status = "Clipboard write could not be queued."
			}
		}
		if state.clipboard_status != "" { ui.text(ctx, state.clipboard_status) }
		if state.clipboard_text != "" { ui.text(ctx, fmt.tprintf("Clipboard: %s", state.clipboard_text)) }
	}
}

on_wake :: proc(state: ^App, ctx: ui.Application_Context) {
	rt := cast(^alicorn.Runtime)ctx
	if state == nil || rt == nil { return }
	state.wake_deliveries += 1
	changed := false
	for {
		event, found := alicorn.semantic_request_pop(rt)
		if !found { break }
		if event.kind == .Perform && event.id == state.input_semantic_id &&
		   event.action == .Set_Value && ui.text_buffer_set(&state.name, event.text_value) {
			changed = true
		}
		alicorn.semantic_request_event_destroy(rt, &event)
	}
	if changed { ui.invalidate(ctx, "browser accessibility value applied") }
	else { ui.invalidate(ctx, "browser application wake delivered") }
}

on_start :: proc(state: ^App, waker: ui.Application_Waker) {
	state.waker = waker
}

on_services :: proc(state: ^App, services: ui.UI_Host_Services) {
	state.host_services = services
}

on_clipboard_complete :: proc(
	data: rawptr,
	request_id: ui.UI_Clipboard_Request_ID,
	result: ui.UI_Clipboard_Result,
	text: string,
) {
	state := cast(^App)data
	if state == nil { return }
	is_write := u64(request_id) & (u64(1) << 63) != 0
	if result == .Success {
		if is_write {
			state.clipboard_status = "Clipboard write complete."
		} else {
			copy, err := strings.clone(text)
			if err == .None {
				if len(state.clipboard_text) > 0 { delete(state.clipboard_text) }
				state.clipboard_text = copy
				state.clipboard_status = "Clipboard read complete."
			}
		}
	} else if result == .Permission_Denied {
		state.clipboard_status = "Clipboard permission was denied by the browser."
	} else if result == .Unsupported {
		state.clipboard_status = "This browser does not support clipboard access here."
	} else if result == .Cancelled {
		state.clipboard_status = "Clipboard request cancelled during shutdown."
	} else if result == .Too_Large {
		state.clipboard_status = "Clipboard text is larger than the 1 MiB browser transfer limit."
	} else if result == .Unavailable {
		state.clipboard_status = "Browser clipboard is unavailable in this context."
	} else {
		state.clipboard_status = "Clipboard request failed."
	}
}

on_stop :: proc(state: ^App) {
	ui.text_buffer_destroy(&state.name)
	if len(state.clipboard_text) > 0 { delete(state.clipboard_text) }
}

main :: proc() {
	name, ok := ui.text_buffer("Browser input, composition, and selection")
	if !ok { panic("could not allocate browser example text buffer") }
	app.name = name
	ui.run(
		&app,
		render,
		title="Alicorn · WebGPU Browser",
		on_start=on_start,
		on_stop=on_stop,
		on_services=on_services,
		on_wake=on_wake,
	)
}
