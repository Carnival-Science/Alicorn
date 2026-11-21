package testui

// Pattern conformance checks are test-only assertions over semantics that an
// application actually publishes. They deliberately add no runtime metadata,
// registry, or control identity beyond the ordinary Semantic_ID graph. A
// checker resolves named parts from a configuration, verifies the static
// published contract, then drives the same keyboard, pointer, and semantic
// paths a host would use. The first violated rule stops the check with the
// causal turn and the semantic/part identity needed to debug it.

import "core:fmt"
import alicorn "alicorn:runtime"

PATTERN_TEXT_CAPACITY :: 192
PATTERN_MAX_OPTIONS :: 256
PATTERN_MAX_GROUPS :: 32
PATTERN_MAX_FOCUS_CYCLE :: 32

Pattern_Kind :: enum {
	Combobox_Listbox,
	Modal_Dialog,
}

// Pattern_Part_ID names a role in a composed control. A configuration supplies
// only the parts its composition actually publishes; optional drive phases are
// skipped when their part is absent.
Pattern_Part_ID :: enum {
	Trigger,
	List,
	Dialog,
	Nested_Dialog,
	Target_Option,
	Disabled_Option,
	Selected_Option,
	Peer_Trigger,
	Primary_Action,
	Secondary_Action,
	Background_Action,
	Extra_Action,
	Transient_Action,
	Nested_Action,
	Nested_Secondary_Action,
	Modal_Action,
}

Pattern_Step :: enum {
	Resolve_Parts,
	Static_Contract,
	Keyboard_Open,
	Navigation,
	Typeahead,
	Keyboard_Selection,
	Escape_Cancel,
	Tab_Close,
	Pointer_Parity,
	Semantic_Action_Parity,
	Disabled_Option,
	Virtual_Reveal,
	Owner_Identity,
	Reorder_Identity,
	Modal_Rejection,
	Containment,
	Focus_Inside,
	Traversal_Wrap,
	Focus_Recovery,
	Nested_Overlay,
	Dismissal,
	Activation_Parity,
}

Pattern_Part :: struct {
	id: Pattern_Part_ID,
	// query resolves the part through ordinary published semantics. It is
	// ignored when semantic_id_valid is set.
	query: Query,
	// A stable semantic ID is the strongest resolution and is what external
	// packages should use when their composition owns a deterministic ID.
	semantic_id: alicorn.Semantic_ID,
	semantic_id_valid: bool,
	// An optional exact retained key filter. The query can also match a key.
	key: alicorn.UI_Key,
	key_valid: bool,
}

Pattern_Config :: struct {
	kind: Pattern_Kind,
	parts: []Pattern_Part,
	// Optional expectations for the initial controlled value, before any drive
	// phase changes it.
	expected_selected_id: alicorn.Semantic_ID,
	expect_selected_id: bool,
	expected_selected_key: u64,
	expect_selected_key: bool,
	expected_option_count: u64,
	expect_option_count: bool,
	// Virtual reveal is exercised only for consumers that realize rows through
	// a bounded scroll window (the stock Select does).
	expect_virtual_reveal: bool,
	// The stock Select's accessibility handler owns Combo_Box Expand requests.
	// A custom composition that publishes its own Combo_Box semantics cannot
	// see that request unless it also opts into the stock handler; set this to
	// false to exercise pointer opening while still checking semantic option
	// Select parity.
	support_semantic_expand: bool,
	// Bounds the modal focus-cycle probe. Zero selects the default.
	max_focus_cycle: int,
}

Pattern_Failure :: struct {
	pattern: Pattern_Kind,
	step: Pattern_Step,
	part: Pattern_Part_ID,
	part_valid: bool,
	semantic_id: alicorn.Semantic_ID,
	key_valid: bool,
	key_text: [PATTERN_TEXT_CAPACITY]u8,
	key_text_length: int,
	expected: [PATTERN_TEXT_CAPACITY]u8,
	expected_length: int,
	actual: [PATTERN_TEXT_CAPACITY]u8,
	actual_length: int,
	message: [PATTERN_TEXT_CAPACITY]u8,
	message_length: int,
	cause_id: u64,
	cause_kind: alicorn.Cause_Kind,
	action_id: alicorn.Action_ID,
	turn: Turn_Report,
}

Pattern_Report :: struct {
	ok: bool,
	failure: Pattern_Failure,
}

Pattern_Options :: struct {
	options: [dynamic]Element,
	groups: [dynamic]Element,
	list: Element,
	has_list: bool,
	trigger: Element,
}

// pattern_check resolves and drives one pattern. It is deterministic: all
// timing is explicit virtual time, every interaction turn is followed by a
// fresh semantic query, and a stale Element is reported rather than reused.
pattern_check :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = config.kind
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	switch config.kind {
	case .Combobox_Listbox:
		_ = pattern_check_combobox_impl(handle, config, &report)
	case .Modal_Dialog:
		_ = pattern_check_modal_dialog_impl(handle, config, &report)
	}
	return report
}

pattern_check_combobox :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Combobox_Listbox
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_combobox_impl(handle, config, &report)
	return report
}

pattern_check_modal_dialog :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Modal_Dialog
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_modal_dialog_impl(handle, config, &report)
	return report
}

// pattern_failure_diagnostic formats a failure for test output. It borrows the
// report only for the duration of the returned string.
pattern_failure_diagnostic :: proc(failure: ^Pattern_Failure) -> string {
	key := "none"
	if failure.key_valid && failure.key_text_length > 0 { key = string(failure.key_text[:failure.key_text_length]) }
	part := "none"
	if failure.part_valid { part = fmt.tprintf("%v", failure.part) }
	turn := fmt.tprintf(
		"turn(input=%v key=%v descriptions=%d focus=%d/%d revision=%d->%d cause=%d)",
		failure.turn.input, failure.turn.key, failure.turn.descriptions,
		failure.turn.focus, failure.turn.focus_semantic_id.value,
		failure.turn.semantic_revision_before, failure.turn.semantic_revision,
		failure.turn.cause_id,
	)
	return fmt.tprintf(
		"%v/%v part=%s semantic=%d/%d key=%s expected=%q actual=%q %s %s",
		failure.pattern, failure.step, part,
		failure.semantic_id.namespace, failure.semantic_id.value, key,
		string(failure.expected[:failure.expected_length]),
		string(failure.actual[:failure.actual_length]),
		string(failure.message[:failure.message_length]), turn,
	)
}

@(private)
pattern_step_input :: proc(handle: ^Test_Handle($T), input: Input) -> Status {
	return step(handle, input)
}

// pattern_settle_description forces one bounded follow-up description. A
// pointer option activation closes the stock popup after the frame that
// consumed the activation, so a test that immediately re-queries otherwise
// observes the previous Expanded=true description. This is not a sleep and it
// does not advance virtual time; it just gives the ordinary application
// description one more pass, exactly as a host's next frame would.
@(private)
pattern_settle_description :: proc(handle: ^Test_Handle($T)) -> Status {
	alicorn.invalidate_root(handle.runtime, "pattern check settle description")
	return pattern_step_input(handle, Input{kind=.Time_Advance})
}

@(private)
pattern_copy_text :: proc(buffer: []u8, length: ^int, text: string) {
	count := copy(buffer, text)
	length^ = count
}

@(private)
pattern_fail_message :: proc(report: ^Pattern_Report, step: Pattern_Step, expected, actual: string) {
	report.ok = false
	failure := &report.failure
	failure.step = step
	failure.part_valid = false
	pattern_copy_text(failure.expected[:], &failure.expected_length, expected)
	pattern_copy_text(failure.actual[:], &failure.actual_length, actual)
}

@(private)
pattern_fail :: proc(
	handle: ^Test_Handle($T),
	report: ^Pattern_Report,
	step: Pattern_Step,
	part: Pattern_Part_ID,
	element: ^Element,
	expected, actual: string,
	message := "",
) -> bool {
	report.ok = false
	failure := &report.failure
	failure.step = step
	failure.part = part
	failure.part_valid = true
	if element != nil {
		failure.semantic_id = element.semantic_id
		failure.key_valid = element.key_valid
		if element.key_valid {
			pattern_copy_text(failure.key_text[:], &failure.key_text_length, fmt.tprintf("%v", element.key))
		}
	}
	pattern_copy_text(failure.expected[:], &failure.expected_length, expected)
	pattern_copy_text(failure.actual[:], &failure.actual_length, actual)
	pattern_copy_text(failure.message[:], &failure.message_length, message)
	failure.turn = last_turn(handle)
	failure.cause_id = failure.turn.cause_id
	failure.cause_kind = failure.turn.cause_kind
	failure.action_id = failure.turn.action_id
	return false
}

@(private)
pattern_part :: proc(config: Pattern_Config, id: Pattern_Part_ID) -> (Pattern_Part, bool) {
	for part in config.parts {
		if part.id == id { return part, true }
	}
	return {}, false
}

@(private)
pattern_has_part :: proc(config: Pattern_Config, id: Pattern_Part_ID) -> bool {
	_, found := pattern_part(config, id)
	return found
}

@(private)
pattern_find_raw :: proc(handle: ^Test_Handle($T), part: Pattern_Part) -> Find_Result {
	if part.semantic_id_valid {
		snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
		defer alicorn.semantic_snapshot_destroy(&snapshot)
		for semantic in snapshot.nodes {
			if semantic.id != part.semantic_id { continue }
			element, ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
			if !ok { return Find_Result{match=.None, status=.Allocation_Failed} }
			return Find_Result{match=.Unique, element=element}
		}
		return Find_Result{match=.None}
	}
	return find(handle, part.query)
}

@(private)
pattern_require_part :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (Element, bool) {
	part, found := pattern_part(config, id)
	if !found {
		pattern_fail(handle, report, step, id, nil, "configured pattern part", "part not configured")
		return {}, false
	}
	result := pattern_find_raw(handle, part)
	if result.match == .Ambiguous {
		pattern_fail(handle, report, step, id, &result.element, "one semantic node for the configured part", "ambiguous query")
		destroy_find_result(&result)
		return {}, false
	}
	if result.match != .Unique || result.status != .Ok {
		pattern_fail(handle, report, step, id, &result.element, "one semantic node for the configured part", "no matching semantic node")
		destroy_find_result(&result)
		return {}, false
	}
	if part.key_valid && (!result.element.key_valid || !ui_keys_equal(result.element.key, part.key)) {
		pattern_fail(handle, report, step, id, &result.element, "configured retained key", "a different retained key")
		destroy_find_result(&result)
		return {}, false
	}
	if result.element.handle_generation != handle.generation {
		pattern_fail(handle, report, step, id, &result.element, "element from the current handle", "stale handle generation")
		destroy_find_result(&result)
		return {}, false
	}
	return result.element, true
}

@(private)
pattern_find_part_optional :: proc(handle: ^Test_Handle($T), config: Pattern_Config, id: Pattern_Part_ID) -> Find_Result {
	part, found := pattern_part(config, id)
	if !found { return Find_Result{match=.None} }
	return pattern_find_raw(handle, part)
}

@(private)
pattern_option_key :: proc(element: ^Element) -> (value: u64, ok: bool) {
	if element == nil || !element.key_valid { return }
	#partial switch key in element.key {
	case u64:
		return key, true
	case alicorn.UI_Key_Pair:
		return key.second, true
	case:
		return
	}
}

@(private)
pattern_query_text :: proc(part: Pattern_Part) -> string {
	if part.semantic_id_valid {
		return fmt.tprintf("semantic %d/%d", part.semantic_id.namespace, part.semantic_id.value)
	}
	return fmt.tprintf(
		"role=%v name=%q match_role=%v match_name=%v",
		part.query.role, part.query.name, part.query.match_role, part.query.match_name,
	)
}

@(private)
pattern_element_inside :: proc(inner, outer: alicorn.Rect, epsilon: f32 = 0.5) -> bool {
	if inner.w <= 0 || inner.h <= 0 { return false }
	return inner.x >= outer.x-epsilon && inner.y >= outer.y-epsilon &&
		inner.x+inner.w <= outer.x+outer.w+epsilon &&
		inner.y+inner.h <= outer.y+outer.h+epsilon
}

@(private)
pattern_rect_intersects :: proc(a, b: alicorn.Rect) -> bool {
	return a.x < b.x+b.w && a.x+a.w > b.x && a.y < b.y+b.h && a.y+a.h > b.y
}

@(private)
pattern_view_destroy :: proc(view: ^Pattern_Options) {
	if view == nil { return }
	destroy_element(&view.trigger)
	if view.has_list { destroy_element(&view.list) }
	for index in 0..<len(view.options) { destroy_element(&view.options[index]) }
	for index in 0..<len(view.groups) { destroy_element(&view.groups[index]) }
	delete(view.options)
	delete(view.groups)
	view^ = {}
}

@(private)
pattern_collect_view :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	require_list: bool,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	view.trigger, ok = pattern_require_part(handle, config, trigger_id, step, report)
	if !ok { return view, false }
	view.options = make([dynamic]Element, 0, 16, handle.allocator)
	view.groups = make([dynamic]Element, 0, 4, handle.allocator)
	list_id: alicorn.Semantic_ID
	if _, configured := pattern_part(config, .List); configured && require_list && trigger_id == .Trigger {
		view.list, ok = pattern_require_part(handle, config, .List, step, report)
		if !ok { pattern_view_destroy(&view); return view, false }
		view.has_list = true
		list_id = view.list.semantic_id
	} else {
		snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
		defer alicorn.semantic_snapshot_destroy(&snapshot)
		for semantic in snapshot.nodes {
			if semantic.role != .List_Box || !semantic.is_collection { continue }
			if semantic.parent != view.trigger.semantic_id { continue }
			element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
			if !element_ok { continue }
			view.list = element
			view.has_list = true
			list_id = semantic.id
			break
		}
	}
	if !view.has_list {
		if require_list {
			pattern_fail(handle, report, step, .List, &view.trigger, "an anchored List_Box semantic", "no List_Box is parented to the trigger")
		}
		return view, !require_list
	}

	snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for semantic in snapshot.nodes {
		if semantic.collection_id != list_id { continue }
		element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if !element_ok { continue }
		#partial switch semantic.role {
		case .List_Box_Option:
			if len(view.options) >= PATTERN_MAX_OPTIONS {
				destroy_element(&element)
				pattern_fail(handle, report, step, .List, &view.list, "at most 256 realized options", "option bound exceeded")
				pattern_view_destroy(&view)
				return view, false
			}
			append(&view.options, element)
		case .Group:
			if len(view.groups) < PATTERN_MAX_GROUPS {
				append(&view.groups, element)
			} else {
				destroy_element(&element)
			}
		case:
			destroy_element(&element)
		}
	}
	// Snapshot iteration is already tree ordered, but position_in_set is the
	// published collection order and must win over incidental realization order.
	for index in 1..<len(view.options) {
		current := view.options[index]
		cursor := index
		for cursor > 0 && view.options[cursor-1].position_in_set > current.position_in_set {
			view.options[cursor] = view.options[cursor-1]
			cursor -= 1
		}
		view.options[cursor] = current
	}
	return view, true
}

@(private)
pattern_verify_combobox_trigger_identity :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Options,
	report: ^Pattern_Report,
) -> bool {
	trigger := &view.trigger
	if trigger.role != .Combo_Box {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "Semantic_Role.Combo_Box", fmt.tprintf("%v", trigger.role))
	}
	if alicorn.semantic_states_has(trigger.states, .Disabled) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "an enabled trigger", "trigger is disabled")
	}
	if !alicorn.semantic_actions_has(trigger.actions, .Focus) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "Focus action on focusable trigger", "missing Focus action")
	}
	return true
}

@(private)
pattern_verify_combobox_trigger_closed :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Options,
	report: ^Pattern_Report,
) -> bool {
	trigger := &view.trigger
	if !pattern_verify_combobox_trigger_identity(handle, view, report) { return false }
	if alicorn.semantic_states_has(trigger.states, .Expanded) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "collapsed trigger before opening", "Expanded state present")
	}
	if !alicorn.semantic_actions_has(trigger.actions, .Expand) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "Expand action while collapsed", "missing Expand action")
	}
	if alicorn.semantic_actions_has(trigger.actions, .Collapse) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "no Collapse action while collapsed", "Collapse action present")
	}
	return true
}

@(private)
pattern_verify_combobox_trigger_open :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Options,
	report: ^Pattern_Report,
) -> bool {
	trigger := &view.trigger
	if !pattern_verify_combobox_trigger_identity(handle, view, report) { return false }
	if !alicorn.semantic_states_has(trigger.states, .Expanded) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "Expanded trigger while open", "Expanded state absent")
	}
	if !alicorn.semantic_actions_has(trigger.actions, .Collapse) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "Collapse action while open", "missing Collapse action")
	}
	if alicorn.semantic_actions_has(trigger.actions, .Expand) {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger, "no Expand action while open", "Expand action is still present")
	}
	return true
}

@(private)
pattern_verify_combobox_static :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	view: ^Pattern_Options,
	report: ^Pattern_Report,
) -> bool {
	trigger, list := &view.trigger, &view.list
	if !pattern_verify_combobox_trigger_open(handle, view, report) { return false }
	if list.role != .List_Box {
		return pattern_fail(handle, report, .Static_Contract, .List, list, "Semantic_Role.List_Box", fmt.tprintf("%v", list.role))
	}
	if list.visual_node == 0 || !list.has_bounds {
		return pattern_fail(handle, report, .Static_Contract, .List, list, "realized List_Box with bounds", "List_Box is logical-only")
	}
	if list.parent_semantic_id != trigger.semantic_id {
		return pattern_fail(handle, report, .Static_Contract, .List, list,
			"List_Box parented to the Combo_Box trigger", "List_Box has a different or absent semantic parent")
	}
	if !list.is_collection {
		return pattern_fail(handle, report, .Static_Contract, .List, list, "List_Box is a semantic collection", "collection metadata absent")
	}
	if !alicorn.semantic_actions_has(list.actions, .Focus) {
		return pattern_fail(handle, report, .Static_Contract, .List, list, "Focus action on the List_Box", "missing Focus action")
	}
	if config.expect_option_count && list.logical_count != config.expected_option_count {
		return pattern_fail(handle, report, .Static_Contract, .List, list,
			fmt.tprintf("%d logical options", config.expected_option_count),
			fmt.tprintf("%d logical options", list.logical_count))
	}
	if len(view.options) == 0 {
		return pattern_fail(handle, report, .Static_Contract, .List, list, "at least one realized List_Box_Option", "no realized options")
	}
	if u64(len(view.options)) > list.logical_count {
		return pattern_fail(handle, report, .Static_Contract, .List, list,
			"realized options within the logical count", fmt.tprintf("%d realized / %d logical", len(view.options), list.logical_count))
	}

	selected_found := 0
	selected_index := -1
	positions := [PATTERN_MAX_OPTIONS]u64{}
	semantic_ids := [PATTERN_MAX_OPTIONS]alicorn.Semantic_ID{}
	keys := [PATTERN_MAX_OPTIONS]u64{}
	for &option, index in view.options[:len(view.options)] {
		if option.role != .List_Box_Option {
			return pattern_fail(handle, report, .Static_Contract, .List, &option, "Semantic_Role.List_Box_Option", fmt.tprintf("%v", option.role))
		}
		if option.collection_id != list.semantic_id {
			return pattern_fail(handle, report, .Static_Contract, .List, &option, "option belongs to the List_Box collection", "option has a different collection")
		}
		if option.position_in_set >= list.logical_count {
			return pattern_fail(handle, report, .Static_Contract, .List, &option, "position within the logical collection", fmt.tprintf("position %d / %d", option.position_in_set, list.logical_count))
		}
		for previous in 0..<index {
			if positions[previous] == option.position_in_set {
				return pattern_fail(handle, report, .Static_Contract, .List, &option, "unique collection positions", "duplicate position_in_set")
			}
			if semantic_ids[previous] == option.semantic_id {
				return pattern_fail(handle, report, .Static_Contract, .List, &option, "unique option Semantic_ID", "duplicate option Semantic_ID")
			}
		}
		positions[index] = option.position_in_set
		semantic_ids[index] = option.semantic_id

		disabled := alicorn.semantic_states_has(option.states, .Disabled)
		if disabled {
			if alicorn.semantic_actions_has(option.actions, .Select) || alicorn.semantic_actions_has(option.actions, .Focus) {
				return pattern_fail(handle, report, .Static_Contract, .Disabled_Option, &option,
					"disabled option without Select/Focus actions", "disabled option advertises Select or Focus")
			}
			if info, info_ok := alicorn.node_info(handle.runtime, option.visual_node); info_ok && info.focusable {
				return pattern_fail(handle, report, .Static_Contract, .Disabled_Option, &option,
					"disabled option is not focusable", "disabled option visual node is focusable")
			}
		} else {
			if !alicorn.semantic_actions_has(option.actions, .Select) {
				return pattern_fail(handle, report, .Static_Contract, .List, &option, "Select action on enabled option", "missing Select action")
			}
			if !alicorn.semantic_actions_has(option.actions, .Focus) {
				return pattern_fail(handle, report, .Static_Contract, .List, &option, "Focus action on enabled option", "missing Focus action")
			}
		}

		option_key, key_ok := pattern_option_key(&option)
		if !key_ok {
			return pattern_fail(handle, report, .Static_Contract, .List, &option, "stable retained option key", "option has no u64 or pair key")
		}
		for previous in 0..<index {
			if keys[previous] == option_key {
				return pattern_fail(handle, report, .Static_Contract, .List, &option, "unique option keys in one owner", "duplicate option key")
			}
		}
		keys[index] = option_key

		if option.parent_semantic_id != list.semantic_id {
			group_found := false
			for &group in view.groups {
				if group.semantic_id != option.parent_semantic_id { continue }
				group_found = true
				if group.role != .Group || group.parent_semantic_id != list.semantic_id || group.collection_id != list.semantic_id {
					return pattern_fail(handle, report, .Static_Contract, .List, &option,
						"option parent is a List_Box Group owned by this collection", "option parent is not an owned Group")
				}
				if len(group.name) == 0 {
					return pattern_fail(handle, report, .Static_Contract, .List, &group, "labeled group has a name", "group name is empty")
				}
				break
			}
			if !group_found {
				return pattern_fail(handle, report, .Static_Contract, .List, &option,
					"option parent is the List_Box or one of its Groups", "option parent is an unowned semantic")
			}
		}

		is_selected := alicorn.semantic_states_has(option.states, .Selected)
		if is_selected {
			selected_found += 1
			selected_index = index
		}
	}
	if selected_found != 1 {
		return pattern_fail(handle, report, .Static_Contract, .Selected_Option, list,
			"exactly one realized option with the Selected state", fmt.tprintf("%d selected options", selected_found))
	}
	if list.collection_selected_id != view.options[selected_index].semantic_id {
		return pattern_fail(handle, report, .Static_Contract, .Selected_Option, &view.options[selected_index],
			"List_Box selected_id names the selected option", "selected_id and Selected state disagree")
	}
	if view.options[selected_index].position_in_set >= list.logical_count {
		return pattern_fail(handle, report, .Static_Contract, .Selected_Option, &view.options[selected_index],
			"selected option position is inside the collection", "selected option position is outside the collection")
	}
	if len(view.options[selected_index].name) > 0 && trigger.value != view.options[selected_index].name {
		return pattern_fail(handle, report, .Static_Contract, .Trigger, trigger,
			"trigger value equals the selected option label", fmt.tprintf("%q", trigger.value))
	}
	if config.expect_selected_id && list.collection_selected_id != config.expected_selected_id {
		return pattern_fail(handle, report, .Static_Contract, .Selected_Option, &view.options[selected_index],
			fmt.tprintf("selected_id %d/%d", config.expected_selected_id.namespace, config.expected_selected_id.value),
			fmt.tprintf("selected_id %d/%d", list.collection_selected_id.namespace, list.collection_selected_id.value))
	}
	if config.expect_selected_key {
		selected_key, key_ok := pattern_option_key(&view.options[selected_index])
		if !key_ok || selected_key != config.expected_selected_key {
			return pattern_fail(handle, report, .Static_Contract, .Selected_Option, &view.options[selected_index],
				fmt.tprintf("selected key %d", config.expected_selected_key), fmt.tprintf("selected key %d", selected_key))
		}
	}
	return true
}

@(private)
pattern_current_option :: proc(view: ^Pattern_Options) -> (Element, bool) {
	for option in view.options {
		if option.collection_current { return option, true }
	}
	return {}, false
}

@(private)
pattern_selected_option :: proc(view: ^Pattern_Options) -> (Element, bool) {
	for option in view.options {
		if option.collection_selected || alicorn.semantic_states_has(option.states, .Selected) { return option, true }
	}
	return {}, false
}

@(private)
pattern_option_named :: proc(view: ^Pattern_Options, name: string) -> (Element, bool) {
	for option in view.options {
		if option.name == name { return option, true }
	}
	return {}, false
}

@(private)
pattern_refresh_open_view :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	view, ok = pattern_collect_view(handle, config, trigger_id, true, step, report)
	if !ok { return view, false }
	if view.list.visual_node == 0 {
		pattern_fail(handle, report, step, .List, &view.list, "a realized List_Box while open", "List_Box is logical-only")
		pattern_view_destroy(&view)
		return view, false
	}
	if !alicorn.semantic_states_has(view.trigger.states, .Expanded) {
		pattern_fail(handle, report, step, .Trigger, &view.trigger, "Expanded trigger while list is open", "Expanded state absent")
		pattern_view_destroy(&view)
		return view, false
	}
	if !alicorn.semantic_actions_has(view.trigger.actions, .Collapse) {
		pattern_fail(handle, report, step, .Trigger, &view.trigger, "Collapse action while open", "missing Collapse action")
		pattern_view_destroy(&view)
		return view, false
	}
	return view, true
}

@(private)
pattern_element_clone :: proc(handle: ^Test_Handle($T), source: ^Element) -> (Element, bool) {
	if source == nil { return {}, false }
	clone := source^
	clone.allocator = handle.allocator
	clone.handle_generation = handle.generation
	clone.description_epoch = handle.description_epoch
	ok: bool
	clone.name, ok = clone_string(source.name, handle.allocator)
	if !ok { return {}, false }
	clone.description, ok = clone_string(source.description, handle.allocator)
	if !ok { destroy_element(&clone); return {}, false }
	clone.value, ok = clone_string(source.value, handle.allocator)
	if !ok { destroy_element(&clone); return {}, false }
	if source.key_valid {
		clone.key, clone.key_valid, ok = clone_key(source.key, handle.allocator)
		if !ok { destroy_element(&clone); return {}, false }
	}
	return clone, true
}

// pattern_focus_semantic sends the ordinary semantic Focus action and verifies
// that the retained focus owner is the requested visual node.
@(private)
pattern_focus_semantic :: proc(
	handle: ^Test_Handle($T),
	element: ^Element,
	step: Pattern_Step,
	part: Pattern_Part_ID,
	report: ^Pattern_Report,
) -> bool {
	status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=element.semantic_id, semantic_action=.Focus})
	if status != .Ok {
		return pattern_fail(handle, report, step, part, element, "semantic Focus accepted", fmt.tprintf("status %v", status))
	}
	if !element.focused {
		// The Element snapshot was taken before the turn. Re-query the same
		// semantic ID through the public snapshot before failing.
		fresh := pattern_element_by_id(handle, element.semantic_id)
		defer destroy_element(&fresh)
		if !fresh.focused {
			return pattern_fail(handle, report, step, part, &fresh, "retained focus on the target element", "focus is elsewhere")
		}
	}
	return true
}

@(private)
pattern_element_by_id :: proc(handle: ^Test_Handle($T), id: alicorn.Semantic_ID) -> Element {
	snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for semantic in snapshot.nodes {
		if semantic.id != id { continue }
		element, ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if ok { return element }
		break
	}
	return {}
}

@(private)
pattern_press_key :: proc(
	handle: ^Test_Handle($T),
	key: Key,
	step: Pattern_Step,
	part: Pattern_Part_ID,
	report: ^Pattern_Report,
) -> bool {
	status := pattern_step_input(handle, Input{kind=.Key, key=key})
	if status != .Ok {
		return pattern_fail(handle, report, step, part, nil, fmt.tprintf("key %v accepted", key), fmt.tprintf("status %v", status), last_turn_diagnostic(handle))
	}
	if !last_turn(handle).stabilized {
		return pattern_fail(handle, report, step, part, nil, "stabilized turn", "Did_Not_Stabilize", last_turn_diagnostic(handle))
	}
	return true
}

@(private)
pattern_click_element :: proc(
	handle: ^Test_Handle($T),
	element: ^Element,
	step: Pattern_Step,
	part: Pattern_Part_ID,
	report: ^Pattern_Report,
) -> bool {
	status := click(handle, element)
	if status != .Ok {
		return pattern_fail(handle, report, step, part, element, "coordinate click accepted", fmt.tprintf("status %v", status), last_turn_diagnostic(handle))
	}
	return true
}

@(private)
pattern_open_keyboard :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	trigger, trigger_ok := pattern_require_part(handle, config, trigger_id, step, report)
	if !trigger_ok { return view, false }
	if !pattern_focus_semantic(handle, &trigger, step, trigger_id, report) {
		destroy_element(&trigger)
		return view, false
	}
	// Re-query before the activation turn so the input acts on current
	// semantics and the report can detect a stale snapshot.
	trigger_id_value := trigger.semantic_id
	destroy_element(&trigger)
	trigger = pattern_element_by_id(handle, trigger_id_value)
	if trigger.semantic_id.namespace == 0 {
		pattern_fail(handle, report, step, trigger_id, nil, "trigger remained queryable", "trigger disappeared after focus")
		return view, false
	}
	open_ok := pattern_press_key(handle, .Space, step, trigger_id, report)
	destroy_element(&trigger)
	if !open_ok { return view, false }
	return pattern_refresh_open_view(handle, config, trigger_id, step, report)
}

@(private)
pattern_open_pointer :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	trigger, trigger_ok := pattern_require_part(handle, config, trigger_id, step, report)
	if !trigger_ok { return view, false }
	if !pattern_click_element(handle, &trigger, step, trigger_id, report) {
		destroy_element(&trigger)
		return view, false
	}
	destroy_element(&trigger)
	return pattern_refresh_open_view(handle, config, trigger_id, step, report)
}

@(private)
pattern_open_semantic :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	trigger, trigger_ok := pattern_require_part(handle, config, trigger_id, step, report)
	if !trigger_ok { return view, false }
	status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=trigger.semantic_id, semantic_action=.Expand})
	destroy_element(&trigger)
	if status != .Ok {
		pattern_fail(handle, report, step, trigger_id, nil, "semantic Expand accepted", fmt.tprintf("status %v", status), last_turn_diagnostic(handle))
		return view, false
	}
	return pattern_refresh_open_view(handle, config, trigger_id, step, report)
}

@(private)
pattern_reopen_after_closed :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	view: Pattern_Options
	ok: bool
	if config.support_semantic_expand {
		view, ok = pattern_open_semantic(handle, config, trigger_id, step, report)
	} else {
		view, ok = pattern_open_pointer(handle, config, trigger_id, step, report)
	}
	if ok { pattern_view_destroy(&view) }
	return ok
}

@(private)
pattern_close_escape :: proc(
	handle: ^Test_Handle($T),
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	return pattern_press_key(handle, .Escape, step, .Trigger, report)
}

@(private)
pattern_verify_closed :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	view, ok := pattern_collect_view(handle, config, .Trigger, false, step, report)
	if !ok { return false }
	defer pattern_view_destroy(&view)
	if view.has_list && view.list.visual_node != 0 {
		return pattern_fail(handle, report, step, .List, &view.list, "no realized List_Box while collapsed", "a realized List_Box is still published")
	}
	if alicorn.semantic_states_has(view.trigger.states, .Expanded) {
		return pattern_fail(handle, report, step, .Trigger, &view.trigger, "collapsed trigger", "Expanded state is still present")
	}
	return true
}

@(private)
pattern_navigate_to_name :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	target: string,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Options, ok: bool) {
	if !pattern_press_key(handle, .Home, step, .List, report) { return view, false }
	limit := PATTERN_MAX_OPTIONS
	if config.expect_option_count { limit = int(config.expected_option_count) }
	for _ in 0..<limit {
		view, ok = pattern_refresh_open_view(handle, config, .Trigger, step, report)
		if !ok { return view, false }
		current, current_ok := pattern_current_option(&view)
		if !current_ok {
			pattern_fail(handle, report, step, .List, &view.list, "an active option after Home", "no current option")
			pattern_view_destroy(&view)
			return view, false
		}
		if current.name == target { return view, true }
		pattern_view_destroy(&view)
		if !pattern_press_key(handle, .Down, step, .List, report) {
			view = {}
			return view, false
		}
	}
	pattern_fail(handle, report, step, .Target_Option, nil,
		fmt.tprintf("navigable option %q", target), "target option was not reached")
	return {}, false
}

@(private)
pattern_select_current :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	target: Element,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	target_local := target
	target_clone, clone_ok := pattern_element_clone(handle, &target_local)
	if !clone_ok {
		return pattern_fail(handle, report, step, .Target_Option, nil, "cloneable target option", "allocation failed")
	}
	defer destroy_element(&target_clone)
	target_key, target_key_ok := pattern_option_key(&target_clone)
	if !target_key_ok {
		return pattern_fail(handle, report, step, .Target_Option, &target_clone, "target option has a stable key", "target key is absent")
	}
	if !pattern_press_key(handle, .Return, step, .Target_Option, report) { return false }
	if !pattern_verify_closed(handle, config, step, report) { return false }
	view, view_ok := pattern_collect_view(handle, config, .Trigger, false, step, report)
	if !view_ok { return false }
	defer pattern_view_destroy(&view)
	if !view.trigger.focused {
		return pattern_fail(handle, report, step, .Trigger, &view.trigger,
			"focus restored to the trigger after selection", "focus is elsewhere")
	}
	if !pattern_reopen_after_closed(handle, config, .Trigger, step, report) { return false }
	opened, opened_ok := pattern_refresh_open_view(handle, config, .Trigger, step, report)
	if !opened_ok { return false }
	defer pattern_view_destroy(&opened)
	selected, selected_ok := pattern_selected_option(&opened)
	if !selected_ok {
		return pattern_fail(handle, report, step, .Selected_Option, &opened.list, "a selected option after selection", "none")
	}
	selected_key, selected_key_ok := pattern_option_key(&selected)
	if !selected_key_ok || selected_key != target_key || selected.name != target.name {
		return pattern_fail(handle, report, step, .Selected_Option, &selected,
			fmt.tprintf("selected key %d label %q", target_key, target.name),
			fmt.tprintf("selected key %d label %q", selected_key, selected.name))
	}
	if !pattern_close_escape(handle, step, report) { return false }
	return pattern_verify_closed(handle, config, step, report)
}

// The main combobox implementation is declared below in small phases so a
// failure identifies the contract that broke rather than only a line number.
@(private)
pattern_check_combobox_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	// 1. Static closed contract. A trigger that is not a Combo_Box, is missing
	// Focus, or does not advertise Expand fails before any input is synthesized.
	initial, initial_ok := pattern_collect_view(handle, config, .Trigger, false, .Static_Contract, report)
	if !initial_ok { return false }
	if !pattern_verify_combobox_trigger_closed(handle, &initial, report) {
		pattern_view_destroy(&initial)
		return false
	}
	if initial.has_list && initial.list.visual_node != 0 {
		pattern_fail(handle, report, .Static_Contract, .List, &initial.list,
			"no realized List_Box before opening", "List_Box is already realized")
		pattern_view_destroy(&initial)
		return false
	}
	pattern_view_destroy(&initial)

	// 2. Keyboard opening and the complete open contract.
	open_view, open_ok := pattern_open_keyboard(handle, config, .Trigger, .Keyboard_Open, report)
	if !open_ok { return false }
	trigger_semantic := open_view.trigger.semantic_id
	if !pattern_verify_combobox_static(handle, config, &open_view, report) {
		pattern_view_destroy(&open_view)
		return false
	}
	// Focus must be inside the listbox or on the trigger after keyboard opening;
	// a composition may choose either, but not an unrelated control.
	focus_element := pattern_focused_element(handle)
	focus_inside := focus_element.semantic_id == trigger_semantic || focus_element.semantic_id == open_view.list.semantic_id
	if !focus_inside {
		for option in open_view.options {
			if option.semantic_id == focus_element.semantic_id { focus_inside = true; break }
		}
	}
	if !focus_inside {
		pattern_fail(handle, report, .Keyboard_Open, .List, &focus_element,
			"focus on the trigger or inside the opened List_Box", "focus is elsewhere")
		destroy_element(&focus_element)
		pattern_view_destroy(&open_view)
		return false
	}
	destroy_element(&focus_element)

	// 3. Navigation: Home/End, Down/Up, wrap, disabled skipping. The active
	// option is published through the List_Box current_id.
	if !pattern_press_key(handle, .Home, .Navigation, .List, report) { pattern_view_destroy(&open_view); return false }
	pattern_view_destroy(&open_view)
	open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
	if !open_ok { return false }
	first, first_ok := pattern_current_option(&open_view)
	if !first_ok || alicorn.semantic_states_has(first.states, .Disabled) {
		pattern_fail(handle, report, .Navigation, .List, &open_view.list, "Home selects the first enabled option", "no enabled current option")
		pattern_view_destroy(&open_view)
		return false
	}
	if !pattern_press_key(handle, .End, .Navigation, .List, report) { pattern_view_destroy(&open_view); return false }
	pattern_view_destroy(&open_view)
	open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
	if !open_ok { return false }
	last, last_ok := pattern_current_option(&open_view)
	if !last_ok || alicorn.semantic_states_has(last.states, .Disabled) {
		pattern_fail(handle, report, .Navigation, .List, &open_view.list, "End selects the last enabled option", "no enabled current option")
		pattern_view_destroy(&open_view)
		return false
	}
	if !pattern_press_key(handle, .Down, .Navigation, .List, report) { pattern_view_destroy(&open_view); return false }
	pattern_view_destroy(&open_view)
	open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
	if !open_ok { return false }
	wrapped, wrapped_ok := pattern_current_option(&open_view)
	if !wrapped_ok || wrapped.semantic_id != first.semantic_id {
		pattern_fail(handle, report, .Navigation, .Trigger, &open_view.list, fmt.tprintf("Down wraps to first option %q", first.name), fmt.tprintf("current option %q", wrapped.name))
		pattern_view_destroy(&open_view)
		return false
	}
	if !pattern_press_key(handle, .Up, .Navigation, .List, report) { pattern_view_destroy(&open_view); return false }
	pattern_view_destroy(&open_view)
	open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
	if !open_ok { return false }
	up_wrapped, up_wrapped_ok := pattern_current_option(&open_view)
	if !up_wrapped_ok || up_wrapped.semantic_id != last.semantic_id {
		pattern_fail(handle, report, .Navigation, .List, &open_view.list, "Up wraps from the first enabled option to the last", "active option did not wrap")
		pattern_view_destroy(&open_view)
		return false
	}
	// Walk the whole realized order once and require a disabled option never
	// becomes current.
	if !pattern_press_key(handle, .Home, .Navigation, .List, report) { pattern_view_destroy(&open_view); return false }
	for _ in 0..<int(open_view.list.logical_count) {
		pattern_view_destroy(&open_view)
		open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
		if !open_ok { return false }
		current, current_ok := pattern_current_option(&open_view)
		if !current_ok {
			pattern_fail(handle, report, .Navigation, .List, &open_view.list, "a current option during Down traversal", "current option is absent")
			pattern_view_destroy(&open_view)
			return false
		}
		if alicorn.semantic_states_has(current.states, .Disabled) {
			pattern_fail(handle, report, .Disabled_Option, .List, &current, "navigation skips disabled options", "disabled option became current")
			pattern_view_destroy(&open_view)
			return false
		}
		pattern_view_destroy(&open_view)
		if !pattern_press_key(handle, .Down, .Navigation, .List, report) { return false }
	}
	open_view, open_ok = pattern_refresh_open_view(handle, config, .Trigger, .Navigation, report)
	if !open_ok { return false }
	pattern_view_destroy(&open_view)

	// 4. Keyboard selection of a target option. Target_Option identifies the
	// option by published name; its stable key is asserted after the turn.
	target_part, target_configured := pattern_part(config, .Target_Option)
	if !target_configured {
		pattern_fail(handle, report, .Keyboard_Selection, .Target_Option, nil, "configured target option", "Target_Option part is absent")
		return false
	}
	nav_view, nav_ok := pattern_navigate_to_name(handle, config, target_part.query.name, .Keyboard_Selection, report)
	if !nav_ok { return false }
	target, target_found := pattern_option_named(&nav_view, target_part.query.name)
	if !target_found {
		pattern_fail(handle, report, .Keyboard_Selection, .Target_Option, &nav_view.list, "target option is realized", "target option is not realized")
		pattern_view_destroy(&nav_view)
		return false
	}
	target_clone, target_clone_ok := pattern_element_clone(handle, &target)
	pattern_view_destroy(&nav_view)
	if !target_clone_ok {
		pattern_fail(handle, report, .Keyboard_Selection, .Target_Option, nil, "cloneable target option", "allocation failed")
		return false
	}
	select_ok := pattern_select_current(handle, config, target_clone, .Keyboard_Selection, report)
	destroy_element(&target_clone)
	if !select_ok { return false }

	// 5. Escape cancels without changing the controlled value.
	cancel_view, cancel_ok := pattern_open_keyboard(handle, config, .Trigger, .Escape_Cancel, report)
	if !cancel_ok { return false }
	before, before_ok := pattern_selected_option(&cancel_view)
	before_key, before_key_ok := pattern_option_key(&before)
	pattern_view_destroy(&cancel_view)
	if !before_ok || !before_key_ok {
		pattern_fail(handle, report, .Escape_Cancel, .Selected_Option, nil, "a selected option before Escape", "no selected option")
		return false
	}
	if !pattern_press_key(handle, .Down, .Escape_Cancel, .List, report) { return false }
	if !pattern_close_escape(handle, .Escape_Cancel, report) { return false }
	if !pattern_verify_closed(handle, config, .Escape_Cancel, report) { return false }
	after_view, after_ok := pattern_collect_view(handle, config, .Trigger, false, .Escape_Cancel, report)
	if !after_ok { return false }
	if !after_view.trigger.focused {
		pattern_fail(handle, report, .Escape_Cancel, .Trigger, &after_view.trigger, "focus restored to the trigger", "focus is elsewhere")
		pattern_view_destroy(&after_view)
		return false
	}
	pattern_view_destroy(&after_view)
	if !pattern_reopen_after_closed(handle, config, .Trigger, .Escape_Cancel, report) { return false }
	reopen, reopen_ok := pattern_refresh_open_view(handle, config, .Trigger, .Escape_Cancel, report)
	if !reopen_ok { return false }
	after, after_selected_ok := pattern_selected_option(&reopen)
	after_key, after_key_ok := pattern_option_key(&after)
	pattern_view_destroy(&reopen)
	if !after_selected_ok || !after_key_ok || after_key != before_key {
		pattern_fail(handle, report, .Escape_Cancel, .Selected_Option, &after, fmt.tprintf("selected key %d after Escape", before_key), fmt.tprintf("selected key %d", after_key))
		return false
	}
	if !pattern_close_escape(handle, .Escape_Cancel, report) { return false }

	// 6. Tab closes the popup and moves focus out.
	tab_view, tab_ok := pattern_open_keyboard(handle, config, .Trigger, .Tab_Close, report)
	if !tab_ok { return false }
	pattern_view_destroy(&tab_view)
	if !pattern_press_key(handle, .Tab, .Tab_Close, .Trigger, report) { return false }
	if !pattern_verify_closed(handle, config, .Tab_Close, report) { return false }
	tab_closed, tab_closed_ok := pattern_collect_view(handle, config, .Trigger, false, .Tab_Close, report)
	if !tab_closed_ok { return false }
	if tab_closed.trigger.focused {
		pattern_fail(handle, report, .Tab_Close, .Trigger, &tab_closed.trigger, "focus moved out of the trigger after Tab", "trigger still has focus")
		pattern_view_destroy(&tab_closed)
		return false
	}
	pattern_view_destroy(&tab_closed)

	// 7. Pointer opens and an option click selects the same target key.
	pointer_view, pointer_ok := pattern_open_pointer(handle, config, .Trigger, .Pointer_Parity, report)
	if !pointer_ok { return false }
	pointer_target, pointer_target_ok := pattern_option_named(&pointer_view, target_part.query.name)
	if !pointer_target_ok {
		pattern_fail(handle, report, .Pointer_Parity, .Target_Option, &pointer_view.list, "target option realized for pointer input", "target option absent")
		pattern_view_destroy(&pointer_view)
		return false
	}
	pointer_key, pointer_key_ok := pattern_option_key(&pointer_target)
	pattern_view_destroy(&pointer_view)
	if !pointer_key_ok {
		pattern_fail(handle, report, .Pointer_Parity, .Target_Option, &pointer_target, "target option key", "key absent")
		return false
	}
	if !pattern_click_target_option(handle, config, target_part.query.name, .Pointer_Parity, report) { return false }
	if !pattern_verify_closed(handle, config, .Pointer_Parity, report) { return false }
	pointer_after, pointer_after_ok := pattern_selected_after_reopen(handle, config, .Pointer_Parity, report)
	if !pointer_after_ok { return false }
	pointer_after_key, pointer_after_key_ok := pattern_option_key(&pointer_after)
	if !pointer_after_key_ok || pointer_after_key != pointer_key {
		pattern_fail(handle, report, .Pointer_Parity, .Target_Option, &pointer_after,
			fmt.tprintf("pointer-selected key %d", pointer_key), fmt.tprintf("selected key %d", pointer_after_key))
		destroy_element(&pointer_after)
		return false
	}
	destroy_element(&pointer_after)
	if !pattern_close_escape(handle, .Pointer_Parity, report) { return false }

	// 8. Semantic Expand/Select parity. Custom compositions can open through
	// pointer input when the runtime's stock Combo_Box handler owns Expand.
	semantic_view: Pattern_Options
	semantic_ok: bool
	if config.support_semantic_expand {
		semantic_view, semantic_ok = pattern_open_semantic(handle, config, .Trigger, .Semantic_Action_Parity, report)
	} else {
		semantic_view, semantic_ok = pattern_open_pointer(handle, config, .Trigger, .Semantic_Action_Parity, report)
	}
	if !semantic_ok { return false }
	semantic_target, semantic_target_ok := pattern_option_named(&semantic_view, target_part.query.name)
	if !semantic_target_ok {
		pattern_fail(handle, report, .Semantic_Action_Parity, .Target_Option, &semantic_view.list, "target option realized", "target option absent")
		pattern_view_destroy(&semantic_view)
		return false
	}
	semantic_key, semantic_key_ok := pattern_option_key(&semantic_target)
	if !semantic_key_ok {
		pattern_fail(handle, report, .Semantic_Action_Parity, .Target_Option, &semantic_target, "target option key", "key absent")
		pattern_view_destroy(&semantic_view)
		return false
	}
	status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=semantic_target.semantic_id, semantic_action=.Select})
	pattern_view_destroy(&semantic_view)
	if status != .Ok {
		pattern_fail(handle, report, .Semantic_Action_Parity, .Target_Option, &semantic_target, "semantic Select accepted", fmt.tprintf("status %v", status))
		return false
	}
	if pattern_settle_description(handle) != .Ok {
		pattern_fail(handle, report, .Semantic_Action_Parity, .Target_Option, &semantic_target, "settled follow-up description", last_turn_diagnostic(handle))
		return false
	}
	if !pattern_verify_closed(handle, config, .Semantic_Action_Parity, report) { return false }
	semantic_after, semantic_after_ok := pattern_selected_after_reopen(handle, config, .Semantic_Action_Parity, report)
	if !semantic_after_ok { return false }
	semantic_after_key, semantic_after_key_ok := pattern_option_key(&semantic_after)
	if !semantic_after_key_ok || semantic_after_key != semantic_key {
		pattern_fail(handle, report, .Semantic_Action_Parity, .Target_Option, &semantic_after,
			fmt.tprintf("semantic-selected key %d", semantic_key), fmt.tprintf("selected key %d", semantic_after_key))
		destroy_element(&semantic_after)
		return false
	}
	destroy_element(&semantic_after)
	if !pattern_close_escape(handle, .Semantic_Action_Parity, report) { return false }

	// 9. Disabled option is not selectable, not current after type-ahead, and is
	// skipped by navigation (already asserted above).
	if disabled_part, disabled_configured := pattern_part(config, .Disabled_Option); disabled_configured {
		disabled_view, disabled_ok := pattern_open_keyboard(handle, config, .Trigger, .Disabled_Option, report)
		if !disabled_ok { return false }
		disabled, disabled_found := pattern_option_named(&disabled_view, disabled_part.query.name)
		if !disabled_found {
			pattern_fail(handle, report, .Disabled_Option, .Disabled_Option, &disabled_view.list, "disabled option realized", "disabled option absent")
			pattern_view_destroy(&disabled_view)
			return false
		}
		if !alicorn.semantic_states_has(disabled.states, .Disabled) {
			pattern_fail(handle, report, .Disabled_Option, .Disabled_Option, &disabled, "Disabled state", "Disabled state absent")
			pattern_view_destroy(&disabled_view)
			return false
		}
		disabled_id := disabled.semantic_id
		pattern_view_destroy(&disabled_view)
		status = pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=disabled_id, semantic_action=.Select})
		if status == .Ok {
			pattern_fail(handle, report, .Disabled_Option, .Disabled_Option, nil, "semantic Select rejected on a disabled option", "Select was accepted")
			return false
		}
		// The rejected Select must leave the popup and the controlled value
		// unchanged. Type-ahead then runs against the same still-open list.
		disabled_refresh, disabled_refresh_ok := pattern_refresh_open_view(handle, config, .Trigger, .Disabled_Option, report)
		if !disabled_refresh_ok { return false }
		pattern_view_destroy(&disabled_refresh)
		if pattern_step_input(handle, Input{kind=.Text_Commit, text=disabled_part.query.name}) != .Ok {
			pattern_fail(handle, report, .Typeahead, .Disabled_Option, nil, "type-ahead turn accepted", "status was not Ok")
			return false
		}
		typing_after, typing_after_ok := pattern_refresh_open_view(handle, config, .Trigger, .Typeahead, report)
		if !typing_after_ok { return false }
		typed_current, typed_current_ok := pattern_current_option(&typing_after)
		if typed_current_ok && alicorn.semantic_states_has(typed_current.states, .Disabled) {
			pattern_fail(handle, report, .Typeahead, .Disabled_Option, &typed_current, "type-ahead skips disabled options", "disabled option became current")
			pattern_view_destroy(&typing_after)
			return false
		}
		pattern_view_destroy(&typing_after)
		if !pattern_close_escape(handle, .Typeahead, report) { return false }
	}

	// 10. Type-ahead to the target and Escape without committing.
	typed_view, typed_ok := pattern_open_keyboard(handle, config, .Trigger, .Typeahead, report)
	if !typed_ok { return false }
	pattern_view_destroy(&typed_view)
	if pattern_step_input(handle, Input{kind=.Text_Commit, text=target_part.query.name}) != .Ok {
		pattern_fail(handle, report, .Typeahead, .Target_Option, nil, "type-ahead turn accepted", "status was not Ok")
		return false
	}
	typed_after, typed_after_ok := pattern_refresh_open_view(handle, config, .Trigger, .Typeahead, report)
	if !typed_after_ok { return false }
	typed_current, typed_current_ok := pattern_current_option(&typed_after)
	if !typed_current_ok || typed_current.name != target_part.query.name {
		pattern_fail(handle, report, .Typeahead, .Target_Option, &typed_after.list,
			fmt.tprintf("type-ahead current option %q", target_part.query.name), "a different current option")
		pattern_view_destroy(&typed_after)
		return false
	}
	pattern_view_destroy(&typed_after)
	if !pattern_close_escape(handle, .Typeahead, report) { return false }

	// 11. Virtual reveal: the active last option must be realized with bounds
	// inside the List_Box viewport after End.
	if config.expect_virtual_reveal {
		reveal_view, reveal_ok := pattern_open_keyboard(handle, config, .Trigger, .Virtual_Reveal, report)
		if !reveal_ok { return false }
		pattern_view_destroy(&reveal_view)
		if !pattern_press_key(handle, .End, .Virtual_Reveal, .List, report) { return false }
		if pattern_settle_description(handle) != .Ok {
			pattern_fail(handle, report, .Virtual_Reveal, .List, nil, "settled follow-up description", last_turn_diagnostic(handle))
			return false
		}
		revealed, revealed_ok := pattern_refresh_open_view(handle, config, .Trigger, .Virtual_Reveal, report)
		if !revealed_ok { return false }
		reveal_current, reveal_current_ok := pattern_current_option(&revealed)
		if !reveal_current_ok {
			pattern_fail(handle, report, .Virtual_Reveal, .List, &revealed.list, "an active last option after End", "no current option")
			pattern_view_destroy(&revealed)
			return false
		}
		if !reveal_current.has_bounds || reveal_current.visual_node == 0 || !pattern_rect_intersects(reveal_current.bounds, revealed.list.bounds) {
			pattern_fail(handle, report, .Virtual_Reveal, .List, &reveal_current,
				fmt.tprintf("realized active option visible within List_Box %v", revealed.list.bounds),
				fmt.tprintf("active option bounds %v visual=%d", reveal_current.bounds, reveal_current.visual_node))
			pattern_view_destroy(&revealed)
			return false
		}
		pattern_view_destroy(&revealed)
		if !pattern_close_escape(handle, .Virtual_Reveal, report) { return false }
	}

	// 12. Two owner instances with the same stable keys must publish distinct
	// option identities. This phase is opt-in through Peer_Trigger.
	if pattern_has_part(config, .Peer_Trigger) {
		primary_ids, primary_keys, primary_ok := pattern_option_identity_map(handle, config, .Trigger, .Owner_Identity, report)
		defer delete(primary_ids)
		defer delete(primary_keys)
		if !primary_ok { return false }
		peer_ids, peer_keys, peer_ok := pattern_option_identity_map(handle, config, .Peer_Trigger, .Owner_Identity, report)
		defer delete(peer_ids)
		defer delete(peer_keys)
		if !peer_ok { return false }
		for index in 0..<len(primary_keys) {
			for peer_index in 0..<len(peer_keys) {
				if primary_keys[index] != peer_keys[peer_index] { continue }
				if primary_ids[index] == peer_ids[peer_index] {
					pattern_fail(handle, report, .Owner_Identity, .Peer_Trigger, nil,
						"same option key resolves to distinct Semantic_IDs in two owners", "both owners published the same option Semantic_ID")
					return false
				}
			}
		}
	}

	// 13. Reordering options in application state must preserve the selected
	// key, label, and Semantic_ID while changing its collection position.
	if reorder_part, reorder_configured := pattern_part(config, .Extra_Action); reorder_configured {
		before_view, before_ok := pattern_open_keyboard(handle, config, .Trigger, .Reorder_Identity, report)
		if !before_ok { return false }
		before_selected_raw, before_selected_ok := pattern_selected_option(&before_view)
		before_selected, before_clone_ok := pattern_element_clone(handle, &before_selected_raw)
		before_count := before_view.list.logical_count
		pattern_view_destroy(&before_view)
		if !before_selected_ok || !before_clone_ok {
			pattern_fail(handle, report, .Reorder_Identity, .Selected_Option, nil, "selected option before reorder", "no selected option")
			if before_clone_ok { destroy_element(&before_selected) }
			return false
		}
		before_position := before_selected.position_in_set
		before_key, before_key_ok := pattern_option_key(&before_selected)
		before_id := before_selected.semantic_id
		before_name := before_selected.name
		if !before_key_ok {
			pattern_fail(handle, report, .Reorder_Identity, .Selected_Option, &before_selected, "selected option key before reorder", "key is absent")
			destroy_element(&before_selected)
			return false
		}
		defer destroy_element(&before_selected)
		if !pattern_close_escape(handle, .Reorder_Identity, report) { return false }
		reorder_action, action_ok := pattern_require_part(handle, config, .Extra_Action, .Reorder_Identity, report)
		if !action_ok { return false }
		if !pattern_click_element(handle, &reorder_action, .Reorder_Identity, .Extra_Action, report) {
			destroy_element(&reorder_action)
			return false
		}
		destroy_element(&reorder_action)
		// The application applies the new order in its next description.
		after_view, after_view_ok := pattern_open_keyboard(handle, config, .Trigger, .Reorder_Identity, report)
		if !after_view_ok { return false }
		after_selected, after_selected_ok := pattern_selected_option(&after_view)
		after_key, after_key_ok := pattern_option_key(&after_selected)
		if !after_selected_ok || !after_key_ok || after_key != before_key || after_selected.name != before_name ||
			after_selected.semantic_id != before_id {
			pattern_fail(handle, report, .Reorder_Identity, .Selected_Option, &after_selected,
				fmt.tprintf("selected identity key=%d label=%q", before_key, before_name),
				fmt.tprintf("selected identity key=%d label=%q", after_key, after_selected.name))
			pattern_view_destroy(&after_view)
			return false
		}
		if after_selected.position_in_set == before_position && before_count > 1 {
			pattern_fail(handle, report, .Reorder_Identity, .Selected_Option, &after_selected,
				"selected option moves to a new collection position", "position was unchanged after reorder")
			pattern_view_destroy(&after_view)
			return false
		}
		pattern_view_destroy(&after_view)
		if !pattern_close_escape(handle, .Reorder_Identity, report) { return false }
	}

	// 14. A trigger behind a modal must not expand or change state.
	if pattern_has_part(config, .Modal_Action) && pattern_has_part(config, .Dialog) {
		if !pattern_modal_rejection_phase(handle, config, report) { return false }
	}
	return true
}

@(private)
pattern_focused_element :: proc(handle: ^Test_Handle($T)) -> Element {
	id := alicorn.focused_node(handle.runtime)
	if id == 0 { return {} }
	info, found := alicorn.node_info(handle.runtime, id)
	if !found { return {} }
	if alicorn.semantic_id_is_valid(info.semantic_id) {
		element := pattern_element_by_id(handle, info.semantic_id)
		if element.semantic_id.namespace != 0 { return element }
	}
	return Element{
		handle_generation=handle.generation,
		description_epoch=handle.description_epoch,
		semantic_id=info.semantic_id,
		visual_node=id,
		bounds=info.bounds,
		has_bounds=info.bounds.w > 0 && info.bounds.h > 0,
		focused=true,
		allocator=handle.allocator,
	}
}

@(private)
pattern_click_target_option :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	name: string,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	view, ok := pattern_refresh_open_view(handle, config, .Trigger, step, report)
	if !ok { return false }
	option, found := pattern_option_named(&view, name)
	pattern_view_destroy(&view)
	if !found {
		pattern_fail(handle, report, step, .Target_Option, nil, fmt.tprintf("realized option %q", name), "option absent")
		return false
	}
	if !pattern_click_element(handle, &option, step, .Target_Option, report) { return false }
	if pattern_settle_description(handle) != .Ok {
		return pattern_fail(handle, report, step, .Target_Option, nil, "settled follow-up description", last_turn_diagnostic(handle))
	}
	return true
}

@(private)
pattern_selected_after_reopen :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (Element, bool) {
	view, ok := pattern_open_keyboard(handle, config, .Trigger, step, report)
	if !ok { return {}, false }
	selected, selected_ok := pattern_selected_option(&view)
	clone, clone_ok := pattern_element_clone(handle, &selected)
	pattern_view_destroy(&view)
	if !selected_ok || !clone_ok {
		if clone_ok { destroy_element(&clone) }
		pattern_fail(handle, report, step, .Selected_Option, nil, "a selected option after reopening", "no selected option")
		return {}, false
	}
	return clone, true
}

@(private)
pattern_option_identity_map :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	trigger_id: Pattern_Part_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (ids: [dynamic]alicorn.Semantic_ID, keys: [dynamic]u64, ok: bool) {
	view, view_ok := pattern_open_keyboard(handle, config, trigger_id, step, report)
	if !view_ok { return ids, keys, false }
	ids = make([dynamic]alicorn.Semantic_ID, 0, len(view.options), handle.allocator)
	keys = make([dynamic]u64, 0, len(view.options), handle.allocator)
	for &option in view.options {
		key, key_ok := pattern_option_key(&option)
		if !key_ok { continue }
		append(&ids, option.semantic_id)
		append(&keys, key)
	}
	pattern_view_destroy(&view)
	if !pattern_close_escape(handle, step, report) { return ids, keys, false }
	return ids, keys, true
}

@(private)
pattern_modal_rejection_phase :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	if !pattern_verify_closed(handle, config, .Modal_Rejection, report) { return false }
	trigger, trigger_ok := pattern_require_part(handle, config, .Trigger, .Modal_Rejection, report)
	if !trigger_ok { return false }
	defer destroy_element(&trigger)
	modal_action, action_ok := pattern_require_part(handle, config, .Modal_Action, .Modal_Rejection, report)
	if !action_ok { return false }
	if !pattern_click_element(handle, &modal_action, .Modal_Rejection, .Modal_Action, report) {
		destroy_element(&modal_action)
		return false
	}
	destroy_element(&modal_action)
	dialog, dialog_ok := pattern_require_part(handle, config, .Dialog, .Modal_Rejection, report)
	if !dialog_ok { return false }
	destroy_element(&dialog)
	if pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=trigger.semantic_id, semantic_action=.Expand}) == .Ok {
		pattern_fail(handle, report, .Modal_Rejection, .Trigger, &trigger,
			"semantic Expand rejected for a trigger behind a modal", "Expand was accepted")
		return false
	}
	after_trigger := pattern_element_by_id(handle, trigger.semantic_id)
	if alicorn.semantic_states_has(after_trigger.states, .Expanded) {
		pattern_fail(handle, report, .Modal_Rejection, .Trigger, &after_trigger,
			"trigger remains collapsed behind the modal", "Expanded state changed")
		destroy_element(&after_trigger)
		return false
	}
	destroy_element(&after_trigger)
	if !pattern_verify_closed(handle, config, .Modal_Rejection, report) { return false }
	if !pattern_press_key(handle, .Escape, .Modal_Rejection, .Dialog, report) { return false }
	if result := pattern_find_part_optional(handle, config, .Dialog); result.match != .None {
		pattern_fail(handle, report, .Modal_Rejection, .Dialog, &result.element,
			"modal dismissed by Escape", "Dialog is still published")
		destroy_find_result(&result)
		return false
	}
	return true
}

@(private)
pattern_modal_open :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (trigger: Element, dialog: Element, ok: bool) {
	trigger, ok = pattern_require_part(handle, config, .Trigger, step, report)
	if !ok { return {}, {}, false }
	if !pattern_focus_semantic(handle, &trigger, step, .Trigger, report) {
		destroy_element(&trigger)
		return {}, {}, false
	}
	trigger_value := trigger.semantic_id
	destroy_element(&trigger)
	trigger = pattern_element_by_id(handle, trigger_value)
	if trigger.semantic_id.namespace == 0 {
		pattern_fail(handle, report, step, .Trigger, nil, "opener remains queryable after focus", "opener disappeared")
		return {}, {}, false
	}
	if !pattern_click_element(handle, &trigger, step, .Trigger, report) {
		destroy_element(&trigger)
		return {}, {}, false
	}
	destroy_element(&trigger)
	trigger = pattern_element_by_id(handle, trigger_value)
	dialog_result := pattern_find_part_optional(handle, config, .Dialog)
	if dialog_result.match != .Unique || dialog_result.status != .Ok {
		pattern_fail(handle, report, step, .Dialog, &dialog_result.element,
			"one Dialog semantic after opening", "Dialog is absent or ambiguous")
		destroy_find_result(&dialog_result)
		destroy_element(&trigger)
		return {}, {}, false
	}
	dialog = dialog_result.element
	focus := pattern_focused_element(handle)
	if !focus.focused || !focus.has_bounds || !pattern_element_inside(focus.bounds, dialog.bounds) {
		pattern_fail(handle, report, step, .Dialog, &focus,
			"keyboard focus inside the opened dialog", "focus is outside the dialog bounds")
		destroy_element(&focus)
		destroy_element(&dialog)
		destroy_element(&trigger)
		return {}, {}, false
	}
	destroy_element(&focus)
	return trigger, dialog, true
}

@(private)
pattern_modal_expect_closed :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	result := pattern_find_part_optional(handle, config, .Dialog)
	if result.match != .None || result.status != .Ok {
		pattern_fail(handle, report, step, .Dialog, &result.element,
			"no Dialog semantic while the modal is closed", "Dialog is still published")
		destroy_find_result(&result)
		return false
	}
	return true
}

@(private)
pattern_check_modal_dialog_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	// Required composition parts.
	for required in ([]Pattern_Part_ID{.Trigger, .Dialog, .Background_Action}) {
		if !pattern_has_part(config, required) {
			pattern_fail(handle, report, .Resolve_Parts, required, nil, "required modal composition part", "part is not configured")
			return false
		}
	}
	if !pattern_modal_expect_closed(handle, config, .Resolve_Parts, report) { return false }

	// 1. Pointer opening establishes focus inside the dialog and containment.
	trigger, dialog, open_ok := pattern_modal_open(handle, config, .Focus_Inside, report)
	if !open_ok { return false }
	defer destroy_element(&trigger)
	dialog_bounds := dialog.bounds
	destroy_element(&dialog)

	background, background_ok := pattern_require_part(handle, config, .Background_Action, .Containment, report)
	if !background_ok { return false }
	if status := click(handle, &background); status == .Ok {
		pattern_fail(handle, report, .Containment, .Background_Action, &background,
			"pointer activation rejected for a background control", "click was accepted")
		destroy_element(&background)
		return false
	}
	if pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=background.semantic_id, semantic_action=.Press}) == .Ok {
		pattern_fail(handle, report, .Containment, .Background_Action, &background,
			"semantic Press rejected for a background control", "semantic Press was accepted")
		destroy_element(&background)
		return false
	}
	destroy_element(&background)
	still_dialog := pattern_find_part_optional(handle, config, .Dialog)
	if still_dialog.match != .Unique {
		pattern_fail(handle, report, .Containment, .Dialog, &still_dialog.element, "Dialog remains open after rejected background input", "Dialog disappeared")
		destroy_find_result(&still_dialog)
		return false
	}
	focus_after_background := pattern_focused_element(handle)
	if !focus_after_background.has_bounds || !pattern_element_inside(focus_after_background.bounds, dialog_bounds) {
		pattern_fail(handle, report, .Containment, .Dialog, &focus_after_background,
			"focus remains inside the dialog", "focus moved outside")
		destroy_element(&focus_after_background)
		destroy_find_result(&still_dialog)
		return false
	}
	destroy_element(&focus_after_background)
	destroy_find_result(&still_dialog)

	// 2. Focus traversal wraps within the modal subtree.
	start_focus := pattern_focused_element(handle)
	start_id := start_focus.semantic_id
	destroy_element(&start_focus)
	cycle := config.max_focus_cycle
	if cycle <= 0 { cycle = 12 }
	cycle = min(cycle, PATTERN_MAX_FOCUS_CYCLE)
	wrapped := false
	seen_distinct := 0
	previous_id := alicorn.Semantic_ID{}
	for _ in 0..<cycle {
		if !pattern_press_key(handle, .Tab, .Traversal_Wrap, .Dialog, report) { return false }
		focus := pattern_focused_element(handle)
		if !focus.has_bounds || !pattern_element_inside(focus.bounds, dialog_bounds) {
			pattern_fail(handle, report, .Traversal_Wrap, .Dialog, &focus,
				"Tab focus stays inside the dialog subtree", "focus left the dialog bounds")
			destroy_element(&focus)
			return false
		}
		if focus.semantic_id != previous_id { seen_distinct += 1 }
		previous_id = focus.semantic_id
		if focus.semantic_id == start_id {
			wrapped = true
			destroy_element(&focus)
			break
		}
		destroy_element(&focus)
	}
	if !wrapped {
		pattern_fail(handle, report, .Traversal_Wrap, .Dialog, nil,
			"focus traversal wraps to its starting control", "no wrap within the bounded probe")
		return false
	}
	if seen_distinct < 2 {
		pattern_fail(handle, report, .Traversal_Wrap, .Dialog, nil,
			"at least two focusable controls inside the dialog", "traversal never left the starting control")
		return false
	}

	// 3. Escape dismisses and restores focus to the saved opener.
	if !pattern_press_key(handle, .Escape, .Dismissal, .Dialog, report) { return false }
	if !pattern_modal_expect_closed(handle, config, .Dismissal, report) { return false }
	opener := pattern_element_by_id(handle, trigger.semantic_id)
	if !opener.focused {
		pattern_fail(handle, report, .Dismissal, .Trigger, &opener,
			"focus restored to the modal opener", "focus is elsewhere")
		destroy_element(&opener)
		return false
	}
	destroy_element(&opener)

	// 4. Activation parity: pointer, keyboard, and semantic activation of the
	// primary action all dismiss through the application's composed control.
	if primary_part, primary_configured := pattern_part(config, .Primary_Action); primary_configured {
		// pointer
		if !pattern_modal_activation(handle, config, .Pointer, .Activation_Parity, report) { return false }
		// keyboard
		if !pattern_modal_activation(handle, config, .Keyboard, .Activation_Parity, report) { return false }
		// semantic
		if !pattern_modal_activation(handle, config, .Semantic, .Activation_Parity, report) { return false }
		_ = primary_part
	}

	// 5. Focus recovery when a dialog child disappears mid-dialog.
	if pattern_has_part(config, .Transient_Action) && pattern_has_part(config, .Extra_Action) {
		recovered_trigger, recovered_dialog, recovered_ok := pattern_modal_open(handle, config, .Focus_Recovery, report)
		if !recovered_ok { return false }
		recovered_bounds := recovered_dialog.bounds
		destroy_element(&recovered_dialog)
		transient, transient_ok := pattern_require_part(handle, config, .Transient_Action, .Focus_Recovery, report)
		if !transient_ok { destroy_element(&recovered_trigger); return false }
		if !pattern_focus_semantic(handle, &transient, .Focus_Recovery, .Transient_Action, report) {
			destroy_element(&transient)
			destroy_element(&recovered_trigger)
			return false
		}
		transient_id := transient.semantic_id
		destroy_element(&transient)
		extra, extra_ok := pattern_require_part(handle, config, .Extra_Action, .Focus_Recovery, report)
		if !extra_ok { destroy_element(&recovered_trigger); return false }
		if !pattern_click_element(handle, &extra, .Focus_Recovery, .Extra_Action, report) {
			destroy_element(&extra)
			destroy_element(&recovered_trigger)
			return false
		}
		destroy_element(&extra)
		if result := pattern_find_part_optional(handle, config, .Transient_Action); result.match != .None {
			pattern_fail(handle, report, .Focus_Recovery, .Transient_Action, &result.element,
				"removed modal child is no longer published", "removed child is still present")
			destroy_find_result(&result)
			destroy_element(&recovered_trigger)
			return false
		}
		dialog_after := pattern_find_part_optional(handle, config, .Dialog)
		if dialog_after.match != .Unique {
			pattern_fail(handle, report, .Focus_Recovery, .Dialog, &dialog_after.element,
				"dialog remains open after child removal", "dialog disappeared")
			destroy_find_result(&dialog_after)
			destroy_element(&recovered_trigger)
			return false
		}
		focus := pattern_focused_element(handle)
		if focus.semantic_id == transient_id || !focus.has_bounds || !pattern_element_inside(focus.bounds, recovered_bounds) {
			pattern_fail(handle, report, .Focus_Recovery, .Dialog, &focus,
				"focus recovers inside the dialog", "focus stayed on the removed child or left the dialog")
			destroy_element(&focus)
			destroy_find_result(&dialog_after)
			destroy_element(&recovered_trigger)
			return false
		}
		destroy_element(&focus)
		destroy_find_result(&dialog_after)
		if !pattern_close_escape(handle, .Focus_Recovery, report) {
			destroy_element(&recovered_trigger)
			return false
		}
		if !pattern_modal_expect_closed(handle, config, .Focus_Recovery, report) {
			destroy_element(&recovered_trigger)
			return false
		}
		destroy_element(&recovered_trigger)
	}

	// 6. Nested/sequential modal: the second overlay owns input and focus, and
	// closing it restores the first overlay without leaking focus to the page.
	if pattern_has_part(config, .Nested_Action) && pattern_has_part(config, .Nested_Dialog) {
		nested_trigger, nested_dialog, nested_ok := pattern_modal_open(handle, config, .Nested_Overlay, report)
		if !nested_ok { return false }
		destroy_element(&nested_dialog)
		nested_action, nested_action_ok := pattern_require_part(handle, config, .Nested_Action, .Nested_Overlay, report)
		if !nested_action_ok { destroy_element(&nested_trigger); return false }
		if !pattern_click_element(handle, &nested_action, .Nested_Overlay, .Nested_Action, report) {
			destroy_element(&nested_action)
			destroy_element(&nested_trigger)
			return false
		}
		destroy_element(&nested_action)
		nested_result := pattern_find_part_optional(handle, config, .Nested_Dialog)
		if nested_result.match != .Unique {
			pattern_fail(handle, report, .Nested_Overlay, .Nested_Dialog, &nested_result.element,
				"second dialog is published", "nested Dialog is absent")
			destroy_find_result(&nested_result)
			destroy_element(&nested_trigger)
			return false
		}
		nested_bounds := nested_result.element.bounds
		destroy_find_result(&nested_result)
		focus := pattern_focused_element(handle)
		if !focus.has_bounds || !pattern_element_inside(focus.bounds, nested_bounds) {
			pattern_fail(handle, report, .Nested_Overlay, .Nested_Dialog, &focus,
				"focus moves into the second dialog", "focus is outside the nested dialog")
			destroy_element(&focus)
			destroy_element(&nested_trigger)
			return false
		}
		destroy_element(&focus)
		// The first dialog's primary action is covered by the second overlay.
		primary, primary_configured := pattern_require_part(handle, config, .Primary_Action, .Nested_Overlay, report)
		if primary_configured {
			if status := click(handle, &primary); status == .Ok {
				pattern_fail(handle, report, .Nested_Overlay, .Primary_Action, &primary,
					"pointer activation rejected for the covered first dialog", "click was accepted")
				destroy_element(&primary)
				destroy_element(&nested_trigger)
				return false
			}
			destroy_element(&primary)
		}
		if !pattern_press_key(handle, .Escape, .Nested_Overlay, .Nested_Dialog, report) {
			destroy_element(&nested_trigger)
			return false
		}
		if result := pattern_find_part_optional(handle, config, .Nested_Dialog); result.match != .None {
			pattern_fail(handle, report, .Nested_Overlay, .Nested_Dialog, &result.element,
				"nested dialog closed by Escape", "nested Dialog is still published")
			destroy_find_result(&result)
			destroy_element(&nested_trigger)
			return false
		}
		first := pattern_find_part_optional(handle, config, .Dialog)
		if first.match != .Unique {
			pattern_fail(handle, report, .Nested_Overlay, .Dialog, &first.element,
				"first dialog is restored", "first Dialog is absent")
			destroy_find_result(&first)
			destroy_element(&nested_trigger)
			return false
		}
		focus = pattern_focused_element(handle)
		if !focus.has_bounds || !pattern_element_inside(focus.bounds, first.element.bounds) {
			pattern_fail(handle, report, .Nested_Overlay, .Dialog, &focus,
				"focus returns inside the first dialog", "focus is outside the first dialog")
			destroy_element(&focus)
			destroy_find_result(&first)
			destroy_element(&nested_trigger)
			return false
		}
		destroy_element(&focus)
		destroy_find_result(&first)
		if !pattern_press_key(handle, .Escape, .Nested_Overlay, .Dialog, report) {
			destroy_element(&nested_trigger)
			return false
		}
		if !pattern_modal_expect_closed(handle, config, .Nested_Overlay, report) {
			destroy_element(&nested_trigger)
			return false
		}
		opener := pattern_element_by_id(handle, trigger.semantic_id)
		if !opener.focused {
			pattern_fail(handle, report, .Nested_Overlay, .Trigger, &opener,
				"focus restored to the original opener", "focus is elsewhere")
			destroy_element(&opener)
			destroy_element(&nested_trigger)
			return false
		}
		destroy_element(&opener)
		destroy_element(&nested_trigger)
	}

	// Confirm the composed dialog itself has no stale focus or published Dialog.
	return pattern_modal_expect_closed(handle, config, .Dismissal, report)
}

@(private)
Pattern_Activation_Kind :: enum { Pointer, Keyboard, Semantic }

@(private)
pattern_modal_activation :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	kind: Pattern_Activation_Kind,
	step_name: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	trigger, dialog, opened := pattern_modal_open(handle, config, step_name, report)
	if !opened { return false }
	destroy_element(&dialog)
	primary, primary_ok := pattern_require_part(handle, config, .Primary_Action, step_name, report)
	if !primary_ok { destroy_element(&trigger); return false }
	switch kind {
	case .Pointer:
		if !pattern_click_element(handle, &primary, step_name, .Primary_Action, report) {
			destroy_element(&primary)
			destroy_element(&trigger)
			return false
		}
	case .Keyboard:
		if !pattern_focus_semantic(handle, &primary, step_name, .Primary_Action, report) {
			destroy_element(&primary)
			destroy_element(&trigger)
			return false
		}
		if !pattern_press_key(handle, .Return, step_name, .Primary_Action, report) {
			destroy_element(&primary)
			destroy_element(&trigger)
			return false
		}
	case .Semantic:
		if pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=primary.semantic_id, semantic_action=.Press}) != .Ok {
			pattern_fail(handle, report, step_name, .Primary_Action, &primary,
				"semantic Press accepted for the primary action", "semantic Press was rejected")
			destroy_element(&primary)
			destroy_element(&trigger)
			return false
		}
	}
	destroy_element(&primary)
	if !pattern_modal_expect_closed(handle, config, step_name, report) {
		destroy_element(&trigger)
		return false
	}
	opener := pattern_element_by_id(handle, trigger.semantic_id)
	if !opener.focused {
		pattern_fail(handle, report, step_name, .Trigger, &opener,
			"focus restored to the opener after the primary action", "focus is elsewhere")
		destroy_element(&opener)
		destroy_element(&trigger)
		return false
	}
	destroy_element(&opener)
	destroy_element(&trigger)
	return true
}
