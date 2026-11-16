package ui

import alicorn "alicorn:runtime"

// Run_State contains the application description shared by platform hosts.
// Keeping this independent of native/sdl_gpu lets compile-time host adapters
// reuse the exact same root and overlay composition.
@(private)
Run_State :: struct($T: typeid) {
	app: ^T,
	render: proc(^T, ^UI),
	render_overlays: proc(^T, ^UI),
	on_initialize: proc(^T, ^alicorn.Runtime),
	on_start: proc(^T, Application_Waker),
	on_wake: proc(^T, Application_Context),
	on_stop: proc(^T),
	on_key: proc(^T, ^alicorn.Runtime, alicorn.Application_Key) -> bool,
	on_text_change: proc(^T, ^alicorn.Runtime, alicorn.Text_Change),
	on_pointer: proc(^T, ^alicorn.Runtime, alicorn.Pointer_Event, Node_ID),
}

@(private)
run_describe :: proc(state: ^Run_State($T), ctx: ^UI) -> alicorn.Node_ID {
	root := alicorn.container_begin(
		ctx,
		.Root,
		label="ui-root",
		key="alicorn.ui.root",
		style=alicorn.layout_style(.Column, grow=1),
	)
	if root == 0 { return 0 }
	state.render(state.app, ctx)
	alicorn.container_end(ctx)
	if state.render_overlays != nil { state.render_overlays(state.app, ctx) }
	return root
}
