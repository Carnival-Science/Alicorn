#+build !js

package sdl3_host

import alicorn "alicorn:runtime"
import "vendor:sdl3"

// Pointer_Button_State preserves the logical button selected on pointer-down
// until the matching physical release, even if modifier keys change mid-press.
Pointer_Button_State :: struct {
	logical_by_physical: [8]int,
}

pointer_button_state_clear :: proc(state: ^Pointer_Button_State) {
	if state != nil { state^ = {} }
}

input_modifier_is_set :: proc(modifiers, mask: sdl3.Keymod) -> bool {
	return modifiers&mask != sdl3.Keymod{}
}

pointer_modifiers_from_sdl :: proc(modifiers: sdl3.Keymod) -> alicorn.Input_Modifiers {
	return alicorn.Input_Modifiers{
		shift=input_modifier_is_set(modifiers, sdl3.KMOD_SHIFT),
		control=input_modifier_is_set(modifiers, sdl3.KMOD_CTRL),
		alt=input_modifier_is_set(modifiers, sdl3.KMOD_ALT),
		super=input_modifier_is_set(modifiers, sdl3.KMOD_GUI),
	}
}

pointer_button_from_sdl :: proc(button: int, modifiers: alicorn.Input_Modifiers) -> int {
	when ODIN_OS == .Darwin {
		// Cocoa's conventional context-click gesture is Control + primary click.
		// Preserve the modifier snapshot, but expose the gesture as secondary so
		// applications can use one portable context-menu path.
		if button == alicorn.POINTER_BUTTON_PRIMARY && modifiers.control {
			return alicorn.POINTER_BUTTON_SECONDARY
		}
	}
	return button
}

pointer_event_from_sdl :: proc(
	event: sdl3.Event,
	modifiers: sdl3.Keymod,
	button_state: ^Pointer_Button_State = nil,
) -> (value: alicorn.Pointer_Event, ok: bool) {
	// SDL mouse coordinates are window-logical coordinates. They are passed
	// through unchanged; only the compositor converts logical geometry to pixels.
	neutral_modifiers := pointer_modifiers_from_sdl(modifiers)
	if event.type == .WINDOW_FOCUS_LOST {
		// SDL may not deliver the matching button-up after focus/capture is lost.
		pointer_button_state_clear(button_state)
	}
	if event.type == .MOUSE_MOTION {
		return alicorn.Pointer_Event{
			kind=.Move,
			x=event.motion.x,
			y=event.motion.y,
			modifiers=neutral_modifiers,
		}, true
	}
	if event.type == .MOUSE_BUTTON_DOWN {
		physical_button := int(event.button.button)
		button := pointer_button_from_sdl(physical_button, neutral_modifiers)
		if button_state != nil && physical_button > 0 && physical_button < len(button_state.logical_by_physical) {
			button_state.logical_by_physical[physical_button] = button
		}
		return alicorn.Pointer_Event{
			kind=.Down,
			x=event.button.x,
			y=event.button.y,
			button=button,
			modifiers=neutral_modifiers,
			click_count=event.button.clicks,
		}, true
	}
	if event.type == .MOUSE_BUTTON_UP {
		physical_button := int(event.button.button)
		button := pointer_button_from_sdl(physical_button, neutral_modifiers)
		if button_state != nil && physical_button > 0 && physical_button < len(button_state.logical_by_physical) {
			if logical_button := button_state.logical_by_physical[physical_button]; logical_button != 0 {
				button = logical_button
			}
			button_state.logical_by_physical[physical_button] = 0
		}
		return alicorn.Pointer_Event{
			kind=.Up,
			x=event.button.x,
			y=event.button.y,
			button=button,
			modifiers=neutral_modifiers,
			click_count=event.button.clicks,
		}, true
	}
	return alicorn.Pointer_Event{}, false
}

pointer_modifier_state_update :: proc(modifiers: ^sdl3.Keymod, event: sdl3.Event) {
	if modifiers == nil { return }
	if event.type == .KEY_DOWN || event.type == .KEY_UP {
		modifiers^ = event.key.mod
	} else if event.type == .WINDOW_FOCUS_LOST {
		modifiers^ = {}
	} else if event.type == .WINDOW_FOCUS_GAINED {
		modifiers^ = sdl3.GetModState()
	}
}

focused_control_key_from_sdl :: proc(key: sdl3.Keycode) -> (mapped: alicorn.Application_Key, ok: bool) {
	switch key {
	case sdl3.K_SPACE: return .Toggle, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER: return .Return, true
	case sdl3.K_LEFT, sdl3.K_DOWN: return .Left, true
	case sdl3.K_RIGHT, sdl3.K_UP: return .Right, true
	case sdl3.K_HOME: return .Home, true
	case sdl3.K_END: return .End, true
	case: return {}, false
	}
}

context_menu_key_from_sdl :: proc(key: sdl3.Keycode) -> alicorn.Context_Menu_Key {
	switch key {
	case sdl3.K_UP: return .Up
	case sdl3.K_DOWN: return .Down
	case sdl3.K_HOME: return .Home
	case sdl3.K_END: return .End
	case sdl3.K_RETURN, sdl3.K_KP_ENTER, sdl3.K_SPACE: return .Activate
	case sdl3.K_ESCAPE: return .Cancel
	case: return .Other
	}
}

scroll_event_from_sdl :: proc(wheel: sdl3.MouseWheelEvent, modifiers: alicorn.Input_Modifiers) -> alicorn.Scroll_Event {
	// SDL X is positive toward the right of the document; Alicorn's deltas
	// describe content motion (positive right/down), so only X needs negating.
	// SDL Y already matches. Natural scrolling is already encoded in the values:
	// do not apply FLIPPED again.
	return alicorn.Scroll_Event{
		delta_x=-wheel.x,
		delta_y=wheel.y,
		ticks_x=-int(wheel.integer_x),
		ticks_y=int(wheel.integer_y),
		x=wheel.mouse_x,
		y=wheel.mouse_y,
		modifiers=modifiers,
	}
}
