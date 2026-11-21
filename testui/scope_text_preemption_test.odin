package testui

import "core:testing"
import alicorn "alicorn:runtime"

// These fixtures exercise the scope-owned text preemption contract through the
// same host-neutral key path native applications use. One scope owns a search
// target (a built-in controlled Text_Field or a generic text_input_target) and
// a sibling grid that wants arrows and Space. text_preempt_keys decides whether
// those keys stay with the editor or reach the grid.

SCOPE_TEXT_ALL_KEYS :: alicorn.Interaction_Key_Set{
	.Left, .Right, .Up, .Down, .Home, .End, .Page_Up, .Page_Down, .Return, .Toggle,
}

SCOPE_TEXT_GRID_LABELS := [4]string{"Alpha", "Beta", "Gamma", "Delta"}

Scope_Text_App :: struct {
	// generic=false uses a controlled Text_Field; generic=true uses a
	// text_input_target owned by the application.
	generic: bool,
	// preempt mirrors the consumer's policy declaration. Toggling it between
	// descriptions proves the contract is configuration, not a code fork.
	preempt: bool,
	// nested=false registers only the outer scope; nested=true adds an inner
	// scope around the text target that declares Left on its own.
	nested: bool,
	modal_open: bool,

	query:       alicorn.Text_Field_Buffer,
	query_ready: bool,
	editor:      [64]u8,
	editor_len:  int,

	active:      int,
	activations: int,

	scope_events: int,
	last_key:     alicorn.Application_Key,
	have_key:     bool,

	inner_events:              int,
	last_inner_key:            alicorn.Application_Key,
	have_inner_key:            bool,
	modal_events:              int,
	modal_activations:         int,
	last_modal_key:            alicorn.Application_Key,
	have_modal_key:            bool,

	text_commits:  int,
	text_keys:     int,
	last_text_key: alicorn.Application_Text_Key_Event,

	outer:     alicorn.Node_ID,
	inner:     alicorn.Node_ID,
	search:    alicorn.Node_ID,
	modal:     alicorn.Node_ID,
	modal_search: alicorn.Node_ID,
}

scope_text_app_init :: proc(app: ^Scope_Text_App, initial: string) -> bool {
	buffer, ok := alicorn.text_field_buffer_init(initial, context.allocator)
	if !ok { return false }
	app.query = buffer
	app.query_ready = true
	return true
}

scope_text_app_destroy :: proc(app: ^Scope_Text_App) {
	if app.query_ready { alicorn.text_field_buffer_destroy(&app.query) }
	app.query_ready = false
}

@(private)
scope_text_apply_key :: proc(app: ^Scope_Text_App, key: alicorn.Application_Key) {
	#partial switch key {
	case .Left: app.active = max(app.active-1, 0)
	case .Right: app.active = min(app.active+1, len(SCOPE_TEXT_GRID_LABELS)-1)
	case .Up, .Home: app.active = 0
	case .Down, .End: app.active = len(SCOPE_TEXT_GRID_LABELS)-1
	case .Toggle, .Return: app.activations += 1
	}
}

@(private)
scope_text_drain_scope :: proc(
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	app: ^Scope_Text_App,
	inner: bool,
) {
	if owner == 0 { return }
	for {
		event, found := alicorn.interaction_event_next(rt, owner)
		if !found { break }
		if event.kind != .Key { continue }
		if inner {
			app.inner_events += 1
			app.last_inner_key = event.key
			app.have_inner_key = true
			// The inner scope only declares Left; still apply the key so the
			// outer scope cannot also observe it.
			scope_text_apply_key(app, event.key)
		} else {
			app.scope_events += 1
			app.last_key = event.key
			app.have_key = true
			scope_text_apply_key(app, event.key)
		}
		alicorn.invalidate_root(rt, "scope text fixture consumed a grid key")
	}
}

@(private)
scope_text_emit_grid :: proc(app: ^Scope_Text_App, ui: ^alicorn.UI) {
	for label, index in SCOPE_TEXT_GRID_LABELS {
		if alicorn.button(
			ui,
			label,
			key=alicorn.key_u64(0x5343454E0000+u64(index)),
			style=alicorn.layout_style(height=30, width=140),
		) {
			app.active = index
			app.activations += 1
		}
	}
}

@(private)
scope_text_emit_target :: proc(app: ^Scope_Text_App, ui: ^alicorn.UI) {
	if app.generic {
		target := alicorn.container_begin(
			ui,
			.Scroll_Region,
			label="Search",
			key=alicorn.key_string("scope-text-generic-search"),
			style=alicorn.layout_style(width=220, height=30),
		)
		if target != 0 {
			_ = alicorn.semantic_description(ui, .Text_Field, "Search")
			_ = alicorn.text_input_target(ui, target)
			_ = alicorn.text(ui, string(app.editor[:app.editor_len]), style=alicorn.layout_style(height=24))
			app.search = target
			alicorn.container_end(ui)
		}
		return
	}
	field := alicorn.text_field_controlled(
		ui,
		&app.query,
		key=alicorn.key_string("scope-text-field-search"),
		style=alicorn.layout_style(width=220, height=30),
	)
	app.search = field.node
	if field.node != 0 { _ = alicorn.semantic_text_field_label(ui, "Search") }
}

scope_text_render :: proc(app: ^Scope_Text_App, ui: ^alicorn.UI) {
	scope_text_drain_scope(ui.runtime, app.outer, app, inner=false)
	if app.nested { scope_text_drain_scope(ui.runtime, app.inner, app, inner=true) }

	owner := alicorn.container_begin(
		ui,
		.Container,
		label="Scope search grid",
		key=alicorn.key_string("scope-text-owner"),
		style=alicorn.layout_style(.Column, gap=4, padding=4),
	)
	app.outer = owner
	if owner == 0 { return }
	options := alicorn.Interaction_Scope_Options{keys=SCOPE_TEXT_ALL_KEYS}
	if app.preempt { options.text_preempt_keys = SCOPE_TEXT_ALL_KEYS }
	_ = alicorn.interaction_scope_register(ui.runtime, owner, rawptr(app), options)

	if app.nested {
		inner := alicorn.container_begin(
			ui,
			.Container,
			label="Scope search",
			key=alicorn.key_string("scope-text-inner"),
			style=alicorn.layout_style(.Column, gap=4),
		)
		app.inner = inner
		if inner != 0 {
			inner_options := alicorn.Interaction_Scope_Options{keys={.Left}}
			if app.preempt { inner_options.text_preempt_keys = {.Left} }
			_ = alicorn.interaction_scope_register(ui.runtime, inner, rawptr(app), inner_options)
			scope_text_emit_target(app, ui)
			alicorn.container_end(ui)
		}
	} else {
		app.inner = 0
		scope_text_emit_target(app, ui)
	}
	scope_text_emit_grid(app, ui)
	if alicorn.button(
		ui,
		"Open modal",
		key=alicorn.key_string("scope-text-open-modal"),
		style=alicorn.layout_style(height=30, width=140),
	) {
		app.modal_open = true
		alicorn.invalidate_root(ui.runtime, "scope text fixture opened its modal")
	}
	alicorn.container_end(ui)
}

@(private)
scope_text_drain_modal :: proc(rt: ^alicorn.Runtime, app: ^Scope_Text_App) {
	if app.modal == 0 { return }
	for {
		event, found := alicorn.interaction_event_next(rt, app.modal)
		if !found { break }
		if event.kind != .Key { continue }
		app.modal_events += 1
		app.last_modal_key = event.key
		app.have_modal_key = true
		app.modal_activations += 1
		alicorn.invalidate_root(rt, "scope text fixture modal consumed a key")
	}
}

scope_text_overlays :: proc(app: ^Scope_Text_App, ui: ^alicorn.UI) {
	if !app.modal_open { return }
	overlay := alicorn.modal_overlay_begin(
		ui,
		key=alicorn.key_string("scope-text-modal-overlay"),
		style=alicorn.layout_style(.Column, align=.Center, justify=.Center),
		backdrop_color=alicorn.Color{0.01, 0.02, 0.04, 0.7},
	)
	if overlay == 0 { return }
	app.modal = overlay
	_ = alicorn.interaction_scope_register(ui.runtime, overlay, rawptr(app), alicorn.Interaction_Scope_Options{
		keys={.Toggle},
		text_preempt_keys={.Toggle},
		modal=true,
	})
	scope_text_drain_modal(ui.runtime, app)
	panel := alicorn.container_begin(
		ui,
		.Container,
		label="Scope text modal",
		style=alicorn.layout_style(.Column, width=300, height=120, padding=12, gap=8),
	)
	if panel != 0 {
		_ = alicorn.semantic_description(ui, .Dialog, "Grid modal", "A modal scope that preempts Space while its own text target keeps focus.")
		_ = alicorn.text(ui, "Space activates this modal scope.", style=alicorn.layout_style(height=24))
		target := alicorn.container_begin(
			ui,
			.Scroll_Region,
			label="Modal search",
			key=alicorn.key_string("scope-text-modal-search"),
			style=alicorn.layout_style(width=200, height=30),
		)
		if target != 0 {
			_ = alicorn.semantic_description(ui, .Text_Field, "Modal search")
			_ = alicorn.text_input_target(ui, target)
			app.modal_search = target
			alicorn.container_end(ui)
		}
		if alicorn.button(ui, "Close modal", key=alicorn.key_string("scope-text-close-modal"), style=alicorn.layout_style(height=30, width=140)) {
			app.modal_open = false
			app.modal = 0
			app.modal_search = 0
			alicorn.invalidate_root(ui.runtime, "scope text fixture closed its modal")
		}
		alicorn.container_end(ui)
	}
	alicorn.modal_overlay_end(ui)
}

scope_text_on_text_key :: proc(
	state: rawptr,
	_rt: ^alicorn.Runtime,
	_owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app := cast(^Scope_Text_App)state
	app.text_keys += 1
	app.last_text_key = event
	if app.generic && event.key == .Backspace && app.editor_len > 0 {
		app.editor_len -= 1
	}
	return true
}

scope_text_on_text_input :: proc(
	state: rawptr,
	_rt: ^alicorn.Runtime,
	_owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Input_Event,
) {
	app := cast(^Scope_Text_App)state
	if event.kind != .Commit || len(event.text) == 0 { return }
	app.text_commits += 1
	chunk := event.text
	if len(chunk) > len(app.editor)-app.editor_len { chunk = chunk[:len(app.editor)-app.editor_len] }
	copy(app.editor[app.editor_len:], chunk)
	app.editor_len += len(chunk)
}

// ---------------------------------------------------------------------------
// Default precedence
// ---------------------------------------------------------------------------

@(test)
test_scope_text_field_default_keeps_editor_precedence :: proc(t: ^testing.T) {
	app := Scope_Text_App{}
	if !testing.expect(t, scope_text_app_init(&app, "ab"), "the fixture should own a text buffer") { return }
	defer scope_text_app_destroy(&app)
	h, status := open(&app, scope_text_render, width=420, height=320,
		render_overlays=scope_text_overlays,
		on_text_key=scope_text_on_text_key,
		on_text_input=scope_text_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	testing.expect(t, step(&h, Input{kind=.Key, key=.Tab}) == .Ok && app.search != 0 &&
		alicorn.focused_node(h.runtime) == app.search,
		"Tab should focus the search field before the grid")
	before, before_ok := alicorn.text_field_interaction(h.runtime, app.search)
	if !testing.expect(t, before_ok, "the search field should report its interaction state") { return }

	testing.expect(t, step(&h, Input{kind=.Key, key=.Home}) == .Ok &&
		app.scope_events == 0 && app.active == 0,
		"without text_preempt_keys Home should stay with the focused text field")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok,
		"Right should be accepted by the focused editor")
	after, after_ok := alicorn.text_field_interaction(h.runtime, app.search)
	testing.expect(t, after_ok && after.caret == 1 && app.scope_events == 0 &&
		app.active == 0,
		"without text_preempt_keys a focused text field should keep Right and leave the grid alone")

	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok &&
		app.scope_events == 0 && app.activations == 0,
		"without text_preempt_keys a focused text field should keep Space")

	testing.expect(t, step(&h, Input{kind=.Key, key=.Down}) == .Ok &&
		app.have_key && app.last_key == .Down && app.active == len(SCOPE_TEXT_GRID_LABELS)-1,
		"the existing command vocabulary should keep preempting a focused text field")

	testing.expect(t, step(&h, Input{kind=.Text_Commit, text="z"}) == .Ok && app.query.text == "azb",
		"committed characters should still reach the focused text field")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Backspace}) == .Ok && app.query.text == "ab",
		"Backspace should still edit the focused text field")
}

// ---------------------------------------------------------------------------
// Configured yield
// ---------------------------------------------------------------------------

@(test)
test_scope_text_field_configured_yield_navigates_and_activates :: proc(t: ^testing.T) {
	app := Scope_Text_App{preempt=true}
	if !testing.expect(t, scope_text_app_init(&app, "ab"), "the fixture should own a text buffer") { return }
	defer scope_text_app_destroy(&app)
	h, status := open(&app, scope_text_render, width=420, height=320,
		render_overlays=scope_text_overlays,
		on_text_key=scope_text_on_text_key,
		on_text_input=scope_text_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	testing.expect(t, step(&h, Input{kind=.Key, key=.Tab}) == .Ok &&
		alicorn.focused_node(h.runtime) == app.search,
		"Tab should focus the search field")
	before, before_ok := alicorn.text_field_interaction(h.runtime, app.search)
	if !testing.expect(t, before_ok, "the search field should report its interaction state") { return }

	for entry in ([?]struct{key: Key, active: int}{
		{.Right, 1},
		{.Right, 2},
		{.Left, 1},
		{.End, len(SCOPE_TEXT_GRID_LABELS)-1},
		{.Home, 0},
	}) {
		testing.expect(t, step(&h, Input{kind=.Key, key=entry.key}) == .Ok && app.active == entry.active &&
			app.have_key,
			"a declared yield should let the grid own navigation while the search field keeps focus")
	}
	after, after_ok := alicorn.text_field_interaction(h.runtime, app.search)
	testing.expect(t, after_ok && after.caret == before.caret,
		"yielded navigation must not move the text caret")

	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok &&
		app.last_key == .Toggle && app.activations == 1,
		"a declared yield should let Space activate through the scope")

	testing.expect(t, step(&h, Input{kind=.Text_Commit, text="q"}) == .Ok && app.query.text == "abq",
		"characters should still reach the focused text field")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Backspace}) == .Ok && app.query.text == "ab",
		"Backspace should still reach the focused text field")
	testing.expect(t, app.scope_events > 0 && app.text_commits == 0,
		"the scope should see only the declared keys while the field sees the edits")

	// IME composition owns every declared yield key.
	testing.expect(t, step(&h, Input{kind=.Text_Preedit, text="か"}) == .Ok,
		"the search field should accept a preedit")
	composing, composing_ok := alicorn.text_field_interaction(h.runtime, app.search)
	events := app.scope_events
	testing.expect(t, composing_ok && composing.composition_active, "the field should report active composition")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.scope_events == events &&
		app.active == 0,
		"active IME composition should keep a declared yield key with the text field")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok && app.scope_events == events &&
		app.activations == 1,
		"active IME composition should keep Space with the text field")
	testing.expect(t, step(&h, Input{kind=.Text_Cancel}) == .Ok,
		"composition should cancel through the harness")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.scope_events == events+1 &&
		app.active == 1,
		"after composition the declared yield should route to the scope again")
}

// ---------------------------------------------------------------------------
// Generic text target
// ---------------------------------------------------------------------------

@(test)
test_scope_generic_text_target_yield_and_composition :: proc(t: ^testing.T) {
	app := Scope_Text_App{generic=true, preempt=true}
	if !testing.expect(t, scope_text_app_init(&app, ""), "the fixture should own a text buffer") { return }
	defer scope_text_app_destroy(&app)
	h, status := open(&app, scope_text_render, width=420, height=320,
		render_overlays=scope_text_overlays,
		on_text_key=scope_text_on_text_key,
		on_text_input=scope_text_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	testing.expect(t, step(&h, Input{kind=.Key, key=.Tab}) == .Ok && app.search != 0 &&
		alicorn.text_input_target_is_active(h.runtime, app.search) &&
		alicorn.focused_node(h.runtime) == app.search,
		"Tab should focus the generic text target")

	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.have_key &&
		app.last_key == .Right && app.active == 1,
		"a declared yield should reach the scope from a generic text target")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok && app.last_key == .Toggle &&
		app.activations == 1,
		"Space should activate through the scope from a generic text target")

	testing.expect(t, step(&h, Input{kind=.Text_Commit, text="hi"}) == .Ok &&
		app.editor_len == 2 && string(app.editor[:app.editor_len]) == "hi",
		"committed characters should still reach the generic text target")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Backspace}) == .Ok &&
		app.last_text_key.key == .Backspace && app.editor_len == 1,
		"Backspace should still reach the generic text target's text-key route")

	// Preedit owns the target; declared yields must not preempt composition.
	testing.expect(t, step(&h, Input{kind=.Text_Preedit, text="かな"}) == .Ok &&
		h.application_composition_owner == app.search,
		"the generic text target should own the preedit")
	events := app.scope_events
	keys := app.text_keys
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.scope_events == events &&
		app.text_keys == keys+1 && app.last_text_key.key == .Right,
		"active composition should keep a declared yield key with the generic text target")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok && app.scope_events == events &&
		app.activations == 1,
		"active composition should keep Space with the generic text target")
	testing.expect(t, step(&h, Input{kind=.Text_Cancel}) == .Ok,
		"composition should cancel through the harness")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.scope_events == events+1 &&
		app.active == 2,
		"after composition the declared yield should route to the scope again")
}

// ---------------------------------------------------------------------------
// Nested scopes and a modal scope
// ---------------------------------------------------------------------------

@(test)
test_scope_text_yield_nested_and_modal_interplay :: proc(t: ^testing.T) {
	app := Scope_Text_App{preempt=true, nested=true}
	if !testing.expect(t, scope_text_app_init(&app, "ab"), "the fixture should own a text buffer") { return }
	defer scope_text_app_destroy(&app)
	h, status := open(&app, scope_text_render, width=520, height=420,
		render_overlays=scope_text_overlays,
		on_text_key=scope_text_on_text_key,
		on_text_input=scope_text_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	testing.expect(t, step(&h, Input{kind=.Key, key=.Tab}) == .Ok &&
		alicorn.focused_node(h.runtime) == app.search,
		"Tab should focus the nested search field")

	testing.expect(t, step(&h, Input{kind=.Key, key=.Left}) == .Ok && app.have_inner_key &&
		app.last_inner_key == .Left && app.active == 0,
		"the nearest declared scope should own Left")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Right}) == .Ok && app.have_key &&
		app.last_key == .Right && app.active == 1,
		"the outer scope should own a key the inner scope did not declare")

	// Open the modal without moving focus, then focus its own text target. This
	// exercises the modal scope owning Space for a descendant text owner while
	// active IME composition still takes the key back.
	app.modal_open = true
	alicorn.invalidate_root(h.runtime, "scope text fixture opened its modal")
	if !testing.expect(t, advance_time(&h, 0) == .Ok && app.modal != 0 && app.modal_search != 0,
		"the modal overlay and its text target should render") { return }
	_ = alicorn.focus(h.runtime, app.modal_search)
	if !testing.expect(t, advance_time(&h, 0) == .Ok &&
		alicorn.focused_node(h.runtime) == app.modal_search,
		"the modal text target should take focus inside the modal") { return }

	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok &&
		app.modal_events == 1 && app.modal_activations == 1 && app.have_modal_key &&
		app.last_modal_key == .Toggle && app.activations == 0,
		"a modal scope should preempt its declared Space ahead of its focused text target")

	testing.expect(t, step(&h, Input{kind=.Text_Preedit, text="か"}) == .Ok &&
		h.application_composition_owner == app.modal_search,
		"the modal text target should own the preedit")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok && app.modal_events == 1,
		"active composition should keep Space with the modal text target")
	testing.expect(t, step(&h, Input{kind=.Text_Cancel}) == .Ok,
		"composition should cancel through the harness")
	testing.expect(t, step(&h, Input{kind=.Key, key=.Space}) == .Ok &&
		app.modal_events == 2 && app.modal_activations == 2,
		"after composition the modal scope should preempt Space again")
}
