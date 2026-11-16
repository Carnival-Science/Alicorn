#+build !js
package web_host

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_web_application_key_mapping :: proc(t: ^testing.T) {
	key, ok := web_application_key(Browser_Key_Event{code="ArrowLeft"}, .Windows)
	testing.expect(t, ok && key == .Left)
	key, ok = web_application_key(Browser_Key_Event{code="KeyF", control=true}, .Windows)
	testing.expect(t, ok && key == .Find)
	key, ok = web_application_key(Browser_Key_Event{code="KeyF", meta=true, shift=true}, .MacOS)
	testing.expect(t, ok && key == .Workspace_Search)
	key, ok = web_application_key(Browser_Key_Event{code="KeyF"}, .Windows)
	testing.expect(t, ok && key == .Fit_Selection)
	key, ok = web_application_key(Browser_Key_Event{code="KeyP", meta=true, shift=true}, .MacOS)
	testing.expect(t, ok && key == .Open_Command_Palette)
	_, ok = web_application_key(Browser_Key_Event{code="KeyP", meta=true, shift=true}, .MacOS, menus_open=true)
	testing.expect(t, !ok, "an open menu keeps the command-palette shortcut")
	key, ok = web_application_key(Browser_Key_Event{code="Tab", control=true, shift=true}, .Windows)
	testing.expect(t, ok && key == .Tab_Previous)
	key, ok = web_application_key(Browser_Key_Event{code="F3", shift=true}, .Windows)
	testing.expect(t, ok && key == .Find_Previous)
	key, ok = web_application_key(Browser_Key_Event{code="Digit0", control=true}, .Windows)
	testing.expect(t, ok && key == .Zoom_Reset)
	_, ok = web_application_key(Browser_Key_Event{code="KeyX"}, .Windows)
	testing.expect(t, !ok)
	windows_other_modifier, windows_other_modifier_ok :=
		web_application_key(Browser_Key_Event{code="KeyF", meta=true}, .Windows)
	mac_other_modifier, mac_other_modifier_ok :=
		web_application_key(Browser_Key_Event{code="KeyF", control=true}, .MacOS)
	testing.expect(t, windows_other_modifier_ok && windows_other_modifier == .Fit_Selection &&
		mac_other_modifier_ok && mac_other_modifier == .Fit_Selection,
		"non-primary modifiers must not trigger the Find or workspace-search shortcuts")
	testing.expect(t, !alicorn.application_key_can_preempt_text_field(.Escape, composition_active=true))
	testing.expect(t, alicorn.application_key_can_preempt_text_field(.Escape, composition_active=false))
}

@(test)
test_web_text_navigation_mapping_matches_platform_shortcuts :: proc(t: ^testing.T) {
	windows, windows_ok := web_text_navigation_key(
		Browser_Key_Event{code="ArrowLeft", control=true, shift=true},
		.Windows,
	)
	testing.expect(t, windows_ok && windows.key == .Word_Left && windows.shift && windows.control)

	mac_line, mac_line_ok := web_text_navigation_key(
		Browser_Key_Event{code="ArrowRight", meta=true},
		.MacOS,
	)
	testing.expect(t, mac_line_ok && mac_line.key == .Line_End && mac_line.super)

	mac_word_delete, mac_word_delete_ok := web_text_navigation_key(
		Browser_Key_Event{code="Backspace", alt=true},
		.MacOS,
	)
	testing.expect(t, mac_word_delete_ok && mac_word_delete.key == .Delete_Word_Backward)

	windows_document, windows_document_ok := web_text_navigation_key(
		Browser_Key_Event{code="Home", control=true},
		.Windows,
	)
	testing.expect(t, windows_document_ok && windows_document.key == .Document_Start)

	mac_document, mac_document_ok := web_text_navigation_key(
		Browser_Key_Event{code="ArrowDown", meta=true},
		.MacOS,
	)
	testing.expect(t, mac_document_ok && mac_document.key == .Document_End)

	_, unsupported := web_text_navigation_key(Browser_Key_Event{code="KeyA"}, .Windows)
	testing.expect(t, !unsupported)
}

@(test)
test_web_scroll_event_normalizes_dom_modes_and_signs :: proc(t: ^testing.T) {
	pixels := web_scroll_event(48, 72, .Pixels, 240, 12, 16)
	testing.expect(t, pixels.delta_x == -2 && pixels.delta_y == -3 &&
		pixels.x == 12 && pixels.y == 16)
	lines := web_scroll_event(2, 3, .Lines, 240, 0, 0)
	testing.expect(t, lines.delta_x == -2 && lines.delta_y == -3)
	pages := web_scroll_event(1, 2, .Pages, 240, 0, 0)
	testing.expect(t, pages.delta_x == -10 && pages.delta_y == -20)
	modified := web_scroll_event(0, 1, .Lines, 240, 1, 2,
		alicorn.Input_Modifiers{control=true, shift=true})
	testing.expect(t, modified.modifiers.control && modified.modifiers.shift)
}

@(test)
test_web_context_menu_shortcuts_are_recognized :: proc(t: ^testing.T) {
	key, ok := web_application_key(Browser_Key_Event{code="ContextMenu"}, .Windows)
	testing.expect(t, ok && key == .Context_Menu)
	key, ok = web_application_key(Browser_Key_Event{code="F10", shift=true}, .Windows)
	testing.expect(t, ok && key == .Context_Menu)
	_, ok = web_application_key(Browser_Key_Event{code="F10"}, .Windows)
	testing.expect(t, !ok)
}

@(test)
test_web_keypress_filter_preserves_text_and_ime_ownership :: proc(t: ^testing.T) {
	testing.expect(t, web_keypress_is_text(Browser_Key_Event{code="KeyA"}, "a", false))
	testing.expect(t, web_keypress_is_text(Browser_Key_Event{code="Space"}, " ", false))
	testing.expect(t, web_keypress_is_text(Browser_Key_Event{code="KeyA"}, "字", false))
	testing.expect(t, !web_keypress_is_text(Browser_Key_Event{code="KeyA", control=true}, "a", false))
	testing.expect(t, web_keypress_is_text(Browser_Key_Event{code="KeyQ", control=true, alt=true}, "@", false))
	testing.expect(t, web_keypress_is_text(Browser_Key_Event{code="KeyE", alt=true}, "€", false))
	testing.expect(t, !web_keypress_is_text(Browser_Key_Event{code="KeyA", meta=true}, "a", false))
	testing.expect(t, !web_keypress_is_text(Browser_Key_Event{code="KeyA"}, "a", true))
	testing.expect(t, !web_keypress_is_text(Browser_Key_Event{code="KeyA"}, "Dead", false))
	testing.expect(t, !web_keypress_is_text(Browser_Key_Event{code="Enter"}, "Enter", false))
}

@(test)
test_browser_utf16_selection_offsets_map_to_utf8_characters :: proc(t: ^testing.T) {
	value := "aé字😀z"
	testing.expect(t, browser_utf16_offset_to_character_index(value, 0) == 0)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 1) == 1)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 2) == 2)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 3) == 3)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 3, round_up=true) == 3,
		"a selection endpoint exactly at a surrogate pair's start stays before it")
	testing.expect(t, browser_utf16_offset_to_character_index(value, 4) == 3,
		"an offset inside an emoji surrogate pair rounds down for a selection start")
	testing.expect(t, browser_utf16_offset_to_character_index(value, 4, round_up=true) == 4,
		"an offset inside an emoji surrogate pair rounds up for a selection end")
	testing.expect(t, browser_utf16_offset_to_character_index(value, 5) == 4)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 5, round_up=true) == 4,
		"a selection endpoint exactly after a surrogate pair stays after it")
	testing.expect(t, browser_utf16_offset_to_character_index(value, 6) == 5)
	testing.expect(t, browser_utf16_offset_to_character_index(value, 99) == 5,
		"out-of-range DOM offsets clamp to the end of the string")
}
