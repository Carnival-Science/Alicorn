#+build js wasm32, js wasm64p32

package web_host

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/wasm/js"
import alicorn "alicorn:runtime"

Browser_Accessibility_Binding :: struct {
	accessibility: ^Browser_Accessibility,
	id: alicorn.Semantic_ID,
	dom_id: string,
	role: alicorn.Semantic_Role,
	actions: alicorn.Semantic_Actions,
	states: alicorn.Semantic_States,
	value: string,
	click_attached: bool,
	focus_attached: bool,
	input_attached: bool,
	composition_attached: bool,
	selection_attached: bool,
}

Browser_Accessibility :: struct {
	host: ^alicorn.Hosted_Runtime,
	root_id: string,
	canvas_id: string,
	text_input_id: string,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	bindings: map[alicorn.Semantic_ID]^Browser_Accessibility_Binding,
	allocator: mem.Allocator,
	revision: u64,
	initialized: bool,
	has_revision: bool,
}

browser_accessibility_init :: proc(
	accessibility: ^Browser_Accessibility,
	host: ^alicorn.Hosted_Runtime,
	root_id, canvas_id: string,
	text_input_id: string = "",
	wake_data: rawptr = nil,
	wake: Browser_Application_Wake_Proc = nil,
	allocator := context.allocator,
) -> bool {
	if accessibility == nil || accessibility.initialized || host == nil ||
	   !browser_accessibility_dom_id_is_safe(root_id) ||
	   !browser_accessibility_dom_id_is_safe(canvas_id) ||
	   (text_input_id != "" && (!browser_accessibility_dom_id_is_safe(text_input_id) ||
	    text_input_id == root_id || text_input_id == canvas_id)) {
		return false
	}
	if _, status := alicorn.hosted_runtime_borrow(host); status != .Ok { return false }
	accessibility^ = Browser_Accessibility{
		host=host,
		root_id=root_id,
		canvas_id=canvas_id,
		text_input_id=text_input_id,
		wake_data=wake_data,
		wake=wake,
		bindings=make(map[alicorn.Semantic_ID]^Browser_Accessibility_Binding, allocator=allocator),
		allocator=allocator,
		initialized=true,
	}
	js.evaluate(fmt.tprintf("window.alicornAccessibilityInit('%s','%s','%s')", root_id, canvas_id, text_input_id))
	return true
}

browser_accessibility_destroy :: proc(accessibility: ^Browser_Accessibility) {
	if accessibility == nil || !accessibility.initialized { return }
	for _, binding in accessibility.bindings {
		browser_accessibility_binding_detach(binding)
		browser_accessibility_binding_delete(binding, accessibility.allocator)
	}
	delete(accessibility.bindings)
	js.evaluate(fmt.tprintf("window.alicornAccessibilityDestroy('%s')", accessibility.root_id))
	accessibility^ = {}
}

// Sync once per semantic revision. Layout-only and renderer-only frames do not
// serialize or reconcile the browser accessibility tree.
browser_accessibility_sync :: proc(accessibility: ^Browser_Accessibility) -> bool {
	if accessibility == nil || !accessibility.initialized || accessibility.host == nil { return false }
	rt, borrow_status := alicorn.hosted_runtime_borrow(accessibility.host)
	if borrow_status != .Ok || rt == nil { return false }
	revision := alicorn.semantic_revision(rt)
	if accessibility.has_revision && revision == accessibility.revision { return true }

	snapshot, truncated := alicorn.semantic_snapshot_bounded(
		rt,
		BROWSER_ACCESSIBILITY_MAX_NODES*2,
		BROWSER_ACCESSIBILITY_MAX_TEXT_BYTES,
		context.temp_allocator,
	)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	if truncated { return browser_accessibility_sync_unavailable(accessibility, revision) }
	payload, projection_status := browser_accessibility_payload_build(
		snapshot,
		accessibility.root_id,
		context.temp_allocator,
	)
	if projection_status != .Success { return browser_accessibility_sync_unavailable(accessibility, revision) }
	defer delete(payload.nodes)
	data, json_status := browser_accessibility_payload_json(payload, context.temp_allocator)
	if json_status != .Success { return browser_accessibility_sync_unavailable(accessibility, revision) }
	defer delete(data)
	json_text := string(data)
	js.evaluate(fmt.tprintf("window.alicornAccessibilityApply(%s)", json_text))
	if !browser_accessibility_bindings_sync(accessibility, snapshot) { return false }
	accessibility.revision = revision
	accessibility.has_revision = true
	return true
}

// Never leave an older accessible tree in place when the current application
// exceeds projection bounds. Replace it with one live status node and detach
// stale action listeners so assistive technology is not offered obsolete data.
browser_accessibility_sync_unavailable :: proc(
	accessibility: ^Browser_Accessibility,
	revision: u64,
) -> bool {
	if accessibility == nil || !accessibility.initialized { return false }
	payload := Browser_Accessibility_Payload{
		root=accessibility.root_id,
		revision=revision,
		nodes=make([dynamic]Browser_Accessibility_Node_View, 0, 1, allocator=context.temp_allocator),
	}
	defer delete(payload.nodes)
	append(&payload.nodes, Browser_Accessibility_Node_View{
		id=fmt.tprintf("%s-limit", accessibility.root_id),
		role="status",
		label="Some controls are unavailable because the accessibility projection limit was reached.",
		live="polite",
		order=0,
	})
	data, status := browser_accessibility_payload_json(payload, context.temp_allocator)
	if status != .Success { return false }
	defer delete(data)
	js.evaluate(fmt.tprintf("window.alicornAccessibilityApply(%s)", string(data)))
	_ = browser_accessibility_bindings_sync(accessibility, alicorn.Semantic_Snapshot{})
	accessibility.revision = revision
	accessibility.has_revision = true
	return true
}

browser_accessibility_bindings_sync :: proc(
	accessibility: ^Browser_Accessibility,
	snapshot: alicorn.Semantic_Snapshot,
) -> bool {
	if accessibility == nil { return false }
	seen := make(map[alicorn.Semantic_ID]bool, allocator=context.temp_allocator)
	defer delete(seen)
	for node in snapshot.nodes {
		if node.role == .Text_Run || !browser_accessibility_node_has_actions(node) { continue }
		seen[node.id] = true
		binding := accessibility.bindings[node.id]
		if binding == nil {
			binding = new(Browser_Accessibility_Binding, allocator=accessibility.allocator)
			binding.accessibility = accessibility
			binding.id = node.id
			dom_id, clone_error := strings.clone(browser_accessibility_semantic_dom_id(accessibility.root_id, node.id), accessibility.allocator)
			if clone_error != nil {
				_ = free(binding, accessibility.allocator)
				return false
			}
			binding.dom_id = dom_id
			accessibility.bindings[node.id] = binding
		}
		binding.role = node.role
		binding.actions = node.actions
		binding.states = node.states
		if !browser_accessibility_binding_value_set(binding, node.value, accessibility.allocator) { return false }
		if !browser_accessibility_binding_attach(binding) { return false }
	}
	removed := make([dynamic]alicorn.Semantic_ID, 0, allocator=context.temp_allocator)
	for id in accessibility.bindings {
		if !seen[id] { append(&removed, id) }
	}
	for id in removed {
		binding := accessibility.bindings[id]
		browser_accessibility_binding_detach(binding)
		browser_accessibility_binding_delete(binding, accessibility.allocator)
		delete_key(&accessibility.bindings, id)
	}
	return true
}

browser_accessibility_node_has_actions :: proc(node: alicorn.Semantic_Node) -> bool {
	for action in alicorn.Semantic_Action {
		if action == .None { continue }
		if alicorn.semantic_actions_has(node.actions, action) { return true }
	}
	return false
}

browser_accessibility_binding_value_set :: proc(
	binding: ^Browser_Accessibility_Binding,
	value: string,
	allocator: mem.Allocator,
) -> bool {
	if binding == nil || binding.value == value { return true }
	copy, err := strings.clone(value, allocator)
	if err != nil { return false }
	if len(binding.value) > 0 { delete(binding.value, allocator) }
	binding.value = copy
	return true
}

browser_accessibility_binding_delete :: proc(binding: ^Browser_Accessibility_Binding, allocator: mem.Allocator) {
	if binding == nil { return }
	if len(binding.value) > 0 { delete(binding.value, allocator) }
	if len(binding.dom_id) > 0 { delete(binding.dom_id, allocator) }
	_ = free(binding, allocator)
}

browser_accessibility_binding_attach :: proc(binding: ^Browser_Accessibility_Binding) -> bool {
	if binding == nil || binding.accessibility == nil { return false }
	actions := binding.actions
	needs_click := alicorn.semantic_actions_has(actions, .Press) ||
		alicorn.semantic_actions_has(actions, .Select) ||
		alicorn.semantic_actions_has(actions, .Expand) ||
		alicorn.semantic_actions_has(actions, .Collapse) ||
		alicorn.semantic_actions_has(actions, .Dismiss)
	if needs_click && !binding.click_attached {
		if !js.add_event_listener(binding.dom_id, .Click, rawptr(binding), browser_accessibility_click) { return false }
		binding.click_attached = true
	} else if !needs_click && binding.click_attached {
		_ = js.remove_event_listener(binding.dom_id, .Click, rawptr(binding), browser_accessibility_click)
		binding.click_attached = false
	}
	needs_focus := alicorn.semantic_actions_has(actions, .Focus)
	if needs_focus && !binding.focus_attached {
		if !js.add_event_listener(binding.dom_id, .Focus, rawptr(binding), browser_accessibility_focus) { return false }
		binding.focus_attached = true
	} else if !needs_focus && binding.focus_attached {
		_ = js.remove_event_listener(binding.dom_id, .Focus, rawptr(binding), browser_accessibility_focus)
		binding.focus_attached = false
	}
	needs_input := alicorn.semantic_actions_has(actions, .Set_Value) ||
		alicorn.semantic_actions_has(actions, .Replace_Selected_Text)
	if needs_input && !binding.input_attached {
		if !js.add_custom_event_listener(binding.dom_id, "input", rawptr(binding), browser_accessibility_input) { return false }
		binding.input_attached = true
	} else if !needs_input && binding.input_attached {
		_ = js.remove_custom_event_listener(binding.dom_id, "input", rawptr(binding), browser_accessibility_input)
		binding.input_attached = false
	}
	if needs_input && !binding.composition_attached {
		if !js.add_custom_event_listener(binding.dom_id, "compositionend", rawptr(binding), browser_accessibility_composition_end) { return false }
		binding.composition_attached = true
	} else if !needs_input && binding.composition_attached {
		_ = js.remove_custom_event_listener(binding.dom_id, "compositionend", rawptr(binding), browser_accessibility_composition_end)
		binding.composition_attached = false
	}
	needs_selection := alicorn.semantic_actions_has(actions, .Set_Text_Selection)
	if needs_selection && !binding.selection_attached {
		if !js.add_event_listener(binding.dom_id, .Select, rawptr(binding), browser_accessibility_selection) { return false }
		binding.selection_attached = true
	} else if !needs_selection && binding.selection_attached {
		_ = js.remove_event_listener(binding.dom_id, .Select, rawptr(binding), browser_accessibility_selection)
		binding.selection_attached = false
	}
	return true
}

browser_accessibility_binding_detach :: proc(binding: ^Browser_Accessibility_Binding) {
	if binding == nil { return }
	if binding.click_attached { _ = js.remove_event_listener(binding.dom_id, .Click, rawptr(binding), browser_accessibility_click) }
	if binding.focus_attached { _ = js.remove_event_listener(binding.dom_id, .Focus, rawptr(binding), browser_accessibility_focus) }
	if binding.input_attached { _ = js.remove_custom_event_listener(binding.dom_id, "input", rawptr(binding), browser_accessibility_input) }
	if binding.composition_attached { _ = js.remove_custom_event_listener(binding.dom_id, "compositionend", rawptr(binding), browser_accessibility_composition_end) }
	if binding.selection_attached { _ = js.remove_event_listener(binding.dom_id, .Select, rawptr(binding), browser_accessibility_selection) }
}

browser_accessibility_request :: proc(
	binding: ^Browser_Accessibility_Binding,
	action: alicorn.Semantic_Action,
	text_value := "",
	numeric_value: f64 = 0,
	has_numeric_value := false,
) -> bool {
	if binding == nil || binding.accessibility == nil { return false }
	handled, status := alicorn.hosted_runtime_accessibility_action(
		binding.accessibility.host,
		binding.id,
		action,
		text_value,
		numeric_value,
		has_numeric_value,
	)
	if handled && status == .Ok && binding.accessibility.wake != nil {
		binding.accessibility.wake(binding.accessibility.wake_data)
	}
	return handled && status == .Ok
}

browser_accessibility_click :: proc(event: js.Event) {
	binding := cast(^Browser_Accessibility_Binding)event.user_data
	if binding == nil { return }
	if alicorn.semantic_actions_has(binding.actions, .Press) {
		_ = browser_accessibility_request(binding, .Press)
	} else if alicorn.semantic_actions_has(binding.actions, .Select) {
		_ = browser_accessibility_request(binding, .Select)
	} else if alicorn.semantic_actions_has(binding.actions, .Expand) &&
		!alicorn.semantic_states_has(binding.states, .Expanded) {
		_ = browser_accessibility_request(binding, .Expand)
	} else if alicorn.semantic_actions_has(binding.actions, .Collapse) &&
		alicorn.semantic_states_has(binding.states, .Expanded) {
		_ = browser_accessibility_request(binding, .Collapse)
	} else if alicorn.semantic_actions_has(binding.actions, .Dismiss) {
		_ = browser_accessibility_request(binding, .Dismiss)
	}
}

browser_accessibility_focus :: proc(event: js.Event) {
	binding := cast(^Browser_Accessibility_Binding)event.user_data
	if binding == nil || !alicorn.semantic_actions_has(binding.actions, .Focus) { return }
	_ = browser_accessibility_request(binding, .Focus)
}

browser_accessibility_input :: proc(event: js.Event) {
	if event.is_composing { return }
	binding := cast(^Browser_Accessibility_Binding)event.user_data
	if binding == nil { return }
	browser_accessibility_input_commit(binding)
}

browser_accessibility_composition_end :: proc(event: js.Event) {
	binding := cast(^Browser_Accessibility_Binding)event.user_data
	if binding == nil { return }
	browser_accessibility_input_commit(binding)
}

browser_accessibility_input_commit :: proc(binding: ^Browser_Accessibility_Binding) {
	if binding == nil || binding.accessibility == nil { return }
	value := browser_accessibility_dom_value(binding.dom_id)
	if value == binding.value { return }
	if binding.role == .Slider {
		numeric := js.get_element_value_f64(binding.dom_id)
		_ = browser_accessibility_request(binding, .Set_Value, numeric_value=numeric, has_numeric_value=true)
		return
	}
	if alicorn.semantic_actions_has(binding.actions, .Set_Value) {
		_ = browser_accessibility_request(binding, .Set_Value, text_value=value)
	} else if alicorn.semantic_actions_has(binding.actions, .Replace_Selected_Text) {
		replacement := browser_accessibility_text_difference(binding.value, value)
		_ = browser_accessibility_request(binding, .Replace_Selected_Text, text_value=replacement)
	}
	_ = browser_accessibility_binding_value_set(binding, value, binding.accessibility.allocator)
}

browser_accessibility_dom_value :: proc(dom_id: string) -> string {
	units := js.get_element_value_string_length(dom_id)
	if units <= 0 { return "" }
	buffer := make([]byte, units*3, context.temp_allocator)
	for &value in buffer { value = 0xFF }
	_ = js.get_element_value_string(dom_id, buffer)
	byte_count := 0
	for byte_count < len(buffer) && buffer[byte_count] != 0xFF { byte_count += 1 }
	return string(buffer[:byte_count])
}

browser_accessibility_selection :: proc(event: js.Event) {
	binding := cast(^Browser_Accessibility_Binding)event.user_data
	if binding == nil || binding.accessibility == nil ||
	   !alicorn.semantic_actions_has(binding.actions, .Set_Text_Selection) { return }
	rt, status := alicorn.hosted_runtime_borrow(binding.accessibility.host)
	if status != .Ok || rt == nil { return }
	start := int(max(js.get_element_key_f64(binding.dom_id, "selectionStart"), 0))
	end := int(max(js.get_element_key_f64(binding.dom_id, "selectionEnd"), 0))
	anchor, anchor_ok := browser_accessibility_text_position(rt, binding.id, start, round_up=false)
	focus, focus_ok := browser_accessibility_text_position(rt, binding.id, end, round_up=true)
	if !anchor_ok || !focus_ok { return }
	direction := browser_accessibility_dom_key_string(binding.dom_id, "selectionDirection")
	if direction == "backward" { anchor, focus = focus, anchor }
	selection := alicorn.Semantic_Text_Selection{anchor=anchor, focus=focus, valid=true}
	if alicorn.semantic_text_selection_apply(rt, binding.id, selection) && binding.accessibility.wake != nil {
		binding.accessibility.wake(binding.accessibility.wake_data)
	}
}

browser_accessibility_dom_key_string :: proc(dom_id, key: string) -> string {
	units := int(max(js.get_element_key_string_length(dom_id, key), 0))
	if units == 0 { return "" }
	buffer := make([]byte, units*3, context.temp_allocator)
	for &value in buffer { value = 0xFF }
	_ = js.get_element_key_string(dom_id, key, buffer)
	byte_count := 0
	for byte_count < len(buffer) && buffer[byte_count] != 0xFF { byte_count += 1 }
	return string(buffer[:byte_count])
}

browser_accessibility_text_position :: proc(
	rt: ^alicorn.Runtime,
	owner_id: alicorn.Semantic_ID,
	utf16_offset: int,
	round_up: bool,
) -> (position: alicorn.Semantic_Text_Position, ok: bool) {
	owner, found := alicorn.semantic_node_lookup(rt, owner_id)
	if !found || (owner.role != .Text_Field && owner.role != .Text_Area) { return {}, false }
	snapshot, truncated := alicorn.semantic_snapshot_bounded(
		rt,
		BROWSER_ACCESSIBILITY_MAX_NODES*2,
		BROWSER_ACCESSIBILITY_MAX_TEXT_BYTES,
		context.temp_allocator,
	)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	if truncated { return {}, false }
	runs := make([dynamic]alicorn.Semantic_Node, 0, allocator=context.temp_allocator)
	defer delete(runs)
	for run in snapshot.nodes {
		if run.role == .Text_Run && run.parent == owner_id { append(&runs, run) }
	}
	slice.sort_by(runs[:], proc(a, b: alicorn.Semantic_Node) -> bool { return a.tree_order < b.tree_order })
	if len(runs) == 0 { return {}, false }
	byte_cursor := 0
	for run in runs {
		if byte_cursor+len(run.value) > len(owner.value) ||
		   owner.value[byte_cursor:byte_cursor+len(run.value)] != run.value { return {}, false }
		byte_cursor += len(run.value)
	}
	if byte_cursor != len(owner.value) { return {}, false }
	remaining := max(utf16_offset, 0)
	for run in runs {
		length_utf16 := browser_accessibility_run_utf16_length(run)
		if remaining <= length_utf16 {
			index, index_ok := browser_accessibility_run_unit_index(run, remaining, round_up)
			if !index_ok { return {}, false }
			return alicorn.Semantic_Text_Position{run_id=run.id, character_index=index}, true
		}
		remaining -= length_utf16
	}
	last := runs[len(runs)-1]
	return alicorn.Semantic_Text_Position{run_id=last.id, character_index=u64(len(last.text_run_character_lengths))},
		remaining == 0
}
