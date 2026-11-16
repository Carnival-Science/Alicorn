package alicorn_sdl_gpu

import alicorn "../../runtime"
import "vendor:sdl3"
import sdl_host "alicorn:host/sdl3"

// native_route_focused_control_key is kept separate from the event loop so the
// platform key convention for retained controls can be verified headlessly.
native_route_focused_control_key :: proc(rt: ^alicorn.Runtime, key: sdl3.Keycode) -> bool {
	key_action, mapped := sdl_host.focused_control_key_from_sdl(key)
	if !mapped { return false }
	return alicorn.application_route_focused_control_key(rt, key_action)
}

pointer_modifiers_from_sdl :: proc(mod: sdl3.Keymod) -> alicorn.Input_Modifiers {
	return sdl_host.pointer_modifiers_from_sdl(mod)
}

Native_Pointer_Button_State :: sdl_host.Pointer_Button_State

native_pointer_button_state_clear :: proc(state: ^Native_Pointer_Button_State) {
	sdl_host.pointer_button_state_clear(state)
}

native_pointer_button_from_sdl :: proc(button: int, modifiers: alicorn.Input_Modifiers) -> int {
	return sdl_host.pointer_button_from_sdl(button, modifiers)
}

pointer_from_sdl_with_modifiers :: proc(
	event: sdl3.Event,
	mod: sdl3.Keymod,
	button_state: ^Native_Pointer_Button_State = nil,
) -> (value: alicorn.Pointer_Event, ok: bool) {
	return sdl_host.pointer_event_from_sdl(event, mod, button_state)
}

native_dispatch_drag_event :: proc(application: ^Application, rt: ^alicorn.Runtime) -> bool {
	event, pending := alicorn.drag_event_take(rt)
	if !pending { return false }
	if application != nil && application.on_drag != nil {
		application.on_drag(application.state, rt, event)
	}
	return true
}

pointer_modifier_state_update :: proc(mod_state: ^sdl3.Keymod, event: sdl3.Event) {
	sdl_host.pointer_modifier_state_update(mod_state, event)
}

poll_sdl_event :: proc(event: ^sdl3.Event) -> bool {
	when ODIN_OS == .Darwin {
		// The Darwin host pumps AppKit explicitly above. PeepEvents retrieves
		// only what SDL has already translated, so it cannot re-enter the
		// blocking SDL_PollEvent -> Cocoa path.
		return sdl3.PeepEvents(event, 1, .GETEVENT, sdl3.EventType.FIRST, sdl3.EventType.LAST) > 0
	} else {
		return sdl3.PollEvent(event)
	}
}

native_event_window_id :: proc(event: sdl3.Event) -> sdl3.WindowID {
	return sdl_host.event_window_id_from_sdl(event)
}

native_event_next :: proc(event: ^sdl3.Event, child: ^Native_Secondary_Window, replay_secondary_events: bool) -> bool {
	if event == nil { return false }
	if replay_secondary_events { return native_secondary_window_pop_event(child, event) }
	return poll_sdl_event(event)
}
