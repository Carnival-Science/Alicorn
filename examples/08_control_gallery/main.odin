package main

// 08 · Control Gallery is the single-file-compatible tour of Alicorn's public
// authoring surface. It uses only the default `alicorn:ui` + `alicorn:runtime`
// SDL_GPU path; no WebGPU package or third-party dependency is involved.
//
// Sections live beside this file:
//   foundations.odin      text, fonts, buttons, icon inventory, groups
//   controls.odin         text field, validation, checkbox, slider, select
//   collections.odin      virtual list, document tabs, drag reorder, scroll
//   layout_surfaces.odin  split panes, Grid, positioned text, surfaces
//   overlays_themes.odin  modal, tooltip, notice, context menu, motion, themes
//
// Run `tools/run_example.ps1 -Example 08_control_gallery` (or the .sh runner).
// Pass `--smoke` to describe every section plus the modal once, print
// `gallery_smoke`, and exit. The live theme reload still reads theme.json from
// the repository root.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import alicorn "alicorn:runtime"
import theme "alicorn:theme"
import ui "alicorn:ui"

GALLERY_THEME_PATH :: "examples/08_control_gallery/theme.json"
GALLERY_SECTION_COUNT :: 6
GALLERY_RECORD_COUNT :: 500
GALLERY_ROW_HEIGHT :: 28
GALLERY_DRAG_TYPE :: alicorn.Drag_Type(0x181001)
GALLERY_DRAG_NAMESPACE :: u64(0x47414C4C45525901)
GALLERY_SURFACE_NAMESPACE :: u64(0x47414C4C45525902)

// Native menu and context-menu commands share one Action_ID registry.
GALLERY_ACTION_FOUNDATIONS :: alicorn.Action_ID(0x181101)
GALLERY_ACTION_CONTROLS :: alicorn.Action_ID(0x181102)
GALLERY_ACTION_COLLECTIONS :: alicorn.Action_ID(0x181103)
GALLERY_ACTION_LAYOUT :: alicorn.Action_ID(0x181104)
GALLERY_ACTION_OVERLAYS :: alicorn.Action_ID(0x181105)
GALLERY_ACTION_MOTION :: alicorn.Action_ID(0x181106)
GALLERY_ACTION_RELOAD_THEME :: alicorn.Action_ID(0x181107)
GALLERY_ACTION_ABOUT :: alicorn.Action_ID(0x181201)
GALLERY_ACTION_RENAME :: alicorn.Action_ID(0x181301)
GALLERY_ACTION_DUPLICATE :: alicorn.Action_ID(0x181302)
GALLERY_ACTION_DELETE :: alicorn.Action_ID(0x181303)

Section :: enum u8 {
	Foundations,
	Controls,
	Collections,
	Layout,
	Overlays,
	Motion,
	Count,
}

Theme_Choice :: enum u8 { Default, Light, Custom }

Doc_Tab :: struct {
	title: string,
	open:  bool,
	dirty: bool,
}

Order_Item :: struct {
	id:    u64,
	label: string,
}

Color_Role_Caption :: struct {
	role:  alicorn.Style_Color_Role,
	label: string,
}

Icon_Caption :: struct {
	id:    alicorn.Icon_ID,
	label: string,
}

GALLERY_SECTION_TITLES := [GALLERY_SECTION_COUNT]string{
	"Foundations",
	"Controls",
	"Collections",
	"Layout & surfaces",
	"Overlays & commands",
	"Motion & themes",
}

// Content extents are logical upper bounds. The page scrolls on compact
// windows; ordinary descriptions do not over-scroll on the default window.
GALLERY_SECTION_HEIGHTS := [GALLERY_SECTION_COUNT]f32{
	720,
	700,
	700,
	720,
	600,
	650,
}

GALLERY_ICONS := [15]Icon_Caption{
	{.Check, "Check"},
	{.Chevron_Down, "Chevron down"},
	{.Chevron_Right, "Chevron right"},
	{.Close, "Close"},
	{.Minus, "Minus"},
	{.Radio_Selected, "Radio"},
	{.Warning, "Warning"},
	{.Info, "Info"},
	{.Folder_Closed, "Folder"},
	{.Folder_Open, "Folder open"},
	{.File, "File"},
	{.Search, "Search"},
	{.Settings, "Settings"},
	{.Terminal, "Terminal"},
	{.More_Horizontal, "More"},
}

GALLERY_COLOR_ROLES := [18]Color_Role_Caption{
	{.Window_Background, "window"},
	{.Surface, "surface"},
	{.Subtle_Surface, "subtle"},
	{.Editor_Background, "editor"},
	{.Text, "text"},
	{.Muted_Text, "muted"},
	{.Accent, "accent"},
	{.Accent_Hover, "accent hover"},
	{.Accent_Pressed, "accent pressed"},
	{.Accent_Text, "accent text"},
	{.Selection, "selection"},
	{.Focus, "focus"},
	{.Semantic_Focus, "semantic focus"},
	{.Border, "border"},
	{.Danger, "danger"},
	{.Success, "success"},
	{.Scrollbar_Track, "scroll track"},
	{.Scrollbar_Thumb, "scroll thumb"},
}

App :: struct {
	// Application state is ordinary Odin data. Alicorn never owns it.
	allocator: mem.Allocator,
	section:   Section,

	name:          ui.Text_Buffer,
	name_invalid:  bool,
	notifications: bool,
	gain:          f32,
	density_key:   u64,
	button_clicks: int,
	icon_clicks:   int,

	selected_record: int,
	renamed_record:  bool,
	order:           [5]Order_Item,
	selected_order:  int,
	drag_status:     [160]u8,
	drag_status_len: int,

	docs:       [3]Doc_Tab,
	active_doc: int,

	dialog_open:   bool,
	dialog_opener: alicorn.Node_ID,
	command_status: [160]u8,
	command_status_len: int,
	pending_notice: bool,
	pending_notice_dismiss: bool,

	motion_choice: int,

	theme_choice:          Theme_Choice,
	theme_choice_explicit: bool,
	light_theme:           alicorn.Style_Theme_ID,
	surface_theme:   alicorn.Style_Theme_ID,
	registered_theme: alicorn.Style_Theme_ID,
	theme_generation: u64,
	theme_status:    [256]u8,
	theme_status_len: int,

	// Retained geometry surface is updated after layout, never during input.
	geometry_surface: alicorn.Node_ID,
	geometry_ready:   bool,
	geometry_width:   f32,
	geometry_height:  f32,

	// Worker-owned theme compilation. The result bytes are published under a
	// mutex; the borrowed waker only requests an application-thread callback.
	waker:            ui.Application_Waker,
	worker:           ^thread.Thread,
	completion_mutex: sync.Mutex,
	compiling:        bool,
	worker_complete:  bool,
	read_failed:      bool,
	candidate:        theme.Theme_JSON_Compile_Output,
	active_output:    theme.Theme_JSON_Compile_Output,

	// Native menu storage is borrowed for the host session.
	menu_view_items: [8]alicorn.Menu_Item,
	menu_help_items: [1]alicorn.Menu_Item,
	menus:           [2]alicorn.Menu,

	smoke:              bool,
	smoke_stage:        int,
	smoke_dialog_shown: bool,
}

gallery_theme_status_set :: proc(app: ^App, message: string) {
	if app == nil { return }
	app.theme_status_len = min(len(message), len(app.theme_status))
	copy(app.theme_status[:app.theme_status_len], message[:app.theme_status_len])
}

gallery_theme_status_text :: proc(app: ^App) -> string {
	if app == nil { return "" }
	return string(app.theme_status[:app.theme_status_len])
}

gallery_command_status_set :: proc(app: ^App, message: string) {
	if app == nil { return }
	app.command_status_len = min(len(message), len(app.command_status))
	copy(app.command_status[:app.command_status_len], message[:app.command_status_len])
}

gallery_command_status_text :: proc(app: ^App) -> string {
	if app == nil { return "" }
	return string(app.command_status[:app.command_status_len])
}

gallery_drag_status_set :: proc(app: ^App, message: string) {
	if app == nil { return }
	app.drag_status_len = min(len(message), len(app.drag_status))
	copy(app.drag_status[:app.drag_status_len], message[:app.drag_status_len])
}

gallery_drag_status_text :: proc(app: ^App) -> string {
	if app == nil { return "" }
	return string(app.drag_status[:app.drag_status_len])
}

gallery_active_theme :: proc(app: ^App) -> alicorn.Style_Theme_ID {
	switch app.theme_choice {
	case .Default:
		return 0
	case .Light:
		return app.light_theme
	case .Custom:
		return app.registered_theme
	}
	return 0
}

gallery_set_section :: proc(app: ^App, rt: ^alicorn.Runtime, section: Section) {
	if app == nil || rt == nil { return }
	app.section = section
	alicorn.invalidate_root(rt, "gallery section changed")
}

gallery_compile_theme_worker :: proc(data: rawptr) {
	app := cast(^App)data
	allocator := app.allocator
	output := theme.Theme_JSON_Compile_Output{}
	read_failed := false
	bytes, err := os.read_entire_file(GALLERY_THEME_PATH, allocator)
	if err != nil {
		read_failed = true
	} else {
		output = theme.theme_compile_json(string(bytes), GALLERY_THEME_PATH, allocator)
		delete(bytes, allocator)
	}
	sync.mutex_lock(&app.completion_mutex)
	app.candidate = output
	app.read_failed = read_failed
	app.worker_complete = true
	sync.mutex_unlock(&app.completion_mutex)
	ui.wake(app.waker)
}

gallery_start_compile :: proc(app: ^App) {
	if app == nil || app.worker != nil { return }
	app.compiling = true
	gallery_theme_status_set(app, "Compiling theme.json; the last good palette stays active.")
	app.worker = thread.create_and_start_with_data(
		rawptr(app), gallery_compile_theme_worker, name="alicorn-gallery-theme-compiler",
	)
	if app.worker == nil {
		app.compiling = false
		gallery_theme_status_set(app, "Could not start the theme compiler worker.")
	}
}

gallery_compile_error_text :: proc(output: ^theme.Theme_JSON_Compile_Output) -> string {
	if output == nil { return "Theme compilation failed; the last good palette remains active." }
	if output.unsupported_extends { return "Only extends: alicorn.base is supported by the preview." }
	if len(output.parsed.diagnostics) > 0 {
		diagnostic := output.parsed.diagnostics[0]
		return fmt.tprintf("%s:%d:%d: %s", diagnostic.span.path, diagnostic.span.line, diagnostic.span.column, diagnostic.message)
	}
	if len(output.compiled.diagnostics) > 0 {
		diagnostic := output.compiled.diagnostics[0]
		return fmt.tprintf("%s:%d:%d: theme rejected (%v)", diagnostic.path, diagnostic.span.line, diagnostic.span.column, diagnostic.code)
	}
	return "Theme compilation failed; the last good palette remains active."
}

gallery_adopt_candidate :: proc(app: ^App, rt: ^alicorn.Runtime, candidate: ^theme.Theme_JSON_Compile_Output) -> (applied: bool) {
	if app == nil || rt == nil || candidate == nil || !candidate.ok { return }
	if len(candidate.compiled.theme.colors) == 0 {
		gallery_theme_status_set(app, "The theme must contain at least one color token.")
		return
	}
	if app.active_output.ok && !theme.theme_preview_structure_compatible(app.active_output, candidate^) {
		gallery_theme_status_set(app, "Rejected: token names, bindings, lengths, recipes, and materials must stay fixed.")
		return
	}
	runtime_theme, adapted := theme.theme_runtime_style_theme(candidate.compiled, app.allocator)
	if !adapted {
		gallery_theme_status_set(app, "Theme compiled but could not adapt to Alicorn's runtime style contract.")
		return
	}
	defer theme.theme_runtime_style_theme_destroy(&runtime_theme, app.allocator)
	// Three flat Button recipes use distinct timing policies; all other controls
	// keep their immediate style updates. Motion remains paint-only.
	durations := [3]time.Duration{
		time.Duration(120)*time.Millisecond,
		time.Duration(180)*time.Millisecond,
		time.Duration(300)*time.Millisecond,
	}
	button_variants := [3]alicorn.Button_Variant{.Default, .Primary, .Toolbar}
	for variant in 0..<len(durations) {
		recipe := runtime_theme.button_recipes.recipes[int(button_variants[variant])]
		recipe.hover_fill_transition = alicorn.Style_Transition{
			duration=durations[variant],
			easing=.Ease,
		}
		runtime_theme.button_recipes.recipes[int(button_variants[variant])] = recipe
	}

	if app.active_output.ok {
		switch alicorn.style_theme_replace(rt, app.registered_theme, runtime_theme) {
		case .Rejected:
			gallery_theme_status_set(app, "Alicorn rejected the candidate; the last good theme remains active.")
			return
		case .Unchanged:
			gallery_theme_status_set(app, "Theme is unchanged; the last good theme remains active.")
		case .Replaced:
			app.theme_generation += 1
			if app.theme_generation == 0 { app.theme_generation = 1 }
			gallery_theme_status_set(app, fmt.tprintf("Applied theme generation %d.", app.theme_generation))
		}
	} else {
		registered := alicorn.style_theme_register(rt, runtime_theme)
		if registered == 0 {
			gallery_theme_status_set(app, "Alicorn rejected the initial runtime theme.")
			return
		}
		app.registered_theme = registered
		app.theme_generation = 1
		gallery_theme_status_set(app, "Custom theme loaded. Edit theme.json and choose Reload Theme.")
	}
	if !app.theme_choice_explicit { app.theme_choice = .Custom }
	theme.theme_json_compile_output_destroy(&app.active_output, app.allocator)
	app.active_output = candidate^
	candidate^ = theme.Theme_JSON_Compile_Output{}
	return true
}

gallery_generate_geometry :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || app.geometry_surface == 0 || app.geometry_ready { return }
	surface, ok := alicorn.gpu_surface_context(rt, app.geometry_surface)
	if !ok || surface.logical_bounds.w <= 0 || surface.logical_bounds.h <= 0 { return }
	width := min(surface.logical_bounds.w, 520)
	height := max(surface.logical_bounds.h, 40)
	app.geometry_width = surface.logical_bounds.w
	app.geometry_height = surface.logical_bounds.h
	rectangles: [24]alicorn.GPU_Surface_Filled_Rectangle
	bars := len(rectangles)
	gap := f32(3)
	bar_width := max((width-f32(bars-1)*gap)/f32(bars), 1)
	accent := alicorn.Color{0.32, 0.62, 0.95, 1}
	muted := alicorn.Color{0.24, 0.30, 0.40, 1}
	for index in 0..<bars {
		height_fraction := 0.18 + 0.68*f32((index*37+13)%100)/100
		bar_height := height*height_fraction
		rectangles[index] = alicorn.GPU_Surface_Filled_Rectangle{
			bounds=alicorn.Rect{f32(index)*(bar_width+gap), height-bar_height, bar_width, bar_height},
			color=accent if index%4 == 0 else muted,
		}
	}
	segments := [1]alicorn.GPU_Surface_Line_Segment{{
		start={0, height-1},
		end={width, height-1},
		thickness=1,
		color=muted,
	}}
	if alicorn.gpu_surface_update_geometry_with_rectangles(rt, app.geometry_surface, rectangles[:], segments[:], nil) {
		app.geometry_ready = true
	}
}

gallery_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	gallery_generate_geometry(app, rt)

	if app.pending_notice {
		app.pending_notice = false
		_ = alicorn.notice_post(rt, alicorn.Notice{
			id="gallery-status",
			title="Control Gallery",
			message="Notices are persistent until dismissed or resolved by the application.",
			severity=.Success,
			lifetime=.Persistent,
			placement=.Toast,
		}, 0)
	}
	if app.pending_notice_dismiss {
		app.pending_notice_dismiss = false
		_ = alicorn.notice_dismiss(rt, "gallery-status")
	}

	if !app.smoke { return }
	if app.smoke_stage < GALLERY_SECTION_COUNT {
		app.section = Section(app.smoke_stage)
		app.smoke_stage += 1
		alicorn.invalidate_root(rt, "gallery smoke section")
	} else if !app.smoke_dialog_shown {
		app.smoke_dialog_shown = true
		app.dialog_open = true
		alicorn.invalidate_root(rt, "gallery smoke modal")
	} else {
		fmt.println("gallery_smoke", "sections", GALLERY_SECTION_COUNT, "modal", true, "ok", true)
		os.exit(0)
	}
}

gallery_drag :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	if app == nil || rt == nil || event.kind != .Dropped { return }
	source_index := -1
	target_index := -1
	for item, index in app.order {
		if u64(item.id) == event.source.value { source_index = index }
		if u64(item.id) == event.target.value { target_index = index }
	}
	if source_index < 0 || target_index < 0 {
		gallery_drag_status_set(app, "Drop ignored: the source or target is no longer in application state.")
		return
	}
	insert := target_index
	if event.position == .After { insert += 1 }
	if insert > source_index { insert -= 1 }
	if insert == source_index {
		gallery_drag_status_set(app, fmt.tprintf("Dropped %s at its existing position.", app.order[source_index].label))
		return
	}
	moved := app.order[source_index]
	if insert < source_index {
		for index := source_index; index > insert; index -= 1 {
			app.order[index] = app.order[index-1]
		}
	} else {
		for index := source_index; index < insert; index += 1 {
			app.order[index] = app.order[index+1]
		}
	}
	app.order[insert] = moved
	app.selected_order = insert
	gallery_drag_status_set(app, fmt.tprintf("Moved %s to position %d.", moved.label, insert+1))
	alicorn.invalidate_root(rt, "gallery drag reorder adopted")
}

gallery_menu_command :: proc(app: ^App, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	switch command {
	case GALLERY_ACTION_FOUNDATIONS: gallery_set_section(app, rt, .Foundations)
	case GALLERY_ACTION_CONTROLS: gallery_set_section(app, rt, .Controls)
	case GALLERY_ACTION_COLLECTIONS: gallery_set_section(app, rt, .Collections)
	case GALLERY_ACTION_LAYOUT: gallery_set_section(app, rt, .Layout)
	case GALLERY_ACTION_OVERLAYS: gallery_set_section(app, rt, .Overlays)
	case GALLERY_ACTION_MOTION: gallery_set_section(app, rt, .Motion)
	case GALLERY_ACTION_RELOAD_THEME:
		app.theme_choice_explicit = false
		gallery_start_compile(app)
		alicorn.invalidate_root(rt, "gallery theme reload requested")
	case GALLERY_ACTION_ABOUT:
		app.pending_notice = true
		alicorn.invalidate_root(rt, "gallery about requested")
	case:
	}
}

gallery_apply_command :: proc(app: ^App, command: alicorn.Action_ID) {
	switch command {
	case GALLERY_ACTION_RENAME:
		app.renamed_record = true
		gallery_command_status_set(app, fmt.tprintf("Renamed record %03d from the context menu.", app.selected_record+1))
	case GALLERY_ACTION_DUPLICATE:
		gallery_command_status_set(app, fmt.tprintf("Duplicate requested for record %03d.", app.selected_record+1))
	case GALLERY_ACTION_DELETE:
		gallery_command_status_set(app, fmt.tprintf("Delete requested for record %03d.", app.selected_record+1))
	case:
		gallery_command_status_set(app, "Command dispatched.")
	}
}

gallery_record_label :: proc(app: ^App, position: int) -> string {
	label := fmt.tprintf("Record %03d · %s", position+1, "stable")
	if app != nil && app.renamed_record && position == app.selected_record {
		return fmt.tprintf("Record %03d · renamed", position+1)
	}
	return label
}

gallery_section_content :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.key_scope(ctx, u64(int(app.section)+1)) {
		switch app.section {
		case .Foundations: gallery_foundations(app, ctx)
		case .Controls: gallery_controls(app, ctx)
		case .Collections: gallery_collections(app, ctx)
		case .Layout: gallery_layout(app, ctx)
		case .Overlays: gallery_overlays_section(app, ctx)
		case .Motion: gallery_motion_themes(app, ctx)
		case .Count:
		}
	}
}

gallery_navigation :: proc(app: ^App, ctx: ^ui.UI) {
	items: [GALLERY_SECTION_COUNT]alicorn.Tab_Bar_Item
	for title, index in GALLERY_SECTION_TITLES {
		items[index] = alicorn.Tab_Bar_Item{
			key=ui.key_u64(u64(index+1)),
			label=title,
			selected=app.section == Section(index),
			tooltip=title,
		}
	}
	result := alicorn.tab_bar(
		ctx,
		"gallery-sections",
		items[:],
		options=alicorn.Tab_Bar_Options{min_tab_width=122, max_tab_width=200, height=36, gap=4},
		style=ui.layout_style(.Row, height=40, clip=true),
	)
	if result.action == .Select && result.item_index >= 0 && result.item_index < GALLERY_SECTION_COUNT {
		app.section = Section(result.item_index)
	}
}

gallery_header :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.row(ctx, height=56, gap=14, align=.Center) {
		if ui.column(ctx, grow=1, gap=2) {
			ui.text(ctx, "Alicorn · Control Gallery", size=25, text_style=alicorn.Text_Style{
				font_weight=alicorn.FONT_WEIGHT_SEMIBOLD,
			})
			ui.text(ctx, "One native SDL_GPU example for every public authoring surface in v0.2.2.")
		}
		if ui.column(ctx, width=190, gap=4, align=.End) {
			name := "Default"
			switch app.theme_choice {
			case .Default: name = "Default"
			case .Light: name = "Light"
			case .Custom: name = fmt.tprintf("Custom #%d", app.theme_generation)
			}
			ui.text(ctx, fmt.tprintf("Theme · %s", name), size=12, color=alicorn.style_color(ctx, .Muted_Text))
			_ = ui.box(ctx, key="gallery-accent-swatch", width=120, height=10,
				fill=alicorn.style_color(ctx, .Accent), radius=5)
		}
	}
}

gallery_footer :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.row(ctx, height=24, gap=12, align=.Center) {
		ui.text(
			ctx,
			fmt.tprintf("%s · Tab / Shift+Tab moves focus · View menu switches sections", GALLERY_SECTION_TITLES[int(app.section)]),
			size=11,
			color=alicorn.style_color(ctx, .Muted_Text),
			style=ui.layout_style(.Row, grow=1, height=20),
		)
		if app.smoke {
			ui.text(ctx, "smoke", size=11, color=alicorn.style_color(ctx, .Danger))
		}
	}
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	theme_id := gallery_active_theme(app)
	scope := alicorn.Style_Environment_Scope{}
	if theme_id != 0 {
		scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=theme_id})
	}

	if ui.panel(ctx, grow=1, padding=18, gap=10, clip=false, label="gallery-root") {
		gallery_header(app, ctx)
		gallery_navigation(app, ctx)
		height := GALLERY_SECTION_HEIGHTS[int(app.section)]
		region := alicorn.scroll_region_begin(
			ctx,
			key="gallery-page",
			content_height=height,
			line_height=28,
			style=ui.layout_style(.Column, grow=1, clip=true),
			label="Gallery section content",
			axes=.Vertical,
		)
		if region.id != 0 {
			if ui.column(ctx, gap=12, padding=4, label="gallery-section") {
				gallery_section_content(app, ctx)
			}
			alicorn.scroll_region_end(ctx)
		}
		gallery_footer(app, ctx)
	}

	if scope.active { alicorn.style_environment_pop(ctx, scope) }
}

gallery_initialize :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil { return }
	app.allocator = context.allocator

	// A light variant is ordinary application data: copy the built-in typed
	// theme, replace semantic colors, and register it once.
	light := alicorn.DEFAULT_STYLE_THEME
	light.colors = [alicorn.STYLE_COLOR_ROLE_COUNT]ui.Color{
		{0.93, 0.95, 0.98, 1},
		{0.99, 0.995, 1, 1},
		{0.90, 0.92, 0.95, 1},
		{0.97, 0.98, 1, 1},
		{0.07, 0.09, 0.14, 1},
		{0.28, 0.33, 0.41, 1},
		{0.07, 0.34, 0.72, 1},
		{0.05, 0.27, 0.60, 1},
		{0.04, 0.21, 0.49, 1},
		{1, 1, 1, 1},
		{0.54, 0.68, 0.88, 0.45},
		{0.05, 0.30, 0.78, 1},
		{0.41, 0.17, 0.64, 1},
		{0.40, 0.46, 0.55, 1},
		{0.70, 0.13, 0.12, 1},
		{0.05, 0.39, 0.20, 1},
		{0.88, 0.90, 0.93, 1},
		{0.48, 0.54, 0.61, 1},
	}
	app.light_theme = alicorn.style_theme_register(rt, light)

	// One scoped theme carries namespaced extension colors for gradient and
	// shape demos. The runtime copies tokens and bindings on registration.
	surface_theme := alicorn.DEFAULT_STYLE_THEME
	surface_theme.color_tokens = {
		alicorn.Color{0.12, 0.38, 0.62, 1},
		alicorn.Color{0.08, 0.70, 0.68, 1},
		alicorn.Color{0.96, 0.60, 0.24, 1},
		alicorn.Color{0.62, 0.42, 0.92, 1},
	}
	start_role := alicorn.style_extension_color_role_id("app.gallery.surface", "gradient.start")
	end_role := alicorn.style_extension_color_role_id("app.gallery.surface", "gradient.end")
	arc_role := alicorn.style_extension_color_role_id("app.gallery.surface", "arc")
	ring_role := alicorn.style_extension_color_role_id("app.gallery.surface", "ring")
	surface_theme.extension_color_roles = {
		alicorn.Style_Extension_Color_Role_Binding{start_role, alicorn.Style_Color_Token_ID(1)},
		alicorn.Style_Extension_Color_Role_Binding{end_role, alicorn.Style_Color_Token_ID(2)},
		alicorn.Style_Extension_Color_Role_Binding{arc_role, alicorn.Style_Color_Token_ID(3)},
		alicorn.Style_Extension_Color_Role_Binding{ring_role, alicorn.Style_Color_Token_ID(4)},
	}
	app.surface_theme = alicorn.style_theme_register(rt, surface_theme)

	gallery_theme_status_set(app, "Preparing the custom theme from theme.json…")
}

gallery_start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	gallery_start_compile(app)
}

gallery_wake :: proc(app: ^App, ctx: ui.Application_Context) {
	sync.mutex_lock(&app.completion_mutex)
	complete := app.worker_complete
	read_failed := app.read_failed
	candidate := app.candidate
	app.candidate = theme.Theme_JSON_Compile_Output{}
	app.worker_complete = false
	app.read_failed = false
	sync.mutex_unlock(&app.completion_mutex)
	if !complete { return }
	if app.worker != nil {
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	app.compiling = false
	if read_failed {
		gallery_theme_status_set(app, "Could not read examples/08_control_gallery/theme.json from the repository root.")
	} else if !candidate.ok {
		gallery_theme_status_set(app, gallery_compile_error_text(&candidate))
	} else {
		rt := cast(^alicorn.Runtime)ctx
		_ = gallery_adopt_candidate(app, rt, &candidate)
	}
	theme.theme_json_compile_output_destroy(&candidate, app.allocator)
	ui.invalidate(ctx, "Control Gallery theme compilation completed")
}

gallery_stop :: proc(app: ^App) {
	if app.worker != nil {
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	theme.theme_json_compile_output_destroy(&app.candidate, app.allocator)
	theme.theme_json_compile_output_destroy(&app.active_output, app.allocator)
}

gallery_install_menus :: proc(app: ^App) {
	app.menu_view_items = [8]alicorn.Menu_Item{
		{kind=.Command, command=GALLERY_ACTION_FOUNDATIONS, label="Foundations", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'1', {.Primary}}},
		{kind=.Command, command=GALLERY_ACTION_CONTROLS, label="Controls", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'2', {.Primary}}},
		{kind=.Command, command=GALLERY_ACTION_COLLECTIONS, label="Collections", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'3', {.Primary}}},
		{kind=.Command, command=GALLERY_ACTION_LAYOUT, label="Layout & surfaces", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'4', {.Primary}}},
		{kind=.Command, command=GALLERY_ACTION_OVERLAYS, label="Overlays & commands", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'5', {.Primary}}},
		{kind=.Command, command=GALLERY_ACTION_MOTION, label="Motion & themes", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'6', {.Primary}}},
		{kind=.Separator},
		{kind=.Command, command=GALLERY_ACTION_RELOAD_THEME, label="Reload theme.json", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'R', {.Primary}}},
	}
	app.menu_help_items = [1]alicorn.Menu_Item{
		{kind=.Command, command=GALLERY_ACTION_ABOUT, label="About the Control Gallery", state=alicorn.Action_State{enabled=true}},
	}
	app.menus[0] = alicorn.Menu{label="View", items=app.menu_view_items[:]}
	app.menus[1] = alicorn.Menu{label="Help", items=app.menu_help_items[:]}
}

main :: proc() {
	name, ok := ui.text_buffer("Alicorn")
	if !ok { return }
	app := App{
		name=name,
		gain=0.65,
		density_key=2,
		selected_record=41,
		selected_order=0,
		active_doc=0,
		motion_choice=0,
		theme_choice=.Default,
		docs={
			{title="main.odin", open=true, dirty=true},
			{title="theme.json", open=true, dirty=false},
			{title="README.md", open=true, dirty=false},
		},
		order={
			{id=1, label="Foundations"},
			{id=2, label="Controls"},
			{id=3, label="Collections"},
			{id=4, label="Layout"},
			{id=5, label="Overlays"},
		},
	}
	for argument in os.args {
		if argument == "--smoke" {
			app.smoke = true
		} else if argument == "--dialog" {
			app.dialog_open = true
		} else if strings.has_prefix(argument, "--section=") {
			// Developer affordance for repeatable screenshots and focused review.
			index, ok := strconv.parse_int(strings.trim_prefix(argument, "--section="))
			if ok && index >= 0 && index < GALLERY_SECTION_COUNT {
				app.section = Section(index)
			}
		} else if strings.has_prefix(argument, "--theme=") {
			switch strings.trim_prefix(argument, "--theme=") {
			case "light":
				app.theme_choice = .Light
				app.theme_choice_explicit = true
			case "custom":
				app.theme_choice = .Custom
				app.theme_choice_explicit = false
			case:
				app.theme_choice = .Default
				app.theme_choice_explicit = true
			}
		}
	}
	defer ui.text_buffer_destroy(&app.name)
	gallery_install_menus(&app)

	ui.run(
		&app,
		render,
		title="Alicorn · Control Gallery",
		width=1180,
		height=900,
		render_overlays=gallery_render_overlays,
		on_initialize=gallery_initialize,
		on_start=gallery_start,
		on_wake=gallery_wake,
		on_stop=gallery_stop,
		on_after_frame=gallery_after_frame,
		on_drag=gallery_drag,
		on_menu_command=gallery_menu_command,
		menus=app.menus[:],
	)
}
