package web_host

import "core:encoding/json"
import "core:fmt"
import alicorn "alicorn:runtime"

// Browser accessibility is a bounded DOM projection of Alicorn's semantic
// snapshot. The DOM is an interaction/accessibility adapter; it never owns
// source values or application state.
Browser_Accessibility_Node_View :: struct {
	id: string "json:\"id\"",
	parent: string "json:\"parent\"",
	role: string "json:\"role\"",
	multiline: bool "json:\"multiline\"",
	label: string "json:\"label\"",
	description: string "json:\"description\"",
	value: string "json:\"value\"",
	checked: bool "json:\"checked\"",
	disabled: bool "json:\"disabled\"",
	selected: bool "json:\"selected\"",
	expanded: bool "json:\"expanded\"",
	read_only: bool "json:\"readOnly\"",
	required: bool "json:\"required\"",
	invalid: bool "json:\"invalid\"",
	busy: bool "json:\"busy\"",
	modified: bool "json:\"modified\"",
	current: bool "json:\"current\"",
	has_bounds: bool "json:\"hasBounds\"",
	bounds_x: f64 "json:\"boundsX\"",
	bounds_y: f64 "json:\"boundsY\"",
	bounds_width: f64 "json:\"boundsWidth\"",
	bounds_height: f64 "json:\"boundsHeight\"",
	can_press: bool "json:\"canPress\"",
	can_focus: bool "json:\"canFocus\"",
	can_set_value: bool "json:\"canSetValue\"",
	can_set_text_selection: bool "json:\"canSetTextSelection\"",
	can_replace_selected_text: bool "json:\"canReplaceSelectedText\"",
	can_increment: bool "json:\"canIncrement\"",
	can_decrement: bool "json:\"canDecrement\"",
	can_select: bool "json:\"canSelect\"",
	can_expand: bool "json:\"canExpand\"",
	can_collapse: bool "json:\"canCollapse\"",
	can_scroll_into_view: bool "json:\"canScrollIntoView\"",
	can_scroll_forward: bool "json:\"canScrollForward\"",
	can_scroll_backward: bool "json:\"canScrollBackward\"",
	can_dismiss: bool "json:\"canDismiss\"",
	collection: bool "json:\"collection\"",
	position_in_set: string "json:\"positionInSet\"",
	size_of_set: string "json:\"sizeOfSet\"",
	selected_id: string "json:\"selectedId\"",
	current_id: string "json:\"currentId\"",
	has_numeric_value: bool "json:\"hasNumericValue\"",
	numeric_value: f64 "json:\"numericValue\"",
	numeric_minimum: f64 "json:\"numericMinimum\"",
	numeric_maximum: f64 "json:\"numericMaximum\"",
	numeric_step: f64 "json:\"numericStep\"",
	live: string "json:\"live\"",
	live_atomic: bool "json:\"liveAtomic\"",
	order: u64 "json:\"order\"",
}

Browser_Accessibility_Payload :: struct {
	root: string "json:\"root\"",
	revision: u64 "json:\"revision\"",
	focus: string "json:\"focus\"",
	show_focus: bool "json:\"showFocus\"",
	viewport_width: f64 "json:\"viewportWidth\"",
	viewport_height: f64 "json:\"viewportHeight\"",
	nodes: [dynamic]Browser_Accessibility_Node_View "json:\"nodes\"",
}

Browser_Accessibility_Projection_Status :: enum {
	Success,
	Invalid_Root_ID,
	Too_Many_Nodes,
	Too_Much_Text,
	Serialization_Failed,
}

BROWSER_ACCESSIBILITY_MAX_NODES :: 2048
BROWSER_ACCESSIBILITY_MAX_TEXT_BYTES :: 1 << 20
BROWSER_ACCESSIBILITY_MAX_JSON_BYTES :: 8 << 20

browser_accessibility_dom_id_is_safe :: proc(id: string) -> bool {
	if len(id) == 0 { return false }
	for ch in id {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		     (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') { return false }
	}
	return true
}

browser_accessibility_semantic_dom_id :: proc(root: string, id: alicorn.Semantic_ID) -> string {
	if id == (alicorn.Semantic_ID{}) { return "" }
	return fmt.tprintf("%s-sem-%016x-%016x", root, id.namespace, id.value)
}

browser_accessibility_role_name :: proc(role: alicorn.Semantic_Role) -> string {
	switch role {
	case .Window: return "group"
	case .Group: return "group"
	case .Static_Text: return "text"
	case .Button: return "button"
	case .Checkbox: return "checkbox"
	case .Slider: return "slider"
	case .Text_Field, .Text_Area: return "textbox"
	case .Text_Run: return "text"
	case .Tab_List: return "tablist"
	case .Tab: return "tab"
	case .List: return "list"
	case .List_Item: return "listitem"
	case .Tree: return "tree"
	case .Tree_Item: return "treeitem"
	case .Menu: return "menu"
	case .Menu_Item: return "menuitem"
	case .Dialog: return "dialog"
	case .Tooltip: return "tooltip"
	case .Scroll_View: return "region"
	case .Combo_Box: return "combobox"
	case .List_Box: return "listbox"
	case .List_Box_Option: return "option"
	case .Status: return "status"
	case .Alert: return "alert"
	case .None: return "generic"
	}
	return "generic"
}

browser_accessibility_payload_build :: proc(
	snapshot: alicorn.Semantic_Snapshot,
	root_id: string,
	show_focus: bool = false,
	viewport_width: f64 = 0,
	viewport_height: f64 = 0,
	allocator := context.allocator,
) -> (payload: Browser_Accessibility_Payload, status: Browser_Accessibility_Projection_Status) {
	if !browser_accessibility_dom_id_is_safe(root_id) { return {}, .Invalid_Root_ID }
	payload = Browser_Accessibility_Payload{
		root=root_id,
		revision=snapshot.revision,
		show_focus=show_focus,
		viewport_width=max(viewport_width, 0),
		viewport_height=max(viewport_height, 0),
		nodes=make([dynamic]Browser_Accessibility_Node_View, 0, min(len(snapshot.nodes), BROWSER_ACCESSIBILITY_MAX_NODES), allocator=allocator),
	}
	text_bytes := 0
	for node in snapshot.nodes {
		// Text runs are selection-mapping products owned by their editable parent;
		// projecting them as separate controls creates a misleading DOM tree.
		if node.role == .Text_Run { continue }
		if len(payload.nodes) >= BROWSER_ACCESSIBILITY_MAX_NODES {
			delete(payload.nodes)
			return {}, .Too_Many_Nodes
		}
		texts := [3]string{node.label, node.description, node.value}
		for text in texts {
			if len(text) > BROWSER_ACCESSIBILITY_MAX_TEXT_BYTES-text_bytes {
				delete(payload.nodes)
				return {}, .Too_Much_Text
			}
			text_bytes += len(text)
		}
		view := Browser_Accessibility_Node_View{
			id=browser_accessibility_semantic_dom_id(root_id, node.id),
			parent=browser_accessibility_semantic_dom_id(root_id, node.parent),
			role=browser_accessibility_role_name(node.role),
			multiline=node.role == .Text_Area,
			label=node.label,
			description=node.description,
			value=node.value,
			checked=alicorn.semantic_states_has(node.states, .Checked),
			disabled=alicorn.semantic_states_has(node.states, .Disabled),
			selected=alicorn.semantic_states_has(node.states, .Selected),
			expanded=alicorn.semantic_states_has(node.states, .Expanded),
			read_only=alicorn.semantic_states_has(node.states, .Read_Only),
			required=alicorn.semantic_states_has(node.states, .Required),
			invalid=alicorn.semantic_states_has(node.states, .Invalid),
			busy=alicorn.semantic_states_has(node.states, .Busy),
			modified=alicorn.semantic_states_has(node.states, .Modified),
			current=alicorn.semantic_states_has(node.states, .Current),
			has_bounds=node.has_bounds,
			bounds_x=f64(node.bounds.x),
			bounds_y=f64(node.bounds.y),
			bounds_width=f64(node.bounds.w),
			bounds_height=f64(node.bounds.h),
			can_press=alicorn.semantic_actions_has(node.actions, .Press),
			can_focus=alicorn.semantic_actions_has(node.actions, .Focus),
			can_set_value=alicorn.semantic_actions_has(node.actions, .Set_Value),
			can_set_text_selection=alicorn.semantic_actions_has(node.actions, .Set_Text_Selection),
			can_replace_selected_text=alicorn.semantic_actions_has(node.actions, .Replace_Selected_Text),
			can_increment=alicorn.semantic_actions_has(node.actions, .Increment),
			can_decrement=alicorn.semantic_actions_has(node.actions, .Decrement),
			can_select=alicorn.semantic_actions_has(node.actions, .Select),
			can_expand=alicorn.semantic_actions_has(node.actions, .Expand),
			can_collapse=alicorn.semantic_actions_has(node.actions, .Collapse),
			can_scroll_into_view=alicorn.semantic_actions_has(node.actions, .Scroll_Into_View),
			can_scroll_forward=alicorn.semantic_actions_has(node.actions, .Scroll_Forward),
			can_scroll_backward=alicorn.semantic_actions_has(node.actions, .Scroll_Backward),
			can_dismiss=alicorn.semantic_actions_has(node.actions, .Dismiss),
			collection=node.is_collection,
			position_in_set=fmt.tprintf("%d", node.position_in_set) if node.position_in_set > 0 else "",
			size_of_set=fmt.tprintf("%d", node.size_of_set) if node.size_of_set > 0 else "",
			selected_id=browser_accessibility_semantic_dom_id(root_id, node.selected_id),
			current_id=browser_accessibility_semantic_dom_id(root_id, node.current_id),
			has_numeric_value=node.has_numeric_value,
			numeric_value=node.numeric_value,
			numeric_minimum=node.numeric_minimum,
			numeric_maximum=node.numeric_maximum,
			numeric_step=node.numeric_step,
			live="polite" if node.live == .Polite else "assertive" if node.live == .Assertive else "off",
			live_atomic=node.live_atomic,
			order=node.tree_order,
		}
		append(&payload.nodes, view)
		if node.id == snapshot.keyboard_focus { payload.focus = view.id }
	}
	return payload, .Success
}

browser_accessibility_payload_json :: proc(
	payload: Browser_Accessibility_Payload,
	allocator := context.allocator,
) -> (data: []byte, status: Browser_Accessibility_Projection_Status) {
	encoded, err := json.marshal(payload, allocator=allocator)
	if err != nil { return nil, .Serialization_Failed }
	if len(encoded) > BROWSER_ACCESSIBILITY_MAX_JSON_BYTES {
		delete(encoded)
		return nil, .Serialization_Failed
	}
	data = encoded
	return data, .Success
}

// text_difference returns the inserted/replacement UTF-8 slice for semantic
// Replace_Selected_Text requests. Boundaries are backed up to scalar edges so
// supplementary characters are never split into malformed byte sequences.
browser_accessibility_text_difference :: proc(previous, current: string) -> string {
	prefix := 0
	for prefix < len(previous) && prefix < len(current) && previous[prefix] == current[prefix] { prefix += 1 }
	for prefix > 0 && (browser_accessibility_utf8_continuation(previous, prefix) ||
	                    browser_accessibility_utf8_continuation(current, prefix)) { prefix -= 1 }
	suffix := 0
	for suffix < len(previous)-prefix && suffix < len(current)-prefix &&
	     previous[len(previous)-suffix-1] == current[len(current)-suffix-1] { suffix += 1 }
	for suffix > 0 && (browser_accessibility_utf8_continuation(previous, len(previous)-suffix) ||
	                   browser_accessibility_utf8_continuation(current, len(current)-suffix)) { suffix -= 1 }
	return current[prefix:len(current)-suffix]
}

browser_accessibility_utf8_continuation :: proc(value: string, index: int) -> bool {
	return index >= 0 && index < len(value) && (value[index] & 0xC0) == 0x80
}

// DOM selection offsets use UTF-16 code units, while Alicorn text positions
// address shaped selectable grapheme units. Keep this conversion platform-
// independent so Unicode boundaries can be regression-tested without a DOM.
browser_accessibility_run_utf16_length :: proc(run: alicorn.Semantic_Node) -> int {
	total := 0
	byte_offset := 0
	for byte_length in run.text_run_character_lengths {
		if byte_length == 0 || byte_offset+int(byte_length) > len(run.value) { return -1 }
		for rune in run.value[byte_offset:byte_offset+int(byte_length)] {
			total += 1
			if rune > 0xFFFF { total += 1 }
		}
		byte_offset += int(byte_length)
	}
	if byte_offset != len(run.value) { return -1 }
	return total
}

browser_accessibility_run_unit_index :: proc(
	run: alicorn.Semantic_Node,
	utf16_offset: int,
	round_up: bool,
) -> (u64, bool) {
	if utf16_offset < 0 { return 0, false }
	byte_offset, utf16_cursor := 0, 0
	for character_index in 0..<len(run.text_run_character_lengths) {
		byte_length := run.text_run_character_lengths[character_index]
		if utf16_offset == utf16_cursor { return u64(character_index), true }
		if byte_length == 0 || byte_offset+int(byte_length) > len(run.value) { return 0, false }
		unit_utf16 := 0
		for rune in run.value[byte_offset:byte_offset+int(byte_length)] {
			unit_utf16 += 1
			if rune > 0xFFFF { unit_utf16 += 1 }
		}
		if utf16_offset < utf16_cursor+unit_utf16 {
			return u64(character_index+1 if round_up else character_index), true
		}
		byte_offset += int(byte_length)
		utf16_cursor += unit_utf16
	}
	if utf16_offset == utf16_cursor && byte_offset == len(run.value) {
		return u64(len(run.text_run_character_lengths)), true
	}
	return 0, false
}
