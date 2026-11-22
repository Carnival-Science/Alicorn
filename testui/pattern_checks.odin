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
	Roving_List,
	Roving_Grid,
	Radio_Group,
	// Table is the static table contract: roles, nesting, coordinates, header
	// grouping, logical counts, and ordinary document navigation. It has no
	// managed-focus requirement.
	Table,
	// Data_Grid is the interactive table contract: the same structure plus
	// managed cell focus, directional navigation, selection, and reveal. The
	// two kinds are deliberately separate because their authoring obligations
	// differ.
	Data_Grid,
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
	Container,
	Item,
	// Compound-control parts. Group names the Radio_Group collection; Table
	// names the static table or interactive grid collection; Row, Header_Row,
	// and Cell name published collection members. Target_Option/Disabled_Option
	// continue to select a radio button or roving item by query.
	Group,
	Table,
	Row,
	Header_Row,
	Cell,
	Disabled_Cell,
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
	Focus_Contract,
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
	// Roving focus policy for .Roving_List and .Roving_Grid. The checker never
	// guesses the consumer's policy: supply the same stride, wrap, row-bound,
	// and Home/End scope the composition publishes.
	roving: Pattern_Roving_Config,
	// Radio policy for .Radio_Group. Initial no-selection is legitimate; set
	// require_initial_selection only when the consuming application itself
	// requires a value.
	radio: Pattern_Radio_Config,
	// Static-table expectations. Rows and columns are compared with the
	// published logical counts when the flags are set.
	table: Pattern_Table_Config,
	// Interactive-grid policy for .Data_Grid.
	grid: Pattern_Grid_Config,
}

// Pattern_Radio_Config describes a radio group's published arrow policy. The
// checker enforces at most one Checked item and Checked/selected_id agreement;
// it never requires an initially selected radio.
Pattern_Radio_Config :: struct {
	// wrap continues arrow focus movement at the opposite end of the group.
	wrap: bool,
	// require_initial_selection is opt-in for consumers whose product contract
	// mandates a value. The W3C radio pattern does not.
	require_initial_selection: bool,
}

// Pattern_Table_Config is the static-table expectation set. The optional counts
// are compared with the table's own published logical counts; zero disables the
// comparison. expect_virtual_reveal is set by a consumer whose table realizes
// rows through a bounded window and reveals them as ordinary document scrolling
// proceeds.
Pattern_Table_Config :: struct {
	expected_row_count:    u64,
	expect_row_count:      bool,
	expected_column_count: u64,
	expect_column_count:   bool,
	expect_virtual_reveal: bool,
}

Pattern_Grid_Selection :: enum {
	// None means activation is not contracted; selection checks are skipped.
	None,
	// Cell selection: the activated cell carries Selected and the grid's
	// selected_id names it.
	Cell,
	// Row selection: the activated cell's row carries Selected and the grid's
	// selected_id names the row collection.
	Row,
}

// Pattern_Grid_Config is the interactive data-grid policy. It reuses the roving
// index policy for arrows, Home/End, disabled skipping, boundaries, and wrap.
Pattern_Grid_Config :: struct {
	columns:     int,
	wrap:        bool,
	row_bounded: bool,
	home_end_row: bool,
	expect_reveal: bool,
	// selection is the configured activation policy. The checker requires the
	// selected identity to agree with the grid collection's selected_id.
	selection: Pattern_Grid_Selection,
}

// Pattern_Roving_Focus selects the published roving representative. Container
// means one focusable collection (items virtual or non-focusable) with its
// Current identity naming the active item. Item means the active item itself
// owns retained focus.
Pattern_Roving_Focus :: enum {
	Container,
	Item,
}

Pattern_Roving_Config :: struct {
	// focus is required: Container or Item.
	focus:      Pattern_Roving_Focus,
	// columns is the grid stride. Values <= 1 describe a linear list.
	columns:    int,
	// wrap continues a move at the opposite end of the item set.
	wrap:       bool,
	// row_bounded stops Left/Right at row edges when wrap is false.
	row_bounded: bool,
	// home_end_row targets the active row rather than the whole set.
	home_end_row: bool,
	// expect_reveal requires the current item to intersect the container
	// after keyboard navigation.
	expect_reveal: bool,
	// activation_closes means Return removes the container (a popup) instead of
	// keeping the composed set mounted.
	activation_closes: bool,
	// expect_selection requires activation to publish Selected on the target
	// and the same identity in the collection's selected_id.
	expect_selection: bool,
	// expect_escape_restore reopens a closing composition, presses Escape, and
	// requires the container to close and the Trigger to regain focus.
	expect_escape_restore: bool,
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
	case .Roving_List, .Roving_Grid:
		_ = pattern_check_roving_impl(handle, config, &report)
	case .Radio_Group:
		_ = pattern_check_radio_impl(handle, config, &report)
	case .Table:
		_ = pattern_check_table_impl(handle, config, &report)
	case .Data_Grid:
		_ = pattern_check_data_grid_impl(handle, config, &report)
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

// ---------------------------------------------------------------------------
// Roving list and grid patterns
// ---------------------------------------------------------------------------

// Pattern_Roving_View is a borrowed snapshot of one published roving set. The
// check requires every logical item to be realized because navigation between
// unrealized rows would otherwise be indistinguishable from a missing
// contract.
@(private)
Pattern_Roving_View :: struct {
	container: Element,
	items:     [dynamic]Element,
	current:   int,
}

@(private)
pattern_roving_view_destroy :: proc(view: ^Pattern_Roving_View) {
	if view == nil { return }
	destroy_element(&view.container)
	for index in 0..<len(view.items) { destroy_element(&view.items[index]) }
	delete(view.items)
	view^ = {}
}

@(private)
pattern_roving_item_enabled :: proc(view: ^Pattern_Roving_View, index: int) -> bool {
	if view == nil || index < 0 || index >= len(view.items) { return false }
	return !alicorn.semantic_states_has(view.items[index].states, .Disabled)
}

@(private)
pattern_roving_scan :: proc(view: ^Pattern_Roving_View, start, direction, lower, upper: int) -> int {
	for index := start; index >= lower && index < upper; index += direction {
		if pattern_roving_item_enabled(view, index) { return index }
	}
	return -1
}

// pattern_roving_expected is an independent implementation of the published
// roving policy. It deliberately does not call the runtime model: the point of
// the check is to compare a consumer's behavior with the configuration, not to
// compare the model with itself.
@(private)
pattern_roving_expected :: proc(
	view: ^Pattern_Roving_View,
	current: int,
	move: alicorn.Roving_Move,
	config: Pattern_Roving_Config,
) -> int {
	count := len(view.items)
	if current < 0 || current >= count { return -1 }
	grid := config.columns > 1
	stride := config.columns if grid else 1
	delta := 0
	horizontal := false
	switch move {
	case .Left:
		delta = -1
		horizontal = grid
	case .Right:
		delta = 1
		horizontal = grid
	case .Up:
		delta = -stride
	case .Down:
		delta = stride
	case .Home:
		if grid && config.home_end_row {
			first := (current/config.columns)*config.columns
			if index := pattern_roving_scan(view, first, 1, 0, count); index >= 0 { return index if index != current else -1 }
			index := pattern_roving_scan(view, first, -1, 0, count)
			return index if index != current else -1
		}
		index := pattern_roving_scan(view, 0, 1, 0, count)
		return index if index != current else -1
	case .End:
		if grid && config.home_end_row {
			first := (current/config.columns)*config.columns
			last := min(first+config.columns, count)-1
			if index := pattern_roving_scan(view, last, -1, 0, count); index >= 0 { return index if index != current else -1 }
			index := pattern_roving_scan(view, last+1, 1, 0, count)
			return index if index != current else -1
		}
		index := pattern_roving_scan(view, count-1, -1, 0, count)
		return index if index != current else -1
	case .Page_Up, .Page_Down:
		return -1
	}
	if delta == 0 { return -1 }
	direction := 1 if delta > 0 else -1
	row_locked := horizontal && config.row_bounded && !config.wrap
	target := current+delta
	if row_locked {
		first := (current/config.columns)*config.columns
		last := min(first+config.columns, count)
		if target < first || target >= last { return -1 }
		return pattern_roving_scan(view, target, direction, first, last)
	}
	if target < 0 || target >= count {
		if !config.wrap { return -1 }
		target = ((target%count)+count)%count
	}
	if config.wrap {
		index := target
		for _ in 0..<count {
			if index < 0 { index += count }
			if index >= count { index -= count }
			if pattern_roving_item_enabled(view, index) { return index if index != current else -1 }
			index += direction
		}
		return -1
	}
	return pattern_roving_scan(view, target, direction, 0, count)
}

@(private)
pattern_collect_roving :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Roving_View, ok: bool) {
	view.container, ok = pattern_require_part(handle, config, .Container, step, report)
	if !ok { return view, false }
	container := &view.container
	if container.role != .List_Box {
		pattern_fail(handle, report, step, .Container, container, "Semantic_Role.List_Box", fmt.tprintf("%v", container.role))
		pattern_roving_view_destroy(&view)
		return view, false
	}
	if !container.is_collection || container.visual_node == 0 || !container.has_bounds || container.logical_count == 0 {
		pattern_fail(handle, report, step, .Container, container,
			"a realized List_Box collection with at least one logical item",
			fmt.tprintf("collection=%v visual=%d bounds=%v logical=%d", container.is_collection, container.visual_node, container.has_bounds, container.logical_count))
		pattern_roving_view_destroy(&view)
		return view, false
	}
	if container.logical_count > PATTERN_MAX_OPTIONS {
		pattern_fail(handle, report, step, .Container, container,
			fmt.tprintf("at most %d roving items", PATTERN_MAX_OPTIONS), fmt.tprintf("%d logical items", container.logical_count))
		pattern_roving_view_destroy(&view)
		return view, false
	}
	view.items = make([dynamic]Element, 0, int(container.logical_count), handle.allocator)
	snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for semantic in snapshot.nodes {
		if semantic.collection_id != container.semantic_id { continue }
		if semantic.role != .List_Box_Option { continue }
		element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if !element_ok { continue }
		append(&view.items, element)
	}
	for index in 1..<len(view.items) {
		current := view.items[index]
		cursor := index
		for cursor > 0 && view.items[cursor-1].position_in_set > current.position_in_set {
			view.items[cursor] = view.items[cursor-1]
			cursor -= 1
		}
		view.items[cursor] = current
	}
	if u64(len(view.items)) != container.logical_count {
		pattern_fail(handle, report, step, .Container, container,
			"every logical roving item realized for deterministic navigation",
			fmt.tprintf("%d realized of %d logical items", len(view.items), container.logical_count))
		pattern_roving_view_destroy(&view)
		return view, false
	}

	current_count := 0
	view.current = -1
	for &item, index in view.items {
		if item.position_in_set >= container.logical_count {
			pattern_fail(handle, report, step, .Item, &item, "item position inside the logical collection",
				fmt.tprintf("position %d", item.position_in_set))
			pattern_roving_view_destroy(&view)
			return view, false
		}
		for previous in 0..<index {
			if view.items[previous].position_in_set == item.position_in_set {
				pattern_fail(handle, report, step, .Item, &item, "unique item positions", "duplicate position_in_set")
				pattern_roving_view_destroy(&view)
				return view, false
			}
		}
		disabled := alicorn.semantic_states_has(item.states, .Disabled)
		focusable := false
		if info, info_ok := alicorn.node_info(handle.runtime, item.visual_node); info_ok { focusable = info.focusable }
		if disabled {
			if focusable {
				pattern_fail(handle, report, .Focus_Contract, .Disabled_Option, &item,
					"a disabled item is not focusable", "disabled item visual node is focusable")
				pattern_roving_view_destroy(&view)
				return view, false
			}
			if alicorn.semantic_actions_has(item.actions, .Focus) || alicorn.semantic_actions_has(item.actions, .Select) {
				pattern_fail(handle, report, step, .Disabled_Option, &item,
					"a disabled item without Focus or Select actions", "disabled item advertises a focusable/selectable action")
				pattern_roving_view_destroy(&view)
				return view, false
			}
		} else if !alicorn.semantic_actions_has(item.actions, .Focus) {
			pattern_fail(handle, report, step, .Item, &item, "Focus action on an enabled roving item", "missing Focus action")
			pattern_roving_view_destroy(&view)
			return view, false
		}
		if item.collection_current {
			current_count += 1
			view.current = index
		}
	}
	if current_count != 1 {
		pattern_fail(handle, report, step, .Container, container,
			"exactly one Current roving item", fmt.tprintf("%d Current items", current_count))
		pattern_roving_view_destroy(&view)
		return view, false
	}
	if alicorn.semantic_id_is_valid(container.collection_current_id) &&
	   container.collection_current_id != view.items[view.current].semantic_id {
		pattern_fail(handle, report, step, .Container, container,
			"the collection current_id names the Current item", "current_id and Current state disagree")
		pattern_roving_view_destroy(&view)
		return view, false
	}

	// One tab-stop representative must exist. A container with no focusable
	// container and no focusable item cannot be reached or driven by keyboard.
	container_focusable := false
	if info, info_ok := alicorn.node_info(handle.runtime, container.visual_node); info_ok {
		container_focusable = info.focusable
	}
	current_focusable := false
	if info, info_ok := alicorn.node_info(handle.runtime, view.items[view.current].visual_node); info_ok {
		current_focusable = info.focusable
	}
	if config.roving.focus == .Container {
		if !container_focusable {
			pattern_fail(handle, report, .Focus_Contract, .Container, container,
				"a focusable roving container (one tab stop)", "container visual node is not focusable")
			pattern_roving_view_destroy(&view)
			return view, false
		}
	} else if !current_focusable {
		pattern_fail(handle, report, .Focus_Contract, .Item, &view.items[view.current],
			"a focusable current roving item (one tab stop)", "current item visual node is not focusable")
		pattern_roving_view_destroy(&view)
		return view, false
	}
	if !pattern_roving_verify_focus(handle, &view, config, .Containment, report) {
		pattern_roving_view_destroy(&view)
		return view, false
	}
	return view, true
}

// pattern_roving_verify_focus asserts that exactly one representative owns
// keyboard focus and that it names the Current item.
@(private)
pattern_roving_verify_focus :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Roving_View,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	if config.roving.focus == .Container {
		if !view.container.focused {
			pattern_fail(handle, report, step, .Container, &view.container,
				"retained focus on the roving container", "focus is elsewhere")
			return false
		}
		return true
	}
	focused_index := -1
	for &item, index in view.items {
		if !item.focused { continue }
		if focused_index >= 0 {
			pattern_fail(handle, report, step, .Item, &item,
				"exactly one focused roving item", "more than one item reports focus")
			return false
		}
		focused_index = index
	}
	if focused_index < 0 {
		pattern_fail(handle, report, step, .Item, &view.items[view.current],
			"one focused roving item", "no item reports focus")
		return false
	}
	if focused_index != view.current {
		pattern_fail(handle, report, step, .Item, &view.items[focused_index],
			"focus stays on the Current item", "focused item is not the Current item")
		return false
	}
	return true
}

@(private)
pattern_roving_press :: proc(
	handle: ^Test_Handle($T),
	move: alicorn.Roving_Move,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	key: Key
	switch move {
	case .Left: key = .Left
	case .Right: key = .Right
	case .Up: key = .Up
	case .Down: key = .Down
	case .Page_Up: key = .Page_Up
	case .Page_Down: key = .Page_Down
	case .Home: key = .Home
	case .End: key = .End
	}
	return pattern_press_key(handle, key, step, .Container, report)
}

@(private)
pattern_roving_refresh :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Roving_View,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	pattern_roving_view_destroy(view)
	refreshed, ok := pattern_collect_roving(handle, config, step, report)
	view^ = refreshed
	return ok
}

@(private)
pattern_roving_step_and_verify :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Roving_View,
	move: alicorn.Roving_Move,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	previous_id := view.items[view.current].semantic_id
	expected := pattern_roving_expected(view, view.current, move, config.roving)
	expected_id := alicorn.Semantic_ID{}
	if expected >= 0 { expected_id = view.items[expected].semantic_id }
	if !pattern_roving_press(handle, move, step, report) { return false }
	if !pattern_roving_refresh(handle, view, config, step, report) { return false }
	if expected < 0 {
		if view.items[view.current].semantic_id != previous_id {
			pattern_fail(handle, report, step, .Container, &view.container,
				fmt.tprintf("%v leaves the Current item in place", move),
				"the Current item moved")
			return false
		}
		return true
	}
	if view.items[view.current].semantic_id != expected_id {
		pattern_fail(handle, report, step, .Container, &view.container,
			fmt.tprintf("%v moves to the expected enabled item", move),
			"the Current item is somewhere else")
		return false
	}
	return true
}

@(private)
pattern_roving_closed :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	// A closing composition retires its overlay subtree and restores focus over
	// the next ordinary description; give the retained tree two passes before
	// asserting the published semantics.
	if pattern_settle_description(handle) != .Ok { return false }
	result := pattern_find_part_optional(handle, config, .Container)
	if result.match == .None && result.status == .Ok { return true }
	if result.match == .Unique && result.status == .Ok && result.element.visual_node == 0 {
		// A stable collection identity can outlive its visual realization; the
		// roving contract only requires that the popup no longer realizes a
		// container.
		destroy_find_result(&result)
		return true
	}
	pattern_fail(handle, report, step, .Container, &result.element,
		"the roving container is gone", "the container is still published")
	destroy_find_result(&result)
	return false
}

@(private)
pattern_roving_trigger_after_close :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	target_name: string,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	trigger, ok := pattern_require_part(handle, config, .Trigger, step, report)
	if !ok { return false }
	defer destroy_element(&trigger)
	if config.roving.expect_selection && trigger.value != target_name {
		pattern_fail(handle, report, step, .Trigger, &trigger,
			fmt.tprintf("trigger value %q", target_name), fmt.tprintf("trigger value %q", trigger.value))
		return false
	}
	if !trigger.focused {
		pattern_fail(handle, report, step, .Trigger, &trigger,
			"focus restored to the roving trigger", "focus is elsewhere")
		return false
	}
	return true
}

@(private)
pattern_roving_open_trigger :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	trigger, ok := pattern_require_part(handle, config, .Trigger, step, report)
	if !ok { return false }
	click_ok := pattern_click_element(handle, &trigger, step, .Trigger, report)
	destroy_element(&trigger)
	if !click_ok { return false }
	if pattern_settle_description(handle) != .Ok {
		pattern_fail(handle, report, step, .Container, nil, "settled follow-up description", last_turn_diagnostic(handle))
		return false
	}
	return true
}

@(private)
pattern_roving_find_item :: proc(view: ^Pattern_Roving_View, id: alicorn.Semantic_ID) -> (Element, bool) {
	for item in view.items {
		if item.semantic_id == id { return item, true }
	}
	return {}, false
}

@(private)
pattern_roving_navigate_to :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Roving_View,
	target: alicorn.Semantic_ID,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	for _ in 0..<PATTERN_MAX_OPTIONS {
		if view.items[view.current].semantic_id == target { return true }
		target_index := -1
		for item, index in view.items {
			if item.semantic_id == target { target_index = index; break }
		}
		if target_index < 0 {
			pattern_fail(handle, report, step, .Target_Option, nil, "the target item is realized", "target item is absent")
			return false
		}
		move := alicorn.Roving_Move.Down
		if config.kind == .Roving_Grid {
			current_row := view.current/config.roving.columns
			target_row := target_index/config.roving.columns
			if target_row > current_row {
				move = .Down
			} else if target_row < current_row {
				move = .Up
			} else if target_index > view.current {
				move = .Right
			} else {
				move = .Left
			}
		} else if target_index < view.current {
			move = .Up
		}
		if !pattern_roving_step_and_verify(handle, view, move, config, step, report) { return false }
	}
	pattern_fail(handle, report, step, .Target_Option, nil, "target item reachable by roving navigation",
		"the navigation bound was exhausted")
	return false
}

@(private)
pattern_roving_activation_open :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Roving_View,
	target: Element,
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	target_local := target
	if config.roving.expect_selection {
		found, found_ok := pattern_roving_find_item(view, target_local.semantic_id)
		if !found_ok {
			return pattern_fail(handle, report, .Activation_Parity, .Target_Option, &target_local,
				"the target item remains realized", "target item is absent")
		}
		if !alicorn.semantic_states_has(found.states, .Selected) || !found.collection_selected {
			return pattern_fail(handle, report, .Activation_Parity, .Target_Option, &found,
				"keyboard activation publishes Selected on the target", "target is not Selected")
		}
		if view.container.collection_selected_id != target_local.semantic_id {
			return pattern_fail(handle, report, .Activation_Parity, .Container, &view.container,
				"the collection selected_id names the activated target", "selected_id and Selected disagree")
		}
	}
	// Pointer parity: the same realized target accepts a coordinate activation
	// and leaves the same published selection.
	pointer, pointer_ok := pattern_roving_find_item(view, target_local.semantic_id)
	if !pointer_ok {
		return pattern_fail(handle, report, .Activation_Parity, .Target_Option, &target_local,
			"the target item remains realized for pointer parity", "target item is absent")
	}
	if !pattern_click_element(handle, &pointer, .Activation_Parity, .Target_Option, report) { return false }
	if pattern_settle_description(handle) != .Ok {
		return pattern_fail(handle, report, .Activation_Parity, .Target_Option, nil,
			"settled follow-up description", last_turn_diagnostic(handle))
	}
	if !pattern_roving_refresh(handle, view, config, .Activation_Parity, report) { return false }
	if config.roving.expect_selection && view.container.collection_selected_id != target_local.semantic_id {
		return pattern_fail(handle, report, .Activation_Parity, .Container, &view.container,
			"pointer activation keeps the same selected identity", "selected_id changed")
	}
	return true
}

@(private)
pattern_check_roving_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	// A popup composition is opened through its trigger; a mounted toolbar or
	// grid has no Trigger part.
	if pattern_has_part(config, .Trigger) {
		if !pattern_roving_open_trigger(handle, config, .Resolve_Parts, report) { return false }
	}
	if config.kind == .Roving_Grid && config.roving.columns <= 1 {
		return pattern_fail(handle, report, .Static_Contract, .Container, nil,
			"a grid configuration with columns > 1", "Roving_Grid requires roving.columns")
	}
	view, ok := pattern_collect_roving(handle, config, .Static_Contract, report)
	if !ok { return false }
	defer pattern_roving_view_destroy(&view)

	// 1. Arrow navigation across the configured strides, including disabled
	// skipping and one focused representative after every turn.
	moves := [5]alicorn.Roving_Move{.Home, .Down, .Right, .Up, .Left}
	move_count := 5
	if config.kind == .Roving_List {
		moves = [5]alicorn.Roving_Move{.Home, .Down, .Up, .End, .Home}
	}
	for index in 0..<move_count {
		if !pattern_roving_step_and_verify(handle, &view, moves[index], config, .Navigation, report) { return false }
		if !pattern_roving_verify_focus(handle, &view, config, .Containment, report) { return false }
	}

	// 2. Boundary and wrap policy. With wrap, a move past the end wraps to the
	// opposite edge; without wrap, focus stays put.
	if config.roving.wrap {
		if !pattern_roving_step_and_verify(handle, &view, .End, config, .Navigation, report) { return false }
		if !pattern_roving_step_and_verify(handle, &view, .Down, config, .Navigation, report) { return false }
	} else {
		if !pattern_roving_step_and_verify(handle, &view, .Home, config, .Navigation, report) { return false }
		boundary := alicorn.Roving_Move.Up
		if config.kind == .Roving_Grid { boundary = .Left }
		if !pattern_roving_step_and_verify(handle, &view, boundary, config, .Navigation, report) { return false }
	}

	// 3. Home/End scope. A grid that targets the row must move to the active
	// row's first/last enabled item, not the set's.
	if !pattern_roving_step_and_verify(handle, &view, .Home, config, .Navigation, report) { return false }
	if config.kind == .Roving_Grid && config.roving.home_end_row {
		if !pattern_roving_step_and_verify(handle, &view, .Down, config, .Navigation, report) { return false }
	}
	if !pattern_roving_step_and_verify(handle, &view, .End, config, .Navigation, report) { return false }

	// 4. Reveal: the current item must be realized within the container.
	if config.roving.expect_reveal {
		if pattern_settle_description(handle) != .Ok { return false }
		if !pattern_roving_refresh(handle, &view, config, .Virtual_Reveal, report) { return false }
		current := &view.items[view.current]
		if !current.has_bounds || !pattern_rect_intersects(current.bounds, view.container.bounds) {
			return pattern_fail(handle, report, .Virtual_Reveal, .Container, current,
				"the Current item is realized inside the container",
				fmt.tprintf("bounds %v inside %v", current.bounds, view.container.bounds))
		}
	}

	_, has_target := pattern_part(config, .Target_Option)
	if !has_target { return true }

	// 5. Navigate to the configured target and activate it through Return.
	target, target_ok := pattern_require_part(handle, config, .Target_Option, .Activation_Parity, report)
	if !target_ok { return false }
	if !pattern_roving_navigate_to(handle, &view, target.semantic_id, config, .Activation_Parity, report) {
		destroy_element(&target)
		return false
	}
	if !pattern_press_key(handle, .Return, .Activation_Parity, .Target_Option, report) { destroy_element(&target); return false }
	if pattern_settle_description(handle) != .Ok {
		pattern_fail(handle, report, .Activation_Parity, .Target_Option, nil,
			"settled follow-up description", last_turn_diagnostic(handle))
		destroy_element(&target)
		return false
	}
	if config.roving.activation_closes {
		if !pattern_roving_closed(handle, config, .Activation_Parity, report) { destroy_element(&target); return false }
		if !pattern_roving_trigger_after_close(handle, config, target.name, .Activation_Parity, report) {
			destroy_element(&target)
			return false
		}
		// Pointer parity: reopening and clicking the same target must close
		// with the same controlled value.
		if !pattern_roving_open_trigger(handle, config, .Activation_Parity, report) { destroy_element(&target); return false }
		reopened, reopened_ok := pattern_collect_roving(handle, config, .Activation_Parity, report)
		if !reopened_ok { destroy_element(&target); return false }
		pointer, pointer_ok := pattern_roving_find_item(&reopened, target.semantic_id)
		pattern_roving_view_destroy(&reopened)
		if !pointer_ok {
			pattern_fail(handle, report, .Activation_Parity, .Target_Option, &target,
				"the target item is realized after reopening", "target item is absent")
			destroy_element(&target)
			return false
		}
		if !pattern_click_element(handle, &pointer, .Activation_Parity, .Target_Option, report) {
			destroy_element(&target)
			return false
		}
		if pattern_settle_description(handle) != .Ok {
			pattern_fail(handle, report, .Activation_Parity, .Target_Option, nil,
				"settled follow-up description", last_turn_diagnostic(handle))
			destroy_element(&target)
			return false
		}
		if !pattern_roving_closed(handle, config, .Activation_Parity, report) { destroy_element(&target); return false }
		if !pattern_roving_trigger_after_close(handle, config, target.name, .Activation_Parity, report) {
			destroy_element(&target)
			return false
		}
		if config.roving.expect_escape_restore {
			if !pattern_roving_open_trigger(handle, config, .Escape_Cancel, report) { destroy_element(&target); return false }
			if !pattern_press_key(handle, .Escape, .Escape_Cancel, .Container, report) { destroy_element(&target); return false }
			if pattern_settle_description(handle) != .Ok {
				pattern_fail(handle, report, .Escape_Cancel, .Container, nil,
					"settled follow-up description", last_turn_diagnostic(handle))
				destroy_element(&target)
				return false
			}
			if !pattern_roving_closed(handle, config, .Escape_Cancel, report) { destroy_element(&target); return false }
			if !pattern_roving_trigger_after_close(handle, config, target.name, .Escape_Cancel, report) {
				destroy_element(&target)
				return false
			}
		}
		destroy_element(&target)
		return true
	}

	// The composed set stays mounted: Return and a pointer click must publish
	// the same Selected identity.
	if !pattern_roving_refresh(handle, &view, config, .Activation_Parity, report) { destroy_element(&target); return false }
	open_ok := pattern_roving_activation_open(handle, &view, target, config, report)
	destroy_element(&target)
	if !open_ok { return false }
	return pattern_roving_verify_focus(handle, &view, config, .Activation_Parity, report)
}

pattern_check_roving_list :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Roving_List
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_roving_impl(handle, config, &report)
	return report
}

pattern_check_roving_grid :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Roving_Grid
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_roving_impl(handle, config, &report)
	return report
}

// ---------------------------------------------------------------------------
// Radio group pattern
// ---------------------------------------------------------------------------

// A radio button may publish either Checked or Selected for its one selection
// indicator. Both are accepted, but at most one item across the group may carry
// either, and the group's selected_id must name it.
@(private)
pattern_radio_checked :: proc(element: ^Element) -> bool {
	if element == nil { return false }
	return alicorn.semantic_states_has(element.states, .Checked) ||
		alicorn.semantic_states_has(element.states, .Selected)
}

@(private)
pattern_radio_enabled :: proc(element: ^Element) -> bool {
	return element != nil && !alicorn.semantic_states_has(element.states, .Disabled)
}

@(private)
Pattern_Radio_View :: struct {
	group:   Element,
	items:   [dynamic]Element,
	focused: int,
}

@(private)
pattern_radio_view_destroy :: proc(view: ^Pattern_Radio_View) {
	if view == nil { return }
	destroy_element(&view.group)
	for index in 0..<len(view.items) { destroy_element(&view.items[index]) }
	delete(view.items)
	view^ = {}
}

@(private)
pattern_radio_find_index :: proc(view: ^Pattern_Radio_View, id: alicorn.Semantic_ID) -> int {
	for item, index in view.items {
		if item.semantic_id == id { return index }
	}
	return -1
}

@(private)
pattern_radio_focusable :: proc(handle: ^Test_Handle($T), item: ^Element) -> bool {
	if item == nil || item.visual_node == 0 { return false }
	if info, found := alicorn.node_info(handle.runtime, item.visual_node); found { return info.focusable }
	return false
}

// pattern_collect_radio resolves the group and its realized radios, then
// verifies the app-owned mutual-exclusion and disabled/focus contract. It never
// requires a selection: an initially empty group is permitted by the W3C radio
// pattern, and require_initial_selection is an explicit consumer opt-in.
@(private)
pattern_collect_radio :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> (view: Pattern_Radio_View, ok: bool) {
	view.group, ok = pattern_require_part(handle, config, .Group, step, report)
	if !ok { return view, false }
	group := &view.group
	if group.role != .Radio_Group {
		pattern_fail(handle, report, step, .Group, group, "Semantic_Role.Radio_Group", fmt.tprintf("%v", group.role))
		pattern_radio_view_destroy(&view)
		return view, false
	}
	if !group.is_collection || group.visual_node == 0 || !group.has_bounds || group.logical_count == 0 {
		pattern_fail(handle, report, step, .Group, group,
			"a realized Radio_Group collection with at least one logical item",
			fmt.tprintf("collection=%v visual=%d bounds=%v logical=%d",
				group.is_collection, group.visual_node, group.has_bounds, group.logical_count))
		pattern_radio_view_destroy(&view)
		return view, false
	}
	if group.logical_count > PATTERN_MAX_OPTIONS {
		pattern_fail(handle, report, step, .Group, group,
			fmt.tprintf("at most %d radio items", PATTERN_MAX_OPTIONS), fmt.tprintf("%d logical items", group.logical_count))
		pattern_radio_view_destroy(&view)
		return view, false
	}
	view.items = make([dynamic]Element, 0, int(group.logical_count), handle.allocator)
	snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for semantic in snapshot.nodes {
		if semantic.collection_id != group.semantic_id || semantic.role != .Radio_Button { continue }
		element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if !element_ok { continue }
		append(&view.items, element)
	}
	for index in 1..<len(view.items) {
		current := view.items[index]
		cursor := index
		for cursor > 0 && view.items[cursor-1].position_in_set > current.position_in_set {
			view.items[cursor] = view.items[cursor-1]
			cursor -= 1
		}
		view.items[cursor] = current
	}
	if u64(len(view.items)) != group.logical_count {
		pattern_fail(handle, report, step, .Group, group,
			"every logical radio realized for deterministic roving",
			fmt.tprintf("%d realized of %d logical items", len(view.items), group.logical_count))
		pattern_radio_view_destroy(&view)
		return view, false
	}

	checked_count := 0
	checked_index := -1
	view.focused = -1
	for &item, index in view.items {
		if item.role != .Radio_Button {
			pattern_fail(handle, report, step, .Item, &item, "Semantic_Role.Radio_Button", fmt.tprintf("%v", item.role))
			pattern_radio_view_destroy(&view)
			return view, false
		}
		if item.parent_semantic_id != group.semantic_id || item.collection_id != group.semantic_id {
			pattern_fail(handle, report, step, .Item, &item,
				"a radio parented to and collected by the group", "parent/collection disagreement")
			pattern_radio_view_destroy(&view)
			return view, false
		}
		if item.position_in_set >= group.logical_count {
			pattern_fail(handle, report, step, .Item, &item, "radio position inside the group",
				fmt.tprintf("position %d", item.position_in_set))
			pattern_radio_view_destroy(&view)
			return view, false
		}
		for previous in 0..<index {
			if view.items[previous].position_in_set == item.position_in_set {
				pattern_fail(handle, report, step, .Item, &item, "unique radio positions", "duplicate position_in_set")
				pattern_radio_view_destroy(&view)
				return view, false
			}
		}
		disabled := !pattern_radio_enabled(&item)
		focusable := pattern_radio_focusable(handle, &item)
		if item.focused {
			if disabled {
				pattern_fail(handle, report, .Focus_Contract, .Item, &item,
					"a disabled radio that is not focused", "disabled radio reports focus")
				pattern_radio_view_destroy(&view)
				return view, false
			}
			if view.focused >= 0 {
				pattern_fail(handle, report, .Containment, .Item, &item,
					"exactly one focused radio", "more than one radio reports focus")
				pattern_radio_view_destroy(&view)
				return view, false
			}
			view.focused = index
		}
		if disabled {
			if focusable {
				pattern_fail(handle, report, .Focus_Contract, .Item, &item,
					"a disabled radio that is not focusable", "disabled radio visual node is focusable")
				pattern_radio_view_destroy(&view)
				return view, false
			}
			if alicorn.semantic_actions_has(item.actions, .Focus) ||
			   alicorn.semantic_actions_has(item.actions, .Press) ||
			   alicorn.semantic_actions_has(item.actions, .Select) {
				pattern_fail(handle, report, step, .Item, &item,
					"a disabled radio without Focus, Press, or Select", "disabled radio advertises an action")
				pattern_radio_view_destroy(&view)
				return view, false
			}
		} else if !alicorn.semantic_actions_has(item.actions, .Press) &&
			!alicorn.semantic_actions_has(item.actions, .Select) {
			pattern_fail(handle, report, step, .Item, &item,
				"an enabled radio with a Press or Select action", "enabled radio advertises no activation")
			pattern_radio_view_destroy(&view)
			return view, false
		}
		if pattern_radio_checked(&item) {
			checked_count += 1
			checked_index = index
		}
	}
	if view.focused < 0 {
		pattern_fail(handle, report, .Focus_Contract, .Group, group,
			"one focused radio representative", "no radio reports focus")
		pattern_radio_view_destroy(&view)
		return view, false
	}
	if checked_count > 1 {
		pattern_fail(handle, report, step, .Group, group,
			"at most one Checked radio (app-owned mutual exclusion)",
			fmt.tprintf("%d radios report Checked/Selected", checked_count))
		pattern_radio_view_destroy(&view)
		return view, false
	}
	if checked_count == 1 {
		checked := &view.items[checked_index]
		if !alicorn.semantic_id_is_valid(group.collection_selected_id) {
			pattern_fail(handle, report, step, .Group, group,
				"the group selected_id names the Checked radio", "selected_id is unset")
			pattern_radio_view_destroy(&view)
			return view, false
		}
		if group.collection_selected_id != checked.semantic_id {
			pattern_fail(handle, report, step, .Group, group,
				"the group selected_id names the Checked radio", "selected_id and Checked disagree")
			pattern_radio_view_destroy(&view)
			return view, false
		}
	} else {
		if alicorn.semantic_id_is_valid(group.collection_selected_id) {
			pattern_fail(handle, report, step, .Group, group,
				"no selected_id while no radio is Checked", "selected_id names a radio but none is Checked")
			pattern_radio_view_destroy(&view)
			return view, false
		}
		if config.radio.require_initial_selection {
			pattern_fail(handle, report, step, .Group, group,
				"an initially Checked radio (consumer opted in)", "the group starts with no selection")
			pattern_radio_view_destroy(&view)
			return view, false
		}
	}
	return view, true
}

@(private)
pattern_radio_refresh :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	pattern_radio_view_destroy(view)
	refreshed, ok := pattern_collect_radio(handle, config, step, report)
	view^ = refreshed
	return ok
}

@(private)
pattern_radio_verify_focus :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	focused := -1
	for &item, index in view.items {
		if !item.focused { continue }
		if focused >= 0 {
			pattern_fail(handle, report, step, .Item, &item,
				"exactly one focused radio", "more than one radio reports focus")
			return false
		}
		focused = index
	}
	if focused < 0 {
		pattern_fail(handle, report, step, .Group, &view.group,
			"one focused radio representative", "no radio reports focus")
		return false
	}
	if !pattern_radio_enabled(&view.items[focused]) {
		pattern_fail(handle, report, step, .Item, &view.items[focused],
			"focus on an enabled radio", "focus is on a disabled radio")
		return false
	}
	view.focused = focused
	return true
}

// pattern_radio_expected is an independent linear policy model. It does not
// call the runtime roving model, so the check compares the application's
// behavior with the configured contract rather than with itself.
@(private)
pattern_radio_expected :: proc(
	view: ^Pattern_Radio_View,
	current: int,
	move: alicorn.Roving_Move,
	wrap: bool,
) -> int {
	count := len(view.items)
	if current < 0 || current >= count { return -1 }
	direction := 0
	#partial switch move {
	case .Left, .Up:
		direction = -1
	case .Right, .Down:
		direction = 1
	case .Home:
		for index in 0..<count {
			if pattern_radio_enabled(&view.items[index]) { return index if index != current else -1 }
		}
		return -1
	case .End:
		for index := count-1; index >= 0; index -= 1 {
			if pattern_radio_enabled(&view.items[index]) { return index if index != current else -1 }
		}
		return -1
	case:
		return -1
	}
	for step in 1..=count {
		index := current+direction*step
		if wrap {
			index = ((index%count)+count)%count
		} else if index < 0 || index >= count {
			return -1
		}
		if pattern_radio_enabled(&view.items[index]) {
			return index if index != current else -1
		}
	}
	return -1
}

@(private)
pattern_radio_press :: proc(
	handle: ^Test_Handle($T),
	move: alicorn.Roving_Move,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	key: Key
	switch move {
	case .Left: key = .Left
	case .Right: key = .Right
	case .Up: key = .Up
	case .Down: key = .Down
	case .Home: key = .Home
	case .End: key = .End
	case .Page_Up: key = .Page_Up
	case .Page_Down: key = .Page_Down
	}
	return pattern_press_key(handle, key, step, .Item, report)
}

@(private)
pattern_radio_step_and_verify :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	move: alicorn.Roving_Move,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	previous := view.focused
	expected := pattern_radio_expected(view, previous, move, config.radio.wrap)
	if !pattern_radio_press(handle, move, step, report) { return false }
	if !pattern_radio_refresh(handle, view, config, step, report) { return false }
	if expected < 0 {
		if view.focused != previous {
			pattern_fail(handle, report, step, .Item, &view.items[view.focused],
				fmt.tprintf("%v leaves focus in place", move), "the focused radio changed")
			return false
		}
		return true
	}
	if view.focused != expected {
		pattern_fail(handle, report, step, .Item, &view.items[view.focused],
			fmt.tprintf("%v moves focus to the expected enabled radio", move),
			"focus is on a different radio")
		return false
	}
	return pattern_radio_verify_focus(handle, view, step, report)
}

@(private)
pattern_radio_verify_selection :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	expected_id: alicorn.Semantic_ID,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	checked_count := 0
	checked_id := alicorn.Semantic_ID{}
	for &item in view.items {
		if !pattern_radio_checked(&item) { continue }
		checked_count += 1
		checked_id = item.semantic_id
	}
	if checked_count != 1 {
		pattern_fail(handle, report, step, .Group, &view.group,
			"exactly one Checked radio after activation",
			fmt.tprintf("%d radios report Checked/Selected", checked_count))
		return false
	}
	if checked_id != expected_id {
		pattern_fail(handle, report, step, .Group, &view.group,
			"the activated radio is Checked", "a different radio is Checked")
		return false
	}
	if view.group.collection_selected_id != expected_id {
		pattern_fail(handle, report, step, .Group, &view.group,
			"the group selected_id names the Checked radio", "selected_id and Checked disagree")
		return false
	}
	return true
}

// pattern_radio_action_parity performs every action the group advertises. An
// advertised action the runtime rejects is a failure, not a skipped phase. This
// is where a non-focusable item that advertises Focus is caught.
@(private)
pattern_radio_action_parity :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	for &item in view.items {
		if !pattern_radio_enabled(&item) { continue }
		if !alicorn.semantic_actions_has(item.actions, .Focus) { continue }
		if !pattern_focus_semantic(handle, &item, .Semantic_Action_Parity, .Item, report) { return false }
	}
	if !pattern_radio_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
	// Collect the advertised activation IDs before any refresh. Refreshing
	// replaces the whole view, so the loop must not retain element pointers.
	activation_ids := make([dynamic]alicorn.Semantic_ID, 0, len(view.items), handle.allocator)
	defer delete(activation_ids)
	for &item in view.items {
		if !pattern_radio_enabled(&item) { continue }
		if alicorn.semantic_actions_has(item.actions, .Press) ||
		   alicorn.semantic_actions_has(item.actions, .Select) {
			append(&activation_ids, item.semantic_id)
		}
	}
	for id in activation_ids {
		index := pattern_radio_find_index(view, id)
		if index < 0 {
			pattern_fail(handle, report, .Semantic_Action_Parity, .Item, nil,
				"the advertised radio remains realized", "radio disappeared before its action ran")
			return false
		}
		item := &view.items[index]
		action := alicorn.Semantic_Action.None
		if alicorn.semantic_actions_has(item.actions, .Press) {
			action = .Press
		} else if alicorn.semantic_actions_has(item.actions, .Select) {
			action = .Select
		}
		if action == .None { continue }
		status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=id, semantic_action=action})
		if status != .Ok {
			return pattern_fail(handle, report, .Semantic_Action_Parity, .Item, item,
				fmt.tprintf("advertised semantic %v accepted", action), fmt.tprintf("status %v", status),
				last_turn_diagnostic(handle))
		}
		if !pattern_radio_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
		if !pattern_radio_verify_selection(handle, view, id, .Semantic_Action_Parity, report) { return false }
	}
	return true
}

@(private)
pattern_radio_navigate_to :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Radio_View,
	target: alicorn.Semantic_ID,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	for _ in 0..<PATTERN_MAX_OPTIONS {
		if view.items[view.focused].semantic_id == target { return true }
		target_index := pattern_radio_find_index(view, target)
		if target_index < 0 {
			pattern_fail(handle, report, step, .Target_Option, nil, "the target radio is realized", "target radio is absent")
			return false
		}
		move := alicorn.Roving_Move.Right
		if target_index < view.focused { move = .Left }
		if !pattern_radio_step_and_verify(handle, view, move, config, step, report) { return false }
	}
	pattern_fail(handle, report, step, .Target_Option, nil,
		"target radio reachable by roving navigation", "the navigation bound was exhausted")
	return false
}

@(private)
pattern_check_radio_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	view, ok := pattern_collect_radio(handle, config, .Static_Contract, report)
	if !ok { return false }
	defer pattern_radio_view_destroy(&view)

	// 1. Advertised Focus/Press/Select parity. This also proves the runtime can
	// perform what the composition tells assistive technology it can do.
	if !pattern_radio_action_parity(handle, &view, config, report) { return false }
	if !pattern_radio_verify_focus(handle, &view, .Containment, report) { return false }

	// 2. Roving arrows, disabled skipping, boundaries, and wrap.
	moves := [7]alicorn.Roving_Move{.Home, .Right, .Right, .Left, .Left, .End, .Home}
	for move in moves {
		if !pattern_radio_step_and_verify(handle, &view, move, config, .Navigation, report) { return false }
	}

	// 3. Activation parity. Space, Return, a pointer click, and a semantic
	// Press must each move the one Checked radio and clear the previous one.
	if !pattern_has_part(config, .Target_Option) { return true }
	target, target_ok := pattern_require_part(handle, config, .Target_Option, .Activation_Parity, report)
	if !target_ok { return false }
	if target.role != .Radio_Button {
		pattern_fail(handle, report, .Activation_Parity, .Target_Option, &target,
			"Semantic_Role.Radio_Button", fmt.tprintf("%v", target.role))
		destroy_element(&target)
		return false
	}
	if !pattern_radio_enabled(&target) {
		pattern_fail(handle, report, .Activation_Parity, .Target_Option, &target,
			"an enabled target radio", "target radio is disabled")
		destroy_element(&target)
		return false
	}
	target_id := target.semantic_id
	destroy_element(&target)
	if !pattern_radio_navigate_to(handle, &view, target_id, config, .Activation_Parity, report) { return false }
	previous_id := alicorn.Semantic_ID{}
	for &item in view.items {
		if pattern_radio_checked(&item) { previous_id = item.semantic_id }
	}
	if !pattern_press_key(handle, .Space, .Activation_Parity, .Target_Option, report) { return false }
	if !pattern_radio_refresh(handle, &view, config, .Activation_Parity, report) { return false }
	if !pattern_radio_verify_selection(handle, &view, target_id, .Activation_Parity, report) { return false }
	if previous_id.namespace != 0 && previous_id != target_id {
		previous_index := pattern_radio_find_index(&view, previous_id)
		if previous_index >= 0 && pattern_radio_checked(&view.items[previous_index]) {
			pattern_fail(handle, report, .Activation_Parity, .Item, &view.items[previous_index],
				"the previously Checked radio is cleared", "the previous radio is still Checked")
			return false
		}
	}

	// Return moves to a different enabled radio.
	other_id := alicorn.Semantic_ID{}
	for &item in view.items {
		if item.semantic_id != target_id && pattern_radio_enabled(&item) {
			other_id = item.semantic_id
			break
		}
	}
	if other_id.namespace != 0 {
		if !pattern_radio_navigate_to(handle, &view, other_id, config, .Activation_Parity, report) { return false }
		if !pattern_press_key(handle, .Return, .Activation_Parity, .Target_Option, report) { return false }
		if !pattern_radio_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		if !pattern_radio_verify_selection(handle, &view, other_id, .Activation_Parity, report) { return false }
		if !pattern_radio_verify_focus(handle, &view, .Activation_Parity, report) { return false }
	}

	// Pointer parity on the configured target.
	if !pattern_radio_navigate_to(handle, &view, target_id, config, .Activation_Parity, report) { return false }
	pointer, pointer_ok := pattern_require_part(handle, config, .Target_Option, .Activation_Parity, report)
	if !pointer_ok { return false }
	click_ok := pattern_click_element(handle, &pointer, .Activation_Parity, .Target_Option, report)
	destroy_element(&pointer)
	if !click_ok { return false }
	if !pattern_radio_refresh(handle, &view, config, .Activation_Parity, report) { return false }
	if !pattern_radio_verify_selection(handle, &view, target_id, .Activation_Parity, report) { return false }

	// Semantic Press parity moves selection without a keyboard or pointer turn.
	if other_id.namespace != 0 {
		status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=other_id, semantic_action=.Press})
		if status != .Ok {
			return pattern_fail(handle, report, .Activation_Parity, .Target_Option, nil,
				"advertised semantic Press accepted", fmt.tprintf("status %v", status), last_turn_diagnostic(handle))
		}
		if !pattern_radio_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		if !pattern_radio_verify_selection(handle, &view, other_id, .Activation_Parity, report) { return false }
	}
	return true
}

pattern_check_radio_group :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Radio_Group
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_radio_impl(handle, config, &report)
	return report
}

// ---------------------------------------------------------------------------
// Static table and interactive data-grid patterns
// ---------------------------------------------------------------------------

@(private)
pattern_table_cell_role :: proc(role: alicorn.Semantic_Role) -> bool {
	#partial switch role {
	case .Table_Cell, .Table_Column_Header, .Table_Row_Header:
		return true
	}
	return false
}

@(private)
Pattern_Grid_Focus :: enum {
	Cell,
	Row,
}

@(private)
Pattern_Cell_View :: struct {
	element: Element,
	row:     int,
	column:  u64,
}

@(private)
Pattern_Table_View :: struct {
	table:        Element,
	rows:         [dynamic]Element,
	cells:        [dynamic]Pattern_Cell_View,
	column_count: int,
	realized:     int,
	focus_mode:   Pattern_Grid_Focus,
	focused_row:  int,
	focused_col:  int,
}

@(private)
pattern_table_view_destroy :: proc(view: ^Pattern_Table_View) {
	if view == nil { return }
	destroy_element(&view.table)
	for index in 0..<len(view.rows) { destroy_element(&view.rows[index]) }
	for index in 0..<len(view.cells) { destroy_element(&view.cells[index].element) }
	delete(view.rows)
	delete(view.cells)
	view^ = {}
}

@(private)
pattern_table_find_row :: proc(view: ^Pattern_Table_View, id: alicorn.Semantic_ID) -> int {
	for row, index in view.rows {
		if row.semantic_id == id { return index }
	}
	return -1
}

@(private)
pattern_table_find_cell :: proc(view: ^Pattern_Table_View, id: alicorn.Semantic_ID) -> int {
	for cell, index in view.cells {
		if cell.element.semantic_id == id { return index }
	}
	return -1
}

@(private)
pattern_table_find_cell_at :: proc(view: ^Pattern_Table_View, row: int, column: u64) -> int {
	for cell, index in view.cells {
		if cell.row == row && cell.column == column { return index }
	}
	return -1
}

@(private)
pattern_table_row_disabled :: proc(view: ^Pattern_Table_View, row: int) -> bool {
	if row < 0 || row >= len(view.rows) { return true }
	return alicorn.semantic_states_has(view.rows[row].states, .Disabled)
}

@(private)
pattern_table_cell_disabled :: proc(view: ^Pattern_Table_View, cell: int) -> bool {
	if cell < 0 || cell >= len(view.cells) { return true }
	if pattern_table_row_disabled(view, view.cells[cell].row) { return true }
	return alicorn.semantic_states_has(view.cells[cell].element.states, .Disabled)
}

@(private)
pattern_table_node_focusable :: proc(handle: ^Test_Handle($T), element: ^Element) -> bool {
	if element == nil || element.visual_node == 0 { return false }
	if info, found := alicorn.node_info(handle.runtime, element.visual_node); found { return info.focusable }
	return false
}

// pattern_collect_table_view validates the shared table/grid structure:
// .Table collection, .Table_Row child collections, allowed cell roles nested
// under their row, unique row/column coordinates, logical counts, and optional
// virtual rows whose realization window matches the published metadata.
@(private)
pattern_collect_table_view :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
	require_all_realized: bool,
) -> (view: Pattern_Table_View, ok: bool) {
	view.table, ok = pattern_require_part(handle, config, .Table, step, report)
	if !ok { return view, false }
	table := &view.table
	if table.role != .Table {
		pattern_fail(handle, report, step, .Table, table, "Semantic_Role.Table", fmt.tprintf("%v", table.role))
		pattern_table_view_destroy(&view)
		return view, false
	}
	if !table.is_collection || table.visual_node == 0 || table.logical_count == 0 {
		pattern_fail(handle, report, step, .Table, table,
			"a realized Table collection with at least one logical row",
			fmt.tprintf("collection=%v visual=%d logical=%d", table.is_collection, table.visual_node, table.logical_count))
		pattern_table_view_destroy(&view)
		return view, false
	}
	if table.logical_count > PATTERN_MAX_OPTIONS {
		pattern_fail(handle, report, step, .Table, table,
			fmt.tprintf("at most %d logical rows", PATTERN_MAX_OPTIONS), fmt.tprintf("%d logical rows", table.logical_count))
		pattern_table_view_destroy(&view)
		return view, false
	}
	view.rows = make([dynamic]Element, 0, int(table.logical_count), handle.allocator)
	view.cells = make([dynamic]Pattern_Cell_View, 0, 16, handle.allocator)
	snapshot := alicorn.semantic_snapshot(handle.runtime, handle.allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for semantic in snapshot.nodes {
		if semantic.collection_id != table.semantic_id || semantic.role != .Table_Row { continue }
		element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if !element_ok { continue }
		append(&view.rows, element)
	}
	for index in 1..<len(view.rows) {
		current := view.rows[index]
		cursor := index
		for cursor > 0 && view.rows[cursor-1].position_in_set > current.position_in_set {
			view.rows[cursor] = view.rows[cursor-1]
			cursor -= 1
		}
		view.rows[cursor] = current
	}
	if len(view.rows) == 0 {
		pattern_fail(handle, report, step, .Table, table, "at least one .Table_Row collection", "no rows are published")
		pattern_table_view_destroy(&view)
		return view, false
	}

	view.realized = 0
	for &row, index in view.rows {
		if row.role != .Table_Row {
			pattern_fail(handle, report, step, .Row, &row, "Semantic_Role.Table_Row", fmt.tprintf("%v", row.role))
			pattern_table_view_destroy(&view)
			return view, false
		}
		if !row.is_collection {
			pattern_fail(handle, report, step, .Row, &row, "a Table_Row collection", "row is not a collection")
			pattern_table_view_destroy(&view)
			return view, false
		}
		if row.parent_semantic_id != table.semantic_id || row.collection_id != table.semantic_id {
			pattern_fail(handle, report, step, .Row, &row,
				"a row parented to and collected by the table", "row parent/collection disagreement")
			pattern_table_view_destroy(&view)
			return view, false
		}
		if row.position_in_set >= table.logical_count {
			pattern_fail(handle, report, step, .Row, &row, "row position inside the table",
				fmt.tprintf("position %d", row.position_in_set))
			pattern_table_view_destroy(&view)
			return view, false
		}
		if row.size_of_set != 0 && row.size_of_set != table.logical_count {
			pattern_fail(handle, report, step, .Row, &row,
				"row size_of_set to match the table's logical count",
				fmt.tprintf("%d rows, size_of_set %d", table.logical_count, row.size_of_set))
			pattern_table_view_destroy(&view)
			return view, false
		}
		for previous in 0..<index {
			if view.rows[previous].position_in_set == row.position_in_set {
				pattern_fail(handle, report, step, .Row, &row, "unique row positions", "duplicate position_in_set")
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
		if row.is_virtual_item {
			if row.visual_node != 0 {
				pattern_fail(handle, report, step, .Row, &row,
					"a virtual row without a visual node", "virtual row has a visual node")
				pattern_table_view_destroy(&view)
				return view, false
			}
		} else {
			view.realized += 1
			if row.visual_node == 0 || !row.has_bounds {
				pattern_fail(handle, report, step, .Row, &row,
					"a realized row with bounds", "realized row has no visual node or bounds")
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
	}

	// Row coordinates are complete when every logical row is published. A
	// consumer that publishes only the realized window is also valid.
	if u64(len(view.rows)) == table.logical_count {
		seen := [PATTERN_MAX_OPTIONS]bool{}
		for &row in view.rows { seen[row.position_in_set] = true }
		for index in 0..<int(table.logical_count) {
			if !seen[index] {
				pattern_fail(handle, report, step, .Row, nil,
					"every row coordinate in the logical set",
					fmt.tprintf("row position %d is missing", index))
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
	}

	fully_realized := u64(view.realized) == table.logical_count && u64(len(view.rows)) == table.logical_count
	window_omitted := fully_realized && table.realized_first == 0 && table.realized_last == 0
	if !window_omitted {
		if table.realized_last < table.realized_first || table.realized_last > table.logical_count {
			pattern_fail(handle, report, step, .Table, table,
				"a realized window inside the logical row count",
				fmt.tprintf("window %d..%d of %d", table.realized_first, table.realized_last, table.logical_count))
			pattern_table_view_destroy(&view)
			return view, false
		}
		if require_all_realized {
			if view.realized != len(view.rows) || u64(view.realized) != table.logical_count {
				pattern_fail(handle, report, step, .Table, table,
					"an interactive grid with every logical row realized",
					fmt.tprintf("%d realized of %d logical rows", view.realized, table.logical_count))
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
		if self_window := table.realized_last-table.realized_first; u64(view.realized) != self_window {
			pattern_fail(handle, report, step, .Table, table,
				"the realized window to match the realized rows",
				fmt.tprintf("%d realized rows, window %d..%d", view.realized, table.realized_first, table.realized_last))
			pattern_table_view_destroy(&view)
			return view, false
		}
		for &row in view.rows {
			inside := row.position_in_set >= table.realized_first && row.position_in_set < table.realized_last
			if row.is_virtual_item == inside {
				pattern_fail(handle, report, step, .Row, &row,
					"virtual rows outside and realized rows inside the published window",
					fmt.tprintf("row %d virtual=%v inside_window=%v", row.position_in_set, row.is_virtual_item, inside))
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
	} else if require_all_realized && (view.realized != len(view.rows) || u64(view.realized) != table.logical_count) {
		pattern_fail(handle, report, step, .Table, table,
			"an interactive grid with every logical row realized",
			fmt.tprintf("%d realized of %d logical rows", view.realized, table.logical_count))
		pattern_table_view_destroy(&view)
		return view, false
	}

	// Collect every table cell role. A cell whose collection is the table (or
	// any non-row collection) is outside a row collection.
	for semantic in snapshot.nodes {
		if !pattern_table_cell_role(semantic.role) { continue }
		if semantic.collection_id == table.semantic_id {
			pattern_fail(handle, report, step, .Cell, &view.table,
				"a cell collected by a .Table_Row", "cell is collected directly by the table")
			pattern_table_view_destroy(&view)
			return view, false
		}
		if !alicorn.semantic_id_is_valid(semantic.collection_id) { continue }
		row_index := pattern_table_find_row(&view, semantic.collection_id)
		if row_index < 0 {
			pattern_fail(handle, report, step, .Cell, &view.table,
				"a cell collected by a published row", "cell is outside every row collection")
			pattern_table_view_destroy(&view)
			return view, false
		}
		element, element_ok := element_from_semantic(handle, semantic, snapshot.nodes[:])
		if !element_ok { continue }
		append(&view.cells, Pattern_Cell_View{element=element, row=row_index, column=semantic.position_in_set})
	}
	for index in 1..<len(view.cells) {
		current := view.cells[index]
		cursor := index
		for cursor > 0 && (view.cells[cursor-1].row > current.row ||
			(view.cells[cursor-1].row == current.row && view.cells[cursor-1].column > current.column)) {
			view.cells[cursor] = view.cells[cursor-1]
			cursor -= 1
		}
		view.cells[cursor] = current
	}
	if len(view.cells) > PATTERN_MAX_OPTIONS {
		pattern_fail(handle, report, step, .Table, table,
			fmt.tprintf("at most %d realized cells", PATTERN_MAX_OPTIONS), fmt.tprintf("%d cells", len(view.cells)))
		pattern_table_view_destroy(&view)
		return view, false
	}

	view.column_count = -1
	for &row, row_index in view.rows {
		if row.is_virtual_item { continue }
		row_cells := 0
		seen := [PATTERN_MAX_OPTIONS]bool{}
		for &cell in view.cells {
			if cell.row != row_index { continue }
			row_cells += 1
			if cell.element.position_in_set >= row.logical_count {
				pattern_fail(handle, report, step, .Cell, &cell.element,
					"cell column inside the row's logical count",
					fmt.tprintf("column %d of %d", cell.element.position_in_set, row.logical_count))
				pattern_table_view_destroy(&view)
				return view, false
			}
			if seen[cell.element.position_in_set] {
				pattern_fail(handle, report, step, .Cell, &cell.element,
					"unique column coordinates", "duplicate position_in_set")
				pattern_table_view_destroy(&view)
				return view, false
			}
			seen[cell.element.position_in_set] = true
			if cell.element.collection_id != row.semantic_id || cell.element.parent_semantic_id != row.semantic_id {
				part := Pattern_Part_ID.Cell
				if cell.element.role == .Table_Column_Header { part = .Header_Row }
				pattern_fail(handle, report, step, part, &cell.element,
					"a cell parented to and collected by its row", "cell parent/collection disagreement")
				pattern_table_view_destroy(&view)
				return view, false
			}
			if cell.element.size_of_set != 0 && cell.element.size_of_set != row.logical_count {
				pattern_fail(handle, report, step, .Cell, &cell.element,
					"cell size_of_set to match the row's logical count",
					fmt.tprintf("%d cells, size_of_set %d", row.logical_count, cell.element.size_of_set))
				pattern_table_view_destroy(&view)
				return view, false
			}
			if !cell.element.is_virtual_item && (cell.element.visual_node == 0 || !cell.element.has_bounds) {
				pattern_fail(handle, report, step, .Cell, &cell.element,
					"a realized cell with bounds", "cell has no visual node or bounds")
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
		if u64(row_cells) != row.logical_count {
			pattern_fail(handle, report, step, .Row, &row,
				"every logical cell of a realized row to be published",
				fmt.tprintf("%d realized cells of %d", row_cells, row.logical_count))
			pattern_table_view_destroy(&view)
			return view, false
		}
		for column in 0..<int(row.logical_count) {
			if !seen[column] {
				pattern_fail(handle, report, step, .Row, &row,
					"contiguous column coordinates", fmt.tprintf("column %d is missing", column))
				pattern_table_view_destroy(&view)
				return view, false
			}
		}
		if view.column_count < 0 {
			view.column_count = int(row.logical_count)
		} else if int(row.logical_count) != view.column_count {
			pattern_fail(handle, report, step, .Row, &row,
				fmt.tprintf("the same %d column count as the other rows", view.column_count),
				fmt.tprintf("%d columns", row.logical_count))
			pattern_table_view_destroy(&view)
			return view, false
		}
	}
	if view.column_count <= 0 {
		pattern_fail(handle, report, step, .Table, table, "at least one realized row with cells", "no cells are published")
		pattern_table_view_destroy(&view)
		return view, false
	}

	// Header grouping: when a header row is configured it must be a table row
	// collection, and every column header must be parented to that row.
	header_index := -1
	if pattern_has_part(config, .Header_Row) {
		result := pattern_find_part_optional(handle, config, .Header_Row)
		if result.match != .Unique || result.status != .Ok {
			pattern_fail(handle, report, step, .Header_Row, &result.element,
				"one published header row", "header row is absent or ambiguous")
			destroy_find_result(&result)
			pattern_table_view_destroy(&view)
			return view, false
		}
		header_index = pattern_table_find_row(&view, result.element.semantic_id)
		if header_index < 0 {
			pattern_fail(handle, report, step, .Header_Row, &result.element,
				"the header row collected by the table", "header row is not a table row")
			destroy_find_result(&result)
			pattern_table_view_destroy(&view)
			return view, false
		}
		header := &view.rows[header_index]
		if !header.is_collection || header.parent_semantic_id != table.semantic_id {
			pattern_fail(handle, report, step, .Header_Row, header,
				"a header row collection parented to the table", "header row is not parented to the table")
			destroy_find_result(&result)
			pattern_table_view_destroy(&view)
			return view, false
		}
		destroy_find_result(&result)
	}
	column_headers := 0
	header_rows := [PATTERN_MAX_OPTIONS]int{}
	for &cell in view.cells {
		if cell.element.role != .Table_Column_Header { continue }
		column_headers += 1
		header_rows[cell.row] += 1
		if header_index >= 0 && cell.row != header_index {
			pattern_fail(handle, report, step, .Header_Row, &cell.element,
				"every column header inside the configured header row", "column header is in another row")
			pattern_table_view_destroy(&view)
			return view, false
		}
	}
	if header_index >= 0 && column_headers == 0 {
		pattern_fail(handle, report, step, .Header_Row, &view.rows[header_index],
			"at least one .Table_Column_Header in the header row", "header row has no column headers")
		pattern_table_view_destroy(&view)
		return view, false
	}
	if header_index < 0 && column_headers > 0 {
		row_count := 0
		for &count in header_rows {
			if count > 0 { row_count += 1 }
		}
		if row_count != 1 {
			pattern_fail(handle, report, step, .Header_Row, &view.table,
				"column headers grouped in one header row", "column headers span multiple rows")
			pattern_table_view_destroy(&view)
			return view, false
		}
	}
	return view, true
}

// pattern_check_table_impl is the static contract. It never requires managed
// focus or roving; it asserts published structure and ordinary-document
// realization, and optionally verifies that a bounded window advances through
// ordinary Page Down scrolling.
@(private)
pattern_check_table_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	view, ok := pattern_collect_table_view(handle, config, .Static_Contract, report, false)
	if !ok { return false }
	defer pattern_table_view_destroy(&view)

	if config.table.expect_row_count && view.table.logical_count != config.table.expected_row_count {
		return pattern_fail(handle, report, .Static_Contract, .Table, &view.table,
			fmt.tprintf("%d logical rows", config.table.expected_row_count),
			fmt.tprintf("%d logical rows", view.table.logical_count))
	}
	if config.table.expect_column_count && u64(view.column_count) != config.table.expected_column_count {
		return pattern_fail(handle, report, .Static_Contract, .Table, &view.table,
			fmt.tprintf("%d columns", config.table.expected_column_count),
			fmt.tprintf("%d columns", view.column_count))
	}

	if pattern_has_part(config, .Row) {
		row, row_ok := pattern_require_part(handle, config, .Row, .Static_Contract, report)
		if !row_ok { return false }
		defer destroy_element(&row)
		if pattern_table_find_row(&view, row.semantic_id) < 0 {
			return pattern_fail(handle, report, .Static_Contract, .Row, &row,
				"the configured row collected by the table", "row is not a table row")
		}
	}
	if pattern_has_part(config, .Cell) {
		cell, cell_ok := pattern_require_part(handle, config, .Cell, .Static_Contract, report)
		if !cell_ok { return false }
		defer destroy_element(&cell)
		if !pattern_table_cell_role(cell.role) {
			return pattern_fail(handle, report, .Static_Contract, .Cell, &cell,
				"a table cell role", fmt.tprintf("%v", cell.role))
		}
		if pattern_table_find_cell(&view, cell.semantic_id) < 0 {
			return pattern_fail(handle, report, .Static_Contract, .Cell, &cell,
				"the configured cell collected by a row", "cell is outside every row collection")
		}
		if !cell.is_virtual_item && (cell.visual_node == 0 || !cell.has_bounds) {
			return pattern_fail(handle, report, .Static_Contract, .Cell, &cell,
				"a realized target cell with bounds", "cell is not realized")
		}
	}

	if config.table.expect_virtual_reveal {
		if u64(view.realized) >= view.table.logical_count {
			return pattern_fail(handle, report, .Static_Contract, .Table, &view.table,
				"a virtualized table for reveal validation", "the whole table is realized")
		}
		first := view.table.realized_first
		last := view.table.realized_last
		if !pattern_press_key(handle, .Page_Down, .Virtual_Reveal, .Table, report) { return false }
		if pattern_settle_description(handle) != .Ok {
			return pattern_fail(handle, report, .Virtual_Reveal, .Table, nil,
				"settled follow-up description", last_turn_diagnostic(handle))
		}
		refreshed, refreshed_ok := pattern_collect_table_view(handle, config, .Virtual_Reveal, report, false)
		if !refreshed_ok { return false }
		defer pattern_table_view_destroy(&refreshed)
		if refreshed.table.realized_first == first && refreshed.table.realized_last == last {
			return pattern_fail(handle, report, .Virtual_Reveal, .Table, &refreshed.table,
				"ordinary Page Down advances the realized row window", "the realized window did not move")
		}
	}
	return true
}

// pattern_grid_enabled reports whether (row, column) is an enabled grid cell.
@(private)
pattern_grid_enabled :: proc(view: ^Pattern_Table_View, row, column: int) -> bool {
	if row < 0 || row >= len(view.rows) || column < 0 || column >= view.column_count { return false }
	if pattern_table_row_disabled(view, row) { return false }
	return pattern_table_cell_disabled(view, pattern_table_find_cell_at(view, row, u64(column))) == false
}

@(private)
pattern_grid_row_enabled :: proc(view: ^Pattern_Table_View, row: int) -> bool {
	if row < 0 || row >= len(view.rows) || pattern_table_row_disabled(view, row) { return false }
	for column in 0..<view.column_count {
		if pattern_grid_enabled(view, row, column) { return true }
	}
	return false
}

@(private)
pattern_grid_linear :: proc(view: ^Pattern_Table_View, row, column: int) -> int {
	return row*view.column_count+column
}

@(private)
pattern_grid_cell_element :: proc(view: ^Pattern_Table_View, row, column: int) -> ^Element {
	index := pattern_table_find_cell_at(view, row, u64(column))
	if index < 0 { return nil }
	return &view.cells[index].element
}

// pattern_grid_scan_row finds the nearest enabled cell in one row.
@(private)
pattern_grid_scan_row :: proc(view: ^Pattern_Table_View, row, start, direction, lower, upper: int) -> int {
	for column := start; column >= lower && column < upper; column += direction {
		if pattern_grid_enabled(view, row, column) { return column }
	}
	return -1
}

// pattern_grid_expected_cell is an independent model of the configured cell
// roving policy. It scans in the direction of travel and skips disabled cells
// and disabled rows, including a row-targeted vertical move whose same-column
// cell is disabled.
@(private)
pattern_grid_expected_cell :: proc(
	view: ^Pattern_Table_View,
	row, column: int,
	move: alicorn.Roving_Move,
	config: Pattern_Grid_Config,
) -> int {
	rows := len(view.rows)
	columns := view.column_count
	if row < 0 || row >= rows || column < 0 || column >= columns { return -1 }
	switch move {
	case .Left, .Right:
		direction := -1 if move == .Left else 1
		if !config.row_bounded {
			total := rows*columns
			linear := pattern_grid_linear(view, row, column)
			candidate := linear+direction
			for _ in 0..<total {
				if config.wrap {
					candidate = ((candidate%total)+total)%total
				} else if candidate < 0 || candidate >= total {
					return -1
				}
				candidate_row := candidate/columns
				candidate_column := candidate%columns
				if pattern_grid_enabled(view, candidate_row, candidate_column) {
					return candidate if candidate != linear else -1
				}
				candidate += direction
			}
			return -1
		}
		found := pattern_grid_scan_row(view, row, column+direction, direction, 0, columns)
		if found >= 0 { return pattern_grid_linear(view, row, found) }
		if !config.wrap { return -1 }
		if direction < 0 {
			found = pattern_grid_scan_row(view, row, columns-1, -1, 0, columns)
		} else {
			found = pattern_grid_scan_row(view, row, 0, 1, 0, columns)
		}
		if found >= 0 && found != column { return pattern_grid_linear(view, row, found) }
		return -1
	case .Up, .Down:
		direction := -1 if move == .Up else 1
		candidate := row+direction
		for _ in 0..<rows {
			if config.wrap {
				candidate = ((candidate%rows)+rows)%rows
			} else if candidate < 0 || candidate >= rows {
				return -1
			}
			if pattern_grid_enabled(view, candidate, column) {
				return pattern_grid_linear(view, candidate, column) if candidate != row else -1
			}
			candidate += direction
		}
		return -1
	case .Home:
		if config.home_end_row {
			found := pattern_grid_scan_row(view, row, 0, 1, 0, columns)
			if found >= 0 && found != column { return pattern_grid_linear(view, row, found) }
			return -1
		}
		for candidate_row in 0..<rows {
			found := pattern_grid_scan_row(view, candidate_row, 0, 1, 0, columns)
			if found >= 0 {
				linear := pattern_grid_linear(view, candidate_row, found)
				return linear if linear != pattern_grid_linear(view, row, column) else -1
			}
		}
		return -1
	case .End:
		if config.home_end_row {
			found := pattern_grid_scan_row(view, row, columns-1, -1, 0, columns)
			if found >= 0 && found != column { return pattern_grid_linear(view, row, found) }
			return -1
		}
		for candidate_row := rows-1; candidate_row >= 0; candidate_row -= 1 {
			found := pattern_grid_scan_row(view, candidate_row, columns-1, -1, 0, columns)
			if found >= 0 {
				linear := pattern_grid_linear(view, candidate_row, found)
				return linear if linear != pattern_grid_linear(view, row, column) else -1
			}
		}
		return -1
	case .Page_Up, .Page_Down:
		return -1
	}
	return -1
}

@(private)
pattern_grid_expected_row :: proc(
	view: ^Pattern_Table_View,
	row: int,
	move: alicorn.Roving_Move,
	wrap: bool,
) -> int {
	rows := len(view.rows)
	if row < 0 || row >= rows { return -1 }
	direction := 0
	#partial switch move {
	case .Up: direction = -1
	case .Down: direction = 1
	case .Home:
		for candidate in 0..<rows {
			if pattern_grid_row_enabled(view, candidate) { return candidate if candidate != row else -1 }
		}
		return -1
	case .End:
		for candidate := rows-1; candidate >= 0; candidate -= 1 {
			if pattern_grid_row_enabled(view, candidate) { return candidate if candidate != row else -1 }
		}
		return -1
	case:
		return -1
	}
	for step in 1..=rows {
		candidate := row+direction*step
		if wrap {
			candidate = ((candidate%rows)+rows)%rows
		} else if candidate < 0 || candidate >= rows {
			return -1
		}
		if pattern_grid_row_enabled(view, candidate) { return candidate if candidate != row else -1 }
	}
	return -1
}

@(private)
pattern_grid_verify_focus :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	focused_cells := 0
	focused_row := -1
	focused_col := -1
	for &cell in view.cells {
		if !cell.element.focused { continue }
		focused_cells += 1
		focused_row = cell.row
		focused_col = int(cell.column)
	}
	if focused_cells > 1 {
		pattern_fail(handle, report, step, .Cell, &view.table,
			"exactly one focused grid cell", fmt.tprintf("%d cells report focus", focused_cells))
		return false
	}
	if focused_cells == 1 {
		view.focus_mode = .Cell
		view.focused_row = focused_row
		view.focused_col = focused_col
		cell := pattern_grid_cell_element(view, focused_row, focused_col)
		if cell != nil && pattern_table_cell_disabled(view, pattern_table_find_cell_at(view, focused_row, u64(focused_col))) {
			pattern_fail(handle, report, step, .Cell, cell,
				"focus on an enabled grid cell", "focus is on a disabled cell")
			return false
		}
		return true
	}
	focused_rows := 0
	for &row, index in view.rows {
		if !row.focused { continue }
		focused_rows += 1
		focused_row = index
	}
	if focused_rows > 1 {
		pattern_fail(handle, report, step, .Row, &view.table,
			"exactly one focused grid cell or row", fmt.tprintf("%d rows report focus", focused_rows))
		return false
	}
	if focused_rows == 0 {
		pattern_fail(handle, report, step, .Cell, &view.table,
			"one focused grid cell or row", "focus escaped the grid")
		return false
	}
	view.focus_mode = .Row
	view.focused_row = focused_row
	view.focused_col = -1
	if !pattern_grid_row_enabled(view, focused_row) {
		pattern_fail(handle, report, step, .Row, &view.rows[focused_row],
			"focus on an enabled grid row", "focus is on a disabled row")
		return false
	}
	return true
}

@(private)
pattern_grid_refresh :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	pattern_table_view_destroy(view)
	refreshed, ok := pattern_collect_table_view(handle, config, step, report, true)
	view^ = refreshed
	if !ok { return false }
	return pattern_grid_verify_focus(handle, view, .Containment, report)
}

@(private)
pattern_grid_press :: proc(
	handle: ^Test_Handle($T),
	move: alicorn.Roving_Move,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	key: Key
	switch move {
	case .Left: key = .Left
	case .Right: key = .Right
	case .Up: key = .Up
	case .Down: key = .Down
	case .Home: key = .Home
	case .End: key = .End
	case .Page_Up: key = .Page_Up
	case .Page_Down: key = .Page_Down
	}
	return pattern_press_key(handle, key, step, .Cell, report)
}

@(private)
pattern_grid_step_and_verify :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	move: alicorn.Roving_Move,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	previous_row := view.focused_row
	previous_column := view.focused_col
	expected := -1
	if view.focus_mode == .Cell {
		expected = pattern_grid_expected_cell(view, previous_row, previous_column, move, config.grid)
	} else {
		expected = pattern_grid_expected_row(view, previous_row, move, config.grid.wrap)
	}
	if !pattern_grid_press(handle, move, step, report) { return false }
	if !pattern_grid_refresh(handle, view, config, step, report) { return false }
	if expected < 0 {
		if view.focus_mode == .Cell {
			if view.focused_row != previous_row || view.focused_col != previous_column {
				cell := pattern_grid_cell_element(view, view.focused_row, view.focused_col)
				pattern_fail(handle, report, step, .Cell, cell,
					fmt.tprintf("%v leaves focus in place", move), "focus moved")
				return false
			}
		} else if view.focused_row != previous_row {
			pattern_fail(handle, report, step, .Row, &view.rows[view.focused_row],
				fmt.tprintf("%v leaves focus in place", move), "focus moved")
			return false
		}
		return true
	}
	if view.focus_mode == .Cell {
		if pattern_grid_linear(view, view.focused_row, view.focused_col) != expected {
			cell := pattern_grid_cell_element(view, view.focused_row, view.focused_col)
			pattern_fail(handle, report, step, .Cell, cell,
				fmt.tprintf("%v moves focus to the expected enabled cell", move), "focus is on another cell")
			return false
		}
		if config.grid.expect_reveal {
			cell := pattern_grid_cell_element(view, view.focused_row, view.focused_col)
			if cell == nil || !cell.has_bounds || !pattern_rect_intersects(cell.bounds, view.table.bounds) {
				return pattern_fail(handle, report, .Virtual_Reveal, .Cell, cell,
					"the focused cell is realized inside the grid viewport",
					fmt.tprintf("bounds %v inside %v", cell.bounds, view.table.bounds))
			}
		}
	} else if view.focused_row != expected {
		pattern_fail(handle, report, step, .Row, &view.rows[view.focused_row],
			fmt.tprintf("%v moves focus to the expected enabled row", move), "focus is on another row")
		return false
	}
	return true
}

@(private)
pattern_grid_expected_index :: proc(view: ^Pattern_Table_View, target: ^Element) -> (row, column: int, ok: bool) {
	for &cell in view.cells {
		if cell.element.semantic_id == target.semantic_id { return cell.row, int(cell.column), true }
	}
	for &row, index in view.rows {
		if row.semantic_id == target.semantic_id { return index, -1, true }
	}
	return -1, -1, false
}

@(private)
pattern_grid_selection_verify :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	expected: ^Element,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	if config.grid.selection == .None { return true }
	selected := 0
	selected_id := alicorn.Semantic_ID{}
	if config.grid.selection == .Cell {
		for &cell in view.cells {
			if !alicorn.semantic_states_has(cell.element.states, .Selected) { continue }
			selected += 1
			selected_id = cell.element.semantic_id
		}
		if selected != 1 || selected_id != expected.semantic_id {
			pattern_fail(handle, report, step, .Cell, &expected^,
				"the activated cell is the one Selected cell", "Selected does not name the activated cell")
			return false
		}
	} else {
		target_row := -1
		for &cell in view.cells {
			if cell.element.semantic_id == expected.semantic_id { target_row = cell.row; break }
		}
		if target_row >= 0 {
			for &row, index in view.rows {
				if !alicorn.semantic_states_has(row.states, .Selected) { continue }
				selected += 1
				selected_id = row.semantic_id
			}
			if selected != 1 || selected_id != view.rows[target_row].semantic_id {
				pattern_fail(handle, report, step, .Row, &view.rows[target_row],
					"the activated cell's row is the one Selected row", "Selected does not name the activated row")
				return false
			}
		} else {
			for &row in view.rows {
				if !alicorn.semantic_states_has(row.states, .Selected) { continue }
				selected += 1
				selected_id = row.semantic_id
			}
			if selected != 1 || selected_id != expected.semantic_id {
				pattern_fail(handle, report, step, .Row, &expected^,
					"the activated row is the one Selected row", "Selected does not name the activated row")
				return false
			}
		}
	}
	if view.table.collection_selected_id != selected_id {
		pattern_fail(handle, report, step, .Table, &view.table,
			"the table/grid selected_id names the Selected item", "selected_id and Selected disagree")
		return false
	}
	return true
}

@(private)
pattern_grid_navigate_cell :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	target_row, target_column: int,
	config: Pattern_Config,
	step: Pattern_Step,
	report: ^Pattern_Report,
) -> bool {
	for _ in 0..<PATTERN_MAX_OPTIONS {
		if view.focus_mode == .Cell && view.focused_row == target_row && view.focused_col == target_column { return true }
		if view.focus_mode == .Row && view.focused_row == target_row { return true }
		if view.focus_mode == .Cell {
			move := alicorn.Roving_Move.Right
			if target_row > view.focused_row {
				move = .Down
			} else if target_row < view.focused_row {
				move = .Up
			} else if target_column < view.focused_col {
				move = .Left
			}
			if !pattern_grid_step_and_verify(handle, view, move, config, step, report) { return false }
			if view.focus_mode == .Row { return false }
		} else {
			move := alicorn.Roving_Move.Down
			if target_row < view.focused_row { move = .Up }
			if !pattern_grid_step_and_verify(handle, view, move, config, step, report) { return false }
		}
	}
	pattern_fail(handle, report, step, .Cell, nil, "the target cell reachable by grid navigation",
		"the navigation bound was exhausted")
	return false
}

@(private)
Pattern_Grid_Action :: struct {
	id:     alicorn.Semantic_ID,
	row:    int,
	column: int,
	action: alicorn.Semantic_Action,
}

@(private)
pattern_grid_action_parity :: proc(
	handle: ^Test_Handle($T),
	view: ^Pattern_Table_View,
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	initial_mode := view.focus_mode
	initial_row := view.focused_row
	initial_column := view.focused_col
	// Focus parity: every advertised Focus must be performable.
	for &cell in view.cells {
		if pattern_table_cell_disabled(view, pattern_table_find_cell_at(view, cell.row, cell.column)) { continue }
		if !alicorn.semantic_actions_has(cell.element.actions, .Focus) { continue }
		if !pattern_focus_semantic(handle, &cell.element, .Semantic_Action_Parity, .Cell, report) { return false }
	}
	if !pattern_grid_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
	// Restore the at-rest representative after the Focus sweep.
	if initial_mode == .Cell {
		index := pattern_table_find_cell_at(view, initial_row, u64(initial_column))
		if index >= 0 && alicorn.semantic_actions_has(view.cells[index].element.actions, .Focus) {
			if !pattern_focus_semantic(handle, &view.cells[index].element, .Semantic_Action_Parity, .Cell, report) { return false }
			if !pattern_grid_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
		}
	} else if initial_row >= 0 && initial_row < len(view.rows) &&
		alicorn.semantic_actions_has(view.rows[initial_row].actions, .Focus) {
		if !pattern_focus_semantic(handle, &view.rows[initial_row], .Semantic_Action_Parity, .Row, report) { return false }
		if !pattern_grid_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
	}

	// Press/Select parity: every advertised activation must be accepted and,
	// when a selection policy exists, must publish the matching Selected.
	// Collect the actions first: a refresh replaces the whole view.
	actions := make([dynamic]Pattern_Grid_Action, 0, len(view.cells), handle.allocator)
	defer delete(actions)
	for &cell in view.cells {
		if pattern_table_cell_disabled(view, pattern_table_find_cell_at(view, cell.row, cell.column)) { continue }
		action := alicorn.Semantic_Action.None
		if alicorn.semantic_actions_has(cell.element.actions, .Press) {
			action = .Press
		} else if alicorn.semantic_actions_has(cell.element.actions, .Select) {
			action = .Select
		}
		if action == .None { continue }
		append(&actions, Pattern_Grid_Action{
			id=cell.element.semantic_id,
			row=cell.row,
			column=int(cell.column),
			action=action,
		})
	}
	for entry in actions {
		status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=entry.id, semantic_action=entry.action})
		if status != .Ok {
			return pattern_fail(handle, report, .Semantic_Action_Parity, .Cell, nil,
				fmt.tprintf("advertised semantic %v accepted", entry.action), fmt.tprintf("status %v", status),
				last_turn_diagnostic(handle))
		}
		if !pattern_grid_refresh(handle, view, config, .Semantic_Action_Parity, report) { return false }
		index := pattern_table_find_cell_at(view, entry.row, u64(entry.column))
		if index < 0 { continue }
		if !pattern_grid_selection_verify(handle, view, &view.cells[index].element, config, .Semantic_Action_Parity, report) {
			return false
		}
	}
	return true
}

@(private)
pattern_check_data_grid_impl :: proc(
	handle: ^Test_Handle($T),
	config: Pattern_Config,
	report: ^Pattern_Report,
) -> bool {
	view, ok := pattern_collect_table_view(handle, config, .Static_Contract, report, true)
	if !ok { return false }
	defer pattern_table_view_destroy(&view)

	if config.grid.columns > 0 && config.grid.columns != view.column_count {
		return pattern_fail(handle, report, .Static_Contract, .Table, &view.table,
			fmt.tprintf("%d grid columns", config.grid.columns), fmt.tprintf("%d published columns", view.column_count))
	}
	if view.column_count <= 1 {
		return pattern_fail(handle, report, .Static_Contract, .Table, &view.table,
			"an interactive grid with more than one column", "the grid is linear")
	}

	// Static disabled policy: disabled cells and rows are not focusable and do
	// not advertise activation or focus.
	for &row in view.rows {
		row_disabled := alicorn.semantic_states_has(row.states, .Disabled)
		for &cell in view.cells {
			if cell.row < 0 || view.rows[cell.row].semantic_id != row.semantic_id { continue }
			disabled := row_disabled || alicorn.semantic_states_has(cell.element.states, .Disabled)
			if row_disabled && !alicorn.semantic_states_has(cell.element.states, .Disabled) {
				pattern_fail(handle, report, .Static_Contract, .Cell, &cell.element,
					"a disabled row to publish Disabled on its cells", "row is Disabled but a cell is not")
				return false
			}
			if disabled {
				if pattern_table_node_focusable(handle, &cell.element) {
					pattern_fail(handle, report, .Focus_Contract, .Cell, &cell.element,
						"a disabled cell that is not focusable", "disabled cell visual node is focusable")
					return false
				}
				if alicorn.semantic_actions_has(cell.element.actions, .Focus) ||
				   alicorn.semantic_actions_has(cell.element.actions, .Press) ||
				   alicorn.semantic_actions_has(cell.element.actions, .Select) {
					pattern_fail(handle, report, .Static_Contract, .Cell, &cell.element,
						"a disabled cell without Focus, Press, or Select", "disabled cell advertises an action")
					return false
				}
				if cell.element.focused {
					pattern_fail(handle, report, .Focus_Contract, .Cell, &cell.element,
						"a disabled cell that is not focused", "disabled cell reports focus")
					return false
				}
			} else if !alicorn.semantic_actions_has(cell.element.actions, .Focus) {
				pattern_fail(handle, report, .Static_Contract, .Cell, &cell.element,
					"an enabled cell with a Focus action", "enabled cell is not focusable")
				return false
			}
		}
	}

	if !pattern_grid_verify_focus(handle, &view, .Static_Contract, report) { return false }

	// 1. Advertised Focus/Press/Select parity.
	if !pattern_grid_action_parity(handle, &view, config, report) { return false }
	if !pattern_grid_verify_focus(handle, &view, .Containment, report) { return false }

	// 2. Directional navigation with disabled skipping, Home/End, boundaries,
	// wrap, containment, and reveal after every turn.
	moves := [12]alicorn.Roving_Move{.Home, .Right, .Right, .Left, .Down, .Up, .End, .Home, .Down, .Down, .Down, .Up}
	for move in moves {
		if !pattern_grid_step_and_verify(handle, &view, move, config, .Navigation, report) { return false }
		if !pattern_grid_verify_focus(handle, &view, .Containment, report) { return false }
	}

	if !pattern_has_part(config, .Cell) { return true }
	target, target_ok := pattern_require_part(handle, config, .Cell, .Activation_Parity, report)
	if !target_ok { return false }
	target_id := target.semantic_id
	target_row, target_column, target_found := pattern_grid_expected_index(&view, &target)
	destroy_element(&target)
	if !target_found || target_row < 0 || target_column < 0 {
		return pattern_fail(handle, report, .Activation_Parity, .Cell, nil,
			"the target cell is an enabled grid cell", "target is absent or disabled")
	}
	if !pattern_grid_enabled(&view, target_row, target_column) {
		return pattern_fail(handle, report, .Activation_Parity, .Cell, nil,
			"the target cell is enabled", "target cell is disabled")
	}
	if !pattern_grid_navigate_cell(handle, &view, target_row, target_column, config, .Activation_Parity, report) {
		return false
	}
	target_index := pattern_table_find_cell_at(&view, target_row, u64(target_column))
	if target_index < 0 {
		return pattern_fail(handle, report, .Activation_Parity, .Cell, nil,
			"the target cell is realized", "target cell is absent")
	}
	if config.grid.selection != .None {
		// Space, Return, then pointer must keep the same selected identity.
		if !pattern_press_key(handle, .Space, .Activation_Parity, .Cell, report) { return false }
		if !pattern_grid_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		index := pattern_table_find_cell_at(&view, target_row, u64(target_column))
		if index < 0 { return false }
		if !pattern_grid_selection_verify(handle, &view, &view.cells[index].element, config, .Activation_Parity, report) {
			return false
		}
		if !pattern_press_key(handle, .Return, .Activation_Parity, .Cell, report) { return false }
		if !pattern_grid_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		index = pattern_table_find_cell_at(&view, target_row, u64(target_column))
		if index < 0 { return false }
		if !pattern_grid_selection_verify(handle, &view, &view.cells[index].element, config, .Activation_Parity, report) {
			return false
		}
		pointer_index := pattern_table_find_cell_at(&view, target_row, u64(target_column))
		if pointer_index < 0 { return false }
		if !pattern_click_element(handle, &view.cells[pointer_index].element, .Activation_Parity, .Cell, report) { return false }
		if !pattern_grid_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		index = pattern_table_find_cell_at(&view, target_row, u64(target_column))
		if index < 0 { return false }
		if !pattern_grid_selection_verify(handle, &view, &view.cells[index].element, config, .Activation_Parity, report) {
			return false
		}
	}

	// Semantic Press parity moves selection to a different enabled cell.
	pressed_id := alicorn.Semantic_ID{}
	for &cell in view.cells {
		if cell.element.semantic_id == target_id { continue }
		if !pattern_grid_enabled(&view, cell.row, int(cell.column)) { continue }
		if !alicorn.semantic_actions_has(cell.element.actions, .Press) { continue }
		pressed_id = cell.element.semantic_id
		break
	}
	if pressed_id.namespace != 0 {
		status := pattern_step_input(handle, Input{kind=.Semantic_Action, semantic_id=pressed_id, semantic_action=.Press})
		if status != .Ok {
			return pattern_fail(handle, report, .Activation_Parity, .Cell, nil,
				"advertised semantic Press accepted", fmt.tprintf("status %v", status), last_turn_diagnostic(handle))
		}
		if !pattern_grid_refresh(handle, &view, config, .Activation_Parity, report) { return false }
		index := pattern_table_find_cell(&view, pressed_id)
		if index < 0 { return false }
		if !pattern_grid_selection_verify(handle, &view, &view.cells[index].element, config, .Activation_Parity, report) {
			return false
		}
	}
	return true
}

pattern_check_table :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Table
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_table_impl(handle, config, &report)
	return report
}

pattern_check_data_grid :: proc(handle: ^Test_Handle($T), config: Pattern_Config) -> Pattern_Report {
	report := Pattern_Report{ok=true}
	report.failure.pattern = .Data_Grid
	if handle == nil || handle.runtime == nil {
		pattern_fail_message(&report, .Resolve_Parts, "valid test handle", "nil handle")
		return report
	}
	_ = pattern_check_data_grid_impl(handle, config, &report)
	return report
}
