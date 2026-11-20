#+build !js

package ui_webgpu

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"
import sdl3_clipboard "alicorn:host/sdl3/clipboard"
import host "alicorn:host/sdl3"

// run is the opt-in native WebGPU entry point for dogfooding the shared
// WebGPU renderer through SDL3. It preserves the ui.run callback model while
// leaving ui.run on SDL_GPU until the renderer's migration acceptance gates
// pass. It lives in its own package so SDL_GPU-only consumers of alicorn:ui
// do not compile the WebGPU host or require wgpu-native at build time.
//
// on_services supplies host capabilities before on_start. The WebGPU host
// supports one independently retained secondary window through
// UI_Host_Services.windows and native AccessKit adapters on Windows/macOS;
// integrated titlebars and native menus are not yet ported.
run :: proc(
	state: ^$T,
	render: proc(^T, ^ui.UI),
	title: string = "Alicorn WebGPU",
	width: int = 720,
	height: int = 480,
	render_overlays: proc(^T, ^ui.UI) = nil,
	on_start: proc(^T, ui.Application_Waker) = nil,
	on_wake: proc(^T, ui.Application_Context) = nil,
	on_stop: proc(^T) = nil,
	smoke: bool = false,
	on_initialize: proc(^T, ^alicorn.Runtime) = nil,
	on_key: proc(^T, ^alicorn.Runtime, alicorn.Application_Key) -> bool = nil,
	on_text_change: proc(^T, ^alicorn.Runtime, alicorn.Text_Change) = nil,
	on_pointer: proc(^T, ^alicorn.Runtime, alicorn.Pointer_Event, alicorn.Node_ID) = nil,
	on_text_key: proc(^T, ^alicorn.Runtime, alicorn.Node_ID, alicorn.Application_Text_Key_Event) -> bool = nil,
	on_services: proc(^T, ui.UI_Host_Services) = nil,
) {
	run_state := ui.Hosted_Run_State(T){
		app=state, render=render, render_overlays=render_overlays,
		on_initialize=on_initialize, on_start=on_start, on_wake=on_wake, on_stop=on_stop,
		on_key=on_key, on_text_change=on_text_change, on_pointer=on_pointer,
		on_text_key=on_text_key,
		on_services=on_services,
	}
	clipboard_backend := sdl3_clipboard.UI_Clipboard_Backend{service=sdl3_clipboard.SDL3ClipboardService()}
	run_state.host_services.clipboard = sdl3_clipboard.UI_Clipboard_Service(&clipboard_backend)
	hosted := ui.run_hosted_config(
		&run_state,
		width,
		height,
		width,
		height,
		1,
		rawptr(&run_state),
		webgpu_unused_post_wake,
	)
	// Load the bundled fonts after the app has had a chance to register custom
	// faces. The host will overwrite the placeholder SDL wake callback.
	initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
		state := cast(^ui.Hosted_Run_State(T))data
		if state.on_initialize != nil { state.on_initialize(state.app, rt) }
		if !alicorn.text_engine_load_default_fonts(rt) {
			fmt.panicf("Alicorn's bundled UI fonts could not be initialized")
		}
	}
	hosted.on_initialize = initialize
	if result := host.sdl3_webgpu_run(hosted, title, width, height, smoke); result != .Ok {
		fmt.panicf("native SDL3/WebGPU application exited with %v", result)
	}
}

@(private)
webgpu_unused_post_wake :: proc(_data: rawptr) -> bool {
	// The native coordinator replaces this callback with an SDL user event.
	return true
}
