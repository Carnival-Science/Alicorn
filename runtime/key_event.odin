package alicorn

// Key_Event is Alicorn's one keyboard contract. Native hosts and headless
// harnesses produce this same struct; applications and the binding resolver
// never need to know whether the key arrived from SDL, the browser, or a
// synthetic test turn.
//
// The fields are deliberately value data:
//   - scancode is the host's physical-key value. It is diagnostic only and is
//     never interpreted by Runtime. Headless input may leave it zero.
//   - key is the host-neutral logical key used by bindings.
//   - modifiers use the same platform-neutral vocabulary as native menus, so
//     Primary means Ctrl on Windows/Linux and Command on macOS.
//   - composition_active and text_input_focused describe the host's text
//     precedence. produces_text reports that a committed character is expected
//     from this transition.
//   - application_key is the optional bridge into the legacy Application_Key
//     vocabulary. A host that cannot map the key leaves has_application_key
//     false; the binding resolver still sees the logical key.
//
// Binding matching is exact: a binding key matches only when both Key_Spec and
// the complete modifier set are equal. A host must normalize platform modifier
// state before constructing the event.

// Key_Spec is the bounded, host-neutral logical key vocabulary. It carries the
// printable and command keys a binding editor needs without exposing platform
// key constants. Unknown keys stay .Unknown and cannot match a binding, but
// still reach the host's ordinary Application_Key policy when the host mapped
// one.
Key_Spec :: enum u16 {
	Unknown,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Zero, One, Two, Three, Four, Five, Six, Seven, Eight, Nine,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Left, Right, Up, Down, Page_Up, Page_Down, Home, End, Insert,
	Space, Return, Escape, Tab, Backspace, Delete,
	Minus, Equal, Left_Bracket, Right_Bracket, Backslash, Semicolon,
	Apostrophe, Comma, Period, Slash, Grave,
}

// Key_Modifiers reuses the native-menu modifier vocabulary so bindings and
// menu accelerators cannot drift into two modifier models.
Key_Modifiers :: Menu_Modifiers

Key_Event :: struct {
	scancode:             u32,
	key:                  Key_Spec,
	modifiers:            Key_Modifiers,
	repeat:               bool,
	composition_active:   bool,
	text_input_focused:   bool,
	produces_text:        bool,
	timestamp_ns:         u64,
	application_key:      Application_Key,
	has_application_key:  bool,
}

// key_spec_is_printable reports keys that ordinarily contribute a character.
// Return, Escape, Tab, Backspace, Delete, and navigation keys are excluded even
// though some of them produce control input.
key_spec_is_printable :: proc(key: Key_Spec) -> bool {
	#partial switch key {
	case .A..=.Z, .Zero..=.Nine, .Space,
	     .Minus, .Equal, .Left_Bracket, .Right_Bracket, .Backslash,
	     .Semicolon, .Apostrophe, .Comma, .Period, .Slash, .Grave:
		return true
	case:
		return false
	}
}

// key_event_produces_text derives the host's expected text delivery from the
// logical key and normalized modifiers. It is the fallback for hosts that
// cannot ask their text system directly; a host with authoritative information
// (an active IME or an SDL text event in flight) should set produces_text
// itself.
key_event_produces_text :: proc(key: Key_Spec, modifiers: Key_Modifiers) -> bool {
	if !key_spec_is_printable(key) { return false }
	// Primary, Super, and Alt chords are application gestures. AltGr-style
	// Ctrl+Alt layouts are reported by the host's text system, not inferred
	// here.
	if Menu_Modifier.Primary in modifiers || Menu_Modifier.Super in modifiers ||
		Menu_Modifier.Alt in modifiers {
		return false
	}
	return true
}

key_modifiers_equal :: proc(a, b: Key_Modifiers) -> bool {
	return menu_shortcut_modifiers_match(Menu_Modifiers(a), Menu_Modifiers(b))
}

key_binding_matches :: proc(key: Key_Spec, modifiers: Key_Modifiers, expected: Key_Spec, expected_modifiers: Key_Modifiers) -> bool {
	return key == expected && key_modifiers_equal(modifiers, expected_modifiers)
}
