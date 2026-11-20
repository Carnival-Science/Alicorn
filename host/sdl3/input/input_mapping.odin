#+build !js

package sdl3_input

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

text_primary_modifier_from_sdl :: proc(modifiers: sdl3.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return input_modifier_is_set(modifiers, sdl3.KMOD_GUI)
	} else {
		return input_modifier_is_set(modifiers, sdl3.KMOD_CTRL)
	}
}

// menu_modifiers_from_sdl converts SDL modifier state into the runtime's
// platform-neutral menu shortcut vocabulary. Primary is Ctrl on Windows/Linux
// and Command on macOS; Super is the Windows key on Windows/Linux and Control
// on macOS. Shortcut matching requires an exact set, so this conversion is
// shared by every SDL3 host rather than re-derived at each accelerator site.
menu_modifiers_from_sdl :: proc(modifiers: sdl3.Keymod) -> alicorn.Menu_Modifiers {
	result: alicorn.Menu_Modifiers
	if text_primary_modifier_from_sdl(modifiers) { result += {.Primary} }
	if input_modifier_is_set(modifiers, sdl3.KMOD_SHIFT) { result += {.Shift} }
	if input_modifier_is_set(modifiers, sdl3.KMOD_ALT) { result += {.Alt} }
	when ODIN_OS == .Darwin {
		if input_modifier_is_set(modifiers, sdl3.KMOD_CTRL) { result += {.Super} }
	} else {
		if input_modifier_is_set(modifiers, sdl3.KMOD_GUI) { result += {.Super} }
	}
	return result
}

text_word_modifier_from_sdl :: proc(modifiers: sdl3.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return input_modifier_is_set(modifiers, sdl3.KMOD_ALT)
	} else {
		return input_modifier_is_set(modifiers, sdl3.KMOD_CTRL)
	}
}

text_line_modifier_from_sdl :: proc(modifiers: sdl3.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return input_modifier_is_set(modifiers, sdl3.KMOD_GUI)
	} else {
		return false
	}
}

text_document_modifier_from_sdl :: proc(modifiers: sdl3.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return text_primary_modifier_from_sdl(modifiers)
	} else {
		return input_modifier_is_set(modifiers, sdl3.KMOD_CTRL)
	}
}

text_key_event_from_sdl :: proc(
	key: sdl3.Keycode,
	modifiers: sdl3.Keymod,
) -> (event: alicorn.Application_Text_Key_Event, mapped: bool) {
	word := text_word_modifier_from_sdl(modifiers)
	line := text_line_modifier_from_sdl(modifiers)
	document := text_document_modifier_from_sdl(modifiers)
	switch key {
	case sdl3.K_LEFT:
		if line { event.key = .Line_Start }
		else if word { event.key = .Word_Left }
		else { event.key = .Left }
	case sdl3.K_RIGHT:
		if line { event.key = .Line_End }
		else if word { event.key = .Word_Right }
		else { event.key = .Right }
	case sdl3.K_HOME: event.key = .Document_Start if document else .Home
	case sdl3.K_END: event.key = .Document_End if document else .End
	case sdl3.K_UP:
		when ODIN_OS == .Darwin {
			event.key = .Document_Start if document else .Up
		} else { event.key = .Up }
	case sdl3.K_DOWN:
		when ODIN_OS == .Darwin {
			event.key = .Document_End if document else .Down
		} else { event.key = .Down }
	case sdl3.K_PAGEUP: event.key = .Page_Up
	case sdl3.K_PAGEDOWN: event.key = .Page_Down
	case sdl3.K_BACKSPACE:
		if line { event.key = .Delete_Line_Backward }
		else if word { event.key = .Delete_Word_Backward }
		else { event.key = .Backspace }
	case sdl3.K_DELETE:
		if line { event.key = .Delete_Line_Forward }
		else if word { event.key = .Delete_Word_Forward }
		else { event.key = .Delete }
	case sdl3.K_TAB: event.key = .Tab
	case: return {}, false
	}
	event.shift = input_modifier_is_set(modifiers, sdl3.KMOD_SHIFT)
	event.control = input_modifier_is_set(modifiers, sdl3.KMOD_CTRL)
	event.alt = input_modifier_is_set(modifiers, sdl3.KMOD_ALT)
	event.super = input_modifier_is_set(modifiers, sdl3.KMOD_GUI)
	return event, true
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

// application_key_from_sdl maps the common native shortcuts shared by SDL3
// hosts. Text-focused callers may still offer only commands that Alicorn
// explicitly permits to preempt text editing and active IME composition.
application_key_from_sdl :: proc(
	key: sdl3.Keycode,
	modifiers: sdl3.Keymod,
	text_input_focused := false,
) -> (mapped: alicorn.Application_Key, ok: bool) {
	primary := text_primary_modifier_from_sdl(modifiers)
	control := input_modifier_is_set(modifiers, sdl3.KMOD_CTRL)
	shift := input_modifier_is_set(modifiers, sdl3.KMOD_SHIFT)
	if key == sdl3.K_TAB && control {
		return .Tab_Previous if shift else .Tab_Next, true
	}
	switch key {
	case sdl3.K_ESCAPE: return .Escape, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER: return .Return, true
	case sdl3.K_SPACE:
		if !text_input_focused { return .Toggle, true }
	case sdl3.K_F2: return .Workspace_Rename, true
	case sdl3.K_F3: return .Find_Previous if shift else .Find_Next, true
	case sdl3.K_F10:
		if shift { return .Context_Menu, true }
	case sdl3.K_LEFT:
		if !text_input_focused { return .Left, true }
	case sdl3.K_RIGHT:
		if !text_input_focused { return .Right, true }
	case sdl3.K_UP:
		if !text_input_focused { return .Up, true }
	case sdl3.K_DOWN:
		if !text_input_focused { return .Down, true }
	case sdl3.K_PAGEUP:
		if !text_input_focused { return .Page_Up, true }
	case sdl3.K_PAGEDOWN:
		if !text_input_focused { return .Page_Down, true }
	case sdl3.K_HOME:
		if !text_input_focused { return .Home, true }
	case sdl3.K_END:
		if !text_input_focused { return .End, true }
	case sdl3.K_1:
		if !text_input_focused { return .Command_1, true }
	case sdl3.K_2:
		if !text_input_focused { return .Command_2, true }
	case sdl3.K_3:
		if !text_input_focused { return .Command_3, true }
	case sdl3.K_O:
		if primary { return .Open_Repository, true }
	case sdl3.K_P:
		if primary && shift { return .Open_Command_Palette, true }
	case sdl3.K_F:
		if primary { return .Workspace_Search if shift else .Find, true }
		if !text_input_focused { return .Fit_Selection, true }
	case sdl3.K_EQUALS, sdl3.K_PLUS, sdl3.K_KP_PLUS:
		if primary { return .Zoom_In, true }
	case sdl3.K_MINUS, sdl3.K_KP_MINUS:
		if primary { return .Zoom_Out, true }
	case sdl3.K_0, sdl3.K_KP_0:
		if primary { return .Zoom_Reset, true }
	case:
	}
	return {}, false
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
