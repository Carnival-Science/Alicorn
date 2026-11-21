package alicorn

import "core:fmt"

// Native menu descriptions are shared by every Alicorn host. The model lives in
// the runtime package so the reference SDL_GPU host, the hosted SDL3/WebGPU
// host, and renderer-agnostic tests use one definition instead of parallel
// copies. Menu transport values are host-neutral: hosts translate their own key
// and modifier constants at the boundary.

Menu_Item_Kind :: enum {
	Command,
	Separator,
	Submenu,
}

Menu_Modifier :: enum {
	Primary,
	Shift,
	Alt,
	Super,
}

Menu_Modifiers :: distinct bit_set[Menu_Modifier; u8]

// A shortcut uses one printable key plus platform-neutral modifiers.
// Primary means Ctrl on Windows/Linux and Command on macOS; Super maps to the
// Windows key on Windows/Linux and Control on macOS.
Menu_Shortcut :: struct {
	key:       rune,
	modifiers: Menu_Modifiers,
}

// Menu descriptions are borrowed for the duration of the host session. Labels
// and menu structure are snapshotted when the host prepares its native menu;
// Action_State is read from the borrowed item storage whenever a native menu
// opens or a host processes an accelerator. Keep that storage stable and update
// its state on the application thread.
Menu_Item :: struct {
	kind:     Menu_Item_Kind,
	command:  Action_ID,
	label:    string,
	state:    Action_State,
	shortcut: Menu_Shortcut,
	items:    []Menu_Item,
}

Menu :: struct {
	label: string,
	items: []Menu_Item,
	// A nonzero command turns this top-level label into a direct action instead
	// of a popup menu. Its state and shortcut are borrowed like item state.
	command: Action_ID,
	state:   Action_State,
	shortcut: Menu_Shortcut,
}

// Menu_Presentation is host presentation policy. Hidden affects only Windows
// integrated-title-bar labels. The native menu descriptions, command shortcuts,
// and Alt menu access remain available.
Menu_Presentation :: enum { Labels, Hidden }

// menu_shortcut_key_equal compares one printable shortcut key case
// insensitively. A zero shortcut key never matches.
menu_shortcut_key_equal :: proc(shortcut_key, key: rune) -> bool {
	if shortcut_key == 0 { return false }
	upper_key := key
	if upper_key >= 'a' && upper_key <= 'z' { upper_key -= ('a' - 'A') }
	upper_shortcut_key := shortcut_key
	if upper_shortcut_key >= 'a' && upper_shortcut_key <= 'z' { upper_shortcut_key -= ('a' - 'A') }
	return upper_key == upper_shortcut_key
}

// menu_shortcut_modifiers_match requires an exact modifier set. A shortcut
// bound to Primary+S must not fire for Primary+Shift+S, Primary+Alt+S, or a
// Super-modified chord.
menu_shortcut_modifiers_match :: proc(expected, actual: Menu_Modifiers) -> bool {
	return (Menu_Modifier.Primary in expected) == (Menu_Modifier.Primary in actual) &&
		(Menu_Modifier.Shift in expected) == (Menu_Modifier.Shift in actual) &&
		(Menu_Modifier.Alt in expected) == (Menu_Modifier.Alt in actual) &&
		(Menu_Modifier.Super in expected) == (Menu_Modifier.Super in actual)
}

menu_match_shortcut_items :: proc(
	items: []Menu_Item,
	key: rune,
	modifiers: Menu_Modifiers,
) -> (command: Action_ID, found: bool) {
	for item in items {
		if item.kind == .Submenu {
			if command, found = menu_match_shortcut_items(item.items, key, modifiers); found {
				return command, true
			}
		} else if item.kind == .Command && item.state.enabled && item.command != Action_ID(0) &&
			item.shortcut.key != 0 && menu_shortcut_modifiers_match(item.shortcut.modifiers, modifiers) &&
			menu_shortcut_key_equal(item.shortcut.key, key) {
			return item.command, true
		}
	}
	return {}, false
}

// menu_match_shortcut walks top-level direct commands in menu order and then
// each menu's items depth-first. It ignores disabled commands so a disabled
// accelerator is neither dispatched nor consumed.
menu_match_shortcut :: proc(
	menus: []Menu,
	key: rune,
	modifiers: Menu_Modifiers,
) -> (command: Action_ID, found: bool) {
	for description in menus {
		if description.command != Action_ID(0) && description.state.enabled &&
			description.shortcut.key != 0 &&
			menu_shortcut_modifiers_match(description.shortcut.modifiers, modifiers) &&
			menu_shortcut_key_equal(description.shortcut.key, key) {
			return description.command, true
		}
		if command, found = menu_match_shortcut_items(description.items, key, modifiers); found {
			return command, true
		}
	}
	return {}, false
}

@(private)
menu_items_command_enabled :: proc(
	items: []Menu_Item,
	command: Action_ID,
) -> (found: bool, enabled: bool) {
	for item in items {
		if item.kind == .Submenu {
			submenu_found, submenu_enabled := menu_items_command_enabled(item.items, command)
			if submenu_found {
				found = true
				if submenu_enabled { enabled = true }
			}
		} else if item.kind == .Command && command != Action_ID(0) && item.command == command {
			found = true
			if item.state.enabled { enabled = true }
		}
	}
	return
}

// menu_command_enabled applies the shared enabled gate for one transport
// command. A top-level direct command uses the window's borrowed description
// state; otherwise every borrowed item that carries this command must include
// at least one enabled entry, and the runtime's registered action (if any) must
// be enabled. Unknown runtime actions remain dispatchable so hosts may forward
// chrome commands the application handles directly.
menu_command_enabled :: proc(menus: []Menu, rt: ^Runtime, command: Action_ID) -> bool {
	direct_command := false
	for description in menus {
		if description.command == command && command != Action_ID(0) {
			direct_command = true
			if !description.state.enabled { return false }
		}
	}
	if !direct_command {
		found, enabled := menu_menus_command_enabled(menus, command)
		if found && !enabled { return false }
		if rt != nil {
			_, state, action_found := action_lookup(rt, command)
			if action_found && !state.enabled { return false }
		}
	}
	return true
}

@(private)
menu_menus_command_enabled :: proc(
	menus: []Menu,
	command: Action_ID,
) -> (found: bool, enabled: bool) {
	for description in menus {
		items_found, items_enabled := menu_items_command_enabled(description.items, command)
		if items_found {
			found = true
			if items_enabled { enabled = true }
		}
	}
	return
}

// menu_shortcut_label formats a shortcut for a native menu item label. Windows
// uses this verbatim after a tab; other adapters may present their own labels.
menu_shortcut_label :: proc(shortcut: Menu_Shortcut) -> string {
	if shortcut.key == 0 { return "" }
	modifiers := shortcut.modifiers
	primary, shift, alt, super := "", "", "", ""
	if Menu_Modifier.Primary in modifiers { primary = "Ctrl+" }
	if Menu_Modifier.Shift in modifiers { shift = "Shift+" }
	if Menu_Modifier.Alt in modifiers { alt = "Alt+" }
	if Menu_Modifier.Super in modifiers { super = "Win+" }
	return fmt.tprintf("%s%s%s%s%c", primary, shift, alt, super, shortcut.key)
}
