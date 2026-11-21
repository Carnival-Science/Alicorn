package scratchpad_scene

// scratchpad_scene is the Scratchpad-shaped workload used by the issue #229
// performance harness. One description is shared by the SDL_GPU reference
// host, the hosted WebGPU hosts, and the headless testui harness so a stage
// timing from one backend is comparable with the others.
//
// The scene intentionally mirrors the real Scratchpad composition without
// importing it: a dense virtualized editor (10,000 logical lines), an
// expandable 1,000-node workspace tree, a closable document tab bar, a pinned
// rounded side panel with a gradient accent, a focused command field with a
// selection, and a status strip.
//
// Application state is preallocated at init. Per-frame description therefore
// does not allocate row labels or tree labels, which keeps the allocation
// counters focused on runtime work (the controlled text field still performs
// its ordinary model-text copy when typing).

import "core:fmt"
import "core:mem"
import "core:strings"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

SCRATCHPAD_WIDTH :: 960
SCRATCHPAD_HEIGHT :: 640
EDITOR_LINE_COUNT :: 10_000
EDITOR_ROW_HEIGHT :: 18
TREE_NODE_COUNT :: 1_000
TREE_ROOT_COUNT :: 20
TREE_CHILDREN_PER_ROOT :: 49
TREE_ROW_HEIGHT :: 22
TAB_COUNT :: 8

Interaction :: enum {
	Typing,
	Scroll,
	Selection,
	Resize,
	Tabs,
	// Churn changes the content of every realized row each step while the
	// retained string keeps its address and length. It is the adversarial
	// high-churn control for description reuse: no node may be reused.
	Churn,
	Idle,
}

interaction_from_name :: proc(name: string) -> (Interaction, bool) {
	switch name {
	case "typing": return .Typing, true
	case "scroll": return .Scroll, true
	case "selection": return .Selection, true
	case "resize": return .Resize, true
	case "tabs": return .Tabs, true
	case "churn": return .Churn, true
	case "idle": return .Idle, true
	}
	return .Idle, false
}

interaction_name :: proc(interaction: Interaction) -> string {
	switch interaction {
	case .Typing: return "typing"
	case .Scroll: return "scroll"
	case .Selection: return "selection"
	case .Resize: return "resize"
	case .Tabs: return "tabs"
	case .Churn: return "churn"
	case .Idle: return "idle"
	}
	return "idle"
}

Gradient_Roles :: struct {
	accent_start, accent_end: alicorn.Style_Extension_Color_Role_ID,
}

Scene :: struct {
	allocator: mem.Allocator,
	interaction: Interaction,
	step: u64,

	lines: []string,
	edit_line_index: int,
	edit_line: [256]u8,
	edit_line_len: int,

	tree_labels_collapsed: []string,
	tree_labels_expanded: []string,
	tree_parent: []int,
	tree_depth: []u8,
	tree_children: []int,
	tree_expanded: []bool,
	tree_visible: []int,
	tree_visible_count: int,

	tab_titles: [TAB_COUNT]string,
	tab_open: [TAB_COUNT]bool,
	active_tab: int,

	editor_scroll: f32,
	tree_scroll: f32,
	// churn_epoch advances once per churn step. The minimap bars and the
	// command field read it so most described nodes change every frame.
	churn_epoch: u64,
	// Realized virtualization ranges recorded by the last description. Churn
	// mutates exactly the rows the runtime realized.
	editor_first: int,
	editor_last: int,
	tree_first: int,
	tree_last: int,

	field_buffer: alicorn.Text_Field_Buffer,
	field_text: [512]u8,
	field_node: alicorn.Node_ID,
	editor_list_id: alicorn.Node_ID,
	tree_list_id: alicorn.Node_ID,

	theme: alicorn.Style_Theme_ID,
	roles: Gradient_Roles,
	initialized: bool,
}

scene_init :: proc(scene: ^Scene, interaction: Interaction, allocator := context.allocator) -> bool {
	if scene == nil { return false }
	scene^ = Scene{allocator=allocator, interaction=interaction}
	scene.lines = make([]string, EDITOR_LINE_COUNT, allocator)
	scene.tree_labels_collapsed = make([]string, TREE_NODE_COUNT, allocator)
	scene.tree_labels_expanded = make([]string, TREE_NODE_COUNT, allocator)
	scene.tree_parent = make([]int, TREE_NODE_COUNT, allocator)
	scene.tree_depth = make([]u8, TREE_NODE_COUNT, allocator)
	scene.tree_children = make([]int, TREE_NODE_COUNT, allocator)
	scene.tree_expanded = make([]bool, TREE_NODE_COUNT, allocator)
	scene.tree_visible = make([]int, TREE_NODE_COUNT, allocator)
	if scene.lines == nil || scene.tree_labels_collapsed == nil ||
	   scene.tree_labels_expanded == nil || scene.tree_parent == nil ||
	   scene.tree_depth == nil || scene.tree_children == nil ||
	   scene.tree_expanded == nil || scene.tree_visible == nil {
		return false
	}

	for index in 0..<EDITOR_LINE_COUNT {
		switch index % 6 {
		case 0:
			scene.lines[index] = fmt.aprintf(
				"%05d  pub fn update_%04d(state: ^State, delta: f32) -> f32 {",
				index+1, index, allocator=allocator,
			)
		case 1:
			scene.lines[index] = fmt.aprintf(
				"%05d      state.value += delta*%.3f", index+1, f32(index%7)*0.125, allocator=allocator,
			)
		case 2:
			scene.lines[index] = fmt.aprintf(
				"%05d      if state.value < 0 { state.value = 0 }", index+1, allocator=allocator,
			)
		case 3:
			scene.lines[index] = fmt.aprintf(
				"%05d      retain(&state.nodes[%04d], \"row-%06d\")", index+1, index%997, index, allocator=allocator,
			)
		case 4:
			scene.lines[index] = fmt.aprintf(
				"%05d      state.flags |= FLAG_RETAINED | FLAG_VISIBLE", index+1, allocator=allocator,
			)
		case 5:
			scene.lines[index] = fmt.aprintf(
				"%05d  }", index+1, allocator=allocator,
			)
		}
	}
	scene.edit_line_index = 5

	root_names := [6]string{"src", "editor", "runtime", "docs", "tests", "benchmarks"}
	leaf_names := [6]string{"main.odin", "scene.odin", "layout.odin", "paint.odin", "reconcile.odin", "text.odin"}
	next := 0
	for root in 0..<TREE_ROOT_COUNT {
		node := next
		next += 1
		scene.tree_parent[node] = -1
		scene.tree_depth[node] = 0
		scene.tree_children[node] = TREE_CHILDREN_PER_ROOT
		scene.tree_labels_collapsed[node] = fmt.aprintf("[+] %s", root_names[root%len(root_names)], allocator=allocator)
		scene.tree_labels_expanded[node] = fmt.aprintf("[-] %s", root_names[root%len(root_names)], allocator=allocator)
		for child_index in 0..<TREE_CHILDREN_PER_ROOT {
			child := next
			next += 1
			scene.tree_parent[child] = node
			scene.tree_depth[child] = 1
			scene.tree_children[child] = 0
			leaf := leaf_names[(root+child_index)%len(leaf_names)]
			scene.tree_labels_collapsed[child] = fmt.aprintf("%s_%03d", leaf, child, allocator=allocator)
			scene.tree_labels_expanded[child] = ""
		}
	}
	scene.tree_expanded[0] = true
	scene.tree_expanded[1+TREE_CHILDREN_PER_ROOT] = true

	scene.tab_titles = [TAB_COUNT]string{
		"scene.odin", "layout.odin", "paint.odin", "reconcile.odin",
		"text.odin", "harness.odin", "ledger.md", "baseline.md",
	}
	for index in 0..<TAB_COUNT { scene.tab_open[index] = true }
	scene.active_tab = 0

	buffer, buffer_ok := alicorn.text_field_buffer_init("filter: retained", allocator)
	if !buffer_ok { return false }
	scene.field_buffer = buffer
	if scene.field_buffer.text == "" { return false }
	scene.initialized = true
	scene_update_tree_visible(scene)
	return true
}

scene_destroy :: proc(scene: ^Scene) {	if scene == nil || !scene.initialized { return }
	for text in scene.lines { if len(text) > 0 { delete(text, scene.allocator) } }
	for text in scene.tree_labels_collapsed { if len(text) > 0 { delete(text, scene.allocator) } }
	for text in scene.tree_labels_expanded { if len(text) > 0 { delete(text, scene.allocator) } }
	delete(scene.lines, scene.allocator)
	delete(scene.tree_labels_collapsed, scene.allocator)
	delete(scene.tree_labels_expanded, scene.allocator)
	delete(scene.tree_parent, scene.allocator)
	delete(scene.tree_depth, scene.allocator)
	delete(scene.tree_children, scene.allocator)
	delete(scene.tree_expanded, scene.allocator)
	delete(scene.tree_visible, scene.allocator)
	alicorn.text_field_buffer_destroy(&scene.field_buffer)
	scene^ = Scene{}
}

// register_theme installs the two gradient stops used by the pinned side-panel
// accent. It is deliberately a separate call so tests can describe the scene
// without a theme and still exercise the surface path.
register_theme :: proc(scene: ^Scene, rt: ^alicorn.Runtime) -> bool {
	if scene == nil || rt == nil { return false }
	scene.roles = Gradient_Roles{
		accent_start=alicorn.style_extension_color_role_id("app.scratchpad.perf", "accent.start"),
		accent_end=alicorn.style_extension_color_role_id("app.scratchpad.perf", "accent.end"),
	}
	theme := alicorn.DEFAULT_STYLE_THEME
	theme.color_tokens = {
		alicorn.Color{0.10, 0.23, 0.36, 1},
		alicorn.Color{0.06, 0.52, 0.58, 1},
	}
	theme.extension_color_roles = {
		alicorn.Style_Extension_Color_Role_Binding{scene.roles.accent_start, alicorn.Style_Color_Token_ID(1)},
		alicorn.Style_Extension_Color_Role_Binding{scene.roles.accent_end, alicorn.Style_Color_Token_ID(2)},
	}
	scene.theme = alicorn.style_theme_register(rt, theme)
	return scene.theme != 0
}

scene_update_tree_visible :: proc(scene: ^Scene) {
	count := 0
	for index in 0..<TREE_NODE_COUNT {
		parent := scene.tree_parent[index]
		if parent >= 0 && !scene.tree_expanded[parent] { continue }
		scene.tree_visible[count] = index
		count += 1
	}
	scene.tree_visible_count = count
}

scene_editor_line_text :: proc(scene: ^Scene, index: int) -> string {
	if index == scene.edit_line_index {
		return string(scene.edit_line[:scene.edit_line_len])
	}
	if index < 0 || index >= len(scene.lines) { return "" }
	return scene.lines[index]
}

scene_editor_list :: proc(scene: ^Scene, ctx: ^ui.UI) {
	rt := ctx.runtime
	if list, ok := ui.virtual_list(
		ctx,
		EDITOR_LINE_COUNT,
		EDITOR_ROW_HEIGHT,
		key="scratchpad-editor-lines",
		height=-1,
		grow=1,
		label="Dense editor text",
		focusable=true,
	); ok {
		scene.editor_list_id = list.scroll.id
		scene.editor_first = list.first
		scene.editor_last = list.last
		for index in list.first..<list.last {
			text := scene_editor_line_text(scene, index)
			// Scratchpad shapes a temporary run for each realized editor row to
			// resolve display ranges before describing the retained row. Repeating
			// that app-shaped work keeps the harness representative instead of
			// measuring a runtime-only fixture.
			if rt != nil {
				if run, built := alicorn.runtime_text_run_build(
					rt,
					text,
					size=12,
					max_width=0,
					font=.Monospace,
					overflow=.Clip,
					editable=true,
					allocator=context.temp_allocator,
					scratch_allocator=alicorn.runtime_scratch_allocator(rt),
				); built {
					alicorn.text_run_destroy(&run)
				}
			}
			if ui.row(ctx, key=ui.key_u64(300_000+u64(index)), height=EDITOR_ROW_HEIGHT, gap=8, label="scratchpad-editor-row") {
				ui.text(
					ctx,
					fmt.tprintf("%d", index+1),
					key=ui.key_u64(400_000+u64(index)),
					style=ui.layout_style(width=42),
					size=11,
					font=.Monospace,
					decorative=true,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
				code := ui.text(
					ctx,
					text,
					key=ui.key_u64(100_000+u64(index)),
					style=ui.layout_style(width=-1, height=EDITOR_ROW_HEIGHT),
					font=.Monospace,
					size=12,
					decorative=true,
					color=alicorn.style_color(ctx, .Text),
				)
				if code != 0 {
					spans := make([dynamic]alicorn.Text_Paint_Span, 0, 3, context.temp_allocator)
					append(&spans, alicorn.Text_Paint_Span{
						start=0, end=min(3, len(text)),
						color=alicorn.Color{0.45, 0.68, 0.98, 1}, color_set=true,
					})
					if len(text) > 10 {
						append(&spans, alicorn.Text_Paint_Span{
							start=6, end=min(10, len(text)),
							color=alicorn.Color{0.82, 0.63, 0.42, 1}, color_set=true,
						})
					}
					append(&spans, alicorn.Text_Paint_Span{
						start=10 if len(text) > 10 else 0, end=len(text),
						color=alicorn.style_color(ctx, .Muted_Text), color_set=true,
					})
					_ = alicorn.text_paint_spans(ctx, code, spans[:])
					delete(spans)
				}
			}
		}
	}
}

scene_tree_list :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if list, ok := ui.virtual_list(
		ctx,
		scene.tree_visible_count,
		TREE_ROW_HEIGHT,
		key="scratchpad-workspace-tree",
		height=-1,
		grow=1,
		label="Workspace tree",
		focusable=true,
	); ok {
		scene.tree_list_id = list.scroll.id
		scene.tree_first = list.first
		scene.tree_last = list.last
		for position in list.first..<list.last {
			node := scene.tree_visible[position]
			expanded := scene.tree_expanded[node]
			label := scene.tree_labels_collapsed[node]
			if expanded { label = scene.tree_labels_expanded[node] }
			padding := 8 + f32(scene.tree_depth[node])*12
			if ui.button(
				ctx,
				label,
				key=ui.key_u64(10_000+u64(node)),
				style=ui.layout_style(.Row, width=-1, height=TREE_ROW_HEIGHT),
				variant=.Quiet,
				content_style=alicorn.button_content_style(.Start, .Center, padding_x=padding),
			) {
				if scene.tree_children[node] > 0 {
					scene.tree_expanded[node] = !scene.tree_expanded[node]
					scene_update_tree_visible(scene)
					ui.invalidate(ctx, "scratchpad tree expansion changed")
				}
			}
		}
	}
}

scene_sidebar :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if ui.panel(
		ctx,
		key="scratchpad-sidebar",
		width=238,
		grow=0,
		padding=8,
		gap=6,
		radius=10,
		stroke=ui.border(1, alicorn.style_color(ctx, .Border)),
		fill=alicorn.style_color(ctx, .Subtle_Surface),
		label="Pinned workspace panel",
	) {
		if scene.theme != 0 {
			if accent := alicorn.surface_begin(
				ctx,
				alicorn.surface_extension_color_role(scene.roles.accent_start),
				key="scratchpad-sidebar-accent",
				style=alicorn.layout_style(.Row, width=-1, height=42, padding=10, align=.Center),
				shape=alicorn.surface_shape_rounded_corners({top_left=8, top_right=8, bottom_right=8, bottom_left=8}),
				gradient=alicorn.surface_gradient_to(alicorn.surface_extension_color_role(scene.roles.accent_end), .Horizontal),
				label="Workspace accent",
			); accent != 0 {
				ui.text(ctx, "SCRATCHPAD", size=12, color=alicorn.Color{0.95, 0.98, 1, 1})
				alicorn.surface_end(ctx)
			}
		}
		ui.text(ctx, "Workspace", size=12, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
		scene_tree_list(scene, ctx)
		ui.text(ctx, "1,000 retained tree nodes", size=10, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
	}
}

scene_tab_bar :: proc(scene: ^Scene, ctx: ^ui.UI) {
	items: [TAB_COUNT]alicorn.Tab_Bar_Item
	count := 0
	for index in 0..<TAB_COUNT {
		if !scene.tab_open[index] { continue }
		items[count] = alicorn.Tab_Bar_Item{
			key=ui.key_u64(u64(index+1)),
			label=scene.tab_titles[index],
			selected=index == scene.active_tab,
			closable=true,
			dirty=index%3 == 1,
		}
		count += 1
	}
	if count == 0 { return }
	result := alicorn.tab_bar(
		ctx,
		"scratchpad-document-tabs",
		items[:count],
		options=alicorn.Tab_Bar_Options{min_tab_width=104, max_tab_width=156, height=32, gap=2},
		style=ui.layout_style(.Row, width=-1, height=36, clip=true),
	)
	switch result.action {
	case .Select:
		// Map the open-item position back to the stable tab index.
		position := 0
		for index in 0..<TAB_COUNT {
			if !scene.tab_open[index] { continue }
			if position == result.item_index {
				if scene.active_tab != index {
					scene.active_tab = index
					ui.invalidate(ctx, "scratchpad tab selected")
				}
				break
			}
			position += 1
		}
	case .Close:
		position := 0
		for index in 0..<TAB_COUNT {
			if !scene.tab_open[index] { continue }
			if position == result.item_index {
				scene.tab_open[index] = false
				if scene.active_tab == index {
					for next in 0..<TAB_COUNT {
						if scene.tab_open[next] { scene.active_tab = next; break }
					}
				}
				ui.invalidate(ctx, "scratchpad tab closed")
				break
			}
			position += 1
		}
	case .None:
	}
}

scene_editor :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if ui.column(ctx, grow=1, gap=6, label="scratchpad-editor") {
		if ui.row(ctx, height=28, gap=8, align=.Center, label="scratchpad-editor-header") {
			ui.text(ctx, "scratchpad / frontend / app", size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
			ui.text(ctx, scene.tab_titles[scene.active_tab], size=13, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
			ui.text(ctx, "editor · virtualized 10,000 lines", size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
		}
		if ui.row(ctx, height=28, gap=4, align=.Center, label="scratchpad-editor-toolbar") {
			toolbar := [6]string{"Run", "Split", "Find", "Wrap", "Outline", "More"}
			for label, index in toolbar {
				if ui.button(
					ctx,
					label,
					key=ui.key_u64(500_000+u64(index)),
					height=24,
					variant=.Quiet,
				) {}
			}
		}
		scene_editor_list(scene, ctx)
		if ui.row(ctx, height=34, gap=8, align=.Center, label="scratchpad-command-row") {
			response := ui.text_field(
				ctx,
				"Go to line",
				&scene.field_buffer,
				key="scratchpad-command-field",
				height=28,
				width=-1,
				grow=1,
			)
			if response.node != 0 { scene.field_node = response.node }
		}
	}
}

scene_minimap :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if ui.panel(
		ctx,
		key="scratchpad-minimap",
		width=64,
		grow=0,
		padding=6,
		gap=2,
		radius=8,
		fill=alicorn.style_color(ctx, .Subtle_Surface),
		label="Editor minimap",
	) {
		for index in 0..<56 {
			height := f32(3 + (index*7)%5)
			// The churn arm changes every minimap bar each frame so the
			// workload reports genuinely high description churn instead of one
			// edited text node.
			if scene.interaction == .Churn {
				height = f32(3 + int((scene.churn_epoch+u64(index))%5))
			}
			_ = ui.box(
				ctx,
				key=ui.key_u64(600_000+u64(index)),
				width=48,
				height=height,
				radius=1,
				fill=alicorn.style_color(ctx, .Border),
			)
		}
	}
}

scene_status_strip :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if ui.row(ctx, height=24, padding=8, gap=16, align=.Center, label="scratchpad-status-strip") {
		ui.text(ctx, "Ln 6, Col 1", size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
		ui.text(ctx, "UTF-8  LF  Odin", size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
		ui.text(ctx, scene.tab_titles[scene.active_tab], size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
		ui.text(ctx, "retained · 120 Hz budget", size=11, color=alicorn.style_color(ctx, .Muted_Text), decorative=true)
	}
}

// scene_describe describes the complete scene. The caller owns the Root scope
// and the host, exactly like every other workload-matrix scene.
scene_describe :: proc(scene: ^Scene, ctx: ^ui.UI) {
	if scene == nil || ctx == nil { return }
	scope := alicorn.Style_Environment_Scope{}
	if scene.theme != 0 {
		scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=scene.theme})
	}
	if ui.column(ctx, grow=1, clip=true, label="scratchpad-root") {
		scene_tab_bar(scene, ctx)
		if ui.row(ctx, grow=1, gap=8, padding=8, clip=true, label="scratchpad-main") {
			scene_sidebar(scene, ctx)
			scene_editor(scene, ctx)
			scene_minimap(scene, ctx)
		}
		scene_status_strip(scene, ctx)
	}
	if scope.active { alicorn.style_environment_pop(ctx, scope) }
}

// scene_focus_field performs the pointer focus and initial selection that a
// user click would produce. The harness calls it once after the first frame.
scene_focus_field :: proc(scene: ^Scene, rt: ^alicorn.Runtime) -> bool {
	if scene == nil || rt == nil || scene.field_node == 0 { return false }
	info, ok := alicorn.node_info(rt, scene.field_node)
	if !ok || !info.active { return false }
	x := info.bounds.x + info.bounds.w*0.5
	y := info.bounds.y + info.bounds.h*0.5
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{
		kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY,
	})
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{
		kind=.Up, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY,
	})
	_ = alicorn.set_text_selection(rt, scene.field_node, 0, len(scene.field_buffer.text))
	alicorn.invalidate_root(rt, "scratchpad command field focused")
	return true
}

// scene_set_interaction selects the next interaction family without
// reinitializing the scene. The benchmark sets this once at startup; the
// headless harness switches it between turns.
scene_set_interaction :: proc(scene: ^Scene, interaction: Interaction) {
	if scene == nil { return }
	scene.interaction = interaction
	scene.step = 0
}

// scene_apply_step applies one interaction step directly to application and
// retained state. Native and hosted hosts call it from their owner thread
// wake, and testui drives the same state through its ordinary callbacks. The
// step returns true when it requested a new description.
scene_apply_step :: proc(scene: ^Scene, rt: ^alicorn.Runtime, step: u64) -> bool {
	if scene == nil || rt == nil { return false }
	scene.step = step
	switch scene.interaction {
	case .Typing:
		if scene.field_node == 0 { return false }
		scene.edit_line_len = (scene.edit_line_len+1) % len(scene.edit_line)
		alphabet := "abcdefghijklmnopqrstuvwxyz0123456789"
		scene.edit_line[scene.edit_line_len-1] = alphabet[int(step)%len(alphabet)]
		value := field_text_for_typing(scene)
		if !alicorn.text_field_buffer_set(&scene.field_buffer, value) { return false }
		alicorn.invalidate_root(rt, "scratchpad typing burst")
		return true
	case .Scroll:
		editor_max := f32(EDITOR_LINE_COUNT*EDITOR_ROW_HEIGHT) - f32(SCRATCHPAD_HEIGHT)
		tree_max := f32(scene.tree_visible_count*TREE_ROW_HEIGHT) - 400
		if editor_max < 1 { editor_max = 1 }
		if tree_max < 1 { tree_max = 1 }
		editor_offset := f32((step*37) % u64(editor_max))
		tree_offset := f32((step*23) % u64(tree_max))
		changed := false
		if scene.editor_list_id != 0 {
			changed = alicorn.scroll_region_set_offset(rt, scene.editor_list_id, editor_offset, "scratchpad editor scroll")
		}
		if scene.tree_list_id != 0 {
			changed = alicorn.scroll_region_set_offset(rt, scene.tree_list_id, tree_offset, "scratchpad tree scroll") || changed
		}
		if !changed { alicorn.invalidate_root(rt, "scratchpad scroll step") }
		return true
	case .Selection:
		if scene.field_node == 0 { return false }
		length := len(scene.field_buffer.text)
		if length < 2 { return false }
		start := int(step*3) % (length-1)
		end := min(start+length/2, length)
		_ = alicorn.set_text_selection(rt, scene.field_node, start, end)
		alicorn.invalidate_root(rt, "scratchpad selection drag")
		return true
	case .Resize:
		width := f32(720 + (step*40) % 240)
		if !alicorn.runtime_set_viewport(rt, alicorn.Rect{0, 0, width, SCRATCHPAD_HEIGHT}) {
			alicorn.invalidate_root(rt, "scratchpad resize sweep")
		}
		return true
	case .Tabs:
		next := int(step % TAB_COUNT)
		if !scene.tab_open[next] {
			for offset in 1..=TAB_COUNT {
				candidate := int((step+u64(offset)) % TAB_COUNT)
				if scene.tab_open[candidate] { next = candidate; break }
			}
		}
		scene.active_tab = next
		alicorn.invalidate_root(rt, "scratchpad tab switch")
		return true
	case .Churn:
		// Every realized row reports new text bytes each step while its
		// retained allocation and length stay put. A pointer-identity shortcut
		// would miss this; only content comparison can see it. The minimap bars
		// and the command field also change, so most described nodes differ on
		// every pass: no description may be reused.
		scene.churn_epoch += 1
		for index in scene.editor_first..<scene.editor_last {
			if index == scene.edit_line_index { continue }
			scene_rotate_digit(scene_editor_line_text(scene, index), scene.churn_epoch)
		}
		for position in scene.tree_first..<scene.tree_last {
			node := scene.tree_visible[position]
			scene_rotate_digit(scene.tree_labels_collapsed[node], scene.churn_epoch)
			scene_rotate_digit(scene.tree_labels_expanded[node], scene.churn_epoch)
		}
		if scene.field_node != 0 {
			scene.edit_line_len = (scene.edit_line_len+1) % len(scene.edit_line)
			if scene.edit_line_len == 0 { scene.edit_line_len = 1 }
			alphabet := "abcdefghijklmnopqrstuvwxyz0123456789"
			scene.edit_line[scene.edit_line_len-1] = alphabet[int(scene.churn_epoch)%len(alphabet)]
			_ = alicorn.text_field_buffer_set(&scene.field_buffer, field_text_for_typing(scene))
		}
		next := int(scene.churn_epoch % TAB_COUNT)
		if !scene.tab_open[next] { next = 0 }
		scene.active_tab = next
		alicorn.invalidate_root(rt, "scratchpad churn mutation")
		return true
	case .Idle:
		return false
	}
	return false
}

// scene_rotate_digit rewrites one ASCII digit in place. The slice address and
// length are unchanged, so only a content comparison can observe the change.
scene_rotate_digit :: proc(text: string, step: u64) {
	if len(text) == 0 { return }
	bytes := transmute([]u8)text
	offset := int(step % u64(len(bytes)))
	for probe in 0..<len(bytes) {
		index := (offset+probe) % len(bytes)
		if bytes[index] >= '0' && bytes[index] <= '9' {
			bytes[index] = u8('0' + (int(bytes[index]-'0')+1) % 10)
			return
		}
	}
	bytes[offset] = 'z' if bytes[offset] != 'z' else 'y'
}

field_text_for_typing :: proc(scene: ^Scene) -> string {
	// Build the controlled value in stable scratch storage so the caller does
	// not have to allocate before the runtime's own model-text copy.
	prefix := "filter: "
	write := 0
	for index in 0..<len(prefix) {
		scene.field_text[write] = prefix[index]
		write += 1
	}
	for index in 0..<scene.edit_line_len {
		scene.field_text[write] = scene.edit_line[index]
		write += 1
	}
	return string(scene.field_text[:write])
}
