package testui

// Positive and negative controls for the roving list/grid pattern checks. The
// grid fixture mirrors the AliKit icon-picker shape: one focusable retained
// virtual list, a List_Box collection with Current identity, non-focusable
// cell items, and pure index proposals from the runtime roving model.

import "core:testing"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

ROVING_FIXTURE_NAMESPACE :: u64(0x524F56494E470001)
ROVING_FIXTURE_COLUMNS :: 4
ROVING_FIXTURE_COUNT :: 7
ROVING_FIXTURE_LABELS := [ROVING_FIXTURE_COUNT]string{
	"One", "Two", "Three", "Four", "Five", "Six", "Seven",
}
ROVING_FIXTURE_DISABLED := [ROVING_FIXTURE_COUNT]bool{
	false, false, true, false, false, false, false,
}

ROVING_FIXTURE_BOX_ID :: alicorn.Semantic_ID{namespace=ROVING_FIXTURE_NAMESPACE, value=1}

roving_fixture_item_id :: proc(index: int) -> alicorn.Semantic_ID {
	if index < 0 || index >= ROVING_FIXTURE_COUNT { return {} }
	return alicorn.Semantic_ID{namespace=ROVING_FIXTURE_NAMESPACE, value=u64(100+index)}
}

Roving_Fixture_Fault :: enum {
	None,
	// A disabled item publishes Disabled semantics while its visual control
	// remains a focusable tab stop.
	Disabled_Focusable,
	// Neither the container nor any item is focusable.
	No_Focusable,
	// Arrow navigation still moves Current but sends retained focus outside.
	Focus_Escape,
}

Roving_Fixture_App :: struct {
	active:          int,
	selected:        int,
	activations:     int,
	fault:           Roving_Fixture_Fault,
	container:       alicorn.Node_ID,
	outside:         alicorn.Node_ID,
	focus_pending:   bool,
	focus_scheduled: bool,
	reveal_pending:  bool,
}

roving_fixture_initialize :: proc(app: ^Roving_Fixture_App) {
	app.active = 0
	app.selected = -1
	app.fault = .None
	app.focus_pending = true
}

@(private)
roving_fixture_enabled :: proc(data: rawptr, index: int) -> bool {
	if index < 0 || index >= ROVING_FIXTURE_COUNT { return false }
	return !ROVING_FIXTURE_DISABLED[index]
}

@(private)
roving_fixture_view :: proc(app: ^Roving_Fixture_App) -> alicorn.Roving_View {
	return alicorn.Roving_View{
		count=ROVING_FIXTURE_COUNT,
		columns=ROVING_FIXTURE_COLUMNS,
		enabled=roving_fixture_enabled,
		data=rawptr(app),
		home_end=.Row,
		row_bounded=true,
	}
}

@(private)
roving_fixture_selected_id :: proc(app: ^Roving_Fixture_App) -> alicorn.Semantic_ID {
	if app.selected < 0 { return {} }
	return roving_fixture_item_id(app.selected)
}

@(private)
roving_fixture_after_frame :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Roving_Fixture_App)data
	app.focus_scheduled = false
	if app.container != 0 && alicorn.focus(rt, app.container) {
		app.focus_pending = false
		alicorn.focus_indicator_set(rt, true)
	}
}

@(private)
roving_fixture_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Roving_Fixture_App)state
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
	case .Page_Up:
		move = .Page_Up
	case .Page_Down:
		move = .Page_Down
	case .Home:
		move = .Home
	case .End:
		move = .End
	case .Return, .Toggle:
		if !ROVING_FIXTURE_DISABLED[app.active] {
			app.selected = app.active
			app.activations += 1
			alicorn.invalidate_root(rt, "roving fixture activation")
		}
		return true
	case:
		return false
	}
	view := roving_fixture_view(app)
	if index := alicorn.roving_propose(view, app.active, move); index >= 0 {
		app.active = index
		app.reveal_pending = true
		alicorn.invalidate_root(rt, "roving fixture navigation")
	}
	if app.fault == .Focus_Escape && key == .Right && app.outside != 0 {
		_ = alicorn.focus(rt, app.outside)
	}
	return true
}

@(private)
roving_fixture_render :: proc(app: ^Roving_Fixture_App, ctx: ^ui.UI) {
	if ui.column(ctx, key=alicorn.key_string("roving-fixture-root"), width=440, gap=8, label="roving-fixture-root") {
		row_count := (ROVING_FIXTURE_COUNT+ROVING_FIXTURE_COLUMNS-1)/ROVING_FIXTURE_COLUMNS
		row_height := f32(40)
		list := alicorn.virtual_list_begin(
			ctx,
			row_count,
			row_height,
			key=alicorn.key_string("roving-fixture-grid"),
			style=ui.layout_style(.Column, width=400, height=row_height*f32(row_count), clip=true),
			label="Roving grid",
			focusable=app.fault != .No_Focusable,
		)
		app.container = list.scroll.id
		if list.scroll.id != 0 {
			collection := alicorn.semantic_collection_begin(
				ctx,
				list.scroll.id,
				ROVING_FIXTURE_BOX_ID,
				.List_Box,
				"Roving grid",
				u64(ROVING_FIXTURE_COUNT),
				selected_id=roving_fixture_selected_id(app),
				current_id=roving_fixture_item_id(app.active),
			)
			for row_index := list.first; row_index < list.last; row_index += 1 {
				if ui.row(ctx, key=ui.key_pair(0x52564752, u64(row_index+1)), width=-1,
					height=row_height, gap=4, label="roving-fixture-row") {
					for column in 0..<ROVING_FIXTURE_COLUMNS {
						index := row_index*ROVING_FIXTURE_COLUMNS+column
						if index >= ROVING_FIXTURE_COUNT {
							if ui.row(ctx, key=ui.key_u64(0x52564750+u64(column)), width=88, height=32, label="roving-fixture-gap") {}
							continue
						}
						label := ROVING_FIXTURE_LABELS[index]
						disabled := ROVING_FIXTURE_DISABLED[index]
						disabled_focusable := app.fault == .Disabled_Focusable && disabled
						owner, activated := alicorn.button_begin(
							ctx,
							label,
							key=ui.key_pair(0x52564954, u64(index+1)),
							style=ui.layout_style(.Row, width=88, height=32, align=.Center, justify=.Center),
							state=alicorn.Button_State{selected=app.selected == index, disabled=disabled && !disabled_focusable},
							presentation=.Custom,
							focusable=disabled_focusable,
						)
						if owner != 0 {
							states := alicorn.Semantic_States{}
							actions := alicorn.Semantic_Actions{}
							if disabled {
								states = alicorn.semantic_states_add(states, .Disabled)
							} else {
								actions = alicorn.semantic_actions_add(actions, .Select)
								actions = alicorn.semantic_actions_add(actions, .Focus)
							}
							if app.selected == index { states = alicorn.semantic_states_add(states, .Selected) }
							if app.active == index { states = alicorn.semantic_states_add(states, .Current) }
							_ = alicorn.semantic_collection_item(ctx, collection, u64(index), alicorn.Semantic_Node_Description{
								id=roving_fixture_item_id(index),
								role=.List_Box_Option,
								label=label,
								value=label,
								states=states,
								actions=actions,
								visual_node=owner,
							})
							_ = ui.text(ctx, label, key=ui.key_u64(1), decorative=true)
							alicorn.button_end(ctx)
							if activated && !disabled {
								app.selected = index
								app.active = index
								app.activations += 1
							}
						}
					}
				}
			}
			alicorn.virtual_list_end(ctx, list)
			if app.reveal_pending {
				_ = alicorn.virtual_list_ensure_visible(
					ctx.runtime,
					list.scroll.id,
					app.active/ROVING_FIXTURE_COLUMNS,
					"roving fixture current item revealed",
				)
				app.reveal_pending = false
			}
		}
		outside, _ := alicorn.button_begin(
			ctx,
			"Outside",
			key=alicorn.key_string("roving-fixture-outside"),
			style=ui.layout_style(.Row, width=120, height=28),
		)
		app.outside = outside
		alicorn.button_end(ctx)
		if app.focus_pending && !app.focus_scheduled {
			app.focus_scheduled = true
			_ = ui.after_frame(ctx, app, roving_fixture_after_frame)
		}
	}
}

@(private)
roving_fixture_open :: proc(
	app: ^Roving_Fixture_App,
	t: ^testing.T,
	fault := Roving_Fixture_Fault.None,
) -> (Test_Handle(Roving_Fixture_App), bool) {
	roving_fixture_initialize(app)
	app.fault = fault
	handle, status := open(
		app,
		roving_fixture_render,
		width=460,
		height=220,
		on_key=roving_fixture_on_key,
	)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { close(&handle) }
		return handle, false
	}
	return handle, true
}

ROVING_FIXTURE_PARTS := [?]Pattern_Part{
	{id=.Container, query=Query{role=.List_Box, name="Roving grid", match_role=true, match_name=true}},
	{id=.Target_Option, query=Query{role=.List_Box_Option, name="Six", match_role=true, match_name=true}},
	{id=.Disabled_Option, query=Query{role=.List_Box_Option, name="Three", match_role=true, match_name=true}},
}

@(private)
roving_fixture_config :: proc() -> Pattern_Config {
	return Pattern_Config{
		kind=.Roving_Grid,
		parts=ROVING_FIXTURE_PARTS[:],
		roving=Pattern_Roving_Config{
			focus=.Container,
			columns=ROVING_FIXTURE_COLUMNS,
			wrap=false,
			row_bounded=true,
			home_end_row=true,
			expect_reveal=true,
			activation_closes=false,
			expect_selection=true,
		},
	}
}

@(test)
test_pattern_check_roving_grid_conforms :: proc(t: ^testing.T) {
	app := Roving_Fixture_App{}
	handle, ok := roving_fixture_open(&app, t)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, roving_fixture_config())
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect_value(t, app.selected, 5)
	testing.expect(t, app.activations >= 1, "keyboard and pointer activation should both propose the target")
}

@(test)
test_pattern_check_roving_grid_rejects_disabled_focusable_item :: proc(t: ^testing.T) {
	app := Roving_Fixture_App{}
	handle, ok := roving_fixture_open(&app, t, .Disabled_Focusable)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, roving_fixture_config())
	if !testing.expect(t, !report.ok, "a focusable disabled item must fail the roving pattern") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Focus_Contract)
}

@(test)
test_pattern_check_roving_grid_rejects_no_focusable_representative :: proc(t: ^testing.T) {
	app := Roving_Fixture_App{}
	handle, ok := roving_fixture_open(&app, t, .No_Focusable)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, roving_fixture_config())
	if !testing.expect(t, !report.ok, "a roving set without a focusable representative must fail") { return }
	testing.expect_value(t, report.failure.step, Pattern_Step.Focus_Contract)
}

@(test)
test_pattern_check_roving_grid_rejects_focus_escape :: proc(t: ^testing.T) {
	app := Roving_Fixture_App{}
	handle, ok := roving_fixture_open(&app, t, .Focus_Escape)
	if !ok { return }
	defer close(&handle)
	report := pattern_check(&handle, roving_fixture_config())
	if !testing.expect(t, !report.ok, "arrow navigation that drops focus outside must fail") { return }
	if report.failure.step != .Containment {
		testing.expect(t, false, pattern_failure_diagnostic(&report.failure))
		return
	}
	testing.expect_value(t, report.failure.step, Pattern_Step.Containment)
}
