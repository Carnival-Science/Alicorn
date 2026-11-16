package web_host

import alicorn "alicorn:runtime"

// Browser_Key_Event is the small KeyboardEvent projection needed for Alicorn
// command mapping. Browser DOM events remain owned by the web host; Runtime
// consumes only the platform-neutral results below.
Browser_Key_Event :: struct {
	code: string,
	control, shift, alt, meta: bool,
}

Browser_Platform :: enum { Windows, MacOS, Linux, Other }

Browser_Wheel_Mode :: enum { Pixels, Lines, Pages }

web_keypress_is_text :: proc(event: Browser_Key_Event, key: string, composing: bool) -> bool {
	// Preserve Alt/Option and Ctrl+Alt keyboard layouts such as AltGr when the
	// browser reports an actual text value. Ctrl-only and Meta chords remain
	// application/browser shortcuts.
	if composing || (event.control && !event.alt) || event.meta || len(key) == 0 { return false }
	if key == "Dead" || key == "Process" || key == "Unidentified" { return false }
	switch event.code {
	case "Enter", "NumpadEnter", "Tab", "Backspace", "Delete", "Escape":
		return false
	}
	return true
}

// web_scroll_event converts DOM wheel values to Alicorn's line-like deltas.
// Pixel deltas are normalized to a 24 CSS-pixel step; page deltas are scaled
// by the canvas height. DOM wheel signs describe scrolling direction, while
// Alicorn's signs describe content movement, so both axes are inverted.
web_scroll_event :: proc(
	delta_x, delta_y: f64,
	mode: Browser_Wheel_Mode,
	viewport_height: f32,
	x, y: f32,
	modifiers: alicorn.Input_Modifiers = {},
) -> alicorn.Scroll_Event {
	scale: f32 = 1.0 / 24.0
	switch mode {
	case .Lines:
		scale = 1
	case .Pages:
		scale = max(viewport_height, 24) / 24
	case .Pixels:
	}
	resolved_x := -f32(delta_x) * scale
	resolved_y := -f32(delta_y) * scale
	return alicorn.Scroll_Event{
		delta_x=resolved_x,
		delta_y=resolved_y,
		ticks_x=int(resolved_x),
		ticks_y=int(resolved_y),
		x=x,
		y=y,
		modifiers=modifiers,
	}
}

web_key_primary_modifier :: proc(event: Browser_Key_Event, platform: Browser_Platform) -> bool {
	return event.meta if platform == .MacOS else event.control
}

// web_application_key mirrors the native application shortcut vocabulary.
// A browser host should call it only after giving text composition and focused
// text editing their normal first-refusal path.
web_application_key :: proc(
	event: Browser_Key_Event,
	platform: Browser_Platform,
	menus_open := false,
) -> (key: alicorn.Application_Key, handled: bool) {
	primary := web_key_primary_modifier(event, platform)
	switch event.code {
	case "ArrowLeft": return .Left, true
	case "ArrowRight": return .Right, true
	case "ArrowUp": return .Up, true
	case "ArrowDown": return .Down, true
	case "PageUp": return .Page_Up, true
	case "PageDown": return .Page_Down, true
	case "Home": return .Home, true
	case "End": return .End, true
	case "Digit1", "Numpad1": return .Command_1, true
	case "Digit2", "Numpad2": return .Command_2, true
	case "Digit3", "Numpad3": return .Command_3, true
	case "Space": return .Toggle, true
	case "Escape": return .Escape, true
	case "Enter", "NumpadEnter": return .Return, true
	case "Tab":
		if event.control {
			return .Tab_Previous if event.shift else .Tab_Next, true
		}
	case "KeyP":
		if primary && event.shift && !menus_open { return .Open_Command_Palette, true }
	case "KeyF":
		if primary { return .Workspace_Search if event.shift else .Find, true }
		return .Fit_Selection, true
	case "F3": return .Find_Previous if event.shift else .Find_Next, true
	case "Equal", "NumpadAdd":
		if primary { return .Zoom_In, true }
	case "Minus", "NumpadSubtract":
		if primary { return .Zoom_Out, true }
	case "Digit0", "Numpad0":
		if primary { return .Zoom_Reset, true }
	case "F2": return .Workspace_Rename, true
	case "KeyO":
		if primary && !menus_open { return .Open_Repository, true }
	case "ContextMenu": return .Context_Menu, true
	case "F10":
		if event.shift { return .Context_Menu, true }
	}
	return {}, false
}

// web_text_navigation_key maps a browser keydown to Alicorn's semantic text
// editing vocabulary. The browser host supplies is_macos from its platform
// capability probe so word, line, and document shortcuts match native policy.
web_text_navigation_key :: proc(
	event: Browser_Key_Event,
	platform: Browser_Platform,
) -> (mapped: alicorn.Application_Text_Key_Event, ok: bool) {
	word := event.control
	line := false
	document := event.control
	is_macos := platform == .MacOS
	if is_macos {
		word = event.alt
		line = event.meta
		document = event.meta
	}
	switch event.code {
	case "ArrowLeft":
		if line { mapped.key = .Line_Start }
		else if word { mapped.key = .Word_Left }
		else { mapped.key = .Left }
	case "ArrowRight":
		if line { mapped.key = .Line_End }
		else if word { mapped.key = .Word_Right }
		else { mapped.key = .Right }
	case "Home": mapped.key = .Document_Start if document else .Home
	case "End": mapped.key = .Document_End if document else .End
	case "ArrowUp":
		if is_macos && document { mapped.key = .Document_Start }
		else { mapped.key = .Up }
	case "ArrowDown":
		if is_macos && document { mapped.key = .Document_End }
		else { mapped.key = .Down }
	case "PageUp": mapped.key = .Page_Up
	case "PageDown": mapped.key = .Page_Down
	case "Backspace":
		if line { mapped.key = .Delete_Line_Backward }
		else if word { mapped.key = .Delete_Word_Backward }
		else { mapped.key = .Backspace }
	case "Delete":
		if line { mapped.key = .Delete_Line_Forward }
		else if word { mapped.key = .Delete_Word_Forward }
		else { mapped.key = .Delete }
	case "Tab": mapped.key = .Tab
	case: return {}, false
	}
	mapped.shift = event.shift
	mapped.control = event.control
	mapped.alt = event.alt
	mapped.super = event.meta
	return mapped, true
}
