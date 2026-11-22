#+build !js
package alicorn

import "core:testing"

// Compound-role semantics: radio groups, progress, and tables use the same
// collection, parent, numeric-value, and action machinery as the existing
// controls. These tests keep the roles honest before AliKit builds components
// on top of them.

COMPOUND_NAMESPACE :: u64(0x53454D434F4D5001)
COMPOUND_RADIO_GROUP :: u64(0x10)
COMPOUND_RADIO_BASE :: u64(0x11)
COMPOUND_TABLE :: u64(0x20)
COMPOUND_HEADER_ROW :: u64(0x21)
COMPOUND_BODY_ROW :: u64(0x22)
COMPOUND_COLUMN_GROUP :: u64(0x23)
COMPOUND_HEADER_BASE :: u64(0x24)
COMPOUND_CELL_BASE :: u64(0x30)
COMPOUND_PROGRESS :: u64(0x40)
COMPOUND_ROLE_BASE :: u64(0x50)
COMPOUND_VIRTUAL_TABLE :: u64(0x60)

compound_id :: proc(value: u64) -> Semantic_ID {
	return Semantic_ID{namespace=COMPOUND_NAMESPACE, value=value}
}

compound_actions :: proc(actions: ..Semantic_Action) -> Semantic_Actions {
	result := Semantic_Actions{}
	for action in actions { result = semantic_actions_add(result, action) }
	return result
}

@(test)
test_compound_roles_publish_with_explicit_semantics :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 480, 320})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the compound-role fixture should build") { return }
	container_begin_simple(
		&ui, .Root, label="compound-root", key=key_string("compound-root"),
		style=layout_style(.Column, width=480, height=320, gap=4, padding=4),
	)
	roles := [8]Semantic_Role{
		.Radio_Button,
		.Radio_Group,
		.Progress,
		.Table,
		.Table_Row,
		.Table_Cell,
		.Table_Column_Header,
		.Table_Row_Header,
	}
	for role, index in roles {
		node := container_begin_simple(
			&ui, .Container, label="compound-role", key=key_u64(COMPOUND_ROLE_BASE+u64(index)),
			style=layout_style(.Row, height=20),
		)
		if node == 0 { continue }
		_ = semantic_describe_as(&ui, compound_id(COMPOUND_ROLE_BASE+u64(index)), role, "Explicit role")
		container_end(&ui)
	}
	progress_node := container_begin_simple(
		&ui, .Container, label="compound-progress", key=key_string("compound-progress"),
		style=layout_style(.Row, height=20),
	)
	if progress_node != 0 {
		published := semantic_describe_as(
			&ui,
			compound_id(COMPOUND_PROGRESS),
			.Progress,
			"Upload",
			value="42%",
			states=semantic_states_add({}, .Busy),
		)
		numeric := semantic_numeric_range(&ui, 0.42, 0, 1, 0.01)
		testing.expect(t, published && numeric,
			"a Progress description should accept the shared numeric range properties")
		container_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)

	for role, index in roles {
		node, found := semantic_node_lookup(&rt, compound_id(COMPOUND_ROLE_BASE+u64(index)))
		testing.expect(t, found && node.role == role,
			"each new semantic role should publish unchanged through an explicit description")
	}
	progress, progress_found := semantic_node_lookup(&rt, compound_id(COMPOUND_PROGRESS))
	testing.expect(t, progress_found && progress.role == .Progress && progress.label == "Upload" &&
		progress.value == "42%" && semantic_states_has(progress.states, .Busy) &&
		progress.has_numeric_value && progress.numeric_value == 0.42 &&
		progress.numeric_minimum == 0 && progress.numeric_maximum == 1 && progress.numeric_step == 0.01,
		"Progress should reuse the existing numeric value/minimum/maximum/step fields")
}

@(test)
test_compound_collection_validation_accepts_only_container_roles :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 480, 320})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the compound-collection fixture should build") { return }
	container_begin_simple(
		&ui, .Root, label="compound-collection-root", key=key_string("compound-collection-root"),
		style=layout_style(.Column, width=480, height=320, gap=4, padding=4),
	)

	accepted := [3]struct { role: Semantic_Role, id: u64 }{
		{.Radio_Group, COMPOUND_RADIO_GROUP},
		{.Table, COMPOUND_TABLE},
		{.Table_Row, COMPOUND_BODY_ROW},
	}
	for entry, index in accepted {
		node := container_begin_simple(
			&ui, .Container, label="accepted-collection", key=key_u64(0x6100+u64(index)),
			style=layout_style(.Column, height=40),
		)
		if node == 0 { continue }
		collection := semantic_collection_begin(
			&ui, node, compound_id(entry.id), entry.role, "Accepted", 1, realized_last=1,
		)
		testing.expect(t, collection.id == compound_id(entry.id) && collection.logical_count == 1,
			"a radio group, table, and table row should be accepted as collections")
		container_end(&ui)
	}

	rejected := [5]struct { role: Semantic_Role, id: u64 }{
		{.Radio_Button, 0x6200},
		{.Progress, 0x6201},
		{.Table_Cell, 0x6202},
		{.Table_Column_Header, 0x6203},
		{.Table_Row_Header, 0x6204},
	}
	for entry, index in rejected {
		node := container_begin_simple(
			&ui, .Container, label="rejected-collection", key=key_u64(0x6300+u64(index)),
			style=layout_style(.Column, height=24),
		)
		if node == 0 { continue }
		collection := semantic_collection_begin(
			&ui, node, compound_id(entry.id), entry.role, "Rejected", 1, realized_last=1,
		)
		testing.expect(t, collection == (Semantic_Collection_Handle{}),
			"non-container compound roles must not become collections")
		container_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)

	rejected_description := Semantic_Node_Description{
		id=compound_id(0x6400),
		role=.Table_Cell,
		label="Cell",
		is_collection=true,
		logical_count=1,
	}
	testing.expect(t, !semantic_node_set(&rt, rejected_description),
		"semantic_node_set must reject is_collection on a cell role")
}

@(test)
test_radio_button_press_routes_through_control_activation :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 200})
	defer destroy_runtime(&rt)
	radio_id := compound_id(COMPOUND_RADIO_BASE)

	describe :: proc(rt: ^Runtime, radio_id: Semantic_ID, press: bool) -> Node_ID {
		ui, build := begin_frame(rt)
		if !build { return 0 }
		container_begin_simple(
			&ui, .Root, label="compound-radio-root", key=key_string("compound-radio-root"),
			style=layout_style(.Column, width=320, height=200, gap=4, padding=4),
		)
		node, _ := button_begin(
			&ui, "Small", key=key_string("compound-radio-small"),
			style=layout_style(width=160, height=32),
		)
		actions := compound_actions(.Focus)
		if press { actions = semantic_actions_add(actions, .Press) }
		_ = semantic_describe_as(
			&ui, radio_id, .Radio_Button, "Small",
			states=semantic_states_add({}, .Checked),
			actions=actions,
		)
		button_end(&ui)
		container_end(&ui)
		end_frame(&ui)
		return node
	}

	radio_node := describe(&rt, radio_id, true)
	radio, found := semantic_node_lookup(&rt, radio_id)
	if !testing.expect(t, found && radio.role == .Radio_Button && radio.visual_node == radio_node &&
		semantic_states_has(radio.states, .Checked) && semantic_actions_has(radio.actions, .Press),
		"an explicitly published radio should retain role, checked state, and Press") { return }

	sequence := rt.activation_sequence
	testing.expect(t, semantic_action_request(&rt, radio_id, .Press),
		"a realized radio advertising Press should accept a semantic Press request")
	testing.expect(t, rt.activation_node == radio_node && rt.activation_sequence == sequence+1,
		"radio Press must route through the ordinary retained control activation path")

	// A radio that does not advertise Press must not be synthesizable.
	_ = describe(&rt, radio_id, false)
	rt.activation_node = 0
	testing.expect(t, !semantic_action_request(&rt, radio_id, .Press) && rt.activation_node == 0,
		"semantic Press must not activate a radio that did not advertise it")
}

@(test)
test_table_rows_and_cells_nest_through_collections_and_item_parents :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 400})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the compound-table fixture should build") { return }

	table_id := compound_id(COMPOUND_TABLE)
	header_row_id := compound_id(COMPOUND_HEADER_ROW)
	body_row_id := compound_id(COMPOUND_BODY_ROW)
	column_group_id := compound_id(COMPOUND_COLUMN_GROUP)

	container_begin_simple(
		&ui, .Root, label="compound-table-root", key=key_string("compound-table-root"),
		style=layout_style(.Column, width=640, height=400, gap=2, padding=4),
	)
	table_node := container_begin_simple(
		&ui, .Container, label="compound-table", key=key_string("compound-table"),
		style=layout_style(.Column, width=600, height=120, gap=2),
	)
	table := semantic_collection_begin(
		&ui, table_node, table_id, .Table, "Scores", 2, realized_last=2,
	)
	testing.expect(t, table.id == table_id,
		"the table collection owner should publish under the supplied semantic ID")

	// Header row: a Table_Row collection whose header cells group under a
	// semantic Group via item.parent while still belonging to the row collection.
	header_row_node := container_begin_simple(
		&ui, .Container, label="compound-header-row", key=key_string("compound-header-row"),
		style=layout_style(.Row, width=600, height=24),
	)
	header_row := semantic_collection_begin(
		&ui, header_row_node, header_row_id, .Table_Row, "Columns", 3, realized_last=3, parent=table_id,
	)
	_ = semantic_collection_item(&ui, table, 0, Semantic_Node_Description{
		id=header_row_id, role=.Table_Row, label="Columns", parent=table_id,
	})
	_ = container_begin_simple(
		&ui, .Container, label="compound-column-group", key=key_string("compound-column-group"),
		style=layout_style(.Row, width=240, height=24),
	)
	_ = semantic_collection_item(&ui, header_row, 0, Semantic_Node_Description{
		id=column_group_id, role=.Group, label="Columns", parent=header_row_id,
	})
	container_end(&ui)
	for label, index in ([2]string{"Name", "Score"}) {
		cell_node := container_begin_simple(
			&ui, .Container, label="compound-column-header", key=key_u64(0x6500+u64(index)),
			style=layout_style(.Row, width=120, height=24),
		)
		if cell_node == 0 { continue }
		_ = semantic_collection_item(&ui, header_row, u64(index)+1, Semantic_Node_Description{
			id=compound_id(COMPOUND_HEADER_BASE+u64(index)),
			role=.Table_Column_Header,
			label=label,
			value=label,
			parent=column_group_id,
		})
		container_end(&ui)
	}
	container_end(&ui)

	// Body row: a Table_Row collection with a row header and an ordinary cell.
	body_row_node := container_begin_simple(
		&ui, .Container, label="compound-body-row", key=key_string("compound-body-row"),
		style=layout_style(.Row, width=600, height=24),
	)
	body_row := semantic_collection_begin(
		&ui, body_row_node, body_row_id, .Table_Row, "", 2, realized_last=2, parent=table_id,
	)
	_ = semantic_collection_item(&ui, table, 1, Semantic_Node_Description{
		id=body_row_id, role=.Table_Row, parent=table_id,
	})
	for label, index in ([2]string{"Ada", "42"}) {
		cell_node := container_begin_simple(
			&ui, .Container, label="compound-body-cell", key=key_u64(0x6600+u64(index)),
			style=layout_style(.Row, width=120, height=24),
		)
		if cell_node == 0 { continue }
		cell_role := Semantic_Role.Table_Cell
		if index == 0 { cell_role = .Table_Row_Header }
		_ = semantic_collection_item(&ui, body_row, u64(index), Semantic_Node_Description{
			id=compound_id(COMPOUND_CELL_BASE+u64(index)),
			role=cell_role,
			label=label,
			value=label,
			parent=body_row_id,
		})
		container_end(&ui)
	}
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)

	table_node_semantic, table_found := semantic_node_lookup(&rt, table_id)
	testing.expect(t, table_found && table_node_semantic.role == .Table &&
		table_node_semantic.is_collection && table_node_semantic.logical_count == 2,
		"the table should publish as a collection with its logical row count")

	header_row_semantic, header_row_found := semantic_node_lookup(&rt, header_row_id)
	body_row_semantic, body_row_found := semantic_node_lookup(&rt, body_row_id)
	testing.expect(t, header_row_found && header_row_semantic.role == .Table_Row &&
		header_row_semantic.is_collection && header_row_semantic.parent == table_id &&
		header_row_semantic.position_in_set == 0 &&
		body_row_found && body_row_semantic.role == .Table_Row &&
		body_row_semantic.is_collection && body_row_semantic.parent == table_id &&
		body_row_semantic.position_in_set == 1,
		"rows should be Table_Row collections parented to the table at their row positions")

	group, group_found := semantic_node_lookup(&rt, column_group_id)
	first_header, first_header_found := semantic_node_lookup(&rt, compound_id(COMPOUND_HEADER_BASE))
	second_header, second_header_found := semantic_node_lookup(&rt, compound_id(COMPOUND_HEADER_BASE+1))
	testing.expect(t, group_found && group.role == .Group && group.parent == header_row_id &&
		group.collection_id == header_row_id && group.position_in_set == 0,
		"a header group should remain a row child while acting as a header-cell parent")
	testing.expect(t, first_header_found && first_header.role == .Table_Column_Header &&
		first_header.parent == column_group_id && first_header.collection_id == header_row_id &&
		first_header.position_in_set == 1 &&
		second_header_found && second_header.role == .Table_Column_Header &&
		second_header.parent == column_group_id && second_header.collection_id == header_row_id &&
		second_header.position_in_set == 2,
		"column headers should name their group through item.parent and keep column coordinates")

	row_header, row_header_found := semantic_node_lookup(&rt, compound_id(COMPOUND_CELL_BASE))
	body_cell, body_cell_found := semantic_node_lookup(&rt, compound_id(COMPOUND_CELL_BASE+1))
	testing.expect(t, row_header_found && row_header.role == .Table_Row_Header &&
		row_header.parent == body_row_id && row_header.collection_id == body_row_id &&
		row_header.position_in_set == 0 &&
		body_cell_found && body_cell.role == .Table_Cell &&
		body_cell.parent == body_row_id && body_cell.collection_id == body_row_id &&
		body_cell.position_in_set == 1,
		"body cells should parent to their row and use position_in_set as the column coordinate")
}

@(test)
test_virtual_table_rows_reuse_collection_virtual_items :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 480, 320})
	defer destroy_runtime(&rt)
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the virtual-table fixture should build") { return }
	table_id := compound_id(COMPOUND_VIRTUAL_TABLE)
	container_begin_simple(
		&ui, .Root, label="compound-virtual-root", key=key_string("compound-virtual-root"),
		style=layout_style(.Column, width=480, height=320, gap=2, padding=4),
	)
	table_node := container_begin_simple(
		&ui, .Container, label="compound-virtual-table", key=key_string("compound-virtual-table"),
		style=layout_style(.Column, width=440, height=120),
	)
	table := semantic_collection_begin(
		&ui, table_node, table_id, .Table, "Log", 50, realized_first=0, realized_last=1,
	)
	_ = container_begin_simple(
		&ui, .Container, label="compound-realized-row", key=key_string("compound-realized-row"),
		style=layout_style(.Row, width=440, height=24),
	)
	_ = semantic_collection_item(&ui, table, 0, Semantic_Node_Description{
		id=compound_id(0x61), role=.Table_Row, label="Row 0",
	})
	container_end(&ui)
	for index in 1..<4 {
		attached := semantic_collection_virtual_item(&ui, table, u64(index), Semantic_Node_Description{
			id=compound_id(0x61+u64(index)),
			role=.Table_Row,
			label="Virtual row",
		})
		testing.expect(t, attached, "a logical table row should attach through the existing virtual-item path")
	}
	container_end(&ui)
	end_frame(&ui)

	for index in 1..<4 {
		row, found := semantic_node_lookup(&rt, compound_id(0x61+u64(index)))
		testing.expect(t, found && row.role == .Table_Row && row.is_virtual_item &&
			row.visual_node == 0 && row.parent == table_id && row.collection_id == table_id &&
			row.position_in_set == u64(index) && row.size_of_set == 50,
			"virtual table rows should retain logical identity, row position, and table size")
	}
}
