# Component recipes

These recipes are compact, working excerpts from the
[Control Gallery](../examples/08_control_gallery/main.odin). The gallery is the
runnable source of truth: each recipe names the file and section that implements
it end to end. Use the [API reference](reference.md) for every parameter and
contract.

Start any recipe from the ordinary application shape:

```odin
import ui "alicorn:ui"

App :: struct { /* application-owned state */ }

render :: proc(app: ^App, ctx: ^ui.UI) {
	// describe the UI here
}

main :: proc() {
	app := App{}
	ui.run(&app, render, title="My app", width=960, height=720)
}
```

The gallery's shell adds a header, a section tab bar, a scrollable page, and a
status footer. See `main.odin` (`render`, `gallery_header`,
`gallery_navigation`, `gallery_footer`).

## A form with application validation

`ui.text_field` emits a visible label and binds it to the field's accessible
name. The app owns the value and decides whether an empty value is invalid.
Add the `.Invalid` semantic state immediately after the field, before describing
the next control.

```odin
name: ui.Text_Buffer
name_invalid: bool
notifications: bool

// In render:
_ = ui.text_field(ctx, "Display name", &app.name, key="display-name", height=34)
if app.name_invalid {
	_ = alicorn.semantic_augment(
		ctx,
		description="Display name is required.",
		states_add=alicorn.semantic_states_add({}, .Invalid),
	)
}
if ui.button(ctx, "Validate", variant=.Primary, width=100) {
	app.name_invalid = len(app.name.text) == 0
}
ui.checkbox(ctx, "Email me about updates", &app.notifications)
```

Initialize and destroy the buffer once:

```odin
name, ok := ui.text_buffer("Alicorn")
if !ok { return }
app := App{name=name}
defer ui.text_buffer_destroy(&app.name)
```

Source: `controls.odin`. Reference:
[text fields and controls](reference.md#small-native-applications), [semantic
model](reference.md#semantic-model-and-collections), [checkbox and slider
recipes](reference.md#checkbox-and-slider-recipes).

## A slider with a human-readable value

`ui.slider_f32` adopts user changes directly. If the numeric value is not the
best thing to announce, call `semantic_range_value_text` immediately after the
slider; the numeric range, minimum, maximum, and step are preserved.

```odin
gain: f32

_ = ui.slider_f32(ctx, "Gain", &app.gain, 0, 1, step=0.05, key="gain", height=40)
_ = alicorn.semantic_range_value_text(ctx, fmt.tprintf("%.0f percent", app.gain*100))
```

Source: `controls.odin`. Reference:
[checkbox and slider recipes](reference.md#checkbox-and-slider-recipes),
[semantic model](reference.md#semantic-model-and-collections).

## A select (combo box) with a disabled option

The application stores the selected key and applies the controlled result on
the next description. The runtime owns the popup, type-ahead, scrolling, focus
restoration, and Combo_Box/List_Box semantics.

```odin
density_key: u64

options := [4]alicorn.Select_Option{
	{key=1, label="Compact"},
	{key=2, label="Comfortable"},
	{key=3, label="Spacious"},
	{key=4, label="Custom theme only", disabled=true},
}
choice := alicorn.select_control(
	ctx,
	"settings-density",
	"Density",
	options[:],
	app.density_key,
	style=ui.layout_style(width=-1, height=36),
)
if choice.changed { app.density_key = choice.selected_key }
```

Source: `controls.odin`. Reference:
[select controls](reference.md#select-controls).

## A virtualized list with selection

Emit only `[list.first, list.last)`. Every row must occupy exactly
`row_height`; keys follow data identity, not the current position.

```odin
selected: int

if list, ok := ui.virtual_list(
	ctx, 500, 28,
	key="records",
	height=260,
	grow=0,
	label="500 stable records",
	focusable=true,
); ok {
	for position in list.first..<list.last {
		if ui.button(
			ctx,
			fmt.tprintf("Record %03d", position+1),
			key=ui.key_u64(u64(position+1)),
			style=ui.layout_style(.Row, height=28),
			state=alicorn.Button_State{selected=position == app.selected},
			content_style=alicorn.button_content_style(.Start, .Center, padding_x=10),
		) {
			app.selected = position
		}
	}
}
```

Source: `collections.odin`. Reference:
[collections and panes](reference.md#collections-and-panes),
[semantic focus in virtualized views](reference.md#semantic-focus-in-virtualized-views).

## Tabs with close and dirty state

`tab_bar` reports one requested action by item index. The app owns the document
list, order, dirty flags, and close policy. Item keys stay stable across
reordering.

```odin
Doc :: struct { title: string, open: bool, dirty: bool }
docs: [3]Doc

items: [3]alicorn.Tab_Bar_Item
count := 0
for doc, index in app.docs {
	if !doc.open { continue }
	items[count] = alicorn.Tab_Bar_Item{
		key=ui.key_u64(u64(index+1)),
		label=doc.title,
		selected=index == app.active_doc,
		closable=true,
		dirty=doc.dirty,
	}
	count += 1
}
result := alicorn.tab_bar(ctx, "document-tabs", items[:count])
switch result.action {
case .Select: // map the open-tab position back to a document
case .Close:  // mark that document closed and choose a new active document
case .None:
}
```

Source: `collections.odin` (`gallery_document_tabs`). Reference:
[tab bars](reference.md#tab-bars).

## Drag to reorder a list

Annotate the most recently described node. The app chooses a nonzero
`Drag_Type` and stable `Semantic_ID`s; Alicorn reports started, target-changed,
dropped, and cancelled events but never decides what a drop means.

```odin
owner, activated := alicorn.button_begin(ctx, item.label, key=ui.key_u64(item.id),
	style=ui.layout_style(.Row, height=30))
if owner != 0 {
	_ = alicorn.semantic_bind(ctx, item.identity)
	_ = alicorn.drag_source(ctx, DRAG_TYPE, item.identity, .Label)
	_ = alicorn.drop_target(ctx, DRAG_TYPE, item.identity, .Between_Vertical)
	if activated { app.selected = item.id }
	alicorn.button_end(ctx)
}

// ui.run(on_drag=...)
if event.kind == .Dropped {
	// Find source and target in application state, then apply Before/After.
	alicorn.invalidate_root(rt, "reorder adopted")
}
```

Source: `collections.odin` (`gallery_reorder_list`) and `main.odin`
(`gallery_drag`). Reference:
[local drag and drop](reference.md#local-drag-and-drop).

## Split panes, Grid, and positioned labels

A split owns a preferred extent; the app does not recompute pane geometry while
the user drags. Grid cells are explicit. Positioned labels use the owner's
content-box coordinates and do not consume flow space.

```odin
split := alicorn.split_begin(ctx, "editor-split", .Horizontal, 220,
	min_first=132, min_second=180, style=ui.layout_style(.Row, height=178))
if split.id != 0 {
	if alicorn.split_first_begin(ctx, split) != 0 {
		ui.text(ctx, "Navigator")
		alicorn.split_first_end(ctx, split)
	}
	_ = alicorn.split_divider(ctx, split, 2, 10)
	if alicorn.split_second_begin(ctx, split) != 0 {
		ui.text(ctx, "Preview")
		alicorn.split_second_end(ctx, split)
	}
	alicorn.split_end(ctx, split)
}

if ui.column(ctx, key="ruler", width=360, height=62, clip=true) {
	_ = ui.box(ctx, width=352, height=1, fill=alicorn.style_color(ctx, .Border))
	for second in 0..=6 {
		x := f32(second)/6*352
		_ = ui.positioned_text(ctx, fmt.tprintf("%ds", second), x, 8,
			key=ui.key_u64(u64(second+1)), size=11)
	}
}
```

Source: `layout_surfaces.odin`. Reference:
[collections and panes](reference.md#collections-and-panes),
[shared-track Grid](reference.md#shared-track-grid),
[positioned labels](reference.md#positioned-labels).

## A modal with focus restoration

Describe the workspace first, close its root, then describe the modal overlay.
The app owns dismissal and asks for focus to return after the next layout.

```odin
dialog_open: bool
dialog_opener: alicorn.Node_ID

opener, clicked := alicorn.button_ex(ctx, "Open dialog", key="open-dialog",
	style=ui.layout_style(width=220, height=32), variant=.Primary)
if clicked {
	app.dialog_opener = opener
	app.dialog_open = true
}

// ui.run(render_overlays=...)
if app.dialog_open && alicorn.modal_overlay_begin(ctx, "confirm-modal",
	style=ui.layout_style(.Column, align=.Center, justify=.Center)) != 0 {
	if ui.panel(ctx, width=440, height=218, padding=22, gap=12) {
		_ = alicorn.semantic_description(ctx, .Dialog, "Confirm deletion")
		if ui.button(ctx, "Cancel", key="cancel", width=110, height=32) {
			app.dialog_open = false
			_ = ui.after_frame(ctx, rawptr(app), restore_dialog_focus)
		}
	}
	alicorn.modal_overlay_end(ctx)
}
```

The callback runs after the next reconciled frame and calls
`alicorn.focus(rt, app.dialog_opener)`. See `gallery_close_dialog` and
`gallery_restore_dialog_focus` in `overlays_themes.odin`. Reference:
[transient modal surfaces](reference.md#transient-modal-surfaces).

## Tooltip and single-level context menu

Attach help immediately after the control. Open a context menu from the focused
control, then describe it after the ordinary root.

```odin
_ = ui.button(ctx, "Hover for help", key="tooltip-target", width=160, height=30)
_ = alicorn.tooltip(ctx, "Tooltips wait for a one-shot hover deadline.", 350)

if ui.button(ctx, "Open context menu", key="open-menu") {
	_ = alicorn.context_menu_open_for_focused(ctx.runtime)
}

// In render_overlays:
if alicorn.context_menu_begin(ctx, "row-menu", width=232) {
	alicorn.context_menu_item(ctx, RENAME, "Rename record")
	alicorn.context_menu_item(ctx, DUPLICATE, "Duplicate record")
	alicorn.context_menu_separator(ctx)
	alicorn.context_menu_item(ctx, DELETE, "Delete record", enabled=false)
	action := alicorn.context_menu_end(ctx)
	if action != 0 { app_handle_command(action) }
}
```

Source: `overlays_themes.odin`. Reference:
[tooltips](reference.md#tooltips), [context menus](reference.md#context-menus).

## Application notices

Post notices between frames. Use stable IDs for conditions that update in place
and let the application dismiss or resolve persistent failures.

```odin
// After end_frame, for example from ui.run(on_after_frame=...):
_ = alicorn.notice_post(rt, alicorn.Notice{
	id="workspace-failure",
	title="Couldn't refresh folder",
	message="The folder's contents may be out of date.",
	severity=.Warning,
	lifetime=.Persistent,
	placement=.Toast,
}, 0)

// Later, when app state resolves the condition:
_ = alicorn.notice_dismiss(rt, "workspace-failure")
```

Source: `overlays_themes.odin` (`gallery_after_frame`). Reference:
[notices](reference.md#notices).

## Theme variants and a scoped accent

Copy and register a typed theme once, then select it with a scoped
`Style_Environment`. A zero theme ID inherits the default.

```odin
// on_initialize(app, rt):
light := alicorn.DEFAULT_STYLE_THEME
light.colors = /* replace the semantic color roles */
app.light_theme = alicorn.style_theme_register(rt, light)

// In render, immediately after a described container boundary:
scope := alicorn.style_environment_push(ctx,
	alicorn.Style_Environment{theme=app.light_theme})
if ui.button(ctx, "Primary action", variant=.Primary) { /* ... */ }
if scope.active { alicorn.style_environment_pop(ctx, scope) }

// A subtree-local accent does not need a theme registration:
accent := alicorn.style_environment_push(ctx, alicorn.Style_Environment{
	accent=alicorn.style_accent(ui.rgb(0xE07A3F)),
})
```

Source: `main.odin` (`gallery_initialize`, `render`) and
`overlays_themes.odin` (`gallery_theme_picker`, `gallery_accent_demo`).
Reference: [scoped style environment](reference.md#scoped-style-environment),
[typed themes](themes.md).

For live JSON color editing, compile off the application thread, validate that
the candidate keeps the same structure, then register or replace it between
frames. See [experimental live color editing](themes.md#experimental-live-color-editing)
and `gallery_adopt_candidate` in `main.odin`.

## Retained motion for a decorative marker

Declare a target during ordinary description. Layout, hit geometry, and
semantics remain authoritative; only presentation moves.

```odin
counter := alicorn.container_begin(ctx, .Container,
	key="selection-indicator",
	style=ui.layout_style(.Row, width=112, height=4),
	color=alicorn.style_color(ctx, .Accent))
_ = ui.motion(ctx, counter,
	ui.Motion_Target{
		translation=ui.Motion_Vector2{f64(app.selected)*(112+8), 0},
		has_translation=true,
	})
alicorn.container_end(ctx)
```

Source: `overlays_themes.odin` (`gallery_motion_demo`). Reference:
[text, runtime, and presentation](reference.md#text-runtime-and-presentation)
and the [retained motion example](../examples/09_retained_motion/main.odin).

## Where to go next

- [Control Gallery](../examples/08_control_gallery/README.md) — the complete,
  runnable inventory behind these recipes.
- [Progressive application guide](guide.md) — the longer form of each concept.
- [API reference](reference.md) — public Odin signatures and behavior limits.
- [Typed themes](themes.md) — authoring, validation, materials, and live reload.
- [Examples](../examples/README.md) — focused lessons for workers, custom
  surfaces, motion, secondary windows, and host-owned presentation.
