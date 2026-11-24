#+build !js
package alicorn

import "core:testing"

Interaction_Scope_Test_Nodes :: struct {
	owner:       Node_ID,
	modal_owner: Node_ID,
	button:      Node_ID,
	event:       Interaction_Event,
	found:       bool,
}

interaction_scope_test_describe :: proc(
	rt: ^Runtime,
	consume_owner: Node_ID = 0,
	register_normal := true,
	register_modal := true,
) -> Interaction_Scope_Test_Nodes {
	result := Interaction_Scope_Test_Nodes{}
	ui, should_build := begin_frame(rt)
	if !should_build { return result }
	container_begin_simple(&ui, .Root, label="interaction-scope-test-root", key="interaction-scope-test-root", style=layout_style(.Column))
	result.owner = container_begin(&ui, .Container, label="tree-scope", key="tree-scope", style=layout_style(.Column))
	result.button, _ = button_ex(&ui, "Tree item", key="tree-scope-button", style=layout_style(width=120, height=30))
	container_end(&ui)
	result.modal_owner = container_begin(&ui, .Container, label="modal-scope", key="modal-scope", style=layout_style(.Column))
	container_end(&ui)
	container_end(&ui)
	if register_normal {
		options := Interaction_Scope_Options{
			keys={.Down},
			composition_yield_keys={.Down},
			pointers={.Secondary_Down},
		}
		_ = interaction_scope_register(rt, result.owner, nil, options)
	}
	if register_modal {
		_ = interaction_scope_register(rt, result.modal_owner, nil,
			Interaction_Scope_Options{keys={.Escape}, modal=true})
	}
	if consume_owner != 0 {
		result.event, result.found = interaction_event_next(rt, consume_owner)
	}
	end_frame(&ui)
	return result
}

@(test)
test_interaction_scope_routes_to_focused_owner_and_modal_owner :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	nodes := interaction_scope_test_describe(&rt)
	testing.expect(t, nodes.owner != 0 && nodes.modal_owner != 0 && nodes.button != 0,
		"the test should retain a tree scope, modal scope, and focusable descendant")
	if nodes.button == 0 { return }
	_ = focus(&rt, nodes.button)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Down),
		"a key registered by the nearest focused ancestor should be consumed")
	nodes = interaction_scope_test_describe(&rt, nodes.owner)
	testing.expect(t, nodes.found && nodes.event.kind == .Key && nodes.event.key == .Down,
		"the focused tree should receive the key during its next description")

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Escape),
		"a matching modal scope should receive input ahead of the focused tree")
	nodes = interaction_scope_test_describe(&rt, nodes.modal_owner)
	testing.expect(t, nodes.found && nodes.event.kind == .Key && nodes.event.key == .Escape,
		"the modal owner should receive the event in its next description")

	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Down, composition_active=true),
		"a key yielded by the focused component during native text composition should remain unhandled")
}

@(test)
test_interaction_scope_routes_pointer_and_drops_events_for_retired_scope :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	nodes := interaction_scope_test_describe(&rt, register_modal=false)
	_ = focus(&rt, nodes.button)
	event := Pointer_Event{kind=.Down, x=12, y=12, button=POINTER_BUTTON_SECONDARY}
	testing.expect(t, application_dispatch_pointer(&rt, nil, nil, event, nodes.button),
		"a pointer event should route to the registered focused ancestor")
	nodes = interaction_scope_test_describe(&rt, nodes.owner)
	testing.expect(t, nodes.found && nodes.event.kind == .Pointer && nodes.event.target == nodes.button,
		"the component should receive the original hit target on its next description")

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Down), "the live scope should accept a key before removal")
	_ = interaction_scope_test_describe(&rt, register_normal=false, register_modal=false)
	testing.expect(t, len(rt.interaction_events) == 0,
		"events owned by a scope omitted from the next description should be discarded")
}

Interaction_Scroll_Scope_Test_Result :: struct {
	owner: Node_ID,
	event: Interaction_Event,
	found: bool,
}

interaction_scroll_scope_test_describe :: proc(rt: ^Runtime, consume_owner: Node_ID = 0) -> Interaction_Scroll_Scope_Test_Result {
	result := Interaction_Scroll_Scope_Test_Result{}
	ui, should_build := begin_frame(rt)
	if !should_build { return result }
	container_begin_simple(&ui, .Root, label="interaction-scroll-scope-root",
		key="interaction-scroll-scope-root", style=layout_style(.Column, width=240, height=120))
	region := scroll_region_begin(&ui, key=key_string("interaction-scroll-scope-region"),
		viewport_height=48, content_height=240,
		style=layout_style(.Column, width=180, height=48), scrollbars=.Hidden, focusable=true)
	result.owner = region.id
	_ = interaction_scope_register(rt, region.id, nil,
		Interaction_Scope_Options{keys={.Down}, composition_yield_keys={.Down}})
	scroll_region_end(&ui)
	container_end(&ui)
	if consume_owner != 0 {
		result.event, result.found = interaction_event_next(rt, consume_owner)
	}
	end_frame(&ui)
	return result
}

@(test)
test_focused_scroll_region_routes_component_scope_before_default_scroll :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	nodes := interaction_scroll_scope_test_describe(&rt)
	if !testing.expect(t, nodes.owner != 0, "the focusable scroll region should be retained") { return }
	if !testing.expect(t, focus(&rt, nodes.owner), "the component's scroll owner should accept focus") { return }
	if !testing.expect(t, application_route_focused_control_key(&rt, .Down),
		"a key declared by the focused component scope should be consumed") { return }
	if !testing.expect(t, scroll_region_offset(&rt, nodes.owner) == 0,
		"the default scroll behavior should not steal a component navigation key") { return }

	nodes = interaction_scroll_scope_test_describe(&rt, nodes.owner)
	testing.expect(t, nodes.found && nodes.event.kind == .Key && nodes.event.key == .Down,
		"the component should receive its key during the next description")
}

// ---------------------------------------------------------------------------
// Text-target key preemption policy
// ---------------------------------------------------------------------------

Interaction_Scope_Text_Test_Nodes :: struct {
	outer:  Node_ID,
	inner:  Node_ID,
	modal:  Node_ID,
	target: Node_ID,
	event:  Interaction_Event,
	found:  bool,
}

// interaction_scope_text_test_describe keeps a focused generic text target
// inside nested scopes and a sibling modal scope, so routing order and the
// text-owner guard can be exercised independently.
interaction_scope_text_test_describe :: proc(
	rt: ^Runtime,
	outer: Interaction_Scope_Options,
	inner: Interaction_Scope_Options,
	modal: Interaction_Scope_Options,
	consume_owner: Node_ID = 0,
) -> Interaction_Scope_Text_Test_Nodes {
	result := Interaction_Scope_Text_Test_Nodes{}
	ui, should_build := begin_frame(rt)
	if !should_build { return result }
	container_begin_simple(&ui, .Root, label="scope-text-root", key="scope-text-root", style=layout_style(.Column))
	result.outer = container_begin(&ui, .Container, label="scope-text-outer", key="scope-text-outer", style=layout_style(.Column))
	result.inner = container_begin(&ui, .Container, label="scope-text-inner", key="scope-text-inner", style=layout_style(.Column))
	result.target = container_begin(&ui, .Scroll_Region, label="scope-text-target", key="scope-text-target", style=layout_style(width=180, height=32))
	if result.target != 0 { _ = text_input_target(&ui, result.target) }
	container_end(&ui)
	container_end(&ui)
	container_end(&ui)
	result.modal = container_begin(&ui, .Container, label="scope-text-modal", key="scope-text-modal", style=layout_style(.Column))
	container_end(&ui)
	container_end(&ui)
	_ = interaction_scope_register(rt, result.outer, nil, outer)
	_ = interaction_scope_register(rt, result.inner, nil, inner)
	_ = interaction_scope_register(rt, result.modal, nil, modal)
	if consume_owner != 0 {
		result.event, result.found = interaction_event_next(rt, consume_owner)
	}
	end_frame(&ui)
	return result
}

@(test)
test_interaction_scope_text_preempt_default_keeps_text_precedence :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 180})
	defer destroy_runtime(&rt)
	keys := Interaction_Key_Set{.Left, .Right, .Up, .Down, .Home, .End, .Toggle, .Return}
	outer := Interaction_Scope_Options{keys=keys}
	nodes := interaction_scope_text_test_describe(&rt, outer, {}, {})
	if !testing.expect(t, nodes.outer != 0 && nodes.target != 0, "the fixture should retain a scope and a text target") { return }
	_ = focus(&rt, nodes.target)

	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Left, text_input_focused=true),
		"without a declared yield a focused text target should keep Left")
	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Toggle, text_input_focused=true),
		"without a declared yield a focused text target should keep Space")
	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Home, text_input_focused=true),
		"without a declared yield a focused text target should keep Home")
	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Down, text_input_focused=true),
		"the existing command vocabulary should still preempt a focused text target")
	nodes = interaction_scope_text_test_describe(&rt, outer, {}, {}, consume_owner=nodes.outer)
	testing.expect(t, nodes.found && nodes.event.key == .Down,
		"the scope should receive only the command key that already preempted text")

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Left),
		"an unfocused text target should not change ordinary scope routing")
	nodes = interaction_scope_text_test_describe(&rt, outer, {}, {}, consume_owner=nodes.outer)
	testing.expect(t, nodes.found && nodes.event.key == .Left,
		"the scope should receive Left when text input is not focused")
}

@(test)
test_interaction_scope_text_preempt_declared_keys_route_and_ime_still_wins :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 180})
	defer destroy_runtime(&rt)
	keys := Interaction_Key_Set{.Left, .Right, .Up, .Down, .Toggle, .Return}
	outer := Interaction_Scope_Options{
		keys=keys,
		composition_yield_keys={.Down},
		text_preempt_keys={.Left, .Right, .Toggle},
	}
	nodes := interaction_scope_text_test_describe(&rt, outer, {}, {})
	if !testing.expect(t, nodes.outer != 0 && nodes.target != 0, "the fixture should retain a scope and a text target") { return }
	_ = focus(&rt, nodes.target)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Left, text_input_focused=true),
		"a declared text_preempt key should reach the scope while text input is focused")
	nodes = interaction_scope_text_test_describe(&rt, outer, {}, {}, consume_owner=nodes.outer)
	testing.expect(t, nodes.found && nodes.event.key == .Left, "the scope should receive the declared Left")
	_ = focus(&rt, nodes.target)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Toggle, text_input_focused=true),
		"a declared text_preempt Space should reach the scope while text input is focused")
	nodes = interaction_scope_text_test_describe(&rt, outer, {}, {}, consume_owner=nodes.outer)
	testing.expect(t, nodes.found && nodes.event.key == .Toggle, "the scope should receive the declared Space")
	_ = focus(&rt, nodes.target)

	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Left, text_input_focused=true, composition_active=true),
		"active IME composition should keep a declared yield key with the text target")
	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Toggle, text_input_focused=true, composition_active=true),
		"active IME composition should keep declared Space with the text target")
	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Down, text_input_focused=true, composition_active=true),
		"composition_yield_keys should keep its existing yield during composition")
	nodes = interaction_scope_text_test_describe(&rt, outer, {}, {}, consume_owner=nodes.outer)
	testing.expect(t, !nodes.found, "composition should leave no scope event for yielded or declared keys")
}

@(test)
test_interaction_scope_text_preempt_composes_with_modal_and_nested_scopes :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 220})
	defer destroy_runtime(&rt)
	outer := Interaction_Scope_Options{keys={.Right}, text_preempt_keys={.Right}}
	inner := Interaction_Scope_Options{keys={.Left}, text_preempt_keys={.Left}}
	modal := Interaction_Scope_Options{keys={.Toggle}, text_preempt_keys={.Toggle}, modal=true}
	nodes := interaction_scope_text_test_describe(&rt, outer, inner, modal)
	if !testing.expect(t, nodes.outer != 0 && nodes.inner != 0 && nodes.modal != 0 && nodes.target != 0,
		"the fixture should retain nested scopes, a modal scope, and a text target") { return }
	_ = focus(&rt, nodes.target)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Left, text_input_focused=true),
		"the nearest declared ancestor should preempt Left")
	nodes = interaction_scope_text_test_describe(&rt, outer, inner, modal, consume_owner=nodes.inner)
	testing.expect(t, nodes.found && nodes.event.key == .Left, "the inner scope should own Left")
	_ = focus(&rt, nodes.target)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Right, text_input_focused=true),
		"the outer scope should still preempt a key the inner scope did not declare")
	nodes = interaction_scope_text_test_describe(&rt, outer, inner, modal, consume_owner=nodes.outer)
	testing.expect(t, nodes.found && nodes.event.key == .Right, "the outer scope should own Right")
	_ = focus(&rt, nodes.target)

	testing.expect(t, application_dispatch_key(&rt, nil, nil, .Toggle, text_input_focused=true),
		"a modal scope should preempt its declared Space even while background text input is focused")
	nodes = interaction_scope_text_test_describe(&rt, outer, inner, modal, consume_owner=nodes.modal)
	testing.expect(t, nodes.found && nodes.event.key == .Toggle, "the modal scope should own Space")

	testing.expect(t, !application_dispatch_key(&rt, nil, nil, .Toggle, text_input_focused=true, composition_active=true),
		"modal text preemption should still respect active IME composition")
}


Interaction_Scope_Test_After_Frame_State :: struct {
	count:        int,
	schedule_next: bool,
}

interaction_scope_test_after_frame_callback :: proc(data: rawptr, rt: ^Runtime) {
	state := cast(^Interaction_Scope_Test_After_Frame_State)data
	if state == nil { return }
	state.count += 1
	if state.schedule_next {
		state.schedule_next = false
		_ = interaction_after_frame_register(rt, data, interaction_scope_test_after_frame_callback)
	}
}

@(test)
test_interaction_after_frame_callback_runs_once_after_reconciliation :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 100, 80})
	defer destroy_runtime(&rt)
	state := Interaction_Scope_Test_After_Frame_State{schedule_next=true}
	testing.expect(t, interaction_after_frame_register(&rt, rawptr(&state), interaction_scope_test_after_frame_callback),
		"a valid one-shot callback should be accepted")
	_ = interaction_scope_test_describe(&rt, register_normal=false, register_modal=false)
	testing.expect(t, state.count == 1 && len(rt.interaction_after_frame) == 1,
		"a callback scheduled while dispatching should be reserved for the following description")
	invalidate_root(&rt, "run the callback scheduled during dispatch")
	_ = interaction_scope_test_describe(&rt, register_normal=false, register_modal=false)
	testing.expect(t, state.count == 2 && len(rt.interaction_after_frame) == 0,
		"the deferred callback should run once and then leave the runtime idle")
}
