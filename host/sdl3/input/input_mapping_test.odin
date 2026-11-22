#+build !js

package sdl3_input

import "core:testing"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

@(test)
test_sdl_pointer_mapping_preserves_coordinates_modifiers_and_clicks :: proc(t: ^testing.T) {
	event := sdl3.Event{}
	event.type = .MOUSE_MOTION
	event.motion.x, event.motion.y = 123.25, 234.75
	mods := sdl3.KMOD_SHIFT | sdl3.KMOD_CTRL | sdl3.KMOD_ALT | sdl3.KMOD_GUI
	pointer, ok := pointer_event_from_sdl(event, mods)
	testing.expect(t, ok && pointer.kind == .Move && pointer.x == 123.25 && pointer.y == 234.75,
		"SDL pointer coordinates remain logical pixels in the Runtime event")
	testing.expect(t, pointer.modifiers.shift && pointer.modifiers.control && pointer.modifiers.alt && pointer.modifiers.super,
		"SDL modifier bits map to platform-neutral Runtime modifiers")

	event = sdl3.Event{}
	event.type = .MOUSE_BUTTON_DOWN
	event.button.button = 1
	event.button.clicks = 2
	event.button.x, event.button.y = 17.5, 22.25
	state := Pointer_Button_State{}
	pointer, ok = pointer_event_from_sdl(event, sdl3.KMOD_CTRL, &state)
	expected_button := alicorn.POINTER_BUTTON_PRIMARY
	when ODIN_OS == .Darwin { expected_button = alicorn.POINTER_BUTTON_SECONDARY }
	testing.expect(t, ok && pointer.kind == .Down && pointer.button == expected_button && pointer.click_count == 2,
		"Control-primary mapping and multi-click count are preserved")
	testing.expect(t, pointer.x == 17.5 && pointer.y == 22.25 && pointer.modifiers.control,
		"button events retain coordinates and modifier state")

	// The release uses the physical-button identity captured on down even if
	// Control changes while the gesture is held.
	event.type = .MOUSE_BUTTON_UP
	pointer, ok = pointer_event_from_sdl(event, {}, &state)
	testing.expect(t, ok && pointer.kind == .Up && pointer.button == expected_button && state == Pointer_Button_State{},
		"button release preserves its down-time mapping and clears the held state")

	event.type = .WINDOW_FOCUS_LOST
	_, ok = pointer_event_from_sdl(event, {}, &state)
	testing.expect(t, !ok && state == Pointer_Button_State{}, "focus loss clears held pointer buttons")
	event.type = .KEY_DOWN
	_, ok = pointer_event_from_sdl(event, {}, &state)
	testing.expect(t, !ok, "non-pointer SDL events do not produce pointer input")
}

@(test)
test_sdl_pointer_back_forward_buttons_are_preserved :: proc(t: ^testing.T) {
	testing.expect(t, pointer_button_from_sdl(sdl3.BUTTON_LEFT, {}) == alicorn.POINTER_BUTTON_PRIMARY,
		"the left button remains the primary pointer button")
	testing.expect(t, pointer_button_from_sdl(sdl3.BUTTON_MIDDLE, {}) == alicorn.POINTER_BUTTON_MIDDLE,
		"the middle button remains the middle pointer button")
	testing.expect(t, pointer_button_from_sdl(sdl3.BUTTON_RIGHT, {}) == alicorn.POINTER_BUTTON_SECONDARY,
		"the right button remains the secondary pointer button")
	testing.expect(t, pointer_button_from_sdl(sdl3.BUTTON_X1, {}) == alicorn.POINTER_BUTTON_BACK,
		"SDL X1 is the back navigation button")
	testing.expect(t, pointer_button_from_sdl(sdl3.BUTTON_X2, {}) == alicorn.POINTER_BUTTON_FORWARD,
		"SDL X2 is the forward navigation button")

	// Down and up must agree on the logical button even though the host caches
	// the down-time mapping by physical SDL button.
	event := sdl3.Event{}
	event.type = .MOUSE_BUTTON_DOWN
	event.button.button = sdl3.BUTTON_X1
	state := Pointer_Button_State{}
	down, down_ok := pointer_event_from_sdl(event, {}, &state)
	event.type = .MOUSE_BUTTON_UP
	up, up_ok := pointer_event_from_sdl(event, {}, &state)
	testing.expect(t, down_ok && up_ok &&
		down.button == alicorn.POINTER_BUTTON_BACK && up.button == alicorn.POINTER_BUTTON_BACK,
		"SDL X1 down/up survive the ordinary pointer mapping unchanged")
}

@(test)
test_sdl_scroll_mapping_preserves_content_direction_and_metadata :: proc(t: ^testing.T) {
	wheel := sdl3.MouseWheelEvent{
		x=1.5,
		y=-2.25,
		integer_x=2,
		integer_y=-3,
		mouse_x=40.5,
		mouse_y=80.25,
	}
	modifiers := alicorn.Input_Modifiers{shift=true, control=true}
	scroll := scroll_event_from_sdl(wheel, modifiers)
	testing.expect(t, scroll.delta_x == -1.5 && scroll.delta_y == -2.25 && scroll.ticks_x == -2 && scroll.ticks_y == -3,
		"SDL wheel deltas map to Alicorn content-motion direction without double-flipping Y")
	testing.expect(t, scroll.x == 40.5 && scroll.y == 80.25 && scroll.modifiers == modifiers,
		"scroll events preserve pointer location and modifiers")
}

@(test)
test_sdl_pointer_modifier_cache_clears_on_focus_loss :: proc(t: ^testing.T) {
	modifiers := sdl3.Keymod{}
	event := sdl3.Event{}
	event.type = .KEY_DOWN
	event.key.mod = sdl3.KMOD_SHIFT
	pointer_modifier_state_update(&modifiers, event)
	testing.expect(t, modifiers == sdl3.KMOD_SHIFT, "key events refresh the ordered modifier snapshot")
	event.type = .WINDOW_FOCUS_LOST
	pointer_modifier_state_update(&modifiers, event)
	testing.expect(t, modifiers == sdl3.Keymod{}, "focus loss clears modifiers when key-up may be missing")
}

@(test)
test_sdl_control_key_mappings_are_backend_independent :: proc(t: ^testing.T) {
	focused_cases := [6]struct { key: sdl3.Keycode, action: alicorn.Application_Key }{
		{sdl3.K_SPACE, .Toggle},
		{sdl3.K_RETURN, .Return},
		{sdl3.K_LEFT, .Left},
		{sdl3.K_UP, .Right},
		{sdl3.K_HOME, .Home},
		{sdl3.K_END, .End},
	}
	for c in focused_cases {
		action, ok := focused_control_key_from_sdl(c.key)
		testing.expect(t, ok && action == c.action, "focused-control key maps to the expected Runtime action")
	}
	_, ok := focused_control_key_from_sdl(sdl3.K_ESCAPE)
	testing.expect(t, !ok, "unhandled focused-control keys stay available to later host routing")

	context_cases := [7]struct { key: sdl3.Keycode, action: alicorn.Context_Menu_Key }{
		{sdl3.K_UP, .Up},
		{sdl3.K_DOWN, .Down},
		{sdl3.K_HOME, .Home},
		{sdl3.K_END, .End},
		{sdl3.K_RETURN, .Activate},
		{sdl3.K_SPACE, .Activate},
		{sdl3.K_ESCAPE, .Cancel},
	}
	for c in context_cases {
		testing.expect(t, context_menu_key_from_sdl(c.key) == c.action, "context-menu key maps to the expected Runtime action")
	}
	testing.expect(t, context_menu_key_from_sdl(sdl3.K_TAB) == .Other,
		"unhandled context-menu keys remain available to Tab traversal and app shortcuts")
}

@(test)
test_sdl_application_shortcuts_respect_text_focus_and_platform_primary_modifier :: proc(t: ^testing.T) {
	primary := sdl3.KMOD_CTRL
	when ODIN_OS == .Darwin { primary = sdl3.KMOD_GUI }
	find, find_ok := application_key_from_sdl(sdl3.K_F, primary)
	search, search_ok := application_key_from_sdl(sdl3.K_F, primary|sdl3.KMOD_SHIFT)
	palette, palette_ok := application_key_from_sdl(sdl3.K_P, primary|sdl3.KMOD_SHIFT)
	zoom, zoom_ok := application_key_from_sdl(sdl3.K_EQUALS, primary)
	testing.expect(t, find_ok && find == .Find && search_ok && search == .Workspace_Search &&
		palette_ok && palette == .Open_Command_Palette && zoom_ok && zoom == .Zoom_In,
		"platform primary shortcuts map to Alicorn application commands")
	ordinary_f, ordinary_f_ok := application_key_from_sdl(sdl3.K_F, {}, true)
	ordinary_left, ordinary_left_ok := application_key_from_sdl(sdl3.K_LEFT, {}, true)
	text_space, text_space_ok := application_key_from_sdl(sdl3.K_SPACE, {}, true)
	text_find, text_find_ok := application_key_from_sdl(sdl3.K_F, primary, true)
	testing.expect(t, ordinary_left_ok && ordinary_left == .Left && text_space_ok &&
		text_space == .Toggle && !alicorn.application_key_can_preempt_text_field(.Left) &&
		!alicorn.application_key_can_preempt_text_field(.Toggle),
		"navigation and Space translate while text has focus; the shared policy still keeps them with the editor unless a scope declares a text preemption")
	testing.expect(t, !ordinary_f_ok && text_find_ok && text_find == .Find,
		"ordinary character-shaped keys remain with the focused editor while explicit shortcuts may preempt")
	cycle, cycle_ok := application_key_from_sdl(sdl3.K_TAB, sdl3.KMOD_CTRL|sdl3.KMOD_SHIFT, true)
	testing.expect(t, cycle_ok && cycle == .Tab_Previous,
		"Control+Shift+Tab remains document navigation even when text has focus")
}

@(test)
test_sdl_text_key_mapping_preserves_platform_editing_conventions :: proc(t: ^testing.T) {
	word_modifier := sdl3.KMOD_CTRL if ODIN_OS != .Darwin else sdl3.KMOD_ALT
	word_left, word_ok := text_key_event_from_sdl(sdl3.K_LEFT, word_modifier|sdl3.KMOD_SHIFT)
	testing.expect(t, word_ok && word_left.key == .Word_Left && word_left.shift &&
		word_left.control == (ODIN_OS != .Darwin) && word_left.alt == (ODIN_OS == .Darwin),
		"platform word modifier is mapped while raw modifiers remain available")

	line_modifier := sdl3.KMOD_GUI if ODIN_OS == .Darwin else sdl3.Keymod{}
	line_end, line_ok := text_key_event_from_sdl(sdl3.K_RIGHT, line_modifier)
	if ODIN_OS == .Darwin {
		testing.expect(t, line_ok && line_end.key == .Line_End && line_end.super,
			"Command-Right maps to line end on macOS")
	} else {
		testing.expect(t, line_ok && line_end.key == .Right && !line_end.super,
			"GUI modifier does not alter line navigation on Windows/Linux")
	}

	document_modifier := sdl3.KMOD_CTRL if ODIN_OS != .Darwin else sdl3.KMOD_GUI
	home, home_ok := text_key_event_from_sdl(sdl3.K_HOME, document_modifier)
	testing.expect(t, home_ok && home.key == .Document_Start,
		"platform document modifier maps Home to document start")

	up, up_ok := text_key_event_from_sdl(sdl3.K_UP, document_modifier)
	if ODIN_OS == .Darwin {
		testing.expect(t, up_ok && up.key == .Document_Start,
			"Command-Up maps to document start on macOS")
	} else {
		testing.expect(t, up_ok && up.key == .Up,
			"Control-Up remains visual-line navigation on Windows/Linux")
	}

	word_delete, delete_ok := text_key_event_from_sdl(sdl3.K_BACKSPACE, word_modifier)
	testing.expect(t, delete_ok && word_delete.key == .Delete_Word_Backward,
		"platform word modifier maps Backspace to word deletion")
	_, printable_ok := text_key_event_from_sdl(sdl3.K_A, {})
	testing.expect(t, !printable_ok, "ordinary printable keys stay on the text-input/IME path")
}

@(test)
test_menu_modifier_mapping_preserves_primary_and_super_roles :: proc(t: ^testing.T) {
	primary_modifier: sdl3.Keymod = sdl3.KMOD_CTRL
	super_modifier: sdl3.Keymod = sdl3.KMOD_GUI
	when ODIN_OS == .Darwin {
		primary_modifier = sdl3.KMOD_GUI
		super_modifier = sdl3.KMOD_CTRL
	}
	testing.expect(t, menu_modifiers_from_sdl(primary_modifier) == alicorn.Menu_Modifiers{.Primary},
		"Primary must map to Ctrl on Windows/Linux and Command on macOS")
	testing.expect(t, menu_modifiers_from_sdl(super_modifier) == alicorn.Menu_Modifiers{.Super},
		"Super must map to the Windows key on Windows/Linux and Control on macOS")
	modifiers := menu_modifiers_from_sdl(
		sdl3.KMOD_SHIFT | sdl3.KMOD_ALT | primary_modifier | super_modifier,
	)
	testing.expect(t, modifiers == alicorn.Menu_Modifiers{.Primary, .Shift, .Alt, .Super},
		"all four menu modifiers must be represented")
	testing.expect(t, menu_modifiers_from_sdl({}) == alicorn.Menu_Modifiers{},
		"an unmodified key has no menu modifiers")
}
