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
