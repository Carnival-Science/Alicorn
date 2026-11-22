#+build !js

package sdl3_input

import alicorn "alicorn:runtime"
import "vendor:sdl3"

// key_spec_from_sdl normalizes SDL's logical keycode into Alicorn's bounded
// binding vocabulary. Unknown keys remain .Unknown; the host still offers them
// to its ordinary Application_Key policy.
key_spec_from_sdl :: proc(key: sdl3.Keycode) -> (spec: alicorn.Key_Spec, mapped: bool) {
	switch key {
	case sdl3.K_A: return .A, true
	case sdl3.K_B: return .B, true
	case sdl3.K_C: return .C, true
	case sdl3.K_D: return .D, true
	case sdl3.K_E: return .E, true
	case sdl3.K_F: return .F, true
	case sdl3.K_G: return .G, true
	case sdl3.K_H: return .H, true
	case sdl3.K_I: return .I, true
	case sdl3.K_J: return .J, true
	case sdl3.K_K: return .K, true
	case sdl3.K_L: return .L, true
	case sdl3.K_M: return .M, true
	case sdl3.K_N: return .N, true
	case sdl3.K_O: return .O, true
	case sdl3.K_P: return .P, true
	case sdl3.K_Q: return .Q, true
	case sdl3.K_R: return .R, true
	case sdl3.K_S: return .S, true
	case sdl3.K_T: return .T, true
	case sdl3.K_U: return .U, true
	case sdl3.K_V: return .V, true
	case sdl3.K_W: return .W, true
	case sdl3.K_X: return .X, true
	case sdl3.K_Y: return .Y, true
	case sdl3.K_Z: return .Z, true
	case sdl3.K_0: return .Zero, true
	case sdl3.K_1: return .One, true
	case sdl3.K_2: return .Two, true
	case sdl3.K_3: return .Three, true
	case sdl3.K_4: return .Four, true
	case sdl3.K_5: return .Five, true
	case sdl3.K_6: return .Six, true
	case sdl3.K_7: return .Seven, true
	case sdl3.K_8: return .Eight, true
	case sdl3.K_9: return .Nine, true
	case sdl3.K_F1: return .F1, true
	case sdl3.K_F2: return .F2, true
	case sdl3.K_F3: return .F3, true
	case sdl3.K_F4: return .F4, true
	case sdl3.K_F5: return .F5, true
	case sdl3.K_F6: return .F6, true
	case sdl3.K_F7: return .F7, true
	case sdl3.K_F8: return .F8, true
	case sdl3.K_F9: return .F9, true
	case sdl3.K_F10: return .F10, true
	case sdl3.K_F11: return .F11, true
	case sdl3.K_F12: return .F12, true
	case sdl3.K_LEFT: return .Left, true
	case sdl3.K_RIGHT: return .Right, true
	case sdl3.K_UP: return .Up, true
	case sdl3.K_DOWN: return .Down, true
	case sdl3.K_PAGEUP: return .Page_Up, true
	case sdl3.K_PAGEDOWN: return .Page_Down, true
	case sdl3.K_HOME: return .Home, true
	case sdl3.K_END: return .End, true
	case sdl3.K_INSERT: return .Insert, true
	case sdl3.K_SPACE: return .Space, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER: return .Return, true
	case sdl3.K_ESCAPE: return .Escape, true
	case sdl3.K_TAB: return .Tab, true
	case sdl3.K_BACKSPACE: return .Backspace, true
	case sdl3.K_DELETE: return .Delete, true
	case sdl3.K_MINUS: return .Minus, true
	case sdl3.K_EQUALS: return .Equal, true
	case sdl3.K_LEFTBRACKET: return .Left_Bracket, true
	case sdl3.K_RIGHTBRACKET: return .Right_Bracket, true
	case sdl3.K_BACKSLASH: return .Backslash, true
	case sdl3.K_SEMICOLON: return .Semicolon, true
	case sdl3.K_APOSTROPHE: return .Apostrophe, true
	case sdl3.K_COMMA: return .Comma, true
	case sdl3.K_PERIOD: return .Period, true
	case sdl3.K_SLASH: return .Slash, true
	case sdl3.K_GRAVE: return .Grave, true
	}
	return .Unknown, false
}

// key_event_from_sdl is the native host's single Key_Event producer. The caller
// supplies the text-focus and IME context it already computed; the application
// key bridge is attached separately so binding resolution is independent of
// whether the key also belongs to the legacy command vocabulary.
key_event_from_sdl :: proc(
	event: sdl3.KeyboardEvent,
	text_input_focused: bool,
	composition_active: bool,
) -> alicorn.Key_Event {
	key, _ := key_spec_from_sdl(event.key)
	modifiers := menu_modifiers_from_sdl(event.mod)
	return alicorn.Key_Event{
		scancode=u32(event.scancode),
		key=key,
		modifiers=modifiers,
		repeat=event.repeat,
		composition_active=composition_active,
		text_input_focused=text_input_focused,
		produces_text=alicorn.key_event_produces_text(key, modifiers) && !composition_active,
		timestamp_ns=u64(event.timestamp),
	}
}

key_event_with_application_key :: proc(
	event: alicorn.Key_Event,
	key: alicorn.Application_Key,
) -> alicorn.Key_Event {
	value := event
	value.application_key = key
	value.has_application_key = true
	return value
}
