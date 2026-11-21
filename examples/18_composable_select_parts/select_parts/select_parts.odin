package select_parts

// Select Parts is a userland composable Select. It is a copyable package that
// uses only public Alicorn facilities: Button owners with presentation=.Custom,
// visual parts, semantic collections, a retained virtual list, a modal overlay,
// interaction scopes, after-frame focus restoration, and theme extension roles.
//
// The package deliberately does not add runtime APIs or touch the built-in
// Select. Applications own option data, the controlled selected key, and any
// application-specific extension such as a pinned Recent group.

import "core:unicode"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

MAX_OPTIONS :: 128
MAX_GROUPS :: 32
MAX_ROWS :: MAX_OPTIONS+MAX_GROUPS
OPTION_LABEL_MAX_BYTES :: 256
GROUP_LABEL_MAX_BYTES :: 256
TYPEAHEAD_CAPACITY :: 64
RECENT_CAPACITY :: 4
DEFAULT_ROW_HEIGHT :: f32(32)
DEFAULT_POPUP_WIDTH :: f32(280)
POPUP_PADDING :: f32(6)
DEFAULT_MAX_VISIBLE_ROWS :: 8
VIEWPORT_MARGIN :: f32(8)
MAX_INSTANCE_ID :: u64(0x3FFFFFFFFFFFFFFF)

Select_Parts_Semantic_Namespace :: u64(0x53454C5041525453)

Select_Parts_Appearance :: enum { Compact, Rich }

Select_Parts_Option :: struct {
	key:      u64,
	label:    string,
	disabled: bool,
	// icon and badge are presentation-only. They do not change the semantic
	// option identity, which is derived from key and instance_id.
	icon:     alicorn.Icon_ID,
	badge:    string,
}

// Select_Parts_Group is one single-level option group. A labeled group renders
// a noninteractive header and exposes a semantic Group around its options.
Select_Parts_Group :: struct {
	label:   string,
	options: []Select_Parts_Option,
	disabled: bool,
}

Select_Parts_Recipe :: struct {
	appearance:     Select_Parts_Appearance,
	trigger_role:   alicorn.Style_Extension_Color_Role_ID,
	popup_role:     alicorn.Style_Extension_Color_Role_ID,
	row_hover_role: alicorn.Style_Extension_Color_Role_ID,
	row_selected_role: alicorn.Style_Extension_Color_Role_ID,
	accent_role:    alicorn.Style_Extension_Color_Role_ID,
	focus_role:     alicorn.Style_Extension_Color_Role_ID,
	badge_role:     alicorn.Style_Extension_Color_Role_ID,
	trigger_width:  f32,
	trigger_height: f32,
	row_height:     f32,
	popup_width:    f32,
	max_visible_rows: int,
}

Theme_Role_Requirement :: struct {
	role: alicorn.Style_Extension_Color_Role_ID,
	name: string,
}

Theme_Contract :: struct {
	required: [6]Theme_Role_Requirement,
	optional: [1]Theme_Role_Requirement,
}

Theme_Contract_Report :: struct {
	required_available: [6]bool,
	optional_available: [1]bool,
}

Select_Parts_Focus_Request :: enum { None, Trigger, Next, Previous }

@(private)
Select_Parts_Row :: struct {
	group:  int,
	option: int,
}

Select_Parts_State :: struct {
	selected_key: u64,
	open:         bool,
	active_key:   u64,
	active_index: int,

	instance_id:         u64,
	trigger_node:        alicorn.Node_ID,
	trigger_semantic_id: alicorn.Semantic_ID,
	list_semantic_id:    alicorn.Semantic_ID,
	overlay_node:        alicorn.Node_ID,
	panel_node:          alicorn.Node_ID,
	scroll_node:         alicorn.Node_ID,

	anchor:  alicorn.Rect,
	panel_bounds: alicorn.Rect,
	viewport: alicorn.Rect,
	style_environment: alicorn.Style_Environment,

	typeahead: [TYPEAHEAD_CAPACITY]u8,
	typeahead_length: int,
	typeahead_pending: bool,

	option_nodes: [MAX_OPTIONS]alicorn.Node_ID,
	option_row:   [MAX_OPTIONS]int,

	just_opened:   bool,
	focus_pending: bool,
	reveal_pending: bool,
	focus_retry:   int,
	pending_focus: Select_Parts_Focus_Request,

	changed_pending: bool,
	changed_key: u64,
	changed_trigger: alicorn.Node_ID,

	recent_keys: [RECENT_CAPACITY]u64,
	recent_count: int,
}

recipe_default :: proc(appearance := Select_Parts_Appearance.Compact) -> Select_Parts_Recipe {
	compact := appearance == .Compact
	recipe := Select_Parts_Recipe{
		appearance=appearance,
		trigger_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "trigger"),
		popup_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "popup"),
		row_hover_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "row_hover"),
		row_selected_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "row_selected"),
		accent_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "accent"),
		focus_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "focus"),
		badge_role=alicorn.style_extension_color_role_id("vendor.acme.parts", "badge"),
		trigger_width=300 if compact else 380,
		trigger_height=36 if compact else 54,
		row_height=DEFAULT_ROW_HEIGHT if compact else 44,
		popup_width=300 if compact else 380,
		max_visible_rows=DEFAULT_MAX_VISIBLE_ROWS,
	}
	return recipe
}

theme_contract_default :: proc(recipe: Select_Parts_Recipe) -> Theme_Contract {
	return Theme_Contract{
		required={
			{role=recipe.trigger_role, name="vendor.acme.parts.trigger"},
			{role=recipe.popup_role, name="vendor.acme.parts.popup"},
			{role=recipe.row_hover_role, name="vendor.acme.parts.row_hover"},
			{role=recipe.row_selected_role, name="vendor.acme.parts.row_selected"},
			{role=recipe.accent_role, name="vendor.acme.parts.accent"},
			{role=recipe.focus_role, name="vendor.acme.parts.focus"},
		},
		optional={
			{role=recipe.badge_role, name="vendor.acme.parts.badge"},
		},
	}
}

theme_contract_check :: proc(
	rt: ^alicorn.Runtime,
	theme: alicorn.Style_Theme_ID,
	contract: Theme_Contract,
) -> Theme_Contract_Report {
	report := Theme_Contract_Report{}
	for requirement, index in contract.required {
		_, report.required_available[index] = alicorn.style_extension_color(rt, theme, requirement.role)
	}
	for requirement, index in contract.optional {
		if requirement.role == 0 {
			report.optional_available[index] = true
		} else {
			_, report.optional_available[index] = alicorn.style_extension_color(rt, theme, requirement.role)
		}
	}
	return report
}

theme_contract_satisfied :: proc(report: Theme_Contract_Report) -> bool {
	for available in report.required_available { if !available { return false } }
	return true
}

theme_contract_missing_required :: proc(
	contract: Theme_Contract,
	report: Theme_Contract_Report,
) -> (missing: [6]string, count: int) {
	for requirement, index in contract.required {
		if !report.required_available[index] {
			missing[count] = requirement.name
			count += 1
		}
	}
	return
}

@(private)
select_parts_recipe_valid :: proc(recipe: Select_Parts_Recipe) -> bool {
	return recipe.trigger_role != 0 && recipe.popup_role != 0 && recipe.row_hover_role != 0 &&
		recipe.row_selected_role != 0 && recipe.accent_role != 0 && recipe.focus_role != 0 &&
		recipe.trigger_width > 0 && recipe.trigger_height > 0 && recipe.row_height > 0 &&
		recipe.popup_width > 0 && recipe.max_visible_rows > 0
}

@(private)
select_parts_groups_option_count :: proc(groups: []Select_Parts_Group) -> int {
	total := 0
	for group in groups { total += len(group.options) }
	return total
}

@(private)
select_parts_groups_valid :: proc(groups: []Select_Parts_Group) -> bool {
	if len(groups) > MAX_GROUPS { return false }
	total := 0
	for group, group_index in groups {
		if len(group.label) > GROUP_LABEL_MAX_BYTES { return false }
		for option, option_index in group.options {
			if option.key == 0 || len(option.label) == 0 || len(option.label) > OPTION_LABEL_MAX_BYTES { return false }
			total += 1
			if total > MAX_OPTIONS { return false }
			for previous_group, previous_group_index in groups {
				if previous_group_index > group_index { break }
				for previous_option, previous_option_index in previous_group.options {
					if previous_group_index == group_index && previous_option_index >= option_index { break }
					if previous_option.key == option.key { return false }
				}
			}
		}
	}
	return true
}

@(private)
select_parts_find_key :: proc(
	groups: []Select_Parts_Group,
	key: u64,
) -> (flat_index: int, group_index: int, option_index: int, found: bool) {
	flat_index = 0
	for group, gi in groups {
		for option, oi in group.options {
			if option.key == key { return flat_index, gi, oi, true }
			flat_index += 1
		}
	}
	return -1, -1, -1, false
}

@(private)
select_parts_option_at :: proc(
	groups: []Select_Parts_Group,
	flat_index: int,
) -> (option: ^Select_Parts_Option, group_index: int, found: bool) {
	if flat_index < 0 { return }
	index := 0
	for group, gi in groups {
		for &candidate in group.options {
			if index == flat_index { return &candidate, gi, true }
			index += 1
		}
	}
	return
}

@(private)
select_parts_option_label :: proc(groups: []Select_Parts_Group, key: u64) -> (string, bool) {
	_, gi, oi, found := select_parts_find_key(groups, key)
	if !found { return "", false }
	return groups[gi].options[oi].label, true
}

@(private)
select_parts_option_enabled :: proc(groups: []Select_Parts_Group, flat_index: int) -> bool {
	option, gi, found := select_parts_option_at(groups, flat_index)
	return found && !option.disabled && !groups[gi].disabled
}

@(private)
select_parts_first_enabled :: proc(groups: []Select_Parts_Group) -> int {
	total := select_parts_groups_option_count(groups)
	for index in 0..<total { if select_parts_option_enabled(groups, index) { return index } }
	return -1
}

@(private)
select_parts_next_enabled :: proc(groups: []Select_Parts_Group, start, delta: int) -> int {
	total := select_parts_groups_option_count(groups)
	if total <= 0 { return -1 }
	index := start
	if index < 0 || index >= total { index = 0 if delta > 0 else total-1 }
	for _ in 0..<total {
		index = (index+delta)%total
		if index < 0 { index += total }
		if select_parts_option_enabled(groups, index) { return index }
	}
	return -1
}

@(private)
select_parts_text_has_prefix :: proc(value, prefix: string) -> bool {
	if len(prefix) == 0 || len(prefix) > TYPEAHEAD_CAPACITY || len(value) > OPTION_LABEL_MAX_BYTES { return false }
	value_runes: [OPTION_LABEL_MAX_BYTES]rune
	value_count := 0
	for value_rune in value {
		value_runes[value_count] = unicode.to_lower(value_rune)
		value_count += 1
	}
	prefix_runes: [TYPEAHEAD_CAPACITY]rune
	prefix_count := 0
	for prefix_rune in prefix {
		prefix_runes[prefix_count] = unicode.to_lower(prefix_rune)
		prefix_count += 1
	}
	if prefix_count > value_count { return false }
	for index in 0..<prefix_count { if prefix_runes[index] != value_runes[index] { return false } }
	return true
}

@(private)
select_parts_typeahead_match :: proc(
	groups: []Select_Parts_Group,
	start: int,
	prefix: string,
) -> int {
	total := select_parts_groups_option_count(groups)
	if total <= 0 || len(prefix) == 0 { return -1 }
	cursor := start
	if cursor < 0 || cursor >= total { cursor = 0 }
	for offset in 1..=total {
		index := (cursor+offset)%total
		option, gi, found := select_parts_option_at(groups, index)
		if !found || option.disabled || groups[gi].disabled { continue }
		if select_parts_text_has_prefix(option.label, prefix) { return index }
	}
	return -1
}

@(private)
select_parts_semantic_mix :: proc(seed, value: u64) -> u64 {
	// SplitMix64 finalizer, kept local so option identity is independent of
	// runtime hash internals.
	state := seed+value+0x9E3779B97F4A7C15
	state = (state ~ (state>>30))*0xBF58476D1CE4E5B9
	state = (state ~ (state>>27))*0x94D049BB133111EB
	return state ~ (state>>31)
}

select_parts_trigger_id :: proc(instance_id: u64) -> alicorn.Semantic_ID {
	if instance_id == 0 || instance_id > MAX_INSTANCE_ID { return {} }
	return alicorn.Semantic_ID{namespace=Select_Parts_Semantic_Namespace, value=select_parts_semantic_mix(instance_id, 0x54524947474552)}
}

select_parts_list_id :: proc(instance_id: u64) -> alicorn.Semantic_ID {
	if instance_id == 0 || instance_id > MAX_INSTANCE_ID { return {} }
	return alicorn.Semantic_ID{namespace=Select_Parts_Semantic_Namespace, value=select_parts_semantic_mix(instance_id, 0x4C495354424F58)}
}

select_parts_option_id :: proc(instance_id, key: u64) -> alicorn.Semantic_ID {
	if instance_id == 0 || instance_id > MAX_INSTANCE_ID || key == 0 { return {} }
	return alicorn.Semantic_ID{namespace=Select_Parts_Semantic_Namespace, value=select_parts_semantic_mix(instance_id, key)}
}

select_parts_group_id :: proc(instance_id: u64, group_index: int) -> alicorn.Semantic_ID {
	if instance_id == 0 || instance_id > MAX_INSTANCE_ID || group_index < 0 || group_index >= MAX_GROUPS { return {} }
	return alicorn.Semantic_ID{namespace=Select_Parts_Semantic_Namespace, value=select_parts_semantic_mix(instance_id, u64(0x47524F5550)+u64(group_index+1))}
}

select_parts_note_recent :: proc(state: ^Select_Parts_State, key: u64) -> bool {
	if state == nil || key == 0 { return false }
	existing := -1
	for index in 0..<state.recent_count { if state.recent_keys[index] == key { existing = index; break } }
	if existing >= 0 {
		for index := existing; index > 0; index -= 1 { state.recent_keys[index] = state.recent_keys[index-1] }
		state.recent_keys[0] = key
		return true
	}
	limit := min(state.recent_count, RECENT_CAPACITY-1)
	for index := limit; index > 0; index -= 1 { state.recent_keys[index] = state.recent_keys[index-1] }
	state.recent_keys[0] = key
	state.recent_count = min(state.recent_count+1, RECENT_CAPACITY)
	return true
}

select_parts_clear_recent :: proc(state: ^Select_Parts_State) {
	if state == nil { return }
	state.recent_keys = {}
	state.recent_count = 0
}

select_parts_recent_keys :: proc(state: ^Select_Parts_State) -> []u64 {
	if state == nil { return nil }
	return state.recent_keys[:state.recent_count]
}

@(private)
select_parts_close :: proc(
	ctx: ^ui.UI,
	state: ^Select_Parts_State,
	request: Select_Parts_Focus_Request,
) {
	if ctx == nil || state == nil { return }
	state.open = false
	state.typeahead_length = 0
	state.typeahead_pending = false
	state.reveal_pending = false
	state.just_opened = false
	state.focus_retry = 0
	state.pending_focus = request
	alicorn.invalidate_root(ctx.runtime, "select parts closed")
}

@(private)
select_parts_open_after_frame :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	state := cast(^Select_Parts_State)data
	if state == nil || rt == nil || !state.open { return }
	state.just_opened = false
	if state.active_index >= 0 {
		focused := false
		if node := state.option_nodes[state.active_index]; node != 0 {
			focused = alicorn.focus(rt, node)
			if focused { alicorn.focus_indicator_set(rt, true) }
		}
		if state.scroll_node != 0 {
			_ = alicorn.virtual_list_ensure_visible(rt, state.scroll_node, state.option_row[state.active_index], "select parts opened and revealed")
		}
		if !focused && state.focus_retry < 2 {
			state.focus_retry += 1
			_ = alicorn.interaction_after_frame_register(rt, state, select_parts_open_after_frame)
		}
	}
}

@(private)
select_parts_after_frame :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	state := cast(^Select_Parts_State)data
	if state == nil || rt == nil { return }
	request := state.pending_focus
	switch request {
	case .None:
		return
	case .Trigger:
		if alicorn.focus(rt, state.trigger_node) {
			alicorn.focus_indicator_set(rt, true)
			state.pending_focus = .None
		} else if state.focus_retry < 2 {
			state.focus_retry += 1
			_ = alicorn.interaction_after_frame_register(rt, state, select_parts_after_frame)
		} else {
			state.pending_focus = .None
		}
	case .Next, .Previous:
		if alicorn.focus(rt, state.trigger_node) {
			alicorn.focus_indicator_set(rt, true)
			direction := alicorn.Focus_Direction.Next
			if request == .Previous { direction = .Previous }
			_ = alicorn.focus_traverse(rt, direction)
			state.pending_focus = .None
		} else if state.focus_retry < 2 {
			state.focus_retry += 1
			_ = alicorn.interaction_after_frame_register(rt, state, select_parts_after_frame)
		} else {
			state.pending_focus = .None
		}
	}
}

@(private)
select_parts_active_index :: proc(state: ^Select_Parts_State, groups: []Select_Parts_Group) -> int {
	if state == nil { return -1 }
	if index := select_parts_find_key_value(groups, state.active_key); index >= 0 && select_parts_option_enabled(groups, index) {
		return index
	}
	if index := select_parts_find_key_value(groups, state.selected_key); index >= 0 && select_parts_option_enabled(groups, index) {
		return index
	}
	return select_parts_first_enabled(groups)
}

@(private)
select_parts_find_key_value :: proc(groups: []Select_Parts_Group, key: u64) -> int {
	if key == 0 { return -1 }
	index, _, _, found := select_parts_find_key(groups, key)
	return index if found else -1
}

@(private)
select_parts_set_active :: proc(
	rt: ^alicorn.Runtime,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	index: int,
	reveal := true,
) -> bool {
	if state == nil || index < 0 || !select_parts_option_enabled(groups, index) { return false }
	option, _, found := select_parts_option_at(groups, index)
	if !found { return false }
	state.active_index = index
	state.active_key = option.key
	if reveal { state.reveal_pending = true }
	if node := state.option_nodes[index]; node != 0 && rt != nil {
		_ = alicorn.focus(rt, node)
		alicorn.focus_indicator_set(rt, true)
	}
	return true
}

@(private)
select_parts_activate_active :: proc(
	rt: ^alicorn.Runtime,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	ctx: ^ui.UI,
) -> bool {
	if state == nil || !state.open { return false }
	index := select_parts_active_index(state, groups)
	if index < 0 { return false }
	option, _, found := select_parts_option_at(groups, index)
	if !found || option.disabled { return false }
	changed := option.key != state.selected_key
	state.selected_key = option.key
	state.active_key = option.key
	state.active_index = index
	if changed {
		state.changed_pending = true
		state.changed_key = option.key
		state.changed_trigger = state.trigger_node
	}
	select_parts_close(ctx, state, .Trigger)
	return true
}

@(private)
select_parts_process_input :: proc(
	ctx: ^ui.UI,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
) {
	if ctx == nil || ctx.runtime == nil || state == nil || !state.open || state.overlay_node == 0 { return }
	rt := ctx.runtime
	for {
		event, found := ui.interaction_event_next(ctx, state.overlay_node)
		if !found { break }
		if event.kind == .Pointer {
			x, y := event.pointer.x, event.pointer.y
			bounds := state.panel_bounds
			if event.pointer.kind == .Down && !(x >= bounds.x && y >= bounds.y && x <= bounds.x+bounds.w && y <= bounds.y+bounds.h) {
				select_parts_close(ctx, state, .Trigger)
				continue
			}
			continue
		}
		if event.kind != .Key { continue }
		if state.typeahead_pending {
			state.typeahead_pending = false
			if index := select_parts_typeahead_match(groups, state.active_index, string(state.typeahead[:state.typeahead_length])); index >= 0 {
				_ = select_parts_set_active(rt, state, groups, index)
			}
		}
		#partial switch event.key {
		case .Up:
			if index := select_parts_next_enabled(groups, state.active_index, -1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index) }
		case .Down:
			if index := select_parts_next_enabled(groups, state.active_index, 1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index) }
		case .Home:
			if index := select_parts_first_enabled(groups); index >= 0 { _ = select_parts_set_active(rt, state, groups, index) }
		case .End:
			if index := select_parts_next_enabled(groups, 0, -1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index) }
		case .Escape:
			select_parts_close(ctx, state, .Trigger)
		case .Return, .Toggle:
			_ = select_parts_activate_active(rt, state, groups, ctx)
		case:
		}
	}
}

// select_parts_text receives committed generic text input from the focused
// option row. It owns its own bounded type-ahead buffer. A bare space with an
// empty buffer maps to activation for parity with stock Select's Space key.
select_parts_text :: proc(
	rt: ^alicorn.Runtime,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	text: string,
) -> bool {
	if rt == nil || state == nil || !state.open || len(text) == 0 { return false }
	if text == " " && state.typeahead_length == 0 {
		// Space is delivered as text input because option rows are generic text
		// targets. Treat it as activation only when it cannot begin a prefix.
		ctx := ui.UI{runtime=rt}
		return select_parts_activate_active(rt, state, groups, &ctx)
	}
	candidate: [TYPEAHEAD_CAPACITY]u8
	candidate_length := state.typeahead_length
	for index in 0..<state.typeahead_length { candidate[index] = state.typeahead[index] }
	copy_count := min(len(text), TYPEAHEAD_CAPACITY-candidate_length)
	for index in 0..<copy_count { candidate[candidate_length+index] = text[index] }
	candidate_length += copy_count
	prefix := string(candidate[:candidate_length])
	if select_parts_typeahead_match(groups, -1, prefix) < 0 {
		// A failed extension resets to the new committed text, matching the
		// stock prefix restart behavior.
		candidate_length = min(len(text), TYPEAHEAD_CAPACITY)
		for index in 0..<candidate_length { candidate[index] = text[index] }
		prefix = string(candidate[:candidate_length])
	}
	state.typeahead_length = candidate_length
	state.typeahead_pending = true
	if index := select_parts_typeahead_match(groups, state.active_index, prefix); index >= 0 {
		_ = select_parts_set_active(rt, state, groups, index)
	}
	alicorn.invalidate_root(rt, "select parts type-ahead input")
	return true
}

// select_parts_text_key receives normalized editing keys for the focused
// option row. Tab closes and asks the after-frame hook to continue ordinary
// focus traversal once the retiring popup is reconciled away.
select_parts_text_key :: proc(
	rt: ^alicorn.Runtime,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	if rt == nil || state == nil || !state.open { return false }
	ctx := ui.UI{runtime=rt}
	#partial switch event.key {
	case .Tab:
		select_parts_close(&ctx, state, .Next if !event.shift else .Previous)
		return true
	case .Home:
		if index := select_parts_first_enabled(groups); index >= 0 { _ = select_parts_set_active(rt, state, groups, index); return true }
	case .End:
		if index := select_parts_next_enabled(groups, 0, -1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index); return true }
	case .Up:
		if index := select_parts_next_enabled(groups, state.active_index, -1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index); return true }
	case .Down:
		if index := select_parts_next_enabled(groups, state.active_index, 1); index >= 0 { _ = select_parts_set_active(rt, state, groups, index); return true }
	case:
	}
	return false
}

@(private)
select_parts_role_color :: proc(recipe: Select_Parts_Recipe, role: alicorn.Style_Extension_Color_Role_ID, fallback: alicorn.Style_Color_Role) -> alicorn.Semantic_Surface_Color_Role {
	if role != 0 { return alicorn.surface_extension_color_role(role) }
	return fallback
}

@(private)
select_parts_trigger_visual :: proc(
	ctx: ^ui.UI,
	owner: alicorn.Node_ID,
	recipe: Select_Parts_Recipe,
	selected: ^Select_Parts_Option,
	placeholder: string,
) {
	display_label := placeholder
	icon_id := alicorn.Icon_ID.None
	badge := ""
	if selected != nil {
		display_label = selected.label
		icon_id = selected.icon
		badge = selected.badge
	}
	focus_radius := recipe.trigger_height*0.5
	frame := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, recipe.focus_role, .Focus),
		key=ui.key_u64(1),
		style=ui.layout_style(.Row, width=-1, height=-1, padding=2),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=focus_radius+2},
		label="select-parts-trigger-focus",
	)
	if frame == 0 { return }
	_ = alicorn.visual_part_attach(ctx, frame, owner, alicorn.visual_part_core(.Focus_Indicator), .Owner_Focus_Visible)
	face := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, recipe.trigger_role, .Surface),
		key=ui.key_u64(2),
		style=ui.layout_style(.Row, width=-1, height=-1, padding=10, gap=8, align=.Center),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=focus_radius},
		label="select-parts-trigger-face",
	)
	if face == 0 { alicorn.surface_end(ctx); return }
	_ = alicorn.visual_part_attach(ctx, face, owner, alicorn.visual_part_core(.Surface))
	if recipe.appearance == .Rich && icon_id != .None {
		if icon_surface := alicorn.surface_begin(
			ctx,
			select_parts_role_color(recipe, recipe.accent_role, .Accent),
			key=ui.key_u64(3),
			style=ui.layout_style(.Row, width=28, height=28, align=.Center, justify=.Center),
			shape=alicorn.surface_shape_circle(),
			label="select-parts-trigger-icon-surface",
		); icon_surface != 0 {
			_ = alicorn.visual_part_attach(ctx, icon_surface, owner, alicorn.visual_part_core(.Overlay))
			_ = ui.icon(ctx, icon_id, key=ui.key_u64(4), size=16, color_role=.Text)
			alicorn.surface_end(ctx)
		}
	}
	label_style := alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, font_size=14 if recipe.appearance == .Compact else 16}
	label_id := ui.text(ctx, display_label, key=ui.key_u64(5),
		style=ui.layout_style(.Row, width=-1, height=recipe.trigger_height-4),
		text_style=label_style, decorative=true)
	if label_id != 0 { _ = alicorn.visual_part_attach(ctx, label_id, owner, alicorn.visual_part_core(.Label)) }
	if recipe.appearance == .Rich && len(badge) > 0 && recipe.badge_role != 0 {
		if badge_surface := alicorn.surface_begin(
			ctx,
			select_parts_role_color(recipe, recipe.badge_role, .Accent),
			key=ui.key_u64(6),
			style=ui.layout_style(.Row, width=alicorn.LAYOUT_SIZE_FIT_CONTENT, height=20, padding=6, align=.Center),
			shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=10},
			label="select-parts-trigger-badge",
		); badge_surface != 0 {
			_ = alicorn.visual_part_attach(ctx, badge_surface, owner, alicorn.visual_part_core(.Overlay))
			_ = ui.text(ctx, badge, key=ui.key_u64(7), size=10, decorative=true)
			alicorn.surface_end(ctx)
		}
	}
	_ = ui.icon(ctx, .Chevron_Down, key=ui.key_u64(8), size=14, color_role=.Muted_Text)
	alicorn.surface_end(ctx)
	alicorn.surface_end(ctx)
}

@(private)
select_parts_row_visual :: proc(
	ctx: ^ui.UI,
	owner: alicorn.Node_ID,
	recipe: Select_Parts_Recipe,
	option: ^Select_Parts_Option,
	selected: bool,
	disabled: bool,
) {
	selected_role := select_parts_role_color(recipe, recipe.row_selected_role, .Selection)
	row_height := recipe.row_height
	radius := f32(7)
	focus := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, recipe.focus_role, .Focus),
		key=ui.key_u64(1),
		style=ui.layout_style(.Row, width=-1, height=-1, padding=2),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=radius+1},
		label="select-parts-row-focus",
	)
	if focus == 0 { return }
	_ = alicorn.visual_part_attach(ctx, focus, owner, alicorn.visual_part_core(.Focus_Indicator), .Owner_Focus_Visible)

	background_role := recipe.popup_role
	if selected { background_role = recipe.row_selected_role }
	face := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, background_role, .Surface),
		key=ui.key_u64(2),
		style=ui.layout_style(.Row, width=-1, height=row_height-2, padding=10, gap=9, align=.Center),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=radius},
		label="select-parts-row-face",
	)
	if face == 0 { alicorn.surface_end(ctx); return }
	_ = alicorn.visual_part_attach(ctx, face, owner, alicorn.visual_part_core(.Surface))
	hover := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, recipe.row_hover_role, .Subtle_Surface),
		key=ui.key_u64(3),
		style=ui.layout_style(.Row, width=-1, height=row_height-2),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=radius},
		label="select-parts-row-hover",
	)
	if hover != 0 {
		_ = alicorn.visual_part_attach(ctx, hover, owner, alicorn.visual_part_core(.Overlay), .Owner_Hovered)
		alicorn.surface_end(ctx)
	}

	if recipe.appearance == .Rich && option.icon != .None {
		icon_surface := alicorn.surface_begin(
			ctx,
			select_parts_role_color(recipe, recipe.accent_role, .Accent),
			key=ui.key_u64(4),
			style=ui.layout_style(.Row, width=26, height=26, align=.Center, justify=.Center),
			shape=alicorn.surface_shape_circle(),
			label="select-parts-row-icon",
		)
		if icon_surface != 0 {
			_ = alicorn.visual_part_attach(ctx, icon_surface, owner, alicorn.visual_part_core(.Label))
			_ = ui.icon(ctx, option.icon, key=ui.key_u64(5), size=15, color_role=.Text)
			alicorn.surface_end(ctx)
		}
	}
	text_color := alicorn.style_color(ctx, .Text)
	if disabled { text_color = alicorn.style_color(ctx, .Muted_Text) }
	text_style := alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, font_size=13 if recipe.appearance == .Compact else 14}
	_ = ui.text(ctx, option.label, key=ui.key_u64(6),
		style=ui.layout_style(.Row, width=-1, height=row_height-4),
		color=text_color, text_style=text_style, decorative=true)
	if recipe.appearance == .Rich && len(option.badge) > 0 && recipe.badge_role != 0 {
		if badge_surface := alicorn.surface_begin(
			ctx,
			select_parts_role_color(recipe, recipe.badge_role, .Accent),
			key=ui.key_u64(7),
			style=ui.layout_style(.Row, width=alicorn.LAYOUT_SIZE_FIT_CONTENT, height=19, padding=6, align=.Center),
			shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=9},
			label="select-parts-row-badge",
		); badge_surface != 0 {
			_ = ui.text(ctx, option.badge, key=ui.key_u64(8), size=10, decorative=true)
			alicorn.surface_end(ctx)
		}
	}
	if selected {
		_ = ui.icon(ctx, .Check, key=ui.key_u64(9), size=14, color_role=.Text)
	}
	alicorn.surface_end(ctx)
	alicorn.surface_end(ctx)
}

@(private)
select_parts_row :: proc(
	ctx: ^ui.UI,
	state: ^Select_Parts_State,
	recipe: Select_Parts_Recipe,
	groups: []Select_Parts_Group,
	collection: alicorn.Semantic_Collection_Handle,
	row: Select_Parts_Row,
	row_index, option_index: int,
	instance_id: u64,
) -> bool {
	if row.option < 0 {
		group := groups[row.group]
		if len(group.label) == 0 { return false }
		header_key := ui.key_pair(u64(0x47525048), u64(row.group+1))
		header := ui.text(
			ctx,
			group.label,
			key=header_key,
			style=ui.layout_style(.Row, width=-1, height=recipe.row_height, padding=10, align=.Center),
			color=alicorn.style_color(ctx, .Muted_Text),
			text_style=alicorn.Text_Style{font_size=11, font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
			decorative=true,
		)
		if header == 0 { return false }
		_ = alicorn.semantic_collection_item(ctx, collection, u64(max(option_index, 0)), alicorn.Semantic_Node_Description{
			id=select_parts_group_id(instance_id, row.group),
			role=.Group,
			label=group.label,
			value=group.label,
			parent=state.list_semantic_id,
		})
		return false
	}

	option, group_index, found := select_parts_option_at(groups, row.option)
	if !found { return false }
	group := groups[group_index]
	disabled := option.disabled || group.disabled
	selected := option.key == state.selected_key
	owner, activated := alicorn.button_begin(
		ctx,
		option.label,
		key=ui.key_pair(u64(0x4F505452), option.key),
		style=ui.layout_style(.Row, width=-1, height=recipe.row_height),
		state=alicorn.Button_State{selected=selected, disabled=disabled},
		content_style=alicorn.button_content_style(.Start, .Center, padding_x=0, padding_y=0),
		presentation=.Custom,
	)
	if owner == 0 { return false }
	state.option_nodes[row.option] = owner
	state.option_row[row.option] = row_index
	if !disabled { _ = alicorn.text_input_target(ctx, owner) }
	parent := alicorn.Semantic_ID{}
	if len(group.label) > 0 { parent = select_parts_group_id(instance_id, group_index) }
	states := alicorn.Semantic_States{}
	actions := alicorn.Semantic_Actions{}
	if selected { states = alicorn.semantic_states_add(states, .Selected) }
	if disabled {
		states = alicorn.semantic_states_add(states, .Disabled)
	} else {
		actions = alicorn.semantic_actions_add(actions, .Select)
		actions = alicorn.semantic_actions_add(actions, .Focus)
	}
	_ = alicorn.semantic_collection_item(ctx, collection, u64(row.option), alicorn.Semantic_Node_Description{
		id=select_parts_option_id(instance_id, option.key),
		role=.List_Box_Option,
		label=option.label,
		value=option.label,
		parent=parent,
		states=states,
		actions=actions,
		visual_node=owner,
	})
	select_parts_row_visual(ctx, owner, recipe, option, selected, disabled)
	alicorn.button_end(ctx)
	if activated && !disabled {
		changed := option.key != state.selected_key
		state.selected_key = option.key
		state.active_key = option.key
		state.active_index = row.option
		if changed {
			state.changed_pending = true
			state.changed_key = option.key
			state.changed_trigger = state.trigger_node
		}
		select_parts_close(ctx, state, .Trigger)
		return true
	}
	return false
}

// select_parts describes the trigger and reports whether the application
// should adopt a new controlled selection. It must be called inside the
// ordinary root scope. Pair it with select_parts_overlay rendered through the
// host's render_overlays callback after the ordinary root closes.
select_parts :: proc(
	ctx: ^ui.UI,
	label: string,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	recipe: Select_Parts_Recipe,
	key: ui.UI_Key,
	instance_id: u64,
) -> bool {
	if ctx == nil || ctx.runtime == nil || !ctx.runtime.frame_open || state == nil ||
		instance_id == 0 || instance_id > MAX_INSTANCE_ID || !select_parts_recipe_valid(recipe) {
		return false
	}
	rt := ctx.runtime
	if state.open {
		modal_root := alicorn.modal_overlay_root(rt)
		if modal_root != 0 && modal_root != state.overlay_node {
			select_parts_close(ctx, state, .Trigger)
		}
	}
	valid := select_parts_groups_valid(groups)
	option_count := select_parts_groups_option_count(groups)
	selected_index, _, _, selected_found := select_parts_find_key(groups, state.selected_key)
	if option_count > 0 && !selected_found { valid = false }
	disabled := !valid || option_count == 0 || !select_parts_groups_has_enabled(groups)
	display_label := label
	if selected_found {
		if selected_label, found := select_parts_option_label(groups, state.selected_key); found { display_label = selected_label }
	}

	if !alicorn.key_scope_begin(ctx, key) { return false }
	defer alicorn.key_scope_end(ctx)
	select_parts_process_input(ctx, state, groups)
	if !state.open && state.pending_focus != .None {
		_ = ui.after_frame(ctx, state, select_parts_after_frame)
	}
	changed := false
	if state.changed_pending && state.changed_trigger == state.trigger_node {
		changed = true
		state.changed_pending = false
		state.changed_trigger = 0
	}
	trigger, activated := alicorn.button_begin(
		ctx,
		display_label,
		key=ui.key_u64(1),
		style=ui.layout_style(.Row, width=recipe.trigger_width, height=recipe.trigger_height),
		state=alicorn.Button_State{disabled=disabled},
		content_style=alicorn.button_content_style(.Start, .Center, padding_x=0, padding_y=0),
		presentation=.Custom,
	)
	if trigger == 0 { return changed }
	state.instance_id = instance_id
	state.trigger_node = trigger
	state.trigger_semantic_id = select_parts_trigger_id(instance_id)
	state.list_semantic_id = select_parts_list_id(instance_id)
	state.style_environment = rt.style_environment
	if info, ok := alicorn.node_info(rt, trigger); ok { state.anchor = info.bounds }
	state.viewport = rt.viewport
	states := alicorn.Semantic_States{}
	actions := alicorn.Semantic_Actions{}
	if !disabled {
		actions = alicorn.semantic_actions_add(actions, .Focus)
		if state.open {
			states = alicorn.semantic_states_add(states, .Expanded)
			actions = alicorn.semantic_actions_add(actions, .Collapse)
		} else {
			actions = alicorn.semantic_actions_add(actions, .Expand)
		}
	}
	_ = alicorn.semantic_description(ctx, .Combo_Box, label, value=display_label, states=states, actions=actions)
	_ = alicorn.semantic_bind(ctx, state.trigger_semantic_id)
	selected_option: Select_Parts_Option
	selected_ptr: ^Select_Parts_Option
	if selected_found {
		option, _, found := select_parts_option_at(groups, selected_index)
		if found {
			selected_option = option^
			selected_ptr = &selected_option
		}
	}
	select_parts_trigger_visual(ctx, trigger, recipe, selected_ptr, label)
	alicorn.button_end(ctx)

	if activated && !disabled {
		if state.open {
			select_parts_close(ctx, state, .Trigger)
		} else if alicorn.modal_overlay_root(rt) == 0 && option_count > 0 {
			state.open = true
			state.just_opened = true
			state.focus_retry = 0
			state.reveal_pending = true
			if state.overlay_node != 0 { state.panel_bounds = {} }
			state.typeahead_length = 0
			state.typeahead_pending = false
			if info, ok := alicorn.node_info(rt, trigger); ok { state.anchor = info.bounds }
			state.viewport = rt.viewport
			index := select_parts_active_index(state, groups)
			if index < 0 { index = selected_index }
			if index >= 0 {
				option, _, found := select_parts_option_at(groups, index)
				if found {
					state.active_index = index
					state.active_key = option.key
				}
			}
			_ = ui.after_frame(ctx, state, select_parts_open_after_frame)
		}
	}
	if state.open && (disabled || !valid || option_count == 0) {
		select_parts_close(ctx, state, .Trigger)
	}
	return changed
}

@(private)
select_parts_groups_has_enabled :: proc(groups: []Select_Parts_Group) -> bool {
	for group in groups {
		for option in group.options { if !option.disabled && !group.disabled { return true } }
	}
	return false
}

// select_parts_overlay must be called from the host's render_overlays hook
// after the ordinary root has closed. It is a no-op for a closed state.
select_parts_overlay :: proc(
	ctx: ^ui.UI,
	label: string,
	state: ^Select_Parts_State,
	groups: []Select_Parts_Group,
	recipe: Select_Parts_Recipe,
	instance_id: u64,
) -> bool {
	if ctx == nil || ctx.runtime == nil || state == nil || !state.open { return false }
	modal_root := alicorn.modal_overlay_root(ctx.runtime)
	if (modal_root != 0 && modal_root != state.overlay_node) || select_parts_foreign_modal_pending(ctx, state) {
		select_parts_close(ctx, state, .None)
		alicorn.invalidate_root(ctx.runtime, "select parts closed below a foreign modal layer")
		return false
	}
	if !select_parts_recipe_valid(recipe) || !select_parts_groups_valid(groups) { return false }
	option_count := select_parts_groups_option_count(groups)
	if option_count == 0 { return false }
	rt := ctx.runtime

	row_count := 0
	rows: [MAX_ROWS]Select_Parts_Row
	flat_index := 0
	for group, group_index in groups {
		if len(group.options) == 0 { continue }
		if len(group.label) > 0 {
			rows[row_count] = Select_Parts_Row{group=group_index, option=-1}
			row_count += 1
		}
		for option in group.options {
			rows[row_count] = Select_Parts_Row{group=group_index, option=flat_index}
			row_count += 1
			flat_index += 1
		}
	}
	if row_count <= 0 { return false }

	row_height := recipe.row_height
	content_height := f32(row_count)*row_height+2*POPUP_PADDING
	max_height := f32(recipe.max_visible_rows)*row_height+2*POPUP_PADDING
	max_height = min(max_height, max(rt.viewport.h-2*VIEWPORT_MARGIN, row_height))
	panel_height := min(content_height, max_height)
	placement := alicorn.context_menu_placement(rt.viewport, state.anchor, recipe.popup_width, panel_height)
	if placement.h <= 0 || placement.w <= 0 { return false }

	state.option_nodes = {}
	state.option_row = {}
	state.overlay_node = 0
	state.panel_node = 0
	state.viewport = rt.viewport

	overlay := alicorn.modal_overlay_begin(
		ctx,
		key=ui.key_pair(instance_id, 0x53454C50415254),
		style=ui.layout_style(.Column, width=-1, height=-1),
		backdrop_color=alicorn.Color{0.01, 0.015, 0.025, 0.32},
	)
	if overlay == 0 { return false }
	state.overlay_node = overlay
	environment_scope := alicorn.style_environment_push(ctx, state.style_environment)
	defer alicorn.style_environment_pop(ctx, environment_scope)

	keys := alicorn.Interaction_Key_Set{.Up, .Down, .Home, .End, .Escape, .Return, .Toggle}
	_ = ui.interaction_scope(ctx, overlay, state, alicorn.Interaction_Scope_Options{
		keys=keys,
		composition_yield_keys=keys,
		pointers={.Primary_Down},
		modal=true,
	})

	top := placement.y
	if top > 0 {
		if ui.row(ctx, key=ui.key_u64(0x5350414345), width=-1, height=top, label="select-parts-y-spacer") {}
	}
	if ui.row(ctx, key=ui.key_u64(0x524F57), width=-1, height=placement.h, align=.Start, label="select-parts-placement-row") {
		if placement.x > 0 {
			if ui.column(ctx, key=ui.key_u64(0x585350414345), width=placement.x, height=placement.h, label="select-parts-x-spacer") {}
		}
		state.panel_node = select_parts_overlay_panel(
			ctx, state, label, groups, recipe, placement, rows[:row_count], instance_id,
		)
	}
	alicorn.modal_overlay_end(ctx)
	return state.panel_node != 0
}

// select_parts_foreign_modal_pending detects a modal layer described earlier
// in the same frame. A top-level scan alone is insufficient because retained
// top-level state advances only during reconciliation.
@(private)
select_parts_foreign_modal_pending :: proc(ctx: ^ui.UI, state: ^Select_Parts_State) -> bool {
	if ctx == nil || ctx.runtime == nil { return false }
	for index := len(ctx.runtime.pending)-1; index >= 0; index -= 1 {
		item := ctx.runtime.pending[index]
		if item.kind == .Description && item.description.kind == .Modal_Overlay &&
			(state == nil || item.description.id != state.overlay_node) {
			return true
		}
	}
	return false
}

// select_parts_set_collection_parent is the pilot's one direct pending-record
// patch. The public semantic collection API can attach items to a collection,
// but it cannot name the collection's own semantic parent. Stock Select patches
// the same pending record internally. This helper is deliberately isolated and
// recorded as a core requirement candidate in the pilot validation.
@(private)
select_parts_set_collection_parent :: proc(ctx: ^ui.UI, collection_id, parent_id: alicorn.Semantic_ID) {
	if ctx == nil || ctx.runtime == nil || !alicorn.semantic_id_is_valid(collection_id) || !alicorn.semantic_id_is_valid(parent_id) { return }
	for index := len(ctx.runtime.pending)-1; index >= 0; index -= 1 {
		item := &ctx.runtime.pending[index]
		if item.kind == .Description && item.description.semantic_id == collection_id {
			item.semantic.parent = parent_id
			return
		}
	}
}

@(private)
select_parts_overlay_panel :: proc(
	ctx: ^ui.UI,
	state: ^Select_Parts_State,
	label: string,
	groups: []Select_Parts_Group,
	recipe: Select_Parts_Recipe,
	placement: alicorn.Rect,
	rows: []Select_Parts_Row,
	instance_id: u64,
) -> alicorn.Node_ID {
	if ctx == nil || ctx.runtime == nil || state == nil { return 0 }
	rt := ctx.runtime
	option_count := select_parts_groups_option_count(groups)
	row_height := recipe.row_height
	panel := alicorn.surface_begin(
		ctx,
		select_parts_role_color(recipe, recipe.popup_role, .Surface),
		key=ui.key_pair(instance_id, 0x50414E454C),
		style=ui.layout_style(.Column, width=placement.w, height=placement.h, padding=POPUP_PADDING),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=10},
		label="select-parts-popup",
	)
	if panel == 0 { return 0 }
	state.panel_node = panel
	state.panel_bounds = placement
	selected_id := select_parts_option_id(instance_id, state.selected_key)
	active_id := select_parts_option_id(instance_id, state.active_key)
	collection := alicorn.semantic_collection_begin(
		ctx,
		panel,
		state.list_semantic_id,
		.List_Box,
		label,
		u64(option_count),
		selected_id=selected_id,
		current_id=active_id,
		realized_first=0,
		realized_last=u64(option_count),
		actions=alicorn.semantic_actions_add({}, .Focus),
	)
	select_parts_set_collection_parent(ctx, state.list_semantic_id, state.trigger_semantic_id)
	list_height := max(placement.h-2*POPUP_PADDING, row_height)
	list := alicorn.virtual_list_begin(
		ctx,
		len(rows),
		row_height,
		key=ui.key_pair(instance_id, 0x4F505453),
		style=ui.layout_style(.Column, width=-1, height=list_height, clip=true),
		label="select-parts-options",
		axes=.Vertical,
		scrollbars=.Auto,
	)
	if list.scroll.id == 0 {
		alicorn.surface_end(ctx)
		return 0
	}
	state.scroll_node = list.scroll.id
	for row_index in list.first..<list.last {
		row := rows[row_index]
		_ = select_parts_row(ctx, state, recipe, groups, collection, row, row_index, row.option, instance_id)
	}
	alicorn.virtual_list_end(ctx, list)

	active_index := select_parts_active_index(state, groups)
	if active_index >= 0 {
		state.active_index = active_index
		if option, _, found := select_parts_option_at(groups, active_index); found { state.active_key = option.key }
		if state.reveal_pending || state.typeahead_pending {
			if _, retained := rt.nodes[state.scroll_node]; retained {
				_ = alicorn.virtual_list_ensure_visible(rt, state.scroll_node, state.option_row[active_index], "select parts active option revealed")
				state.reveal_pending = false
				state.typeahead_pending = false
			}
		}
	}
	alicorn.surface_end(ctx)
	return panel
}
