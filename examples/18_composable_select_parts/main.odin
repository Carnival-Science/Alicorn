package main

// 18 - Composable Select Parts demonstrates a userland Select assembled from
// public Button, visual-part, semantic-collection, virtual-list, modal-overlay,
// interaction-scope, after-frame, and theme facilities. The stock Select stays
// untouched; the example adds rich rows and an application-owned Recent group.

import "core:fmt"
import alicorn "alicorn:runtime"
import parts "./select_parts"
import theme "alicorn:theme"
import ui "alicorn:ui"

THEME_PATH :: "examples/18_composable_select_parts/select_parts/theme.json"
THEME_JSON :: parts.DEFAULT_THEME_JSON

MAX_EXAMPLE_OPTIONS :: 8

window_role :: proc() -> alicorn.Style_Extension_Color_Role_ID {
	return alicorn.style_extension_color_role_id("app.example", "parts_window")
}

App :: struct {
	compact: parts.Select_Parts_State,
	rich:    parts.Select_Parts_State,
	compact_recipe: parts.Select_Parts_Recipe,
	rich_recipe:    parts.Select_Parts_Recipe,

	options: [MAX_EXAMPLE_OPTIONS]parts.Select_Parts_Option,
	rich_groups: [2]parts.Select_Parts_Group,

	recent_options: [MAX_EXAMPLE_OPTIONS]parts.Select_Parts_Option,
	other_options:  [MAX_EXAMPLE_OPTIONS]parts.Select_Parts_Option,
	compact_groups: [2]parts.Select_Parts_Group,


	theme_id: alicorn.Style_Theme_ID,
	theme_error: bool,
	missing_roles: [6]string,
	missing_role_count: int,

	last_change: string,
	changes: int,
}

example_options :: proc() -> [MAX_EXAMPLE_OPTIONS]parts.Select_Parts_Option {
	return {
		{key=1, label="Automatic", badge="AUTO", icon=.Settings},
		{key=2, label="Balanced", badge="DEFAULT", icon=.Info},
		{key=3, label="Performance", badge="FAST", icon=.Terminal},
		{key=4, label="Battery saver", icon=.Warning},
		{key=5, label="Studio", badge="PRO", icon=.Folder_Open},
		{key=6, label="Night shift", icon=.Search},
		{key=7, label="Locked preset", badge="LOCKED", icon=.Close, disabled=true},
		{key=8, label="Custom", icon=.More_Horizontal},
	}
}

app_default :: proc() -> App {
	app := App{}
	app.options = example_options()
	app.compact_recipe = parts.recipe_default(.Compact)
	app.rich_recipe = parts.recipe_default(.Rich)
	app.compact.selected_key = 2
	app.rich.selected_key = 5
	return app
}

app_prepare :: proc(app: ^App) {
	if app == nil { return }
	app.rich_groups = [2]parts.Select_Parts_Group{
		{label="Everyday", options=app.options[:4]},
		{label="Specialized", options=app.options[4:]},
	}
	parts.select_parts_note_recent(&app.compact, 2)
	parts.select_parts_note_recent(&app.compact, 5)
	build_compact_groups(app)
}

build_compact_groups :: proc(app: ^App) {
	recent_count := 0
	other_count := 0
	for key in parts.select_parts_recent_keys(&app.compact) {
		for option in app.options {
			if option.key == key && recent_count < MAX_EXAMPLE_OPTIONS {
				app.recent_options[recent_count] = option
				recent_count += 1
				break
			}
		}
	}
	for option in app.options {
		pinned := false
		for index in 0..<recent_count { if app.recent_options[index].key == option.key { pinned = true; break } }
		if pinned { continue }
		if other_count < MAX_EXAMPLE_OPTIONS {
			app.other_options[other_count] = option
			other_count += 1
		}
	}
	app.compact_groups = [2]parts.Select_Parts_Group{
		{label="Recent", options=app.recent_options[:recent_count]},
		{label="All presets", options=app.other_options[:other_count]},
	}
}

initialize_app :: proc(app: ^App, rt: ^alicorn.Runtime) {
	registration := theme.theme_json_register(rt, string(THEME_JSON), THEME_PATH)
	defer theme.theme_json_register_result_destroy(&registration)
	app.theme_id = registration.theme_id
	if app.theme_id == 0 {
		if registration.failure == .Compile && len(registration.output.parsed.diagnostics) > 0 {
			diagnostic := registration.output.parsed.diagnostics[0]
			fmt.println("Theme error", diagnostic.span.line, diagnostic.span.column, diagnostic.message)
		} else {
			fmt.println("The embedded select-parts theme could not be registered:", registration.failure)
		}
		app.theme_error = true
		return
	}
	contract := parts.theme_contract_default(app.compact_recipe)
	report := parts.theme_contract_check(rt, app.theme_id, contract)
	missing, missing_count := parts.theme_contract_missing_required(contract, report)
	app.missing_roles = missing
	app.missing_role_count = missing_count
	for index in 0..<missing_count { fmt.println("Missing select-parts theme role:", missing[index]) }
	if missing_count > 0 {
		app.theme_error = true
		return
	}
	if !report.optional_available[0] {
		fmt.println("Optional select-parts badge role is unbound; badges use the accent role.")
		app.compact_recipe.badge_role = 0
		app.rich_recipe.badge_role = 0
	}
	if _, window_found := alicorn.style_extension_color(rt, app.theme_id, window_role()); !window_found {
		fmt.println("Missing application theme role: app.example.parts_window")
		app.theme_error = true
	}
}

initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	initialize_app(cast(^App)state, rt)
}

consume_pin_input :: proc(app: ^App, ctx: ^ui.UI) {
	if app == nil || ctx == nil || app.compact.trigger_node == 0 { return }
	if event, found := ui.interaction_event_next(ctx, app.compact.trigger_node); found {
		if event.kind == .Key && event.key == .Command_1 {
			parts.select_parts_note_recent(&app.compact, app.compact.selected_key)
		}
	}
}

render_contents :: proc(app: ^App, ctx: ^ui.UI) {
	if app.theme_error || app.theme_id == 0 {
		ui.text(ctx, "The select-parts theme is incomplete.", size=20)
		for index in 0..<app.missing_role_count {
			ui.text(ctx, fmt.tprintf("Missing theme role: %s", app.missing_roles[index]))
		}
		return
	}
	consume_pin_input(app, ctx)
	build_compact_groups(app)
	environment := alicorn.Style_Environment{theme=app.theme_id}
	scope := alicorn.style_environment_push(ctx, environment)
	defer alicorn.style_environment_pop(ctx, scope)

	if ui.column(ctx, key=ui.key_u64(1), grow=1, padding=28, gap=18, label="select-parts-demo") {
		ui.text(ctx, "Composable select parts", size=28)
		ui.text(ctx,
			"Same option keys, two appearances, one userland package. Stock Select remains unchanged.")
		if ui.row(ctx, key=ui.key_u64(2), gap=28, align=.Start, label="select-parts-instances") {
			if ui.column(ctx, key=ui.key_u64(3), width=360, gap=10, label="compact-instance") {
				ui.text(ctx, "A - Compact dropdown", size=14)
				if parts.select_parts(
					ctx, "Rendering preset", &app.compact, app.compact_groups[:],
					app.compact_recipe, key=ui.key_u64(10), instance_id=101,
				) {
					app.changes += 1
					app.last_change = fmt.tprintf("Compact selected key %d.", app.compact.selected_key)
				}
				ui.text(ctx,
					"Recent options are application-owned. Focus the trigger and press Ctrl+1 to pin the current value.",
					size=12, color=alicorn.style_color(ctx, .Muted_Text))
				if ui.row(ctx, key=ui.key_u64(4), gap=8, align=.Center) {
					if ui.button(ctx, "Pin current", key=ui.key_u64(11), width=104, height=28, variant=.Quiet) {
						parts.select_parts_note_recent(&app.compact, app.compact.selected_key)
					}
					if ui.button(ctx, "Clear recents", key=ui.key_u64(12), width=104, height=28, variant=.Quiet) {
						parts.select_parts_clear_recent(&app.compact)
					}
				}
				ui.text(ctx, fmt.tprintf("Selected key %d. %d controlled changes.", app.compact.selected_key, app.changes),
					size=12, color=alicorn.style_color(ctx, .Muted_Text))
			}
			if ui.column(ctx, key=ui.key_u64(5), width=420, gap=10, label="rich-instance") {
				ui.text(ctx, "B - Rich rows with icons and badges", size=14)
				if parts.select_parts(
					ctx, "Workspace profile", &app.rich, app.rich_groups[:],
					app.rich_recipe, key=ui.key_u64(20), instance_id=202,
				) {
					app.changes += 1
					app.last_change = fmt.tprintf("Rich selected key %d.", app.rich.selected_key)
				}
				ui.text(ctx,
					"Each row is a custom Button containing an icon, label, badge, selected indicator, hover cue, and focus frame.",
					size=12, color=alicorn.style_color(ctx, .Muted_Text))
				ui.text(ctx, fmt.tprintf("Selected key %d.", app.rich.selected_key),
					size=12, color=alicorn.style_color(ctx, .Muted_Text))
			}
		}
		ui.text(ctx,
			"Up/Down, Home/End, Enter, Escape, Tab, pointer activation, type-ahead, outside-click dismissal, focus restore, grouped headers, disabled options, and virtual reveal use the same public facilities.",
			size=12, color=alicorn.style_color(ctx, .Muted_Text))
		if len(app.last_change) > 0 {
			ui.text(ctx, app.last_change, size=12)
		}
	}

	// Application-authored scoped input attached to the package-owned trigger.
	_ = ui.interaction_scope(ctx, app.compact.trigger_node, rawptr(app),
		ui.Interaction_Scope_Options{keys={.Command_1}})
}

render_overlays :: proc(app: ^App, ctx: ^ui.UI) {
	if app == nil || ctx == nil { return }
	if parts.select_parts_overlay(ctx, "Rendering preset", &app.compact, app.compact_groups[:], app.compact_recipe, 101) {
		return
	}
	_ = parts.select_parts_overlay(ctx, "Workspace profile", &app.rich, app.rich_groups[:], app.rich_recipe, 202)
}

on_text_input :: proc(app: ^App, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Hosted_Text_Input_Event) {
	if event.kind != .Commit || len(event.text) == 0 { return }
	if app.compact.open {
		_ = parts.select_parts_text(rt, &app.compact, app.compact_groups[:], event.text)
	} else if app.rich.open {
		_ = parts.select_parts_text(rt, &app.rich, app.rich_groups[:], event.text)
	}
}

on_text_key :: proc(
	app: ^App,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	if app.compact.open {
		return parts.select_parts_text_key(rt, &app.compact, app.compact_groups[:], event)
	}
	if app.rich.open {
		return parts.select_parts_text_key(rt, &app.rich, app.rich_groups[:], event)
	}
	return false
}

build_application :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^App)state
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="select-parts-test-root",
		key=alicorn.key_string("select-parts-root"), style=alicorn.layout_style(.Column, grow=1))
	render_contents(app, &ctx)
	alicorn.container_end(&ctx)
	render_overlays(app, &ctx)
	alicorn.end_frame(&ctx)
	return root
}

main :: proc() {
	app := app_default()
	app_prepare(&app)
	ui.run(
		&app,
		render_contents,
		title="Alicorn - Composable Select Parts",
		width=1080,
		height=560,
		render_overlays=render_overlays,
		on_initialize=initialize_app,
		on_text_input=on_text_input,
		on_text_key=on_text_key,
	)
}
