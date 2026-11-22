#+build !js
package ui

import "core:testing"
import alicorn "alicorn:runtime"

// This fixture sketches the two compound components AliKit will own: a radio
// group and a table. Both are ordinary application-authored surfaces that use
// the public semantic collection APIs; Alicorn supplies focus, activation,
// naming, and projection.

SEMANTIC_COMPOUND_NAMESPACE :: u64(0x554953454D434F01)
SEMANTIC_COMPOUND_RADIO_GROUP :: u64(0x10)
SEMANTIC_COMPOUND_RADIO_BASE :: u64(0x20)
SEMANTIC_COMPOUND_TABLE :: u64(0x40)
SEMANTIC_COMPOUND_HEADER_ROW :: u64(0x41)
SEMANTIC_COMPOUND_BODY_ROW :: u64(0x42)
SEMANTIC_COMPOUND_HEADER_BASE :: u64(0x50)
SEMANTIC_COMPOUND_CELL_BASE :: u64(0x60)

Semantic_Compound_State :: struct {
	selected: int,
	activated: int,
}

semantic_compound_id :: proc(value: u64) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=SEMANTIC_COMPOUND_NAMESPACE, value=value}
}

semantic_compound_describe :: proc(rt: ^alicorn.Runtime, state: ^Semantic_Compound_State) {
	alicorn.invalidate_root(rt, "semantic compound fixture")
	ui, build := alicorn.begin_frame(rt)
	if !build { return }
	root := alicorn.container_begin_simple(
		&ui, .Root, label="semantic-compound-root", key=alicorn.key_string("semantic-compound-root"),
		style=alicorn.layout_style(.Column, width=520, height=360, gap=8, padding=8),
	)
	if root != 0 {
		semantic_compound_describe_radios(&ui, state)
		semantic_compound_describe_table(&ui)
		alicorn.container_end(&ui)
	}
	alicorn.end_frame(&ui)
}

semantic_compound_describe_radios :: proc(ui: ^UI, state: ^Semantic_Compound_State) {
	group_node := alicorn.container_begin_simple(
		ui, .Container, label="semantic-compound-radio-group",
		key=alicorn.key_string("semantic-compound-radio-group"),
		style=alicorn.layout_style(.Row, width=460, height=32, gap=8),
	)
	if group_node == 0 { return }
	group_id := semantic_compound_id(SEMANTIC_COMPOUND_RADIO_GROUP)
	labels := [3]string{"Small", "Medium", "Large"}
	selected_id := semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE+u64(state.selected))
	group := alicorn.semantic_collection_begin(
		ui, group_node, group_id, .Radio_Group, "Size", u64(len(labels)),
		selected_id=selected_id, realized_last=u64(len(labels)),
	)
	for label, index in labels {
		id := semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE+u64(index))
		node, activated := alicorn.button_begin(
			ui, label, key=alicorn.key_u64(SEMANTIC_COMPOUND_RADIO_BASE+u64(index)),
			style=alicorn.layout_style(width=140, height=28),
		)
		if node != 0 {
			states := alicorn.Semantic_States{}
			if index == state.selected { states = alicorn.semantic_states_add(states, .Checked) }
			actions := alicorn.semantic_actions_add(alicorn.semantic_actions_add({}, .Press), .Focus)
			_ = alicorn.semantic_collection_item(ui, group, u64(index), alicorn.Semantic_Node_Description{
				id=id,
				role=.Radio_Button,
				label=label,
				states=states,
				actions=actions,
			})
			if activated { state.activated = index }
		}
		alicorn.button_end(ui)
	}
	alicorn.container_end(ui)
}

semantic_compound_describe_table :: proc(ui: ^UI) {
	table_node := alicorn.container_begin_simple(
		ui, .Container, label="semantic-compound-table",
		key=alicorn.key_string("semantic-compound-table"),
		style=alicorn.layout_style(.Column, width=460, height=80, gap=2),
	)
	if table_node == 0 { return }
	table_id := semantic_compound_id(SEMANTIC_COMPOUND_TABLE)
	table := alicorn.semantic_collection_begin(
		ui, table_node, table_id, .Table, "Scores", 2, realized_last=2,
	)

	header_row_id := semantic_compound_id(SEMANTIC_COMPOUND_HEADER_ROW)
	header_row_node := alicorn.container_begin_simple(
		ui, .Container, label="semantic-compound-header-row",
		key=alicorn.key_string("semantic-compound-header-row"),
		style=alicorn.layout_style(.Row, width=460, height=28),
	)
	header_row := alicorn.semantic_collection_begin(
		ui, header_row_node, header_row_id, .Table_Row, "Columns", 2,
		realized_last=2, parent=table_id,
	)
	_ = alicorn.semantic_collection_item(ui, table, 0, alicorn.Semantic_Node_Description{
		id=header_row_id, role=.Table_Row, label="Columns", parent=table_id,
	})
	for label, index in ([2]string{"Name", "Score"}) {
		_ = alicorn.container_begin_simple(
			ui, .Container, label="semantic-compound-column-header",
			key=alicorn.key_u64(0x1400+u64(index)),
			style=alicorn.layout_style(.Row, width=180, height=28),
		)
		_ = alicorn.semantic_collection_item(ui, header_row, u64(index), alicorn.Semantic_Node_Description{
			id=semantic_compound_id(SEMANTIC_COMPOUND_HEADER_BASE+u64(index)),
			role=.Table_Column_Header,
			label=label,
			value=label,
			parent=header_row_id,
		})
		alicorn.container_end(ui)
	}
	alicorn.container_end(ui)

	body_row_id := semantic_compound_id(SEMANTIC_COMPOUND_BODY_ROW)
	body_row_node := alicorn.container_begin_simple(
		ui, .Container, label="semantic-compound-body-row",
		key=alicorn.key_string("semantic-compound-body-row"),
		style=alicorn.layout_style(.Row, width=460, height=28),
	)
	body_row := alicorn.semantic_collection_begin(
		ui, body_row_node, body_row_id, .Table_Row, "", 2,
		realized_last=2, parent=table_id,
	)
	_ = alicorn.semantic_collection_item(ui, table, 1, alicorn.Semantic_Node_Description{
		id=body_row_id, role=.Table_Row, parent=table_id,
	})
	for label, index in ([2]string{"Ada", "42"}) {
		_ = alicorn.container_begin_simple(
			ui, .Container, label="semantic-compound-cell",
			key=alicorn.key_u64(0x1500+u64(index)),
			style=alicorn.layout_style(.Row, width=180, height=28),
		)
		cell_role := alicorn.Semantic_Role.Table_Cell
		if index == 0 { cell_role = .Table_Row_Header }
		_ = alicorn.semantic_collection_item(ui, body_row, u64(index), alicorn.Semantic_Node_Description{
			id=semantic_compound_id(SEMANTIC_COMPOUND_CELL_BASE+u64(index)),
			role=cell_role,
			label=label,
			value=label,
			parent=body_row_id,
		})
		alicorn.container_end(ui)
	}
	alicorn.container_end(ui)
	alicorn.container_end(ui)
}

@(test)
test_semantic_compound_fixture_publishes_radio_group_and_table :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 520, 360})
	defer alicorn.destroy_runtime(&rt)
	state := Semantic_Compound_State{selected=1, activated=-1}

	alicorn.invalidate_root(&rt, "semantic compound fixture")
	semantic_compound_describe(&rt, &state)

	group_id := semantic_compound_id(SEMANTIC_COMPOUND_RADIO_GROUP)
	group, group_found := alicorn.semantic_node_lookup(&rt, group_id)
	if !testing.expect(t, group_found && group.role == .Radio_Group && group.is_collection &&
		group.logical_count == 3 && group.selected_id == semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE+1),
		"the fixture should describe a three-option radio group with a selected radio") { return }

	first, first_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE))
	second, second_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE+1))
	testing.expect(t, first_found && first.role == .Radio_Button && first.parent == group_id &&
		first.collection_id == group_id && first.position_in_set == 0 &&
		!alicorn.semantic_states_has(first.states, .Checked) &&
		second_found && second.role == .Radio_Button && second.parent == group_id &&
		second.position_in_set == 1 && alicorn.semantic_states_has(second.states, .Checked) &&
		alicorn.semantic_actions_has(second.actions, .Press),
		"radios should publish explicit roles, positions, checked state, and Press")

	table, table_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_TABLE))
	header, header_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_HEADER_ROW))
	body, body_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_BODY_ROW))
	header_cell, header_cell_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_HEADER_BASE+1))
	row_header, row_header_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_CELL_BASE))
	body_cell, body_cell_found := alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_CELL_BASE+1))
	testing.expect(t, table_found && table.role == .Table && table.is_collection && table.logical_count == 2 &&
		header_found && header.role == .Table_Row && header.is_collection && header.parent == table.id &&
		header.position_in_set == 0 &&
		body_found && body.role == .Table_Row && body.is_collection && body.parent == table.id &&
		body.position_in_set == 1,
		"the fixture table should publish rows as child collections at row coordinates")
	testing.expect(t, header_cell_found && header_cell.role == .Table_Column_Header &&
		header_cell.parent == semantic_compound_id(SEMANTIC_COMPOUND_HEADER_ROW) &&
		header_cell.position_in_set == 1 &&
		row_header_found && row_header.role == .Table_Row_Header &&
		row_header.parent == semantic_compound_id(SEMANTIC_COMPOUND_BODY_ROW) &&
		body_cell_found && body_cell.role == .Table_Cell &&
		body_cell.parent == semantic_compound_id(SEMANTIC_COMPOUND_BODY_ROW) &&
		body_cell.position_in_set == 1,
		"column headers, row headers, and cells should nest under their rows at column coordinates")

	// Assistive technology presses the first radio. The controlled fixture
	// consumes activation on the next frame and moves selection.
	testing.expect(t, alicorn.semantic_action_request(&rt, semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE), .Press),
		"the published radio should accept a semantic Press")
	state.activated = -1
	semantic_compound_describe(&rt, &state)
	testing.expect(t, state.activated == 0,
		"the radio component should consume its one-shot activation like an ordinary Button")

	state.selected = state.activated
	semantic_compound_describe(&rt, &state)
	first, first_found = alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE))
	second, second_found = alicorn.semantic_node_lookup(&rt, semantic_compound_id(SEMANTIC_COMPOUND_RADIO_BASE+1))
	testing.expect(t, first_found && second_found &&
		alicorn.semantic_states_has(first.states, .Checked) &&
		!alicorn.semantic_states_has(second.states, .Checked),
		"re-describing the controlled selection should move checked state to the pressed radio")
}
