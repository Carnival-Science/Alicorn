#+build windows

// Optional per-editor AccessKit bridge for alicorn:host/plugin.
//
// The core plugin package deliberately does not link SDL or AccessKit. A host
// that wants native semantics imports this package and installs the returned
// Plugin_Accessibility callbacks on each editor config. The existing SDL3
// per-window accessibility host is reused; only the adapter attachment differs
// because the plugin host creates a child HWND directly instead of an SDL
// window.
package plugin_accessibility

import alicorn "alicorn:runtime"
import plugin "alicorn:host/plugin"
import sdl3_accessibility "alicorn:host/sdl3/accessibility"

Editor_Accessibility :: struct {
	host:  sdl3_accessibility.Native_Accessibility_Host,
	waker: sdl3_accessibility.Native_Host_Event_Waker,
	ready: bool,
}

// plugin_accessibility_init fills the host-owned callbacks for one editor.
// Allocate one Editor_Accessibility per editor and keep it alive until the
// editor's destroy callback runs.
plugin_accessibility_init :: proc(state: ^Editor_Accessibility) -> plugin.Plugin_Accessibility {
	if state == nil { return {} }
	state.waker = sdl3_accessibility.Native_Host_Event_Waker{active=false}
	if !sdl3_accessibility.native_accessibility_host_init(&state.host, &state.waker) {
		return {}
	}
	state.ready = true
	return plugin.Plugin_Accessibility{
		data=rawptr(state),
		attach=plugin_accessibility_attach,
		sync=plugin_accessibility_sync,
		drain=plugin_accessibility_drain,
		focus_changed=plugin_accessibility_focus_changed,
		destroy=plugin_accessibility_destroy,
	}
}

plugin_accessibility_ready :: proc(state: ^Editor_Accessibility) -> bool {
	return state != nil && state.ready && state.host.adapter != nil
}

@(private)
plugin_accessibility_attach :: proc(data: rawptr, _kind: plugin.Plugin_Parent_Kind, native_window: rawptr) -> bool {
	state := cast(^Editor_Accessibility)data
	if state == nil || !state.ready { return false }
	return sdl3_accessibility.native_accessibility_adapter_init_hwnd(&state.host, native_window)
}

@(private)
plugin_accessibility_sync :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	content_inset_top, scale_x, scale_y: f32,
) {
	state := cast(^Editor_Accessibility)data
	if state == nil || !state.ready { return }
	_ = sdl3_accessibility.native_accessibility_sync(
		&state.host, rt, content_inset_top, scale_x, scale_y,
	)
}

@(private)
plugin_accessibility_drain :: proc(data: rawptr, hosted: ^alicorn.Hosted_Runtime) {
	state := cast(^Editor_Accessibility)data
	if state == nil || !state.ready || hosted == nil { return }
	rt, status := alicorn.hosted_runtime_borrow(hosted)
	if status != .Ok { return }
	sdl3_accessibility.native_accessibility_drain_actions(&state.host, rt)
	_ = alicorn.hosted_runtime_deliver_semantic_requests(hosted)
}

@(private)
plugin_accessibility_focus_changed :: proc(data: rawptr, focused: bool) {
	state := cast(^Editor_Accessibility)data
	if state == nil || !state.ready { return }
	sdl3_accessibility.native_accessibility_focus_changed(&state.host, focused)
}

@(private)
plugin_accessibility_destroy :: proc(data: rawptr) {
	state := cast(^Editor_Accessibility)data
	if state == nil { return }
	sdl3_accessibility.native_accessibility_host_destroy(&state.host)
	state.ready = false
}
