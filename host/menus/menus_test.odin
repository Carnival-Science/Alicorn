package host_menus

import "core:testing"
import alicorn "alicorn:runtime"

// The fixture mirrors the shapes a real editor menu tree uses: File/Edit/View/
// Help top-level menus, command shortcuts, separators, a nested submenu, a
// checked command, a disabled command, and a direct top-level command.
Menu_Fixture_State :: struct {
	calls:        int,
	last_command: alicorn.Action_ID,
	commands:     [8]alicorn.Action_ID,
}

menu_fixture_callback :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	_ = rt
	state := cast(^Menu_Fixture_State)data
	state.calls += 1
	state.last_command = command
	if state.calls <= len(state.commands) { state.commands[state.calls-1] = command }
}

Menu_Fixture :: struct {
	state:        Menu_Fixture_State,
	menu_state:   Menu_Service,
	file_items:   [6]alicorn.Menu_Item,
	recent_items: [1]alicorn.Menu_Item,
	edit_items:   [4]alicorn.Menu_Item,
	view_items:   [2]alicorn.Menu_Item,
	help_items:   [1]alicorn.Menu_Item,
	menus:        [5]alicorn.Menu,
}

menu_fixture_init :: proc(fixture: ^Menu_Fixture) -> ^Menu_Service {
	fixture.recent_items = [1]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(5), label="notes.md", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'1', {.Primary}}},
	}
	fixture.file_items = [6]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(1), label="New", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'N', {.Primary}}},
		{kind=.Command, command=alicorn.Action_ID(2), label="Open…", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'O', {.Primary}}},
		{kind=.Submenu, label="Open Recent", state=alicorn.Action_State{enabled=true}},
		{kind=.Separator},
		{kind=.Command, command=alicorn.Action_ID(3), label="Save", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'S', {.Primary}}},
		{kind=.Command, command=alicorn.Action_ID(4), label="Save As", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'S', {.Primary, .Shift}}},
	}
	fixture.file_items[2].items = fixture.recent_items[:]
	fixture.edit_items = [4]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(6), label="Cut", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'X', {.Primary}}},
		{kind=.Command, command=alicorn.Action_ID(7), label="Copy", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'C', {.Primary}}},
		{kind=.Command, command=alicorn.Action_ID(8), label="Paste", state=alicorn.Action_State{enabled=false}, shortcut=alicorn.Menu_Shortcut{'V', {.Primary}}},
		{kind=.Separator},
	}
	fixture.view_items = [2]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(9), label="Word Wrap", state=alicorn.Action_State{enabled=true, checked=true}},
		{kind=.Command, command=alicorn.Action_ID(10), label="Command Palette", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'P', {.Primary, .Shift}}},
	}
	fixture.help_items = [1]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(11), label="About", state=alicorn.Action_State{enabled=true}},
	}
	fixture.menus = [5]alicorn.Menu{
		{label="File", items=fixture.file_items[:]},
		{label="Edit", items=fixture.edit_items[:]},
		{label="View", items=fixture.view_items[:]},
		{label="Help", items=fixture.help_items[:]},
		{label="Sync", command=alicorn.Action_ID(12), state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'Y', {.Primary}}},
	}
	menu_service_init(
		&fixture.menu_state,
		fixture.menus[:],
		alicorn.Menu_Presentation.Labels,
		rawptr(&fixture.state),
		menu_fixture_callback,
	)
	return &fixture.menu_state
}

@(test)
test_menu_service_matches_scratchpad_shaped_shortcuts :: proc(t: ^testing.T) {
	fixture: Menu_Fixture
	service := menu_fixture_init(&fixture)
	primary := alicorn.Menu_Modifiers{.Primary}

	command, found := menu_service_match_shortcut(service, 'X', primary)
	testing.expect(t, found && command == alicorn.Action_ID(6), "Primary+X should match Cut")

	command, found = menu_service_match_shortcut(service, 's', primary)
	testing.expect(t, found && command == alicorn.Action_ID(3), "shortcut key comparison should be case insensitive")

	command, found = menu_service_match_shortcut(service, 'S', primary + {.Shift})
	testing.expect(t, found && command == alicorn.Action_ID(4), "Primary+Shift+S should match Save As, not Save")

	command, found = menu_service_match_shortcut(service, '1', primary)
	testing.expect(t, found && command == alicorn.Action_ID(5), "nested submenu shortcuts should match")

	command, found = menu_service_match_shortcut(service, 'P', primary + {.Shift})
	testing.expect(t, found && command == alicorn.Action_ID(10), "a second menu should resolve its own accelerator")

	command, found = menu_service_match_shortcut(service, 'Y', primary)
	testing.expect(t, found && command == alicorn.Action_ID(12), "a direct top-level command should match its shortcut")

	_, found = menu_service_match_shortcut(service, 'S', primary + {.Alt})
	testing.expect(t, !found, "an unexpected modifier must not match a shortcut")

	_, found = menu_service_match_shortcut(service, 'S', primary + {.Super})
	testing.expect(t, !found, "Super is a distinct modifier from Primary")

	_, found = menu_service_match_shortcut(service, 'V', primary)
	testing.expect(t, !found, "a disabled command must not match an accelerator")

	fixture.file_items[4].state.enabled = false
	_, found = menu_service_match_shortcut(service, 'S', primary)
	testing.expect(t, !found, "disabling borrowed state must disable the accelerator")
	fixture.file_items[4].state.enabled = true
	command, found = menu_service_match_shortcut(service, 'S', primary)
	testing.expect(t, found && command == alicorn.Action_ID(3), "re-enabling borrowed state must restore the accelerator")
}

@(test)
test_menu_service_shortcut_dispatch_and_repeat_suppression :: proc(t: ^testing.T) {
	fixture: Menu_Fixture
	service := menu_fixture_init(&fixture)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	primary := alicorn.Menu_Modifiers{.Primary}

	testing.expect(t, menu_service_try_shortcut(service, &rt, 'X', primary, false),
		"a matching non-repeating accelerator should be consumed")
	testing.expect(t, fixture.state.calls == 1 && fixture.state.last_command == alicorn.Action_ID(6),
		"one accelerator should dispatch exactly one command")

	testing.expect(t, menu_service_try_shortcut(service, &rt, 'X', primary, true),
		"a repeating matching accelerator should remain consumed")
	testing.expect(t, fixture.state.calls == 1, "a repeating accelerator must not dispatch again")

	testing.expect(t, !menu_service_try_shortcut(service, &rt, 'Z', primary, false),
		"an unbound key should not be consumed")

	// A disabled accelerator is not consumed either: the key remains available
	// to application text and shortcut routing, matching the native host.
	testing.expect(t, !menu_service_try_shortcut(service, &rt, 'V', primary, false),
		"a disabled accelerator must not be consumed")
	testing.expect(t, fixture.state.calls == 1, "a disabled accelerator must not dispatch")
}

@(test)
test_menu_service_dispatch_applies_enabled_gate_and_trace :: proc(t: ^testing.T) {
	fixture: Menu_Fixture
	service := menu_fixture_init(&fixture)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200}, alicorn.Runtime_Config{trace_capacity=8})
	defer alicorn.destroy_runtime(&rt)

	testing.expect(t, menu_service_dispatch_command(service, &rt, alicorn.Action_ID(7)),
		"an enabled command should dispatch")
	testing.expect(t, fixture.state.calls == 1, "the host callback should receive the gated command")

	testing.expect(t, !menu_service_dispatch_command(service, &rt, alicorn.Action_ID(8)),
		"a disabled menu item must not dispatch")
	testing.expect(t, fixture.state.calls == 1, "a disabled menu item must not reach the callback")

	fixture.menus[4].state.enabled = false
	testing.expect(t, !menu_service_dispatch_command(service, &rt, alicorn.Action_ID(12)),
		"a disabled direct top-level command must not dispatch")
	fixture.menus[4].state.enabled = true

	testing.expect(t, alicorn.action_update(&rt,
		alicorn.Action_Descriptor{id=alicorn.Action_ID(30), name="test.document.export", label="Export"},
		alicorn.Action_State{enabled=false}),
		"test action should register as disabled")
	testing.expect(t, !menu_service_dispatch_command(service, &rt, alicorn.Action_ID(30)),
		"a command backed by a disabled runtime action must not dispatch")
	_ = alicorn.action_update(&rt,
		alicorn.Action_Descriptor{id=alicorn.Action_ID(30), name="test.document.export", label="Export"},
		alicorn.Action_State{enabled=true})
	testing.expect(t, menu_service_dispatch_command(service, &rt, alicorn.Action_ID(30)),
		"enabling the runtime action should restore dispatch")
}

@(test)
test_menu_presentation_and_shortcut_labels :: proc(t: ^testing.T) {
	testing.expect(t, menu_presentation_labels_visible(.Labels, false),
		"system chrome always presents menu labels")
	testing.expect(t, menu_presentation_labels_visible(.Labels, true),
		"explicit Labels presentation shows integrated-titlebar labels")
	testing.expect(t, !menu_presentation_labels_visible(.Hidden, true),
		"Hidden suppresses integrated-titlebar labels")
	testing.expect(t, menu_presentation_labels_visible(.Hidden, false),
		"Hidden keeps a system menu bar; it only affects integrated-titlebar chrome")

	label := alicorn.menu_shortcut_label(alicorn.Menu_Shortcut{'S', {.Primary, .Shift}})
	testing.expect(t, label == "Ctrl+Shift+S", "shortcut labels must keep the native host's formatting")
	testing.expect(t, alicorn.menu_shortcut_label(alicorn.Menu_Shortcut{}) == "",
		"an unbound shortcut has no label")
}
