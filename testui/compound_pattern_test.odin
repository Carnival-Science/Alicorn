package testui

// Positive and negative controls for the compound-control pattern kinds added
// for issue #238: Radio_Group, the static Table contract, and the interactive
// Data_Grid contract. The fixtures are ordinary application-authored surfaces
// using the public semantic collection APIs; the checkers consume only
// published semantics and logical input.

import "core:fmt"
import "core:testing"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

// ---------------------------------------------------------------------------
// Radio group fixture
// ---------------------------------------------------------------------------

RADIO_FIXTURE_NAMESPACE :: u64(0x524144494F000001)
RADIO_FIXTURE_COUNT :: 4
RADIO_FIXTURE_LABELS := [RADIO_FIXTURE_COUNT]string{"Small", "Medium", "Large", "Extra"}
// Large is disabled in the positive fixture so arrow traversal must skip it.
RADIO_FIXTURE_DISABLED := [RADIO_FIXTURE_COUNT]bool{false, false, true, false}

RADIO_FIXTURE_GROUP_ID :: alicorn.Semantic_ID{namespace=RADIO_FIXTURE_NAMESPACE, value=1}

radio_fixture_item_id :: proc(index: int) -> alicorn.Semantic_ID {
	if index < 0 || index >= RADIO_FIXTURE_COUNT { return {} }
	return alicorn.Semantic_ID{namespace=RADIO_FIXTURE_NAMESPACE, value=u64(100+index)}
}

Radio_Fixture_Fault :: enum {
	None,
	// Two radios publish Checked; application-owned mutual exclusion is broken.
	Two_Checked,
	// The group selected_id names a different radio than the Checked one.
	Selected_Mismatch,
	// A Disabled radio's visual control remains a focusable tab stop.
	Disabled_Focusable,
	// An enabled radio advertises Focus while its visual node is not focusable.
	Focus_Rejected,
}

Radio_Fixture_App :: struct {
	selected:        int,
	active:          int,
	activations:     int,
	fault:           Radio_Fixture_Fault,
	group_nodes:     [RADIO_FIXTURE_COUNT]alicorn.Node_ID,
	focus_pending:   bool,
	focus_scheduled: bool,
}

@(private)
radio_fixture_initialize :: proc(app: ^Radio_Fixture_App) {
	app.selected = 1
	app.active = 1
	app.fault = .None
	app.focus_pending = true
}

@(private)
radio_fixture_enabled :: proc(data: rawptr, index: int) -> bool {
	if index < 0 || index >= RADIO_FIXTURE_COUNT { return false }
	app := cast(^Radio_Fixture_App)data
	if app.fault == .Disabled_Focusable && index == 2 { return false }
	return !RADIO_FIXTURE_DISABLED[index]
}

@(private)
radio_fixture_after_frame :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Radio_Fixture_App)data
	app.focus_scheduled = false
	if !app.focus_pending { return }
	if app.active < 0 || app.active >= RADIO_FIXTURE_COUNT { return }
	if app.group_nodes[app.active] != 0 && alicorn.focus(rt, app.group_nodes[app.active]) {
		app.focus_pending = false
		alicorn.focus_indicator_set(rt, true)
	}
}

@(private)
radio_fixture_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Radio_Fixture_App)state
	move: alicorn.Roving_Move
	#partial switch key {
	case .Left:
		move = .Left
	case .Right:
		move = .Right
	case .Up:
		move = .Up
	case .Down:
		move = .Down
	case .Home:
		move = .Home
	case .End:
		move = .End
	case:
		return false
	}
	view := alicorn.Roving_View{
		count=RADIO_FIXTURE_COUNT,
		enabled=radio_fixture_enabled,
		data=rawptr(app),
		wrap=true,
	}
	if index := alicorn.roving_propose(view, app.active, move); index >= 0 {
		app.active = index
		app.focus_pending = true
		alicorn.invalidate_root(rt, "radio fixture navigation")
	}
	return true
}

@(private)
radio_fixture_render :: proc(app: ^Radio_Fixture_App, ctx: ^ui.UI) {
	if !ui.column(ctx, key=alicorn.key_string("radio-fixture-root"), width=460, gap=10, label="radio-fixture-root") {
		return
	}
	group_node := alicorn.container_begin(
		ctx,
		.Container,
		label="Radio fixture",
		key=alicorn.key_string("radio-fixture-group"),
		style=ui.layout_style(.Column, width=420, height=220, gap=8),
	)
	if group_node != 0 {
		selected_id := alicorn.Semantic_ID{}
		if app.selected >= 0 {
			selected_id = radio_fixture_item_id(app.selected)
		}
		if app.fault == .Selected_Mismatch && app.selected >= 0 {
			selected_id = radio_fixture_item_id((app.selected+1)%RADIO_FIXTURE_COUNT)
		}
		group := alicorn.semantic_collection_begin(
			ctx,
			group_node,
			RADIO_FIXTURE_GROUP_ID,
			.Radio_Group,
			"Size",
			u64(RADIO_FIXTURE_COUNT),
			selected_id=selected_id,
			realized_last=u64(RADIO_FIXTURE_COUNT),
		)
		for label, index in RADIO_FIXTURE_LABELS {
			disabled := RADIO_FIXTURE_DISABLED[index]
			disabled_focusable := app.fault == .Disabled_Focusable && disabled
			focus_rejected := app.fault == .Focus_Rejected && index == 3
			node, activated := alicorn.button_begin(
				ctx,
				label,
				key=ui.key_pair(0x52414449, u64(index+1)),
				style=ui.layout_style(.Row, width=180, height=32),
				state=alicorn.Button_State{selected=app.selected == index, disabled=disabled && !disabled_focusable},
				focusable=(!disabled || disabled_focusable) && !focus_rejected,
				presentation=.Default,
			)
			app.group_nodes[index] = node
			if node != 0 {
				states := alicorn.Semantic_States{}
				actions := alicorn.Semantic_Actions{}
				if disabled { states = alicorn.semantic_states_add(states, .Disabled) }
				if !disabled {
					actions = alicorn.semantic_actions_add(actions, .Press)
					actions = alicorn.semantic_actions_add(actions, .Focus)
				}
				if app.selected == index { states = alicorn.semantic_states_add(states, .Checked) }
				if app.fault == .Two_Checked && index == 0 && app.selected != index {
					states = alicorn.semantic_states_add(states, .Checked)
				}
				_ = alicorn.semantic_collection_item(ctx, group, u64(index), alicorn.Semantic_Node_Description{
					id=radio_fixture_item_id(index),
					role=.Radio_Button,
					label=label,
					states=states,
					actions=actions,
				})
				_ = ui.text(ctx, label, key=ui.key_u64(0x524C424C+u64(index)), decorative=true)
				alicorn.button_end(ctx)
				if activated {
					app.selected = index
					app.active = index
					app.activations += 1
					alicorn.invalidate_root(ctx.runtime, "radio fixture activation")
				}
			}
		}
		alicorn.container_end(ctx)
	}
	if app.focus_pending && !app.focus_scheduled {
		app.focus_scheduled = true
		_ = ui.after_frame(ctx, app, radio_fixture_after_frame)
	}
}

@(private)
radio_fixture_open :: proc(
	app: ^Radio_Fixture_App,
	t: ^testing.T,
	fault := Radio_Fixture_Fault.None,
) -> (Test_Handle(Radio_Fixture_App), bool) {
	radio_fixture_initialize(app)
	app.fault = fault
	handle, status := open(app, radio_fixture_render, width=500, height=280, on_key=radio_fixture_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { close(&handle) }
		return handle, false
	}
	return handle, true
}

RADIO_FIXTURE_PARTS := [?]Pattern_Part{
	{id=.Group, query=Query{role=.Radio_Group, name="Size", match_role=true, match_name=true}},
	{id=.Target_Option, query=Query{role=.Radio_Button, name="Extra", match_role=true, match_name=true}},
}

@(private)
radio_fixture_config :: proc() -> Pattern_Config {
	return Pattern_Config{
		kind=.Radio_Group,
		parts=RADIO_FIXTURE_PARTS[:],
		radio=Pattern_Radio_Config{wrap=true},
	}
}

@(test)
test_pattern_check_radio_group_conforms :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, radio_fixture_config())
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.selected == 0,
		"the semantic Press parity phase should leave the first enabled radio selected")
	testing.expect(t, app.activations >= 1, "activation should have run at least once")
}

@(test)
test_pattern_check_radio_group_permits_initial_no_selection :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	app.selected = -1
	app.active = 0
	app.focus_pending = true
	alicorn.invalidate_root(handle.runtime, "radio fixture initial no selection")
	if status := step(&handle, Input{kind=.Time_Advance}); status != .Ok {
		testing.expect(t, false, last_turn_diagnostic(&handle))
		return
	}
	report := pattern_check(&handle, radio_fixture_config())
	testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure))
}

@(test)
test_pattern_check_radio_group_requires_selection_when_opted_in :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	app.selected = -1
	app.active = 0
	app.focus_pending = true
	alicorn.invalidate_root(handle.runtime, "radio fixture opted-in initial selection")
	if status := step(&handle, Input{kind=.Time_Advance}); status != .Ok {
		testing.expect(t, false, last_turn_diagnostic(&handle))
		return
	}
	config := radio_fixture_config()
	config.radio.require_initial_selection = true
	report := pattern_check(&handle, config)
	if !testing.expect(t, !report.ok, "an opted-in initial selection must fail when empty") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_radio_group_rejects_two_checked :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t, .Two_Checked)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, radio_fixture_config())
	if !testing.expect(t, !report.ok, "two Checked radios must fail mutual exclusion") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_radio_group_rejects_selected_id_mismatch :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t, .Selected_Mismatch)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, radio_fixture_config())
	if !testing.expect(t, !report.ok, "Checked and selected_id disagreement must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_radio_group_rejects_disabled_focusable :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t, .Disabled_Focusable)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, radio_fixture_config())
	if !testing.expect(t, !report.ok, "a focusable disabled radio must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Focus_Contract)
}

@(test)
test_pattern_check_radio_group_rejects_advertised_focus_rejection :: proc(t: ^testing.T) {
	app := Radio_Fixture_App{}
	handle, ok := radio_fixture_open(&app, t, .Focus_Rejected)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, radio_fixture_config())
	if !testing.expect(t, !report.ok, "an advertised-but-rejected Focus action must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Semantic_Action_Parity)
}

// ---------------------------------------------------------------------------
// Static table fixture
// ---------------------------------------------------------------------------

TABLE_FIXTURE_NAMESPACE :: u64(0x5441424C45000001)
TABLE_FIXTURE_ROWS :: 3
TABLE_FIXTURE_COLUMNS :: 2

TABLE_FIXTURE_ID :: alicorn.Semantic_ID{namespace=TABLE_FIXTURE_NAMESPACE, value=1}

table_fixture_row_id :: proc(row: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= TABLE_FIXTURE_ROWS { return {} }
	return alicorn.Semantic_ID{namespace=TABLE_FIXTURE_NAMESPACE, value=u64(100+row)}
}

table_fixture_cell_id :: proc(row, column: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= TABLE_FIXTURE_ROWS || column < 0 || column >= TABLE_FIXTURE_COLUMNS { return {} }
	return alicorn.Semantic_ID{namespace=TABLE_FIXTURE_NAMESPACE, value=u64(1000+row*10+column)}
}

Table_Fixture_Fault :: enum {
	None,
	// One body row publishes fewer realized cells than its logical count.
	Inconsistent_Columns,
	// A Table_Cell is collected directly by the table instead of a row.
	Cell_Outside_Row,
	// Column headers declare the table, not their header row, as parent.
	Header_Not_Parented,
}

Table_Fixture_App :: struct {
	fault: Table_Fixture_Fault
}

@(private)
table_fixture_render :: proc(app: ^Table_Fixture_App, ctx: ^ui.UI) {
	if !ui.column(ctx, key=alicorn.key_string("table-fixture-root"), width=460, gap=8, label="table-fixture-root") {
		return
	}
	table_node := alicorn.container_begin(
		ctx,
		.Container,
		label="Table fixture",
		key=alicorn.key_string("table-fixture-table"),
		style=ui.layout_style(.Column, width=420, height=150, gap=2),
	)
	if table_node != 0 {
		table := alicorn.semantic_collection_begin(
			ctx,
			table_node,
			TABLE_FIXTURE_ID,
			.Table,
			"Scores",
			u64(TABLE_FIXTURE_ROWS),
			realized_last=u64(TABLE_FIXTURE_ROWS),
		)
		// Header row.
		header_node := alicorn.container_begin(
			ctx,
			.Container,
			label="Columns row",
			key=alicorn.key_string("table-fixture-header-row"),
			style=ui.layout_style(.Row, width=420, height=28),
		)
		if header_node != 0 {
			header_id := table_fixture_row_id(0)
			_ = alicorn.semantic_collection_item(ctx, table, 0, alicorn.Semantic_Node_Description{
				id=header_id,
				role=.Table_Row,
				label="Columns",
				parent=TABLE_FIXTURE_ID,
			})
			header := alicorn.semantic_collection_begin(
				ctx,
				header_node,
				header_id,
				.Table_Row,
				"Columns",
				u64(TABLE_FIXTURE_COLUMNS),
				realized_last=u64(TABLE_FIXTURE_COLUMNS),
				parent=TABLE_FIXTURE_ID,
			)
			for label, column in ([2]string{"Name", "Score"}) {
				cell_node := alicorn.container_begin(
					ctx,
					.Container,
					label="column-header",
					key=ui.key_pair(0x54414248, u64(column+1)),
					style=ui.layout_style(.Row, width=200, height=28),
				)
				if cell_node != 0 {
					parent := header_id
					if app.fault == .Header_Not_Parented { parent = TABLE_FIXTURE_ID }
					_ = alicorn.semantic_collection_item(ctx, header, u64(column), alicorn.Semantic_Node_Description{
						id=table_fixture_cell_id(0, column),
						role=.Table_Column_Header,
						label=label,
						value=label,
						parent=parent,
					})
					alicorn.container_end(ctx)
				}
			}
			alicorn.container_end(ctx)
		}
		// Body rows.
		body_labels := [2][2]string{{"Ada", "42"}, {"Grace", "37"}}
		for labels, body in body_labels {
			row := body+1
			row_node := alicorn.container_begin(
				ctx,
				.Container,
				label="body-row",
				key=ui.key_pair(0x54414252, u64(row+1)),
				style=ui.layout_style(.Row, width=420, height=28),
			)
			if row_node == 0 { continue }
			row_id := table_fixture_row_id(row)
			_ = alicorn.semantic_collection_item(ctx, table, u64(row), alicorn.Semantic_Node_Description{
				id=row_id,
				role=.Table_Row,
				parent=TABLE_FIXTURE_ID,
			})
			row_collection := alicorn.semantic_collection_begin(
				ctx,
				row_node,
				row_id,
				.Table_Row,
				"",
				u64(TABLE_FIXTURE_COLUMNS),
				realized_last=u64(TABLE_FIXTURE_COLUMNS),
				parent=TABLE_FIXTURE_ID,
			)
			columns := TABLE_FIXTURE_COLUMNS
			if app.fault == .Inconsistent_Columns && row == 2 { columns = 1 }
			for column in 0..<columns {
				label := labels[column]
				cell_node := alicorn.container_begin(
					ctx,
					.Container,
					label="table-cell",
					key=ui.key_pair(0x54414243, u64(row*10+column+1)),
					style=ui.layout_style(.Row, width=200, height=28),
				)
				if cell_node != 0 {
					role := alicorn.Semantic_Role.Table_Cell
					if column == 0 { role = .Table_Row_Header }
					_ = alicorn.semantic_collection_item(ctx, row_collection, u64(column), alicorn.Semantic_Node_Description{
						id=table_fixture_cell_id(row, column),
						role=role,
						label=label,
						value=label,
						parent=row_id,
					})
					alicorn.container_end(ctx)
				}
			}
			alicorn.container_end(ctx)
		}
		if app.fault == .Cell_Outside_Row {
			stray := alicorn.container_begin(
				ctx,
				.Container,
				label="stray-cell",
				key=alicorn.key_string("table-fixture-stray"),
				style=ui.layout_style(.Row, width=200, height=28),
			)
			if stray != 0 {
				_ = alicorn.semantic_collection_item(ctx, table, 0, alicorn.Semantic_Node_Description{
					id=alicorn.Semantic_ID{namespace=TABLE_FIXTURE_NAMESPACE, value=999},
					role=.Table_Cell,
					label="Stray",
					parent=TABLE_FIXTURE_ID,
				})
				alicorn.container_end(ctx)
			}
		}
		alicorn.container_end(ctx)
	}
}

@(private)
table_fixture_open :: proc(
	app: ^Table_Fixture_App,
	t: ^testing.T,
	fault := Table_Fixture_Fault.None,
) -> (Test_Handle(Table_Fixture_App), bool) {
	app.fault = fault
	handle, status := open(app, table_fixture_render, width=500, height=240)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { close(&handle) }
		return handle, false
	}
	return handle, true
}

TABLE_FIXTURE_PARTS := [?]Pattern_Part{
	{id=.Table, query=Query{role=.Table, name="Scores", match_role=true, match_name=true}},
	{id=.Header_Row, query=Query{role=.Table_Row, name="Columns", match_role=true, match_name=true}},
	{id=.Cell, query=Query{role=.Table_Cell, name="42", match_role=true, match_name=true}},
}

@(private)
table_fixture_config :: proc() -> Pattern_Config {
	return Pattern_Config{
		kind=.Table,
		parts=TABLE_FIXTURE_PARTS[:],
		table=Pattern_Table_Config{
			expected_row_count=TABLE_FIXTURE_ROWS,
			expect_row_count=true,
			expected_column_count=TABLE_FIXTURE_COLUMNS,
			expect_column_count=true,
		},
	}
}

@(test)
test_pattern_check_static_table_conforms :: proc(t: ^testing.T) {
	app := Table_Fixture_App{}
	handle, ok := table_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, table_fixture_config())
	testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure))
}

@(test)
test_pattern_check_static_table_rejects_inconsistent_columns :: proc(t: ^testing.T) {
	app := Table_Fixture_App{}
	handle, ok := table_fixture_open(&app, t, .Inconsistent_Columns)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, table_fixture_config())
	if !testing.expect(t, !report.ok, "a row with a different realized column count must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_static_table_rejects_cell_outside_row :: proc(t: ^testing.T) {
	app := Table_Fixture_App{}
	handle, ok := table_fixture_open(&app, t, .Cell_Outside_Row)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, table_fixture_config())
	if !testing.expect(t, !report.ok, "a cell collected by the table must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_static_table_rejects_header_parent :: proc(t: ^testing.T) {
	app := Table_Fixture_App{}
	handle, ok := table_fixture_open(&app, t, .Header_Not_Parented)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, table_fixture_config())
	if !testing.expect(t, !report.ok, "a column header not parented to its row must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
	testing.expect_value(t, report.failure.part, Pattern_Part_ID.Header_Row)
}

// ---------------------------------------------------------------------------
// Virtual static table fixture
// ---------------------------------------------------------------------------

VIRTUAL_TABLE_NAMESPACE :: u64(0x5441424C45000002)
VIRTUAL_TABLE_ROWS :: 8
VIRTUAL_TABLE_COLUMNS :: 2
VIRTUAL_TABLE_ROW_HEIGHT :: f32(24)
VIRTUAL_TABLE_VIEWPORT :: f32(72)

VIRTUAL_TABLE_ID :: alicorn.Semantic_ID{namespace=VIRTUAL_TABLE_NAMESPACE, value=1}

virtual_table_row_id :: proc(row: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= VIRTUAL_TABLE_ROWS { return {} }
	return alicorn.Semantic_ID{namespace=VIRTUAL_TABLE_NAMESPACE, value=u64(100+row)}
}

virtual_table_cell_id :: proc(row, column: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= VIRTUAL_TABLE_ROWS || column < 0 || column >= VIRTUAL_TABLE_COLUMNS { return {} }
	return alicorn.Semantic_ID{namespace=VIRTUAL_TABLE_NAMESPACE, value=u64(1000+row*10+column)}
}

Virtual_Table_App :: struct {
	scroll: alicorn.Node_ID,
	next:   int,
}

@(private)
virtual_table_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Virtual_Table_App)state
	target := app.next
	#partial switch key {
	case .Page_Down:
		target = min(app.next+3, VIRTUAL_TABLE_ROWS-1)
	case .Page_Up:
		target = max(app.next-3, 0)
	case:
		return false
	}
	if app.scroll != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.scroll, target, "virtual table document scroll")
	}
	app.next = target
	alicorn.invalidate_root(rt, "virtual table document scroll")
	return true
}

@(private)
virtual_table_render :: proc(app: ^Virtual_Table_App, ctx: ^ui.UI) {
	if !ui.column(ctx, key=alicorn.key_string("virtual-table-root"), width=460, gap=8, label="virtual-table-root") {
		return
	}
	list := alicorn.virtual_list_begin(
		ctx,
		VIRTUAL_TABLE_ROWS,
		VIRTUAL_TABLE_ROW_HEIGHT,
		key=alicorn.key_string("virtual-table-scroll"),
		style=ui.layout_style(.Column, width=420, height=VIRTUAL_TABLE_VIEWPORT, clip=true),
		label="All scores",
	)
	app.scroll = list.scroll.id
	if list.scroll.id != 0 {
		table := alicorn.semantic_collection_begin(
			ctx,
			list.scroll.id,
			VIRTUAL_TABLE_ID,
			.Table,
			"All scores",
			u64(VIRTUAL_TABLE_ROWS),
			realized_first=u64(list.first),
			realized_last=u64(list.last),
		)
		for row in 0..<VIRTUAL_TABLE_ROWS {
			if row < list.first || row >= list.last {
				_ = alicorn.semantic_collection_virtual_item(ctx, table, u64(row), alicorn.Semantic_Node_Description{
					id=virtual_table_row_id(row),
					role=.Table_Row,
					label="Virtual row",
					parent=VIRTUAL_TABLE_ID,
					is_collection=true,
					logical_count=u64(VIRTUAL_TABLE_COLUMNS),
				})
				continue
			}
			row_node := alicorn.container_begin(
				ctx,
				.Container,
				label="virtual-table-row",
				key=ui.key_pair(0x56545257, u64(row+1)),
				style=ui.layout_style(.Row, width=420, height=VIRTUAL_TABLE_ROW_HEIGHT),
			)
			if row_node == 0 { continue }
			row_id := virtual_table_row_id(row)
			_ = alicorn.semantic_collection_item(ctx, table, u64(row), alicorn.Semantic_Node_Description{
				id=row_id,
				role=.Table_Row,
				parent=VIRTUAL_TABLE_ID,
			})
			row_collection := alicorn.semantic_collection_begin(
				ctx,
				row_node,
				row_id,
				.Table_Row,
				"",
				u64(VIRTUAL_TABLE_COLUMNS),
				realized_last=u64(VIRTUAL_TABLE_COLUMNS),
				parent=VIRTUAL_TABLE_ID,
			)
			for column in 0..<VIRTUAL_TABLE_COLUMNS {
				label := fmt.tprintf("R%dC%d", row+1, column+1)
				cell_node := alicorn.container_begin(
					ctx,
					.Container,
					label="virtual-table-cell",
					key=ui.key_pair(0x5654434C, u64(row*10+column+1)),
					style=ui.layout_style(.Row, width=200, height=VIRTUAL_TABLE_ROW_HEIGHT),
				)
				if cell_node != 0 {
					role := alicorn.Semantic_Role.Table_Cell
					if column == 0 { role = .Table_Row_Header }
					_ = alicorn.semantic_collection_item(ctx, row_collection, u64(column), alicorn.Semantic_Node_Description{
						id=virtual_table_cell_id(row, column),
						role=role,
						label=label,
						value=label,
						parent=row_id,
					})
					alicorn.container_end(ctx)
				}
			}
			alicorn.container_end(ctx)
		}
	}
	alicorn.virtual_list_end(ctx, list)
}

@(private)
virtual_table_open :: proc(app: ^Virtual_Table_App, t: ^testing.T) -> (Test_Handle(Virtual_Table_App), bool) {
	app.scroll = 0
	app.next = 0
	handle, status := open(app, virtual_table_render, width=500, height=220, on_key=virtual_table_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { close(&handle) }
		return handle, false
	}
	return handle, true
}

VIRTUAL_TABLE_PARTS := [?]Pattern_Part{
	{id=.Table, query=Query{role=.Table, name="All scores", match_role=true, match_name=true}},
	{id=.Cell, query=Query{role=.Table_Cell, name="R1C2", match_role=true, match_name=true}},
}

@(test)
test_pattern_check_static_table_virtual_rows_conform :: proc(t: ^testing.T) {
	app := Virtual_Table_App{}
	handle, ok := virtual_table_open(&app, t)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, Pattern_Config{
		kind=.Table,
		parts=VIRTUAL_TABLE_PARTS[:],
		table=Pattern_Table_Config{
			expected_row_count=VIRTUAL_TABLE_ROWS,
			expect_row_count=true,
			expected_column_count=VIRTUAL_TABLE_COLUMNS,
			expect_column_count=true,
			expect_virtual_reveal=true,
		},
	})
	testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure))
}

// ---------------------------------------------------------------------------
// Interactive data-grid fixture
// ---------------------------------------------------------------------------

GRID_FIXTURE_NAMESPACE :: u64(0x4441544147520001)
GRID_FIXTURE_ROWS :: 4
GRID_FIXTURE_COLUMNS :: 4
GRID_FIXTURE_ROW_HEIGHT :: f32(32)
GRID_FIXTURE_VIEWPORT :: f32(100)

GRID_FIXTURE_ID :: alicorn.Semantic_ID{namespace=GRID_FIXTURE_NAMESPACE, value=1}

grid_fixture_row_id :: proc(row: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= GRID_FIXTURE_ROWS { return {} }
	return alicorn.Semantic_ID{namespace=GRID_FIXTURE_NAMESPACE, value=u64(100+row)}
}

grid_fixture_cell_id :: proc(row, column: int) -> alicorn.Semantic_ID {
	if row < 0 || row >= GRID_FIXTURE_ROWS || column < 0 || column >= GRID_FIXTURE_COLUMNS { return {} }
	return alicorn.Semantic_ID{namespace=GRID_FIXTURE_NAMESPACE, value=u64(1000+row*10+column)}
}

Grid_Fixture_Fault :: enum {
	None,
	// Two semantic cells name the same focused visual node.
	Two_Focused,
	// Right arrow navigation moves focus to a control outside the grid.
	Focus_Escape,
	// Activation selects a different cell than the focused one.
	Selection_Mismatch,
	// An enabled cell advertises Focus while its visual node is not focusable.
	Focus_Rejected,
}

Grid_Fixture_Selection :: enum {
	Cell,
	Row,
}

Grid_Fixture_App :: struct {
	selected:        int,
	selected_row:    int,
	selection:       Grid_Fixture_Selection,
	focus_index:     int,
	activations:     int,
	fault:           Grid_Fixture_Fault,
	cell_nodes:      [GRID_FIXTURE_ROWS][GRID_FIXTURE_COLUMNS]alicorn.Node_ID,
	outside:         alicorn.Node_ID,
	scroll:          alicorn.Node_ID,
	focus_pending:   bool,
	focus_scheduled: bool,
	last_move:       alicorn.Roving_Move,
	has_last_move:   bool,
}

@(private)
grid_fixture_initialize :: proc(app: ^Grid_Fixture_App) {
	app.selected = -1
	app.selected_row = -1
	app.selection = .Cell
	app.focus_index = 0
	app.activations = 0
	app.focus_pending = true
	app.has_last_move = false
}

@(private)
grid_fixture_enabled :: proc(data: rawptr, index: int) -> bool {
	if index < 0 || index >= GRID_FIXTURE_ROWS*GRID_FIXTURE_COLUMNS { return false }
	app := cast(^Grid_Fixture_App)data
	row := index/GRID_FIXTURE_COLUMNS
	column := index%GRID_FIXTURE_COLUMNS
	if row == 3 { return false }
	if row == 1 && column == 2 { return false }
	if app.fault == .Focus_Rejected && row == 2 && column == 1 { return false }
	return true
}

@(private)
grid_fixture_disabled :: proc(row, column: int) -> bool {
	return row == 3 || (row == 1 && column == 2)
}

@(private)
grid_fixture_after_frame :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Grid_Fixture_App)data
	app.focus_scheduled = false
	if !app.focus_pending { return }
	if app.fault == .Focus_Escape && app.has_last_move && app.last_move == .Right && app.outside != 0 {
		_ = alicorn.focus(rt, app.outside)
		app.focus_pending = false
		return
	}
	row := app.focus_index/GRID_FIXTURE_COLUMNS
	column := app.focus_index%GRID_FIXTURE_COLUMNS
	if app.scroll != 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.scroll, row, "grid fixture focus reveal")
	}
	if app.cell_nodes[row][column] != 0 && alicorn.focus(rt, app.cell_nodes[row][column]) {
		app.focus_pending = false
		alicorn.focus_indicator_set(rt, true)
	}
}

@(private)
grid_fixture_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Grid_Fixture_App)state
	move: alicorn.Roving_Move
	#partial switch key {
	case .Left:
		move = .Left
	case .Right:
		move = .Right
	case .Up:
		move = .Up
	case .Down:
		move = .Down
	case .Home:
		move = .Home
	case .End:
		move = .End
	case:
		return false
	}
	view := alicorn.Roving_View{
		count=GRID_FIXTURE_ROWS*GRID_FIXTURE_COLUMNS,
		columns=GRID_FIXTURE_COLUMNS,
		enabled=grid_fixture_enabled,
		data=rawptr(app),
		home_end=.Row,
		row_bounded=true,
	}
	if index := alicorn.roving_propose(view, app.focus_index, move); index >= 0 {
		app.focus_index = index
		app.focus_pending = true
		app.last_move = move
		app.has_last_move = true
		alicorn.invalidate_root(rt, "grid fixture navigation")
	}
	return true
}

@(private)
grid_fixture_select :: proc(app: ^Grid_Fixture_App, index: int) {
	if app.selection == .Row {
		app.selected_row = index/GRID_FIXTURE_COLUMNS
		app.selected = -1
		app.activations += 1
		return
	}
	app.selected = index
	if app.fault == .Selection_Mismatch {
		for candidate in 1..=GRID_FIXTURE_ROWS*GRID_FIXTURE_COLUMNS {
			next := (index+candidate)%(GRID_FIXTURE_ROWS*GRID_FIXTURE_COLUMNS)
			if grid_fixture_enabled(rawptr(app), next) {
				app.selected = next
				break
			}
		}
	}
	app.activations += 1
}

@(private)
grid_fixture_render :: proc(app: ^Grid_Fixture_App, ctx: ^ui.UI) {
	// A semantic Press on a Table_Cell role is queued by the runtime instead of
	// being routed as control activation (only Button/Checkbox/Radio_Button are
	// routed directly). Consume the ordinary application request so the
	// advertised Press is actually performable.
	for {
		event, found := alicorn.semantic_request_pop(ctx.runtime)
		if !found { break }
		if event.kind == .Perform && event.id.namespace == GRID_FIXTURE_NAMESPACE {
			encoded := int(event.id.value)-1000
			if encoded >= 0 && encoded < GRID_FIXTURE_ROWS*10 {
				row := encoded/10
				column := encoded%10
				if row < GRID_FIXTURE_ROWS && column < GRID_FIXTURE_COLUMNS {
					index := row*GRID_FIXTURE_COLUMNS+column
					if grid_fixture_enabled(rawptr(app), index) { grid_fixture_select(app, index) }
				}
			}
		}
		alicorn.semantic_request_event_destroy(ctx.runtime, &event)
	}
	if !ui.column(ctx, key=alicorn.key_string("grid-fixture-root"), width=480, gap=8, label="grid-fixture-root") {
		return
	}
	list := alicorn.virtual_list_begin(
		ctx,
		GRID_FIXTURE_ROWS,
		GRID_FIXTURE_ROW_HEIGHT,
		key=alicorn.key_string("grid-fixture-scroll"),
		style=ui.layout_style(.Column, width=440, height=GRID_FIXTURE_VIEWPORT, clip=true),
		label="Data grid",
		focusable=true,
	)
	app.scroll = list.scroll.id
	if list.scroll.id != 0 {
		selected_id := alicorn.Semantic_ID{}
		if app.selection == .Row && app.selected_row >= 0 {
			selected_id = grid_fixture_row_id(app.selected_row)
		} else if app.selected >= 0 {
			row := app.selected/GRID_FIXTURE_COLUMNS
			column := app.selected%GRID_FIXTURE_COLUMNS
			selected_id = grid_fixture_cell_id(row, column)
		}
		grid := alicorn.semantic_collection_begin(
			ctx,
			list.scroll.id,
			GRID_FIXTURE_ID,
			.Table,
			"Data grid",
			u64(GRID_FIXTURE_ROWS),
			selected_id=selected_id,
			realized_first=u64(list.first),
			realized_last=u64(list.last),
		)
		for row in list.first..<list.last {
			row_node := alicorn.container_begin(
				ctx,
				.Container,
				label="grid-row",
				key=ui.key_pair(0x47524944, u64(row+1)),
				style=ui.layout_style(.Row, width=440, height=GRID_FIXTURE_ROW_HEIGHT),
			)
			if row_node == 0 { continue }
			row_id := grid_fixture_row_id(row)
			row_states := alicorn.Semantic_States{}
			if row == 3 { row_states = alicorn.semantic_states_add(row_states, .Disabled) }
			if app.selection == .Row && app.selected_row == row {
				row_states = alicorn.semantic_states_add(row_states, .Selected)
			}
			_ = alicorn.semantic_collection_item(ctx, grid, u64(row), alicorn.Semantic_Node_Description{
				id=row_id,
				role=.Table_Row,
				label=fmt.tprintf("Row %d", row+1),
				parent=GRID_FIXTURE_ID,
				states=row_states,
			})
			row_collection := alicorn.semantic_collection_begin(
				ctx,
				row_node,
				row_id,
				.Table_Row,
				fmt.tprintf("Row %d", row+1),
				u64(GRID_FIXTURE_COLUMNS),
				realized_last=u64(GRID_FIXTURE_COLUMNS),
				parent=GRID_FIXTURE_ID,
			)
			for column in 0..<GRID_FIXTURE_COLUMNS {
				index := row*GRID_FIXTURE_COLUMNS+column
				disabled := grid_fixture_disabled(row, column)
				focus_rejected := app.fault == .Focus_Rejected && row == 2 && column == 1
				label := fmt.tprintf("R%dC%d", row+1, column+1)
				if column == 0 { label = fmt.tprintf("Row %d", row+1) }
				node, activated := alicorn.button_begin(
					ctx,
					label,
					key=ui.key_pair(0x4752434C, u64(index+1)),
					style=ui.layout_style(.Row, width=100, height=GRID_FIXTURE_ROW_HEIGHT, align=.Center, justify=.Center),
					state=alicorn.Button_State{selected=app.selection == .Cell && app.selected == index, disabled=disabled},
					focusable=!disabled && !focus_rejected,
					presentation=.Custom,
				)
				app.cell_nodes[row][column] = node
				if node != 0 {
					states := alicorn.Semantic_States{}
					actions := alicorn.Semantic_Actions{}
					if disabled { states = alicorn.semantic_states_add(states, .Disabled) }
					if !disabled {
						actions = alicorn.semantic_actions_add(actions, .Press)
						actions = alicorn.semantic_actions_add(actions, .Focus)
					}
					if app.selected == index && app.selection == .Cell { states = alicorn.semantic_states_add(states, .Selected) }
					role := alicorn.Semantic_Role.Table_Cell
					if column == 0 { role = .Table_Row_Header }
					if !(app.fault == .Two_Focused && row == 0 && column == 2) {
						_ = alicorn.semantic_collection_item(ctx, row_collection, u64(column), alicorn.Semantic_Node_Description{
							id=grid_fixture_cell_id(row, column),
							role=role,
							label=label,
							value=label,
							states=states,
							actions=actions,
							parent=row_id,
						})
					}
					_ = ui.text(ctx, label, key=ui.key_u64(0x47545854+u64(index)), decorative=true)
					alicorn.button_end(ctx)
					if activated {
						grid_fixture_select(app, index)
						alicorn.invalidate_root(ctx.runtime, "grid fixture activation")
					}
				}
			}
			alicorn.container_end(ctx)
		}
		if app.fault == .Two_Focused && app.cell_nodes[0][0] != 0 {
			// Publish a second semantic cell that names the same focused visual
			// node. This models a composition that points two cells at one
			// retained control, which the grid focus contract must reject.
			_ = alicorn.semantic_node_set(ctx.runtime, alicorn.Semantic_Node_Description{
				id=grid_fixture_cell_id(0, 2),
				role=.Table_Cell,
				label="R1C3",
				value="R1C3",
				parent=grid_fixture_row_id(0),
				collection_id=grid_fixture_row_id(0),
				position_in_set=2,
				size_of_set=u64(GRID_FIXTURE_COLUMNS),
				visual_node=app.cell_nodes[0][0],
				actions=alicorn.semantic_actions_add(alicorn.semantic_actions_add({}, .Press), .Focus),
			})
		}
	}
	alicorn.virtual_list_end(ctx, list)
	outside, _ := alicorn.button_begin(
		ctx,
		"Outside",
		key=alicorn.key_string("grid-fixture-outside"),
		style=ui.layout_style(.Row, width=120, height=28),
	)
	app.outside = outside
	alicorn.button_end(ctx)
	if app.focus_pending && !app.focus_scheduled {
		app.focus_scheduled = true
		_ = ui.after_frame(ctx, app, grid_fixture_after_frame)
	}
}

@(private)
grid_fixture_open :: proc(
	app: ^Grid_Fixture_App,
	t: ^testing.T,
	fault := Grid_Fixture_Fault.None,
	selection := Grid_Fixture_Selection.Cell,
) -> (Test_Handle(Grid_Fixture_App), bool) {
	grid_fixture_initialize(app)
	app.fault = fault
	app.selection = selection
	handle, status := open(app, grid_fixture_render, width=520, height=240, on_key=grid_fixture_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { close(&handle) }
		return handle, false
	}
	return handle, true
}

GRID_FIXTURE_PARTS := [?]Pattern_Part{
	{id=.Table, query=Query{role=.Table, name="Data grid", match_role=true, match_name=true}},
	{id=.Cell, query=Query{role=.Table_Cell, name="R2C4", match_role=true, match_name=true}},
}

@(private)
grid_fixture_config :: proc() -> Pattern_Config {
	return Pattern_Config{
		kind=.Data_Grid,
		parts=GRID_FIXTURE_PARTS[:],
		grid=Pattern_Grid_Config{
			columns=GRID_FIXTURE_COLUMNS,
			wrap=false,
			row_bounded=true,
			home_end_row=true,
			expect_reveal=true,
			selection=.Cell,
		},
	}
}

@(test)
test_pattern_check_data_grid_conforms :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, grid_fixture_config())
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.activations >= 1, "grid activation should have run")
	testing.expect(t, app.selected >= 0, "grid selection should be published")
}

@(test)
test_pattern_check_data_grid_row_selection_conforms :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t, .None, .Row)
	if !ok { return }
	defer close(&handle)
	config := grid_fixture_config()
	config.grid.selection = .Row
	report := pattern_check(&handle, config)
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.selected_row >= 0, "row selection should be published")
}

@(test)
test_pattern_check_data_grid_rejects_two_focused_cells :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t, .Two_Focused)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, grid_fixture_config())
	if !testing.expect(t, !report.ok, "two semantic cells naming one focused node must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Static_Contract)
}

@(test)
test_pattern_check_data_grid_rejects_focus_escape :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t, .Focus_Escape)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, grid_fixture_config())
	if !testing.expect(t, !report.ok, "focus leaving the grid on an arrow must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Containment)
}

@(test)
test_pattern_check_data_grid_rejects_selection_mismatch :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t, .Selection_Mismatch)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, grid_fixture_config())
	if !testing.expect(t, !report.ok, "selection that disagrees with the activated cell must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Semantic_Action_Parity)
}

@(test)
test_pattern_check_data_grid_rejects_advertised_focus_rejection :: proc(t: ^testing.T) {
	app := Grid_Fixture_App{}
	handle, ok := grid_fixture_open(&app, t, .Focus_Rejected)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, grid_fixture_config())
	if !testing.expect(t, !report.ok, "an advertised-but-rejected grid Focus must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Semantic_Action_Parity)
}
