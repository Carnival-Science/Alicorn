// Issue #190 sparse application updates and authoring cost.
//
// One deterministic, source-visible fixture rendered through three authoring
// modes that describe the same rows, labels, buttons and selection state:
//
//   root   - every application change calls invalidate_root and the describe
//            function re-emits every row.
//   region - every row is one stable keyed region with an application-owned
//            revision. A row change bumps that revision and invalidates the
//            row key.
//   app    - a purposefully hand-optimized app-owned path. Each row has a
//            shell region plus label and action sub-regions. A label change
//            bumps the label revision; a selection change bumps the row's
//            shell and action revisions; a width change bumps the shell.
//
// The three modes have the same semantics and the same final retained geometry
// for the same application state; only their update dependency shape differs.
// Every scenario is applied to a settled tree, measured on fresh runtimes, and
// then compared against a fresh runtime that describes the same final state.
// This fixture is CPU/headless: it measures application description, retained
// reconciliation, layout, paint and composition. It does not measure native GPU
// presentation (#168) and its timings are specific to this machine.
//
// Build and run (Windows, from the repository root):
//
//   odin build benchmarks\diagnostics\issue190_sparse_updates.odin -file -o:speed `
//       -collection:alicorn=. -out:out\issue190_sparse_updates.exe
//   out\issue190_sparse_updates.exe
//
// Optional arguments:
//   --samples=N              samples per (mode, size, scenario) (default 24)
//   --sizes=100,1000,3000    live-control sizes (default all three)
//   --scenario=name          one scenario (default all)
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"

FONT_DATA :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

MAX_ROWS :: 3100
ROW_HEIGHT :: f32(28)
ROW_INNER_HEIGHT :: f32(20)
ROW_PADDING :: f32(4)
LABEL_WIDTH :: f32(140)
BUTTON_WIDTH :: f32(72)
ROW_WIDTH_NARROW :: f32(240)
ROW_WIDTH_WIDE :: f32(320)
VIEWPORT_WIDTH :: f32(1280)
VIEWPORT_HEIGHT :: f32(900)
VIRTUAL_ITEM_COUNT :: 100_000
VIRTUAL_ROW_HEIGHT :: f32(20)
VIRTUAL_VIEWPORT_HEIGHT :: f32(400)
VIRTUAL_WIDTH :: f32(640)
IDLE_FRAMES :: 200
MAX_SAMPLES :: 64
TEXT_COLOR :: alicorn.Color{0.90, 0.93, 0.97, 1}
SIZE_VALUES: [3]int = {100, 1000, 3000}

// Exact revision/dependency bookkeeping each authoring mode maintains. These
// constants are printed in the report and asserted against the model below.
//   root   - 0 per-row revisions; one global invalidate_root edge.
//   region - 1 revision and 1 region key per row, plus 1 app revision.
//   app    - 3 revisions and 3 region keys per row (shell, label, action),
//            plus 1 app revision.
ROOT_REVISIONS_PER_ROW :: 0
REGION_REVISIONS_PER_ROW :: 1
APP_REVISIONS_PER_ROW :: 3

Mode :: enum { Root, Region, App }
mode_name :: proc(mode: Mode) -> string {
	switch mode {
	case .Root:   return "root"
	case .Region: return "region"
	case .App:    return "app"
	}
	return "unknown"
}

Scenario :: enum {
	Mount,
	Label_Change,
	Identical_Write,
	Hover_Move,
	Selection_Switch,
	Width_Change,
	Reorder_Insert_Remove,
	Theme_Change,
	Destroy,
	Virtual_Scroll,
}

SCENARIO_NAMES := [Scenario]string{
	.Mount = "initial_mount",
	.Label_Change = "one_label_change",
	.Identical_Write = "identical_value_write",
	.Hover_Move = "hover_move",
	.Selection_Switch = "two_row_selection",
	.Width_Change = "one_row_width",
	.Reorder_Insert_Remove = "reorder_insert_remove",
	.Theme_Change = "broad_theme_change",
	.Destroy = "destroy",
	.Virtual_Scroll = "virtual_scroll_100k",
}

REPORT_SCENARIOS := []Scenario{
	.Mount,
	.Label_Change,
	.Identical_Write,
	.Hover_Move,
	.Selection_Switch,
	.Width_Change,
	.Reorder_Insert_Remove,
	.Theme_Change,
	.Destroy,
}

SITE_ROOT :: alicorn.Source_Site{"benchmarks/diagnostics/issue190_sparse_updates.odin", 1, 1, "issue190-root"}
SITE_COLUMN :: alicorn.Source_Site{"benchmarks/diagnostics/issue190_sparse_updates.odin", 4, 1, "issue190-rows"}
SITE_VIRTUAL_ROOT :: alicorn.Source_Site{"benchmarks/diagnostics/issue190_sparse_updates.odin", 5, 1, "issue190-virtual-root"}

// ---------------------------------------------------------------------------
// Application model. All strings are owned by this process and preallocated so
// a measured update never pays for string formatting. Keys depend only on the
// durable row id, exactly like an application using a stable item key.
// ---------------------------------------------------------------------------

Row :: struct {
	id:              int,
	label:           string,
	value:           u64,
	selected:        bool,
	width_class:     int,
	// region mode
	revision:        u64,
	// app mode
	shell_revision:  u64,
	label_revision:  u64,
	action_revision: u64,
}

Fixture :: struct {
	mode:         Mode,
	n:            int,
	count:        int,
	next_id:      int,
	rows:         [MAX_ROWS]Row,
	app_revision: u64,
	theme:        alicorn.Style_Theme,
	theme_id:     alicorn.Style_Theme_ID,
	count_text:   string,
}

Row_Keys :: struct {
	row:           [MAX_ROWS]string,
	bg:            [MAX_ROWS]string,
	label_text:    [MAX_ROWS]string,
	button:        [MAX_ROWS]string,
	label_region:  [MAX_ROWS]string,
	action_region: [MAX_ROWS]string,
	base_label:    [MAX_ROWS]string,
	edited_label:  [MAX_ROWS]string,
}

KEYS: Row_Keys
KEYS_READY := false

init_keys :: proc() {
	if KEYS_READY { return }
	for id in 0..<MAX_ROWS {
		KEYS.row[id] = fmt.aprintf("row-%04d", id)
		KEYS.bg[id] = fmt.aprintf("row-%04d-bg", id)
		KEYS.label_text[id] = fmt.aprintf("row-%04d-label-text", id)
		KEYS.button[id] = fmt.aprintf("row-%04d-button", id)
		KEYS.label_region[id] = fmt.aprintf("row-%04d-label", id)
		KEYS.action_region[id] = fmt.aprintf("row-%04d-action", id)
		KEYS.base_label[id] = fmt.aprintf("Item %04d", id)
		KEYS.edited_label[id] = fmt.aprintf("Item %04d edited", id)
	}
	KEYS_READY = true
}

theme_variant :: proc(variant: int) -> alicorn.Style_Theme {
	theme := alicorn.DEFAULT_STYLE_THEME
	if variant == 0 {
		theme.colors[int(alicorn.Style_Color_Role.Accent)] = alicorn.Color{0.28, 0.55, 0.82, 1}
		theme.colors[int(alicorn.Style_Color_Role.Surface)] = alicorn.Color{0.075, 0.09, 0.12, 1}
		theme.colors[int(alicorn.Style_Color_Role.Text)] = alicorn.Color{0.90, 0.93, 0.97, 1}
		theme.colors[int(alicorn.Style_Color_Role.Selection)] = alicorn.Color{0.22, 0.44, 0.80, 0.35}
	} else {
		theme.colors[int(alicorn.Style_Color_Role.Accent)] = alicorn.Color{0.86, 0.42, 0.20, 1}
		theme.colors[int(alicorn.Style_Color_Role.Surface)] = alicorn.Color{0.13, 0.085, 0.07, 1}
		theme.colors[int(alicorn.Style_Color_Role.Text)] = alicorn.Color{0.98, 0.92, 0.86, 1}
		theme.colors[int(alicorn.Style_Color_Role.Selection)] = alicorn.Color{0.80, 0.38, 0.16, 0.35}
	}
	return theme
}

init_fixture :: proc(app: ^Fixture, mode: Mode, n: int) {
	app^ = Fixture{mode=mode, n=n, count=n, next_id=n, app_revision=1, theme=theme_variant(0)}
	app.count_text = fmt.aprintf("%d rows", n)
	for index in 0..<n {
		app.rows[index] = Row{
			id=index,
			label=KEYS.base_label[index],
			value=u64(index)*10,
			selected=index == 7,
			width_class=0,
			revision=1,
			shell_revision=1,
			label_revision=1,
			action_revision=1,
		}
	}
}

row_width :: proc(row: ^Row) -> f32 {
	return row.width_class == 0 ? ROW_WIDTH_NARROW : ROW_WIDTH_WIDE
}

// ---------------------------------------------------------------------------
// Description. The three modes share the row internals and differ only in the
// region boundaries and the cost of re-entering them.
// ---------------------------------------------------------------------------

row_root_style :: proc(row: ^Row) -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, width=row_width(row), height=ROW_HEIGHT, padding=0)
}

bg_style :: proc() -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, width=-1, height=ROW_HEIGHT, padding=ROW_PADDING, grow=1)
}

label_style :: proc() -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, width=LABEL_WIDTH, height=ROW_INNER_HEIGHT)
}

button_style :: proc() -> alicorn.Layout_Style {
	return alicorn.layout_style(.Row, width=BUTTON_WIDTH, height=ROW_INNER_HEIGHT)
}

bg_role :: proc(selected: bool) -> alicorn.Semantic_Surface_Color_Role {
	if selected { return alicorn.surface_core_color_role(.Selection) }
	return alicorn.surface_core_color_role(.Surface)
}

describe_row_contents :: proc(ui: ^alicorn.UI, row: ^Row) {
	id := row.id
	bg := alicorn.surface_begin(ui, bg_role(row.selected), key=alicorn.key_string(KEYS.bg[id]), style=bg_style(), label="row-bg")
	if bg != 0 {
		label_wrap := alicorn.container_begin_simple(ui, .Container, label="row-label", style=label_style(), color=alicorn.DEFAULT_COLOR)
		if label_wrap != 0 {
			_ = alicorn.text_simple(ui, row.label, alicorn.key_string(KEYS.label_text[id]), label_style(),
				text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
			_ = alicorn.semantic_static_text(ui)
			alicorn.container_end(ui)
		}
		action_wrap := alicorn.container_begin_simple(ui, .Container, label="row-action", style=button_style(), color=alicorn.DEFAULT_COLOR)
		if action_wrap != 0 {
			_ = alicorn.button(ui, "run", alicorn.key_string(KEYS.button[id]), button_style(),
				state=alicorn.Button_State{selected=row.selected})
			alicorn.container_end(ui)
		}
		alicorn.surface_end(ui)
	}
}

describe_row_root :: proc(ui: ^alicorn.UI, row: ^Row) {
	id := row.id
	root := alicorn.container_begin_simple(ui, .Container, label=KEYS.row[id], key=alicorn.key_string(KEYS.row[id]), style=row_root_style(row), color=alicorn.DEFAULT_COLOR)
	if root == 0 { return }
	describe_row_contents(ui, row)
	alicorn.container_end(ui)
}

describe_row_region :: proc(ui: ^alicorn.UI, row: ^Row) {
	id := row.id
	root, reused := alicorn.region_begin(ui, KEYS.row[id], row.revision, style=row_root_style(row))
	if root == 0 { return }
	if !reused {
		describe_row_contents(ui, row)
	}
	alicorn.region_end(ui, root, reused, 0)
}

describe_row_app :: proc(ui: ^alicorn.UI, row: ^Row) {
	id := row.id
	shell, reused := alicorn.region_begin(ui, KEYS.row[id], row.shell_revision, style=row_root_style(row))
	if shell == 0 { return }
	if !reused {
		bg := alicorn.surface_begin(ui, bg_role(row.selected), key=alicorn.key_string(KEYS.bg[id]), style=bg_style(), label="row-bg")
		if bg != 0 {
			label_id, label_reused := alicorn.region_begin(ui, KEYS.label_region[id], row.label_revision, style=label_style())
			if label_id != 0 && !label_reused {
				_ = alicorn.text_simple(ui, row.label, alicorn.key_string(KEYS.label_text[id]), label_style(),
					text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
				_ = alicorn.semantic_static_text(ui)
			}
			alicorn.region_end(ui, label_id, label_reused, 0)
			action_id, action_reused := alicorn.region_begin(ui, KEYS.action_region[id], row.action_revision, style=button_style())
			if action_id != 0 && !action_reused {
				_ = alicorn.button(ui, "run", alicorn.key_string(KEYS.button[id]), button_style(),
					state=alicorn.Button_State{selected=row.selected})
			}
			alicorn.region_end(ui, action_id, action_reused, 0)
			alicorn.surface_end(ui)
		}
	}
	alicorn.region_end(ui, shell, reused, 0)
}

describe_app :: proc(ui: ^alicorn.UI, app: ^Fixture) {
	root := alicorn.container_begin_ex(ui, .Root, SITE_ROOT, label="issue190-root", style=alicorn.layout_style(.Column, width=-1, height=-1))
	if root == 0 { return }
	scope := alicorn.style_environment_push(ui, alicorn.Style_Environment{theme=app.theme_id})
	_ = alicorn.text_simple(ui, "sparse update fixture", alicorn.key_string("toolbar-title"), alicorn.layout_style(.Row, height=21),
		text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
	_ = alicorn.text_simple(ui, app.count_text, alicorn.key_string("toolbar-count"), alicorn.layout_style(.Row, height=21),
		text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
	column := alicorn.container_begin_ex(ui, .Container, SITE_COLUMN, label="rows", style=alicorn.layout_style(.Column, width=-1, height=-1))
	if column != 0 {
		switch app.mode {
		case .Root:
			for index in 0..<app.count {
				describe_row_root(ui, &app.rows[index])
			}
		case .Region:
			for index in 0..<app.count {
				describe_row_region(ui, &app.rows[index])
			}
		case .App:
			for index in 0..<app.count {
				describe_row_app(ui, &app.rows[index])
			}
		}
		alicorn.container_end(ui)
	}
	alicorn.style_environment_pop(ui, scope)
	alicorn.container_end(ui)
}

// ---------------------------------------------------------------------------
// Runtime plumbing and counters.
// ---------------------------------------------------------------------------

Runtime_Handle :: struct {
	rt:    alicorn.Runtime,
	stats: alicorn.Runtime_Allocation_Stats,
}

new_bench_runtime :: proc(h: ^Runtime_Handle, viewport: alicorn.Rect) {
	h.stats = {}
	h.rt = alicorn.new_runtime(viewport, alicorn.Runtime_Config{allocation_stats=&h.stats})
}

destroy_bench_runtime :: proc(h: ^Runtime_Handle) {
	alicorn.destroy_runtime(&h.rt)
}

Alloc_Snapshot :: struct {
	persistent_calls: u64,
	persistent_frees: u64,
	live_bytes:       i64,
	scratch_calls:    u64,
	scratch_peak:     u64,
}

alloc_snapshot :: proc(stats: ^alicorn.Runtime_Allocation_Stats) -> Alloc_Snapshot {
	return Alloc_Snapshot{
		persistent_calls=stats.persistent_alloc_calls,
		persistent_frees=stats.persistent_free_calls,
		live_bytes=stats.persistent_requested_bytes_live,
		scratch_calls=stats.scratch_alloc_calls,
		scratch_peak=stats.scratch_requested_bytes_peak,
	}
}

Alloc_Delta :: struct {
	calls:      u64,
	frees:      u64,
	live_delta: i64,
	scratch:    u64,
}

alloc_delta :: proc(before, after: Alloc_Snapshot) -> Alloc_Delta {
	return Alloc_Delta{
		calls=after.persistent_calls-before.persistent_calls,
		frees=after.persistent_frees-before.persistent_frees,
		live_delta=after.live_bytes-before.live_bytes,
		scratch=after.scratch_calls-before.scratch_calls,
	}
}

Alloc_Delta_Accum :: struct {
	calls:      u64,
	frees:      u64,
	live_delta: i64,
	scratch:    u64,
}

Work :: struct {
	descriptions_emitted:       u64,
	descriptions_reused:        u64,
	regions_skipped:            u64,
	retained_subtrees_reused:   u64,
	nodes_created:              u64,
	nodes_retired:              u64,
	reconcile_nodes:            u64,
	measure_requests:           u64,
	measure_cache_hits:         u64,
	measure_cache_misses:       u64,
	measure_nodes_examined:     u64,
	measure_nodes_executed:     u64,
	layout_nodes:               u64,
	paint_nodes:                u64,
	composition_nodes:          u64,
	display_commands_finalized: u64,
	display_full_passes:        u64,
	semantic_order_nodes:       u64,
	global_fallbacks:           u64,
	text_shape_requests:        u64,
	layout_updates:             u64,
	paint_updates:              u64,
	composite_updates:          u64,
	hover_transitions:          u64,
	pointer_events:             u64,
	style_resolutions:          u64,
	semantic_descriptions:      u64,
	idle_frames:                u64,
	gpu_submits:                u64,
}

work_delta :: proc(before, after: alicorn.Frame_Stats) -> Work {
	return Work{
		descriptions_emitted=after.descriptions_emitted-before.descriptions_emitted,
		descriptions_reused=after.descriptions_reused-before.descriptions_reused,
		regions_skipped=after.regions_skipped-before.regions_skipped,
		retained_subtrees_reused=after.retained_subtrees_reused-before.retained_subtrees_reused,
		nodes_created=after.nodes_created-before.nodes_created,
		nodes_retired=after.nodes_retired-before.nodes_retired,
		reconcile_nodes=after.reconcile_nodes_visited-before.reconcile_nodes_visited,
		measure_requests=after.measure_requests-before.measure_requests,
		measure_cache_hits=after.measure_cache_hits-before.measure_cache_hits,
		measure_cache_misses=after.measure_cache_misses-before.measure_cache_misses,
		measure_nodes_examined=after.measure_nodes_examined-before.measure_nodes_examined,
		measure_nodes_executed=after.measure_nodes_executed-before.measure_nodes_executed,
		layout_nodes=after.layout_nodes_visited-before.layout_nodes_visited,
		paint_nodes=after.paint_nodes_visited-before.paint_nodes_visited,
		composition_nodes=after.composition_nodes_visited-before.composition_nodes_visited,
		display_commands_finalized=after.display_commands_finalized-before.display_commands_finalized,
		display_full_passes=after.display_finalization_full_passes-before.display_finalization_full_passes,
		semantic_order_nodes=after.semantic_order_nodes_examined-before.semantic_order_nodes_examined,
		global_fallbacks=after.global_fallbacks-before.global_fallbacks,
		text_shape_requests=after.text_shape_requests-before.text_shape_requests,
		layout_updates=after.layout_updates-before.layout_updates,
		paint_updates=after.paint_updates-before.paint_updates,
		composite_updates=after.composite_updates-before.composite_updates,
		hover_transitions=after.hover_target_transitions-before.hover_target_transitions,
		pointer_events=after.pointer_events-before.pointer_events,
		style_resolutions=after.style_resolutions-before.style_resolutions,
		semantic_descriptions=after.semantic_descriptions_emitted-before.semantic_descriptions_emitted,
		idle_frames=after.idle_frames-before.idle_frames,
		gpu_submits=after.gpu_submits-before.gpu_submits,
	}
}

// work_stage_is_zero ignores idle_frames: a no-op build correctly increments
// that counter when begin_frame rejects the frame.
work_stage_is_zero :: proc(work: Work) -> bool {	return work.descriptions_emitted == 0 &&
		work.descriptions_reused == 0 &&
		work.regions_skipped == 0 &&
		work.retained_subtrees_reused == 0 &&
		work.nodes_created == 0 &&
		work.nodes_retired == 0 &&
		work.reconcile_nodes == 0 &&
		work.measure_requests == 0 &&
		work.measure_cache_hits == 0 &&
		work.measure_cache_misses == 0 &&
		work.measure_nodes_examined == 0 &&
		work.measure_nodes_executed == 0 &&
		work.layout_nodes == 0 &&
		work.paint_nodes == 0 &&
		work.composition_nodes == 0 &&
		work.display_commands_finalized == 0 &&
		work.display_full_passes == 0 &&
		work.semantic_order_nodes == 0 &&
		work.global_fallbacks == 0 &&
		work.text_shape_requests == 0 &&
		work.layout_updates == 0 &&
		work.paint_updates == 0 &&
		work.composite_updates == 0 &&
		work.hover_transitions == 0 &&
		work.pointer_events == 0 &&
		work.style_resolutions == 0 &&
		work.semantic_descriptions == 0 &&
		work.gpu_submits == 0
}

work_min :: proc(a, b: Work) -> Work {
	return Work{
		descriptions_emitted=min(a.descriptions_emitted, b.descriptions_emitted),
		descriptions_reused=min(a.descriptions_reused, b.descriptions_reused),
		regions_skipped=min(a.regions_skipped, b.regions_skipped),
		retained_subtrees_reused=min(a.retained_subtrees_reused, b.retained_subtrees_reused),
		nodes_created=min(a.nodes_created, b.nodes_created),
		nodes_retired=min(a.nodes_retired, b.nodes_retired),
		reconcile_nodes=min(a.reconcile_nodes, b.reconcile_nodes),
		measure_requests=min(a.measure_requests, b.measure_requests),
		measure_cache_hits=min(a.measure_cache_hits, b.measure_cache_hits),
		measure_cache_misses=min(a.measure_cache_misses, b.measure_cache_misses),
		measure_nodes_examined=min(a.measure_nodes_examined, b.measure_nodes_examined),
		measure_nodes_executed=min(a.measure_nodes_executed, b.measure_nodes_executed),
		layout_nodes=min(a.layout_nodes, b.layout_nodes),
		paint_nodes=min(a.paint_nodes, b.paint_nodes),
		composition_nodes=min(a.composition_nodes, b.composition_nodes),
		display_commands_finalized=min(a.display_commands_finalized, b.display_commands_finalized),
		display_full_passes=min(a.display_full_passes, b.display_full_passes),
		semantic_order_nodes=min(a.semantic_order_nodes, b.semantic_order_nodes),
		global_fallbacks=min(a.global_fallbacks, b.global_fallbacks),
		text_shape_requests=min(a.text_shape_requests, b.text_shape_requests),
		layout_updates=min(a.layout_updates, b.layout_updates),
		paint_updates=min(a.paint_updates, b.paint_updates),
		composite_updates=min(a.composite_updates, b.composite_updates),
		hover_transitions=min(a.hover_transitions, b.hover_transitions),
		pointer_events=min(a.pointer_events, b.pointer_events),
		style_resolutions=min(a.style_resolutions, b.style_resolutions),
		semantic_descriptions=min(a.semantic_descriptions, b.semantic_descriptions),
		idle_frames=min(a.idle_frames, b.idle_frames),
		gpu_submits=min(a.gpu_submits, b.gpu_submits),
	}
}

// work_stable_equal compares the deterministic stage counters. Paint-only theme
// replacement queues retained repaint work in Runtime map order, so the display
// composer's incremental-vs-full choice can vary between otherwise identical
// runs. Those composition counters are recorded and reported, but not treated
// as a determinism contract.
work_stable_equal :: proc(a, b: Work, scenario: Scenario) -> bool {
	if scenario != .Theme_Change { return a == b }
	left := a
	right := b
	left.composition_nodes = 0; right.composition_nodes = 0
	left.display_commands_finalized = 0; right.display_commands_finalized = 0
	left.display_full_passes = 0; right.display_full_passes = 0
	left.composite_updates = 0; right.composite_updates = 0
	return left == right
}

benchmark_failure :: proc(message: string) {	fmt.println("BENCHMARK FAILURE:", message)
	os.exit(1)
}

require :: proc(condition: bool, message: string) {
	if !condition { benchmark_failure(message) }
}

// ---------------------------------------------------------------------------
// Frame helpers.
// ---------------------------------------------------------------------------

describe_frame :: proc(rt: ^alicorn.Runtime, app: ^Fixture) -> bool {
	ui, build := alicorn.begin_frame(rt)
	if !build { return false }
	describe_app(&ui, app)
	alicorn.end_frame(&ui)
	return true
}

// settle drains corrective/retained work without applying a scenario. The
// number of extra frames is bounded; a correct fixture returns to idle.
settle :: proc(rt: ^alicorn.Runtime, app: ^Fixture, limit := 8) -> int {
	for pass in 0..<limit {
		ui, build := alicorn.begin_frame(rt)
		if !build { return pass }
		describe_app(&ui, app)
		alicorn.end_frame(&ui)
	}
	benchmark_failure("fixture did not settle after 8 corrective frames")
	return limit
}

mount_and_settle :: proc(h: ^Runtime_Handle, app: ^Fixture) {
	if !alicorn.text_engine_load_font(&h.rt.text_engine, FONT_DATA) {
		benchmark_failure("fixture font did not load")
	}
	app.theme_id = alicorn.style_theme_register(&h.rt, app.theme)
	require(app.theme_id != 0, "fixture theme registration failed")
	require(describe_frame(&h.rt, app), "fresh runtime must describe its initial tree")
	_ = settle(&h.rt, app)
}

// ---------------------------------------------------------------------------
// Scenario application. `apply_scenario_live` performs the application's
// invalidation calls; the model-only pass builds the same final state for the
// fresh correctness oracle.
// ---------------------------------------------------------------------------

apply_model_label_change :: proc(app: ^Fixture) {
	app.rows[7].label = KEYS.edited_label[7]
	app.rows[7].value += 1
}

apply_model_selection :: proc(app: ^Fixture) {
	app.rows[7].selected = false
	app.rows[42].selected = true
}

apply_model_width :: proc(app: ^Fixture) {
	app.rows[11].width_class = 1
}

insert_row_at :: proc(app: ^Fixture, position: int) {
	id := app.next_id
	app.next_id += 1
	for index := app.count; index > position; index -= 1 {
		app.rows[index] = app.rows[index-1]
	}
	app.rows[position] = Row{
		id=id,
		label=KEYS.base_label[id],
		value=u64(id)*10,
		selected=false,
		width_class=0,
		revision=1,
		shell_revision=1,
		label_revision=1,
		action_revision=1,
	}
	app.count += 1
}

apply_model_structure :: proc(app: ^Fixture) -> (moved_first_id, moved_second_id, inserted_id, removed_id: int) {
	// Move the row currently at position 5 before the row currently at
	// position 3, insert a fresh row at position 3, then remove the last row.
	// The final live-control count equals the starting count.
	moved_first_id = app.rows[5].id
	moved_second_id = app.rows[3].id
	row := app.rows[5]
	for index := 5; index > 3; index -= 1 {
		app.rows[index] = app.rows[index-1]
	}
	app.rows[3] = row
	insert_row_at(app, 3)
	inserted_id = app.rows[3].id
	removed_id = app.rows[app.count-1].id
	app.count -= 1
	return
}

find_row_position :: proc(app: ^Fixture, id: int) -> int {
	for index in 0..<app.count {
		if app.rows[index].id == id { return index }
	}
	return -1
}

apply_scenario_live :: proc(rt: ^alicorn.Runtime, app: ^Fixture, scenario: Scenario) {
	mode := app.mode
	switch scenario {
	case .Mount:
		// A fresh runtime is already invalidated.
	case .Label_Change:
		apply_model_label_change(app)
		switch mode {
		case .Root:
			alicorn.invalidate_root(rt, "issue190 root label change")
		case .Region:
			row := &app.rows[7]
			row.revision += 1
			alicorn.invalidate_region(rt, KEYS.row[row.id], row.revision, "issue190 label changed")
		case .App:
			row := &app.rows[7]
			row.label_revision += 1
			alicorn.invalidate_region(rt, KEYS.label_region[row.id], row.label_revision, "issue190 label changed")
			// Nested regions are unreachable while their enclosing shell is
			// reused. The app clears the shell cache at its current revision
			// without adding a revision edge.
			alicorn.invalidate_region(rt, KEYS.row[row.id], row.shell_revision, "issue190 reach nested label")
		}
	case .Identical_Write:
		// The write is intentionally identical to the retained label. Only the
		// root mode cannot tell; region and app mode perform no work at all.
		if mode == .Root {
			alicorn.invalidate_root(rt, "issue190 identical write root rebuild")
		}
	case .Hover_Move:
		// Runtime-owned interaction; no application invalidation at all.
	case .Selection_Switch:
		apply_model_selection(app)
		switch mode {
		case .Root:
			alicorn.invalidate_root(rt, "issue190 root selection switch")
		case .Region:
			for index in ([2]int{7, 42}) {
				row := &app.rows[index]
				row.revision += 1
				alicorn.invalidate_region(rt, KEYS.row[row.id], row.revision, "issue190 row selection changed")
			}
		case .App:
			for index in ([2]int{7, 42}) {
				row := &app.rows[index]
				row.shell_revision += 1
				row.action_revision += 1
				alicorn.invalidate_region(rt, KEYS.row[row.id], row.shell_revision, "issue190 row selection shell changed")
				alicorn.invalidate_region(rt, KEYS.action_region[row.id], row.action_revision, "issue190 row selection action changed")
			}
		}
	case .Width_Change:
		apply_model_width(app)
		switch mode {
		case .Root:
			alicorn.invalidate_root(rt, "issue190 root width change")
		case .Region:
			row := &app.rows[11]
			row.revision += 1
			alicorn.invalidate_region(rt, KEYS.row[row.id], row.revision, "issue190 row width changed")
		case .App:
			row := &app.rows[11]
			row.shell_revision += 1
			alicorn.invalidate_region(rt, KEYS.row[row.id], row.shell_revision, "issue190 row width changed")
		}
	case .Reorder_Insert_Remove:
		first_id, second_id, _, _ := apply_model_structure(app)
		switch mode {
		case .Root:
			alicorn.invalidate_root(rt, "issue190 root structural change")
		case .Region, .App:
			// Structure is a global membership change. The moved rows also get
			// explicit revision edges so their content is treated as touched.
			for id in ([2]int{first_id, second_id}) {
				position := find_row_position(app, id)
				if position < 0 { continue }
				row := &app.rows[position]
				if mode == .Region {
					row.revision += 1
					alicorn.invalidate_region(rt, KEYS.row[row.id], row.revision, "issue190 moved row")
				} else {
					row.shell_revision += 1
					alicorn.invalidate_region(rt, KEYS.row[row.id], row.shell_revision, "issue190 moved row")
				}
			}
			alicorn.invalidate_root(rt, "issue190 structural membership changed")
		}
	case .Theme_Change:
		app.theme = theme_variant(1)
	case .Destroy, .Virtual_Scroll:
		// Handled by the caller.
	}
}

// ---------------------------------------------------------------------------
// Sample structure.
// ---------------------------------------------------------------------------

Sample :: struct {
	api_ns:      i64,
	describe_ns: i64,
	frame_ns:    i64,
	work:        Work,
	alloc:       Alloc_Delta,
	build:       bool,
}

Sample_Set :: struct {
	samples: [MAX_SAMPLES]Sample,
	count:   int,
}

Scene_Result :: struct {
	set:              Sample_Set,
	work:             Work,
	alloc:            Alloc_Delta_Accum,
	retained_nodes:   int,
	build_count:      int,
	correctness_ok:   bool,
	correctness_note: string,
	idle_ok:          bool,
	idle_frames:      u64,
	idle_checked:     bool,
}

Results :: struct {
	scenes:  [Mode][3][Scenario]Scene_Result,
	virtual: [Mode]Scene_Result,
}

size_value :: proc(size_index: int) -> int {
	return SIZE_VALUES[size_index]
}

now_ns :: proc(start: time.Time) -> i64 {
	return time.duration_nanoseconds(time.since(start))
}

// run_update performs one measured application update: application mutation and
// invalidation (api), then description, then end_frame.
run_update :: proc(rt: ^alicorn.Runtime, app: ^Fixture, scenario: Scenario) -> Sample {
	before_stats := alicorn.frame_stats_snapshot(rt)
	before_alloc := alloc_snapshot(rt.allocation_stats)
	start := time.now()
	apply_scenario_live(rt, app, scenario)
	api_ns := now_ns(start)

	describe_start := time.now()
	ui, build := alicorn.begin_frame(rt)
	if build {
		describe_app(&ui, app)
	}
	describe_ns := now_ns(describe_start)

	frame_ns: i64 = 0
	if build {
		frame_start := time.now()
		alicorn.end_frame(&ui)
		frame_ns = now_ns(frame_start)
	}
	after_stats := alicorn.frame_stats_snapshot(rt)
	return Sample{
		api_ns=api_ns,
		describe_ns=describe_ns,
		frame_ns=frame_ns,
		work=work_delta(before_stats, after_stats),
		alloc=alloc_delta(before_alloc, alloc_snapshot(rt.allocation_stats)),
		build=build,
	}
}

hover_button_center :: proc(rt: ^alicorn.Runtime, app: ^Fixture, row_index: int) -> (x, y: f32, ok: bool) {
	if row_index < 0 || row_index >= app.count { return }
	row := &app.rows[row_index]
	id, found := alicorn.node_by_key(rt, alicorn.key_string(KEYS.button[row.id]), .Button)
	if !found { return }
	info, info_ok := alicorn.node_info(rt, id)
	if !info_ok { return }
	return info.bounds.x+info.bounds.w*0.5, info.bounds.y+info.bounds.h*0.5, true
}

hover_pointer :: proc(rt: ^alicorn.Runtime, app: ^Fixture, row_index: int) {
	x, y, ok := hover_button_center(rt, app, row_index)
	require(ok, "hover target button was not retained")
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{kind=.Move, x=x, y=y, timestamp_ns=1})
}

run_hover_update :: proc(rt: ^alicorn.Runtime, app: ^Fixture) -> Sample {
	before_stats := alicorn.frame_stats_snapshot(rt)
	before_alloc := alloc_snapshot(rt.allocation_stats)
	start := time.now()
	hover_pointer(rt, app, 5)
	api_ns := now_ns(start)
	describe_ns: i64 = 0
	frame_start := time.now()
	presentation, ready := alicorn.begin_presentation_frame(rt)
	require(ready, "hover must request a retained presentation frame")
	alicorn.end_presentation_frame(&presentation)
	frame_ns := now_ns(frame_start)
	after_stats := alicorn.frame_stats_snapshot(rt)
	return Sample{
		api_ns=api_ns,
		describe_ns=describe_ns,
		frame_ns=frame_ns,
		work=work_delta(before_stats, after_stats),
		alloc=alloc_delta(before_alloc, alloc_snapshot(rt.allocation_stats)),
	}
}

run_theme_update :: proc(rt: ^alicorn.Runtime, app: ^Fixture) -> Sample {
	before_stats := alicorn.frame_stats_snapshot(rt)
	before_alloc := alloc_snapshot(rt.allocation_stats)
	start := time.now()
	app.theme = theme_variant(1)
	result := alicorn.style_theme_replace(rt, app.theme_id, app.theme)
	require(result == .Replaced, fmt.tprintf("theme replacement must be accepted (result=%v id=%d themes=%d)", result, u32(app.theme_id), len(rt.style_themes)))
	require(!rt.invalidated, "paint-only theme replacement must not request application description")
	api_ns := now_ns(start)
	frame_start := time.now()
	presentation, ready := alicorn.begin_presentation_frame(rt)
	require(ready, "theme replacement must request a retained presentation frame")
	alicorn.end_presentation_frame(&presentation)
	frame_ns := now_ns(frame_start)
	after_stats := alicorn.frame_stats_snapshot(rt)
	return Sample{
		api_ns=api_ns,
		describe_ns=0,
		frame_ns=frame_ns,
		work=work_delta(before_stats, after_stats),
		alloc=alloc_delta(before_alloc, alloc_snapshot(rt.allocation_stats)),
	}
}

// ---------------------------------------------------------------------------
// Fresh-runtime correctness oracle.
// ---------------------------------------------------------------------------

Paint_Summary :: struct {
	count: int,
	hash:  u64,
}

hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	h := hash ~ value
	h = (h << 13) | (h >> 51)
	h ~= h >> 7
	h = (h << 17) | (h >> 47)
	return h
}

hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	return hash_u64(hash, u64(transmute(u32)value))
}

hash_rect :: proc(hash: u64, rect: alicorn.Rect) -> u64 {
	h := hash_f32(hash, rect.x)
	h = hash_f32(h, rect.y)
	h = hash_f32(h, rect.w)
	h = hash_f32(h, rect.h)
	return h
}

hash_color :: proc(hash: u64, color: alicorn.Color) -> u64 {
	h := hash_f32(hash, color.r)
	h = hash_f32(h, color.g)
	h = hash_f32(h, color.b)
	h = hash_f32(h, color.a)
	return h
}

paint_command_hash :: proc(hash: u64, command: alicorn.Paint_Command, include_owner := true) -> u64 {
	h := hash
	if include_owner { h = hash_u64(h, u64(command.owner)) }
	h = hash_rect(h, command.bounds)
	h = hash_rect(h, command.clip)
	h = hash_f32(h, command.opacity)
	h = hash_f32(h, command.translation[0])
	h = hash_f32(h, command.translation[1])
	switch payload in command.payload {
	case alicorn.Surface_Paint:
		h = hash_u64(h, 1)
		h = hash_color(h, payload.fill)
		h = hash_color(h, payload.stroke.color)
		h = hash_f32(h, payload.stroke.width)
		h = hash_u64(h, u64(payload.shape.kind))
		h = hash_f32(h, payload.shape.corner_radius)
		h = hash_u64(h, u64(payload.material))
		h = hash_f32(h, payload.physical_height)
	case alicorn.Text_Paint:
		h = hash_u64(h, 2)
		h = hash_color(h, payload.color)
		h = hash_u64(h, u64(len(payload.spans)))
		for span in payload.spans {
			h = hash_u64(h, u64(span.start))
			h = hash_u64(h, u64(span.end))
			if span.color_set { h = hash_color(h, span.color) }
			if span.background_set { h = hash_color(h, span.background) }
		}
	case alicorn.Icon_Paint:
		h = hash_u64(h, 3)
		h = hash_u64(h, u64(payload.id))
		h = hash_color(h, payload.color)
	case alicorn.Backdrop_Effect_Paint:
		h = hash_u64(h, 4)
		h = hash_f32(h, payload.sigma)
	case alicorn.Geometry_Paint:
		h = hash_u64(h, 5)
	case alicorn.Image_Paint:
		h = hash_u64(h, 6)
	}
	return h
}

paint_summary :: proc(rt: ^alicorn.Runtime) -> Paint_Summary {
	view, ok := alicorn.paint_display_list(rt)
	if !ok { return {} }
	summary := Paint_Summary{count=len(view.commands), hash=0xcbf29ce484222325}
	for command in view.commands {
		summary.hash = paint_command_hash(summary.hash, command)
	}
	return summary
}

// paint_visual_summary ignores node identity. The three authoring modes use
// different keys and therefore different Node_IDs for the same visual tree, so
// cross-mode parity compares only geometry and resolved colors.
paint_visual_summary :: proc(rt: ^alicorn.Runtime) -> Paint_Summary {
	view, ok := alicorn.paint_display_list(rt)
	if !ok { return {} }
	summary := Paint_Summary{count=len(view.commands), hash=0xcbf29ce484222325}
	for command in view.commands {
		summary.hash = paint_command_hash(summary.hash, command, include_owner=false)
	}
	return summary
}

paint_diff_note :: proc(live, fresh: ^alicorn.Runtime) -> string {
	live_view, live_ok := alicorn.paint_display_list(live)
	fresh_view, fresh_ok := alicorn.paint_display_list(fresh)
	if !live_ok || !fresh_ok { return "paint display unavailable" }
	for index in 0..<min(len(live_view.commands), len(fresh_view.commands)) {
		left := live_view.commands[index]
		right := fresh_view.commands[index]
		left_hash := paint_command_hash(0xcbf29ce484222325, left)
		right_hash := paint_command_hash(0xcbf29ce484222325, right)
		if left_hash == right_hash { continue }
		return fmt.tprintf("paint command %d differs owner=%d/%d bounds=%v/%v clip=%v/%v payload=%v/%v",
			index, left.owner, right.owner, left.bounds, right.bounds, left.clip, right.clip,
			left.payload, right.payload)
	}
	return fmt.tprintf("paint command counts differ %d/%d", len(live_view.commands), len(fresh_view.commands))
}

semantic_node_matches :: proc(a, b: alicorn.Semantic_Node) -> bool {
	if a.id != b.id || a.role != b.role || a.label != b.label || a.description != b.description || a.value != b.value ||
	   a.states != b.states || a.actions != b.actions || a.parent != b.parent || a.visual_node != b.visual_node ||
	   a.bounds != b.bounds || a.has_bounds != b.has_bounds || a.tree_order != b.tree_order ||
	   a.is_collection != b.is_collection || a.logical_count != b.logical_count ||
	   a.realized_first != b.realized_first || a.realized_last != b.realized_last ||
	   a.selected_id != b.selected_id || a.current_id != b.current_id || a.collection_id != b.collection_id ||
	   a.position_in_set != b.position_in_set || a.size_of_set != b.size_of_set ||
	   a.is_virtual_item != b.is_virtual_item || a.numeric_value != b.numeric_value ||
	   a.numeric_minimum != b.numeric_minimum || a.numeric_maximum != b.numeric_maximum ||
	   a.numeric_step != b.numeric_step || a.has_numeric_value != b.has_numeric_value ||
	   a.text_selection != b.text_selection || a.live != b.live || a.live_atomic != b.live_atomic ||
	   len(a.text_run_character_lengths) != len(b.text_run_character_lengths) {
		return false
	}
	for value, index in a.text_run_character_lengths {
		if value != b.text_run_character_lengths[index] { return false }
	}
	return true
}

semantics_match :: proc(live, fresh: ^alicorn.Runtime) -> (ok: bool, note: string) {
	left := alicorn.semantic_snapshot(live, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&left)
	right := alicorn.semantic_snapshot(fresh, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&right)
	if left.keyboard_focus != right.keyboard_focus {
		return false, "semantic keyboard focus differs"
	}
	if len(left.nodes) != len(right.nodes) {
		return false, fmt.tprintf("semantic node count %d != %d", len(left.nodes), len(right.nodes))
	}
	for node, index in left.nodes {
		if !semantic_node_matches(node, right.nodes[index]) {
			return false, fmt.tprintf("semantic node %d differs (role=%v value=%q)", index, node.role, node.value)
		}
	}
	return true, ""
}

representative_ids :: proc(app: ^Fixture, out: []int) -> int {
	count := 0
	ids := [10]int{0, 1, 2, 3, 5, 7, 11, 42, app.count-1, app.count/2}
	for value in ids {
		if value < 0 || value >= app.count { continue }
		duplicate := false
		for index in 0..<count {
			if out[index] == value { duplicate = true; break }
		}
		if duplicate { continue }
		if count < len(out) {
			out[count] = value
			count += 1
		}
	}
	return count
}

node_projection_matches :: proc(live, fresh: ^alicorn.Runtime, app: ^Fixture) -> (ok: bool, note: string) {
	ids: [16]int
	id_count := representative_ids(app, ids[:])
	for position in 0..<id_count {
		row := &app.rows[ids[position]]
		cases := [3]struct{key: alicorn.UI_Key, kind: alicorn.Node_Kind}{
			{alicorn.key_string(KEYS.row[row.id]), .Container},
			{alicorn.key_string(KEYS.label_text[row.id]), .Text},
			{alicorn.key_string(KEYS.button[row.id]), .Button},
		}
		for entry in cases {
			left_id, left_found := alicorn.node_by_key(live, entry.key, entry.kind)
			right_id, right_found := alicorn.node_by_key(fresh, entry.key, entry.kind)
			if left_found != right_found {
				return false, fmt.tprintf("row %d key presence differs", row.id)
			}
			if !left_found { continue }
			left_info, left_ok := alicorn.node_info(live, left_id)
			right_info, right_ok := alicorn.node_info(fresh, right_id)
			if !left_ok || !right_ok || left_info != right_info {
				return false, fmt.tprintf("row %d key node info differs", row.id)
			}
			if entry.kind == .Text {
				lines := alicorn.text_node_line_count(live, left_id)
				if lines != alicorn.text_node_line_count(fresh, right_id) {
					return false, fmt.tprintf("row %d label line count differs", row.id)
				}
				for line_index in 0..<lines {
					a, a_ok := alicorn.text_node_line_geometry(live, left_id, line_index)
					b, b_ok := alicorn.text_node_line_geometry(fresh, right_id, line_index)
					if a_ok != b_ok || (a_ok && a != b) {
						return false, fmt.tprintf("row %d label line geometry differs", row.id)
					}
				}
			}
		}
	}
	return true, ""
}

inspector_projection :: proc(rt: ^alicorn.Runtime) -> string {
	inspection := alicorn.inspect(rt)
	defer delete(inspection)
	builder := strings.builder_make(context.temp_allocator)
	line_start := 0
	for index in 0..=len(inspection) {
		if index != len(inspection) && inspection[index] != '\n' { continue }
		line := inspection[line_start:index]
		if strings.starts_with(line, "  style environment:") ||
		   strings.starts_with(line, "  semantic surface:") ||
		   strings.starts_with(line, "  button recipe:") ||
		   strings.starts_with(line, "  optical surface:") ||
		   strings.starts_with(line, "  token provenance:") ||
		   strings.starts_with(line, "  text run:") {
			// Generation counters are runtime bookkeeping, not visual output:
			// a live theme replacement advances them while a fresh build does
			// not. Compare the resolved values only.
			visible := line
			if marker := strings.index(visible, " generations="); marker >= 0 { visible = visible[:marker] }
			if marker := strings.index(visible, " generation="); marker >= 0 { visible = visible[:marker] }
			fmt.sbprintf(&builder, "%s\n", visible)
		}
		line_start = index+1
	}
	return strings.to_string(builder)
}

projection_diff_note :: proc(left, right: string) -> string {
	left_lines := strings.split(left, "\n")
	defer delete(left_lines)
	right_lines := strings.split(right, "\n")
	defer delete(right_lines)
	for index in 0..<min(len(left_lines), len(right_lines)) {
		if left_lines[index] == right_lines[index] { continue }
		return fmt.tprintf("line %d live=%q fresh=%q", index, left_lines[index], right_lines[index])
	}
	return fmt.tprintf("line counts differ %d/%d", len(left_lines), len(right_lines))
}

// compare_against_fresh builds the same final application state, mounts it on a
// fresh runtime, and compares public projections. `hover_row` >= 0 replays the
// same synthesized runtime-owned hover on the fresh runtime.
compare_against_fresh :: proc(live: ^alicorn.Runtime, app: ^Fixture, hover_row: int) -> (ok: bool, note: string) {
	fresh := new(Fixture)
	defer free(fresh)
	fresh^ = app^
	h: Runtime_Handle
	new_bench_runtime(&h, alicorn.Rect{0, 0, VIEWPORT_WIDTH, VIEWPORT_HEIGHT})
	defer destroy_bench_runtime(&h)
	if !alicorn.text_engine_load_font(&h.rt.text_engine, FONT_DATA) {
		return false, "fresh fixture font did not load"
	}
	fresh.theme_id = alicorn.style_theme_register(&h.rt, fresh.theme)
	require(fresh.theme_id != 0, "fresh fixture theme registration failed")
	require(describe_frame(&h.rt, fresh), "fresh oracle must describe the final state")
	_ = settle(&h.rt, fresh)
	if hover_row >= 0 {
		hover_pointer(&h.rt, fresh, hover_row)
		presentation, ready := alicorn.begin_presentation_frame(&h.rt)
		if ready { alicorn.end_presentation_frame(&presentation) }
	}
	if alicorn.focused_node(live) != alicorn.focused_node(&h.rt) {
		return false, "keyboard focus differs"
	}
	semantics_ok, semantics_note := semantics_match(live, &h.rt)
	if !semantics_ok { return false, semantics_note }
	nodes_ok, nodes_note := node_projection_matches(live, &h.rt, fresh)
	if !nodes_ok { return false, nodes_note }
	live_paint := paint_summary(live)
	fresh_paint := paint_summary(&h.rt)
	if live_paint.count != fresh_paint.count || live_paint.hash != fresh_paint.hash {
		return false, fmt.tprintf("paint projection differs (%d/%d %016x/%016x): %s",
			live_paint.count, fresh_paint.count, live_paint.hash, fresh_paint.hash,
			paint_diff_note(live, &h.rt))
	}
	if app.n <= 100 {
		live_projection := inspector_projection(live)
		fresh_projection := inspector_projection(&h.rt)
		if live_projection != fresh_projection {
			return false, fmt.tprintf("inspector style/paint projection differs: %s", projection_diff_note(live_projection, fresh_projection))
		}
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Idle check.
// ---------------------------------------------------------------------------

run_idle_check :: proc(rt: ^alicorn.Runtime) -> (idle_frames: u64, ok: bool) {
	before_stats := alicorn.frame_stats_snapshot(rt)
	before_alloc := alloc_snapshot(rt.allocation_stats)
	for _ in 0..<IDLE_FRAMES {
		_, build := alicorn.begin_frame(rt)
		if build { return 0, false }
	}
	after_stats := alicorn.frame_stats_snapshot(rt)
	after_alloc := alloc_snapshot(rt.allocation_stats)
	work := work_delta(before_stats, after_stats)
	alloc := alloc_delta(before_alloc, after_alloc)
	if !work_stage_is_zero(work) { return work.idle_frames, false }
	if alloc.calls != 0 || alloc.scratch != 0 { return work.idle_frames, false }
	return work.idle_frames, true
}

// ---------------------------------------------------------------------------
// Assertions. These are deterministic work-count checks; they are independent
// of timing.
// ---------------------------------------------------------------------------

expect :: proc(ok: bool, scenario_name, mode: string, n: int, what: string, actual, expected: u64) {
	if ok { return }
	benchmark_failure(fmt.tprintf("scene=%s mode=%s n=%d %s=%d expected=%d", scenario_name, mode, n, what, actual, expected))
}

check_scene :: proc(scenario: Scenario, result: ^Scene_Result, app: ^Fixture) {
	mode := app.mode
	n := u64(app.n)
	name := SCENARIO_NAMES[scenario]
	work := result.work
	switch scenario {
	case .Mount:
		switch mode {
		case .Root:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(work.regions_skipped == 0, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, 0)
		case .Region:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(work.regions_skipped == 0, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, 0)
		case .App:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(work.regions_skipped == 0, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, 0)
		}
		expect(work.nodes_created == work.descriptions_emitted, name, mode_name(mode), app.n, "created", work.nodes_created, work.descriptions_emitted)
		expect(work.nodes_retired == 0, name, mode_name(mode), app.n, "retired", work.nodes_retired, 0)
	case .Label_Change:
		switch mode {
		case .Root:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(work.regions_skipped == 0, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, 0)
		case .Region:
			expect(work.descriptions_emitted == n+9, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+9)
			expect(work.regions_skipped == n-1, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n-1)
			expect(work.retained_subtrees_reused == n-1, name, mode_name(mode), app.n, "subtree_reuse", work.retained_subtrees_reused, n-1)
		case .App:
			expect(work.descriptions_emitted == n+8, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+8)
			expect(work.regions_skipped == n, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n)
			expect(work.retained_subtrees_reused == n, name, mode_name(mode), app.n, "subtree_reuse", work.retained_subtrees_reused, n)
		}
		expect(work.nodes_created == 0, name, mode_name(mode), app.n, "created", work.nodes_created, 0)
		expect(work.nodes_retired == 0, name, mode_name(mode), app.n, "retired", work.nodes_retired, 0)
	case .Identical_Write:
		if mode == .Root {
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(result.build_count == result.set.count, name, mode_name(mode), app.n, "build", u64(result.build_count), u64(result.set.count))
		} else {
			expect(work_stage_is_zero(work), name, mode_name(mode), app.n, "nonzero stage work", 1, 0)
			expect(result.build_count == 0, name, mode_name(mode), app.n, "build", u64(result.build_count), 0)
		}
	case .Hover_Move:
		expect(work.descriptions_emitted == 0, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 0)
		expect(work.reconcile_nodes == 0, name, mode_name(mode), app.n, "reconcile", work.reconcile_nodes, 0)
		expect(work.layout_nodes == 0, name, mode_name(mode), app.n, "layout", work.layout_nodes, 0)
		expect(work.hover_transitions == 1, name, mode_name(mode), app.n, "hover_transitions", work.hover_transitions, 1)
	case .Selection_Switch:
		switch mode {
		case .Root:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
		case .Region:
			expect(work.descriptions_emitted == n+14, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+14)
			expect(work.regions_skipped == n-2, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n-2)
		case .App:
			expect(work.descriptions_emitted == n+12, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+12)
			expect(work.regions_skipped == n, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n)
		}
		expect(work.nodes_created == 0, name, mode_name(mode), app.n, "created", work.nodes_created, 0)
	case .Width_Change:
		switch mode {
		case .Root:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
		case .Region:
			expect(work.descriptions_emitted == n+9, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+9)
			expect(work.regions_skipped == n-1, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n-1)
		case .App:
			expect(work.descriptions_emitted == n+7, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+7)
			expect(work.regions_skipped == n+1, name, mode_name(mode), app.n, "regions_skipped", work.regions_skipped, n+1)
		}
		expect(work.layout_updates > 0, name, mode_name(mode), app.n, "layout_updates", work.layout_updates, 1)
	case .Reorder_Insert_Remove:
		expect(app.count == app.n, name, mode_name(mode), app.n, "final count", u64(app.count), n)
		switch mode {
		case .Root:
			expect(work.descriptions_emitted == 6*n+4, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 6*n+4)
			expect(work.nodes_created == 6, name, mode_name(mode), app.n, "created", work.nodes_created, 6)
			expect(work.nodes_retired == 6, name, mode_name(mode), app.n, "retired", work.nodes_retired, 6)
			expect(work.reconcile_nodes == 6*n+4, name, mode_name(mode), app.n, "reconcile", work.reconcile_nodes, 6*n+4)
		case .Region:
			expect(work.descriptions_emitted == n+19, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+19)
			expect(work.nodes_created == 6, name, mode_name(mode), app.n, "created", work.nodes_created, 6)
			expect(work.nodes_retired == 6, name, mode_name(mode), app.n, "retired", work.nodes_retired, 6)
			expect(work.reconcile_nodes <= n+32, name, mode_name(mode), app.n, "reconcile bounded", work.reconcile_nodes, n+32)
		case .App:
			expect(work.descriptions_emitted == n+15, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, n+15)
			expect(work.nodes_created == 6, name, mode_name(mode), app.n, "created", work.nodes_created, 6)
			expect(work.nodes_retired == 6, name, mode_name(mode), app.n, "retired", work.nodes_retired, 6)
			expect(work.reconcile_nodes <= n+32, name, mode_name(mode), app.n, "reconcile bounded", work.reconcile_nodes, n+32)
		}
	case .Theme_Change:
		expect(work.descriptions_emitted == 0, name, mode_name(mode), app.n, "emit", work.descriptions_emitted, 0)
		expect(work.reconcile_nodes == 0, name, mode_name(mode), app.n, "reconcile", work.reconcile_nodes, 0)
		expect(work.layout_nodes == 0, name, mode_name(mode), app.n, "layout", work.layout_nodes, 0)
		expect(work.paint_nodes > 0, name, mode_name(mode), app.n, "paint visits", work.paint_nodes, 1)
	case .Destroy, .Virtual_Scroll:
	}
}

check_virtual :: proc(result: ^Scene_Result, mode: Mode) {
	expect(result.work.descriptions_emitted > 0, SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), VIRTUAL_ITEM_COUNT, "emit", result.work.descriptions_emitted, 1)
	expect(result.work.descriptions_emitted < 400, SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), VIRTUAL_ITEM_COUNT, "emit bound", result.work.descriptions_emitted, 400)
	expect(result.work.reconcile_nodes < 500, SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), VIRTUAL_ITEM_COUNT, "reconcile bound", result.work.reconcile_nodes, 500)
	expect(result.work.nodes_created > 0, SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), VIRTUAL_ITEM_COUNT, "created", result.work.nodes_created, 1)
	expect(result.work.nodes_retired > 0, SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), VIRTUAL_ITEM_COUNT, "retired", result.work.nodes_retired, 1)
}

// ---------------------------------------------------------------------------
// Percentiles.
// ---------------------------------------------------------------------------

percentile :: proc(values: []i64, fraction: f64) -> i64 {
	if len(values) == 0 { return 0 }
	sorted := make([]i64, len(values), context.temp_allocator)
	copy(sorted, values)
	slice.sort(sorted)
	index := int(math.ceil(f64(len(sorted))*fraction))-1
	if index < 0 { index = 0 }
	if index >= len(sorted) { index = len(sorted)-1 }
	return sorted[index]
}

median :: proc(values: []i64) -> i64 {
	if len(values) == 0 { return 0 }
	sorted := make([]i64, len(values), context.temp_allocator)
	copy(sorted, values)
	slice.sort(sorted)
	return sorted[len(sorted)/2]
}

Aggregate :: struct {
	api:      []i64,
	describe: []i64,
	frame:    []i64,
	total:    []i64,
}

aggregate_samples :: proc(set: ^Sample_Set) -> Aggregate {
	api := make([]i64, set.count, context.temp_allocator)
	describe := make([]i64, set.count, context.temp_allocator)
	frame := make([]i64, set.count, context.temp_allocator)
	total := make([]i64, set.count, context.temp_allocator)
	for index in 0..<set.count {
		sample := set.samples[index]
		api[index] = sample.api_ns
		describe[index] = sample.describe_ns
		frame[index] = sample.frame_ns
		total[index] = sample.api_ns+sample.describe_ns+sample.frame_ns
	}
	return Aggregate{api=api, describe=describe, frame=frame, total=total}
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

print_work :: proc(scenario: Scenario, mode: Mode, n: int, work: Work, alloc: Alloc_Delta_Accum, retained: int) {
	fmt.printf(
		"scene=%s n=%d mode=%s emit=%d reuse=%d region_skip=%d subtree_reuse=%d reconcile=%d measure_req=%d measure_hit=%d measure_miss=%d measure_examined=%d measure_executed=%d layout=%d paint_visit=%d compose_visit=%d display_finalized=%d display_full=%d semantic_order=%d global_fallbacks=%d text_shapes=%d layout_updates=%d paint_updates=%d composite_updates=%d created=%d retired=%d hover=%d pointer=%d alloc_calls=%d alloc_frees=%d alloc_live_delta=%d scratch_calls=%d retained_nodes=%d\n",
		SCENARIO_NAMES[scenario], n, mode_name(mode),
		work.descriptions_emitted, work.descriptions_reused, work.regions_skipped,
		work.retained_subtrees_reused, work.reconcile_nodes, work.measure_requests,
		work.measure_cache_hits, work.measure_cache_misses, work.measure_nodes_examined,
		work.measure_nodes_executed, work.layout_nodes, work.paint_nodes,
		work.composition_nodes, work.display_commands_finalized, work.display_full_passes,
		work.semantic_order_nodes, work.global_fallbacks, work.text_shape_requests,
		work.layout_updates, work.paint_updates, work.composite_updates,
		work.nodes_created, work.nodes_retired, work.hover_transitions, work.pointer_events,
		alloc.calls, alloc.frees, alloc.live_delta, alloc.scratch, retained,
	)
}

print_timings :: proc(scenario: Scenario, mode: Mode, n, samples: int, aggregate: Aggregate) {
	fmt.printf(
		"timing scene=%s n=%d mode=%s samples=%d api_p50_ns=%d api_p95_ns=%d api_p99_ns=%d describe_p50_ns=%d describe_p95_ns=%d describe_p99_ns=%d frame_p50_ns=%d frame_p95_ns=%d frame_p99_ns=%d total_p50_ns=%d total_p95_ns=%d total_p99_ns=%d total_min_ns=%d total_max_ns=%d\n",
		SCENARIO_NAMES[scenario], n, mode_name(mode), samples,
		median(aggregate.api), percentile(aggregate.api, 0.95), percentile(aggregate.api, 0.99),
		median(aggregate.describe), percentile(aggregate.describe, 0.95), percentile(aggregate.describe, 0.99),
		median(aggregate.frame), percentile(aggregate.frame, 0.95), percentile(aggregate.frame, 0.99),
		median(aggregate.total), percentile(aggregate.total, 0.95), percentile(aggregate.total, 0.99),
		percentile(aggregate.total, 0.0), percentile(aggregate.total, 1.0),
	)
}

// ---------------------------------------------------------------------------
// Virtualized leg.
// ---------------------------------------------------------------------------

describe_virtual_row :: proc(ui: ^alicorn.UI, app_mode: Mode, index: int) {
	key := fmt.tprintf("vrow-%06d", index)
	label := fmt.tprintf("item %06d", index)
	bg_key := fmt.tprintf("%s-bg", key)
	label_key := fmt.tprintf("%s-label", key)
	label_text_key := fmt.tprintf("%s-label-text", key)
	button_key := fmt.tprintf("%s-button", key)
	action_key := fmt.tprintf("%s-action", key)
	root_style := alicorn.layout_style(.Row, width=VIRTUAL_WIDTH, height=VIRTUAL_ROW_HEIGHT)
	bg := alicorn.layout_style(.Row, width=-1, height=VIRTUAL_ROW_HEIGHT, padding=ROW_PADDING, grow=1)
	inner := alicorn.layout_style(.Row, width=LABEL_WIDTH, height=ROW_INNER_HEIGHT)
	btn := alicorn.layout_style(.Row, width=BUTTON_WIDTH, height=ROW_INNER_HEIGHT)
	switch app_mode {
	case .Root:
		root := alicorn.container_begin_simple(ui, .Container, label=key, key=alicorn.key_string(key), style=root_style, color=alicorn.DEFAULT_COLOR)
		if root == 0 { return }
		_ = alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string(bg_key), style=bg, label="virtual-row-bg")
		label_wrap := alicorn.container_begin_simple(ui, .Container, label="virtual-row-label", style=inner, color=alicorn.DEFAULT_COLOR)
		if label_wrap != 0 {
			_ = alicorn.text_simple(ui, label, alicorn.key_string(label_key), inner, text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
			_ = alicorn.semantic_static_text(ui)
			alicorn.container_end(ui)
		}
		action_wrap := alicorn.container_begin_simple(ui, .Container, label="virtual-row-action", style=btn, color=alicorn.DEFAULT_COLOR)
		if action_wrap != 0 {
			_ = alicorn.button(ui, "run", alicorn.key_string(button_key), btn)
			alicorn.container_end(ui)
		}
		alicorn.surface_end(ui)
		alicorn.container_end(ui)
	case .Region:
		root, reused := alicorn.region_begin(ui, key, 1, style=root_style)
		if root == 0 { return }
		if !reused {
			_ = alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string(bg_key), style=bg, label="virtual-row-bg")
			label_wrap := alicorn.container_begin_simple(ui, .Container, label="virtual-row-label", style=inner, color=alicorn.DEFAULT_COLOR)
			if label_wrap != 0 {
				_ = alicorn.text_simple(ui, label, alicorn.key_string(label_key), inner, text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
				_ = alicorn.semantic_static_text(ui)
				alicorn.container_end(ui)
			}
			action_wrap := alicorn.container_begin_simple(ui, .Container, label="virtual-row-action", style=btn, color=alicorn.DEFAULT_COLOR)
			if action_wrap != 0 {
				_ = alicorn.button(ui, "run", alicorn.key_string(button_key), btn)
				alicorn.container_end(ui)
			}
			alicorn.surface_end(ui)
		}
		alicorn.region_end(ui, root, reused, 0)
	case .App:
		shell, reused := alicorn.region_begin(ui, key, 1, style=root_style)
		if shell == 0 { return }
		if !reused {
			_ = alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface), key=alicorn.key_string(bg_key), style=bg, label="virtual-row-bg")
			label_region, label_reused := alicorn.region_begin(ui, label_key, 1, style=inner)
			if label_region != 0 && !label_reused {
				_ = alicorn.text_simple(ui, label, alicorn.key_string(label_text_key), inner, text_style=alicorn.Text_Style{overflow=.Ellipsis}, color=TEXT_COLOR)
				_ = alicorn.semantic_static_text(ui)
			}
			alicorn.region_end(ui, label_region, label_reused, 0)
			action_region, action_reused := alicorn.region_begin(ui, action_key, 1, style=btn)
			if action_region != 0 && !action_reused {
				_ = alicorn.button(ui, "run", alicorn.key_string(button_key), btn)
			}
			alicorn.region_end(ui, action_region, action_reused, 0)
			alicorn.surface_end(ui)
		}
		alicorn.region_end(ui, shell, reused, 0)
	}
}

describe_virtual :: proc(ui: ^alicorn.UI, mode: Mode) -> alicorn.Virtual_List_Handle {
	root := alicorn.container_begin_ex(ui, .Root, SITE_VIRTUAL_ROOT, label="issue190-virtual-root", style=alicorn.layout_style(.Column, width=-1, height=-1))
	handle: alicorn.Virtual_List_Handle
	if root != 0 {
		handle = alicorn.virtual_list_begin(ui, VIRTUAL_ITEM_COUNT, VIRTUAL_ROW_HEIGHT,
			key=alicorn.key_string("issue190-virtual-list"),
			style=alicorn.layout_style(.Column, width=VIRTUAL_WIDTH, height=VIRTUAL_VIEWPORT_HEIGHT),
			content_width=VIRTUAL_WIDTH, line_width=VIRTUAL_ROW_HEIGHT,
			label="issue190-virtual-list")
		if handle.scroll.id != 0 {
			for index in handle.first..<handle.last {
				describe_virtual_row(ui, mode, index)
			}
			alicorn.virtual_list_end(ui, handle)
		}
		alicorn.container_end(ui)
	}
	return handle
}

run_virtual_mount :: proc(h: ^Runtime_Handle, mode: Mode) -> alicorn.Virtual_List_Handle {
	if !alicorn.text_engine_load_font(&h.rt.text_engine, FONT_DATA) {
		benchmark_failure("virtual fixture font did not load")
	}
	ui, build := alicorn.begin_frame(&h.rt)
	require(build, "virtual fixture must describe its initial tree")
	handle := describe_virtual(&ui, mode)
	alicorn.end_frame(&ui)
	for _ in 0..<8 {
		ui2, more := alicorn.begin_frame(&h.rt)
		if !more { break }
		_ = describe_virtual(&ui2, mode)
		alicorn.end_frame(&ui2)
	}
	return handle
}

run_virtual_scroll :: proc(rt: ^alicorn.Runtime, mode: Mode, target: f32, scroll_id: alicorn.Node_ID) -> (Sample, alicorn.Virtual_List_Handle) {
	before_stats := alicorn.frame_stats_snapshot(rt)
	before_alloc := alloc_snapshot(rt.allocation_stats)
	start := time.now()
	_ = alicorn.scroll_region_set_offset(rt, scroll_id, target, "issue190 virtual scroll")
	api_ns := now_ns(start)
	describe_start := time.now()
	ui, build := alicorn.begin_frame(rt)
	handle: alicorn.Virtual_List_Handle
	if build {
		handle = describe_virtual(&ui, mode)
	}
	describe_ns := now_ns(describe_start)
	frame_ns: i64 = 0
	if build {
		frame_start := time.now()
		alicorn.end_frame(&ui)
		frame_ns = now_ns(frame_start)
	}
	after_stats := alicorn.frame_stats_snapshot(rt)
	return Sample{
		api_ns=api_ns,
		describe_ns=describe_ns,
		frame_ns=frame_ns,
		work=work_delta(before_stats, after_stats),
		alloc=alloc_delta(before_alloc, alloc_snapshot(rt.allocation_stats)),
		build=build,
	}, handle
}

compare_virtual_fresh :: proc(live: ^alicorn.Runtime, mode: Mode) -> (ok: bool, note: string) {
	h: Runtime_Handle
	new_bench_runtime(&h, alicorn.Rect{0, 0, VIEWPORT_WIDTH, VIEWPORT_HEIGHT})
	defer destroy_bench_runtime(&h)
	handle := run_virtual_mount(&h, mode)
	if handle.scroll.id == 0 { return false, "fresh virtual mount retained no scroll region" }
	semantics_ok, semantics_note := semantics_match(live, &h.rt)
	if !semantics_ok { return false, semantics_note }
	live_paint := paint_summary(live)
	fresh_paint := paint_summary(&h.rt)
	if live_paint.count != fresh_paint.count || live_paint.hash != fresh_paint.hash {
		return false, "virtual paint projection differs"
	}
	return true, ""
}

run_virtual_sample :: proc(mode: Mode, sample_index: int, results: ^Results) {
	result := &results.virtual[mode]
	first := result.set.count == 0
	h: Runtime_Handle
	new_bench_runtime(&h, alicorn.Rect{0, 0, VIEWPORT_WIDTH, VIEWPORT_HEIGHT})
	handle := run_virtual_mount(&h, mode)
	require(handle.scroll.id != 0, "virtual list retained no scroll region")
	down, down_handle := run_virtual_scroll(&h.rt, mode, VIRTUAL_VIEWPORT_HEIGHT, handle.scroll.id)
	require(down_handle.first == 20, "virtual scroll down must realize row 20 first")
	require(down.work.descriptions_emitted > 0 && down.work.descriptions_emitted < 400,
		"virtual scroll must describe O(visible) rows")
	require(down.work.reconcile_nodes < 500, "virtual scroll must reconcile O(visible) rows")
	back, back_handle := run_virtual_scroll(&h.rt, mode, 0, handle.scroll.id)
	require(back_handle.first == 0, "virtual scroll back must restore row 0")
	require(back.work.descriptions_emitted > 0 && back.work.descriptions_emitted < 400,
		"virtual scroll back must describe O(visible) rows")
	down.frame_ns += back.frame_ns
	down.describe_ns += back.describe_ns
	down.api_ns += back.api_ns
	result.set.samples[result.set.count] = down
	result.set.count += 1
	result.build_count += 1
	if first {
		ok, note := compare_virtual_fresh(&h.rt, mode)
		result.correctness_ok = ok
		result.correctness_note = note
		result.work = down.work
		result.alloc = Alloc_Delta_Accum{
			calls=down.alloc.calls,
			frees=down.alloc.frees,
			live_delta=down.alloc.live_delta,
			scratch=down.alloc.scratch,
		}
		result.retained_nodes = len(h.rt.nodes)
		result.idle_frames, result.idle_ok = run_idle_check(&h.rt)
		result.idle_checked = true
		check_virtual(result, mode)
	}
	destroy_bench_runtime(&h)
	_ = sample_index
}

run_virtual_group :: proc(samples: int, results: ^Results) {
	for mode in ([3]Mode{.Root, .Region, .App}) {
		results.virtual[mode] = Scene_Result{correctness_ok=true}
	}
	for sample_index in 0..<samples {
		if sample_index % 2 == 0 {
			for mode in ([3]Mode{.Root, .Region, .App}) { run_virtual_sample(mode, sample_index, results) }
		} else {
			for mode in ([3]Mode{.App, .Region, .Root}) { run_virtual_sample(mode, sample_index, results) }
		}
	}
	for mode in ([3]Mode{.Root, .Region, .App}) {
		result := &results.virtual[mode]
		if result.set.count == 0 { continue }
		minimum := result.set.samples[0].work
		instable := false
		for sample_index in 1..<result.set.count {
			if result.set.samples[sample_index].work != result.set.samples[0].work { instable = true }
			minimum = work_min(minimum, result.set.samples[sample_index].work)
		}
		result.work = minimum
		if instable {
			fmt.printf("WARN counter_instability scene=%s mode=%s\n",
				SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode))
		}
	}
}

// ---------------------------------------------------------------------------
// Main driver.
// ---------------------------------------------------------------------------

// run_scene_sample measures one fresh-runtime sample. Mode order is alternated
// by run_scenario_group so CPU frequency drift is not attributed to one mode.
run_scene_sample :: proc(mode: Mode, size_index: int, scenario: Scenario, sample_index: int, results: ^Results) {
	n := size_value(size_index)
	result := &results.scenes[mode][size_index][scenario]
	first := result.set.count == 0
	h: Runtime_Handle
	new_bench_runtime(&h, alicorn.Rect{0, 0, VIEWPORT_WIDTH, VIEWPORT_HEIGHT})
	app := new(Fixture)
	defer free(app)
	init_fixture(app, mode, n)
	if scenario == .Mount {
		// The measured mount starts from a fresh, empty runtime.
		if !alicorn.text_engine_load_font(&h.rt.text_engine, FONT_DATA) {
			benchmark_failure("mount fixture font did not load")
		}
		app.theme_id = alicorn.style_theme_register(&h.rt, app.theme)
		require(app.theme_id != 0, "mount theme registration failed")
	} else {
		mount_and_settle(&h, app)
	}
	if scenario == .Hover_Move {
		hover_pointer(&h.rt, app, 4)
		presentation, ready := alicorn.begin_presentation_frame(&h.rt)
		if ready { alicorn.end_presentation_frame(&presentation) }
	}
	sample: Sample
	switch scenario {
	case .Mount, .Label_Change, .Identical_Write, .Selection_Switch, .Width_Change, .Reorder_Insert_Remove:
		sample = run_update(&h.rt, app, scenario)
	case .Hover_Move:
		sample = run_hover_update(&h.rt, app)
	case .Theme_Change:
		sample = run_theme_update(&h.rt, app)
	case .Destroy:
		before_alloc := alloc_snapshot(h.rt.allocation_stats)
		retained := len(h.rt.nodes)
		start := time.now()
		destroy_bench_runtime(&h)
		elapsed := now_ns(start)
		after_alloc := alloc_snapshot(&h.stats)
		a := alloc_delta(before_alloc, after_alloc)
		if first {
			result.retained_nodes = retained
			result.alloc.calls = a.calls
			result.alloc.frees = a.frees
			result.alloc.live_delta = a.live_delta
			result.alloc.scratch = a.scratch
		}
		require(retained > 0, "destroy fixture retained no nodes")
		require(a.frees > 0, "destroy must free retained allocations")
		require(h.stats.persistent_requested_bytes_live == 0, "destroy must release all tracked runtime bytes")
		result.set.samples[result.set.count] = Sample{api_ns=elapsed}
		result.set.count += 1
		result.idle_ok = true
		result.idle_checked = false
		return
	case .Virtual_Scroll:
		benchmark_failure("virtual scenario must use run_virtual_group")
	}
	result.set.samples[result.set.count] = sample
	result.set.count += 1
	if sample.build { result.build_count += 1 }
	if first {
		_ = settle(&h.rt, app)
		hover_row := -1
		if scenario == .Hover_Move { hover_row = 5 }
		ok, note := compare_against_fresh(&h.rt, app, hover_row)
		result.correctness_ok = ok
		result.correctness_note = note
		result.work = sample.work
		result.alloc = Alloc_Delta_Accum{
			calls=sample.alloc.calls,
			frees=sample.alloc.frees,
			live_delta=sample.alloc.live_delta,
			scratch=sample.alloc.scratch,
		}
		result.retained_nodes = len(h.rt.nodes)
		result.idle_frames, result.idle_ok = run_idle_check(&h.rt)
		result.idle_checked = true
		check_scene(scenario, result, app)
	}
	destroy_bench_runtime(&h)
	_ = sample_index
}

finalize_scene :: proc(mode: Mode, size_index: int, scenario: Scenario, results: ^Results) {
	n := size_value(size_index)
	result := &results.scenes[mode][size_index][scenario]
	if result.set.count == 0 { return }
	minimum := result.set.samples[0].work
	nondeterministic := false
	for sample_index in 1..<result.set.count {
		sample := result.set.samples[sample_index]
		if !work_stable_equal(sample.work, result.set.samples[0].work, scenario) {
			nondeterministic = true
		}
		minimum = work_min(minimum, sample.work)
	}
	result.work = minimum
	if nondeterministic {
		fmt.printf("WARN counter_nondeterministic scene=%s n=%d mode=%s fields=composition_nodes,display_finalized,composite_updates,display_full_passes samples=%d\n",
			SCENARIO_NAMES[scenario], n, mode_name(mode), result.set.count)
		for sample, index in result.set.samples[:result.set.count] {
			fmt.printf("WARN counter_sample scene=%s n=%d mode=%s sample=%d composition_nodes=%d display_finalized=%d composite_updates=%d display_full_passes=%d\n",
				SCENARIO_NAMES[scenario], n, mode_name(mode), index,
				sample.work.composition_nodes, sample.work.display_commands_finalized,
				sample.work.composite_updates, sample.work.display_full_passes)
		}
	}
}

run_scenario_group :: proc(size_index: int, scenario: Scenario, samples: int, results: ^Results) {
	for mode in ([3]Mode{.Root, .Region, .App}) {
		results.scenes[mode][size_index][scenario] = Scene_Result{correctness_ok=true}
	}
	for sample_index in 0..<samples {
		if sample_index % 2 == 0 {
			for mode in ([3]Mode{.Root, .Region, .App}) {
				run_scene_sample(mode, size_index, scenario, sample_index, results)
			}
		} else {
			for mode in ([3]Mode{.App, .Region, .Root}) {
				run_scene_sample(mode, size_index, scenario, sample_index, results)
			}
		}
	}
	for mode in ([3]Mode{.Root, .Region, .App}) {
		finalize_scene(mode, size_index, scenario, results)
	}
}

print_mode_edges :: proc(n: int) {
	fmt.printf("authoring_edges: live_controls=%d rows_with_label_and_button=%d\n", n, n)
	fmt.printf("  mode=root rows=%d revisions_per_row=%d total_revisions=%d region_keys=%d invalidation_calls=global_root\n",
		n, ROOT_REVISIONS_PER_ROW, 1, 0)
	fmt.printf("  mode=region rows=%d revisions_per_row=%d total_revisions=%d region_keys=%d invalidation_calls=per_changed_row\n",
		n, REGION_REVISIONS_PER_ROW, n+1, n)
	fmt.printf("  mode=app rows=%d revisions_per_row=%d total_revisions=%d region_keys=%d invalidation_calls=per_changed_subregion\n",
		n, APP_REVISIONS_PER_ROW, n*APP_REVISIONS_PER_ROW+1, n*APP_REVISIONS_PER_ROW)
	fmt.println("  mode=app nested_region_reachability=invalidate_enclosing_shell_at_current_revision")
}

slope_class :: proc(value_100, value_3000: u64) -> string {
	if value_100 == 0 && value_3000 == 0 { return "O(1)" }
	if value_3000 <= 64 { return "O(visible)/bounded" }
	ratio := f64(value_3000)/f64(max(value_100, 1))
	if ratio >= 4 && ratio <= 64 { return "O(all live)" }
	if ratio < 4 { return "O(1)-ish" }
	return "superlinear"
}

print_slopes :: proc(results: ^Results, sizes: []int, size_count: int) {
	if size_count < 2 { return }
	last := size_count-1
	for scenario in REPORT_SCENARIOS {
		for mode in ([3]Mode{.Root, .Region, .App}) {
			first_result := &results.scenes[mode][0][scenario]
			last_result := &results.scenes[mode][last][scenario]
			if first_result.set.count == 0 || last_result.set.count == 0 { continue }
			first_aggregate := aggregate_samples(&first_result.set)
			last_aggregate := aggregate_samples(&last_result.set)
			p50_first := median(first_aggregate.total)
			p50_last := median(last_aggregate.total)
			n_first := f64(sizes[0])
			n_last := f64(sizes[last])
			slope := (f64(p50_last)-f64(p50_first))/(n_last-n_first)
			fmt.printf("slope scene=%s mode=%s total p50_first_ns=%d p50_last_ns=%d first_n=%d last_n=%d ns_per_row=%.2f description_class=%s reconcile_class=%s layout_class=%s paint_class=%s\n",
				SCENARIO_NAMES[scenario], mode_name(mode), p50_first, p50_last, sizes[0], sizes[last], slope,
				slope_class(first_result.work.descriptions_emitted, last_result.work.descriptions_emitted),
				slope_class(first_result.work.reconcile_nodes, last_result.work.reconcile_nodes),
				slope_class(first_result.work.layout_nodes, last_result.work.layout_nodes),
				slope_class(first_result.work.paint_nodes, last_result.work.paint_nodes))
			fmt.printf("slope_api scene=%s mode=%s first_n=%d last_n=%d api_p50_first_ns=%d api_p50_last_ns=%d\n",
				SCENARIO_NAMES[scenario], mode_name(mode), sizes[0], sizes[last],
				median(first_aggregate.api), median(last_aggregate.api))
		}
	}
}

parse_u64 :: proc(value: string) -> u64 {
	result: u64 = 0
	for index in 0..<len(value) {
		c := value[index]
		if c < '0' || c > '9' { benchmark_failure(fmt.tprintf("invalid numeric argument %q", value)) }
		result = result*10+u64(c-'0')
	}
	return result
}

// ---------------------------------------------------------------------------
// Cross-mode parity. The three modes have different keys and Node_IDs but must
// describe the same visual tree. Compare owner-independent paint and a semantic
// projection that ignores identity/order.
// ---------------------------------------------------------------------------

cross_mode_semantic_projection :: proc(rt: ^alicorn.Runtime) -> string {
	snapshot := alicorn.semantic_snapshot(rt, context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	builder := strings.builder_make(context.temp_allocator)
	for node in snapshot.nodes {
		fmt.sbprintf(&builder, "%v|%s|%s|%d|%d|%.4f,%.4f,%.4f,%.4f|%t|%t|%d|%d|%d|%t|%.4f|%.4f|%.4f|%t\n",
			node.role, node.label, node.value, transmute(u32)node.states, transmute(u32)node.actions,
			node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h, node.has_bounds,
			node.is_collection, node.logical_count, node.position_in_set, node.size_of_set,
			node.is_virtual_item, node.numeric_value, node.numeric_minimum, node.numeric_maximum,
			node.has_numeric_value)
	}
	return strings.to_string(builder)
}

cross_mode_visual_check :: proc(size_index: int) -> bool {
	n := size_value(size_index)
	names := [3]string{"root", "region", "app"}
	semantics: [3]string
	paints: [3]Paint_Summary
	for mode_index in 0..<3 {
		mode := Mode(mode_index)
		h: Runtime_Handle
		new_bench_runtime(&h, alicorn.Rect{0, 0, VIEWPORT_WIDTH, VIEWPORT_HEIGHT})
		app := new(Fixture)
		init_fixture(app, mode, n)
		mount_and_settle(&h, app)
		semantics[mode_index] = cross_mode_semantic_projection(&h.rt)
		paints[mode_index] = paint_visual_summary(&h.rt)
		destroy_bench_runtime(&h)
		free(app)
	}
	for mode_index in 1..<3 {
		if semantics[0] != semantics[mode_index] {
			fmt.printf("BENCHMARK FAILURE: cross-mode visual n=%d mode=%s semantic projection differs from root: %s\n",
				n, names[mode_index], projection_diff_note(semantics[0], semantics[mode_index]))
			return false
		}
		if paints[0].count != paints[mode_index].count || paints[0].hash != paints[mode_index].hash {
			fmt.printf("BENCHMARK FAILURE: cross-mode visual n=%d mode=%s paint differs (%d/%d %016x/%016x)\n",
				n, names[mode_index], paints[0].count, paints[mode_index].count, paints[0].hash, paints[mode_index].hash)
			return false
		}
	}
	fmt.printf("cross_mode_visual n=%d status=PASS paint_commands=%d semantic_nodes=%d\n",
		n, paints[0].count, strings.count(semantics[0], "\n"))
	return true
}

// ---------------------------------------------------------------------------
// Incidental correctness probe.
//
// Paint-only theme replacement recomputes control recipes and semantic
// surfaces, but a plain Text node's paint color is captured from the style
// environment during description (`node.color`). This probe records whether the
// current runtime recolors such a text node after a same-id theme replacement.
// It is an observation, not a pass/fail gate: the sparse fixture uses explicit
// text colors so its theme scenario isolates retained paint work.
// ---------------------------------------------------------------------------

probe_text_paint_color :: proc(rt: ^alicorn.Runtime, key: string) -> (color: alicorn.Color, ok: bool) {
	id, found := alicorn.node_by_key(rt, alicorn.key_string(key), .Text)
	if !found { return }
	view, view_ok := alicorn.paint_display_list(rt)
	if !view_ok { return }
	for command in view.commands {
		if command.owner != id { continue }
		if payload, is_text := command.payload.(alicorn.Text_Paint); is_text {
			return payload.color, true
		}
	}
	return
}

run_theme_text_probe :: proc() {
	h: Runtime_Handle
	new_bench_runtime(&h, alicorn.Rect{0, 0, 320, 120})
	defer destroy_bench_runtime(&h)
	if !alicorn.text_engine_load_font(&h.rt.text_engine, FONT_DATA) {
		benchmark_failure("theme text probe font did not load")
	}
	theme_id := alicorn.style_theme_register(&h.rt, theme_variant(0))
	require(theme_id != 0, "theme text probe theme registration failed")
	ui, build := alicorn.begin_frame(&h.rt)
	require(build, "theme text probe must describe")
	root := alicorn.container_begin_ex(&ui, .Root, SITE_VIRTUAL_ROOT, label="theme-text-probe", style=alicorn.layout_style(.Column, width=320, height=120))
	scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=theme_id})
	_ = alicorn.text_simple(&ui, "theme resolved text", alicorn.key_string("theme-probe-text"),
		alicorn.layout_style(.Row, width=200, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.style_environment_pop(&ui, scope)
	if root != 0 { alicorn.container_end(&ui) }
	alicorn.end_frame(&ui)
	for _ in 0..<4 {
		ui2, more := alicorn.begin_frame(&h.rt)
		if !more { break }
		alicorn.end_frame(&ui2)
	}
	before, before_ok := probe_text_paint_color(&h.rt, "theme-probe-text")
	require(before_ok, "theme text probe did not retain its text paint")
	replacement := theme_variant(1)
	require(alicorn.style_theme_replace(&h.rt, theme_id, replacement) == .Replaced, "theme text probe replacement failed")
	presentation, ready := alicorn.begin_presentation_frame(&h.rt)
	if ready { alicorn.end_presentation_frame(&presentation) }
	after, after_ok := probe_text_paint_color(&h.rt, "theme-probe-text")
	require(after_ok, "theme text probe lost its text paint")
	expected := alicorn.style_theme_color(&h.rt, theme_id, .Text)
	status := "stale"
	if after == expected { status = "updated" }
	fmt.printf("theme_text_probe status=%s before=%.3f,%.3f,%.3f after=%.3f,%.3f,%.3f expected=%.3f,%.3f,%.3f note=description_resolved_text_color_is_not_recomputed_by_paint_only_replacement\n",
		status, before.r, before.g, before.b, after.r, after.g, after.b, expected.r, expected.g, expected.b)
}

run_virtual_report :: proc(results: ^Results, samples: int) {	run_virtual_group(samples, results)
	for mode in ([3]Mode{.Root, .Region, .App}) {
		result := &results.virtual[mode]
		print_work(.Virtual_Scroll, mode, VIRTUAL_ITEM_COUNT, result.work, result.alloc, result.retained_nodes)
		aggregate := aggregate_samples(&result.set)
		print_timings(.Virtual_Scroll, mode, VIRTUAL_ITEM_COUNT, result.set.count, aggregate)
		status := "PASS" if result.correctness_ok else "FAIL"
		idle_status := "PASS" if result.idle_ok else "FAIL"
		fmt.printf("correctness scene=%s n=%d mode=%s status=%s note=%s idle=%s idle_frames=%d gpu_submits=%d\n",
			SCENARIO_NAMES[.Virtual_Scroll], VIRTUAL_ITEM_COUNT, mode_name(mode), status,
			result.correctness_note, idle_status, result.idle_frames, result.work.gpu_submits)
		require(result.correctness_ok, fmt.tprintf("virtual correctness failed for mode %s: %s", mode_name(mode), result.correctness_note))
		require(result.idle_ok, fmt.tprintf("virtual idle failed for mode %s", mode_name(mode)))
		require(result.set.count == samples, "virtual sample count mismatch")
	}
}

main :: proc() {
	init_keys()
	sample_count := 24
	size_values := [3]int{100, 1000, 3000}
	size_count := 3
	selected_scenario := Scenario.Mount
	has_selected := false

	for arg in os.args[1:] {
		if strings.starts_with(arg, "--samples=") {
			sample_count = int(parse_u64(arg[len("--samples="):]))
			if sample_count < 1 { sample_count = 1 }
		} else if strings.starts_with(arg, "--sizes=") {
			parts, split_error := strings.split(arg[len("--sizes="):], ",")
			require(split_error == nil, "could not parse --sizes")
			defer delete(parts)
			count := 0
			for part in parts {
				value := int(parse_u64(part))
				if value <= 0 { continue }
				if count < len(size_values) { size_values[count] = value }
				count += 1
			}
			if count > 0 { size_count = min(count, len(size_values)) }
		} else if strings.starts_with(arg, "--scenario=") {
			name := arg[len("--scenario="):]
			for index in 0..<len(SCENARIO_NAMES) {
				candidate := Scenario(index)
				if name == SCENARIO_NAMES[candidate] {
					selected_scenario = candidate
					has_selected = true
					break
				}
			}
			if !has_selected { benchmark_failure(fmt.tprintf("unknown scenario %q", name)) }
		}
	}
	if sample_count > MAX_SAMPLES {
		benchmark_failure(fmt.tprintf("--samples=%d exceeds MAX_SAMPLES=%d", sample_count, MAX_SAMPLES))
	}
	SIZE_VALUES = size_values

	fmt.println("Alicorn issue #190 sparse application updates and authoring cost")
	build_kind := "debug"
	when !ODIN_DEBUG { build_kind = "release" }
	fmt.printf("fixture=benchmarks/diagnostics/issue190_sparse_updates.odin build=%s samples=%d sizes=",
		build_kind, sample_count)
	for size_index in 0..<size_count {
		if size_index > 0 { fmt.printf(",") }
		fmt.printf("%d", size_values[size_index])
	}
	fmt.printf(" viewport=%.0fx%.0f row_height=%.0f theme=issue190-painted\n",
		VIEWPORT_WIDTH, VIEWPORT_HEIGHT, ROW_HEIGHT)
	fmt.printf("virtual=logical_items:%d visible_rows:%d row_height=%.0f viewport_height=%.0f\n",
		VIRTUAL_ITEM_COUNT, int(VIRTUAL_VIEWPORT_HEIGHT/VIRTUAL_ROW_HEIGHT), VIRTUAL_ROW_HEIGHT, VIRTUAL_VIEWPORT_HEIGHT)
	fmt.println("measurement=headless_cpu description+reconcile+measure+layout+paint+compose; no_gpu_presentation")
	fmt.println("columns=api_ns application mutation+invalidation; describe_ns begin_frame+description; frame_ns end_frame; total_ns sum")

	results := new(Results)
	defer free(results)

	print_mode_edges(size_values[size_count-1])

	scenario_list := REPORT_SCENARIOS
	if has_selected {
		if selected_scenario == .Virtual_Scroll {
			scenario_list = []Scenario{}
		} else {
			scenario_list = []Scenario{selected_scenario}
		}
	}

	for scenario in scenario_list {
		for size_index in 0..<size_count {
			run_scenario_group(size_index, scenario, sample_count, results)
		}
	}

	cross_mode_ok := true
	for size_index in 0..<size_count {
		if !cross_mode_visual_check(size_index) { cross_mode_ok = false }
	}

	for scenario in scenario_list {
		for size_index in 0..<size_count {
			n := size_values[size_index]
			for mode in ([3]Mode{.Root, .Region, .App}) {
				result := &results.scenes[mode][size_index][scenario]
				if result.set.count == 0 { continue }
				print_work(scenario, mode, n, result.work, result.alloc, result.retained_nodes)
				aggregate := aggregate_samples(&result.set)
				print_timings(scenario, mode, n, result.set.count, aggregate)
				status := "PASS" if result.correctness_ok else "FAIL"
				idle_status := "n/a"
				if result.idle_checked { idle_status = "PASS" if result.idle_ok else "FAIL" }
				fmt.printf("correctness scene=%s n=%d mode=%s status=%s note=%s idle=%s idle_frames=%d build_count=%d gpu_submits=%d\n",
					SCENARIO_NAMES[scenario], n, mode_name(mode), status, result.correctness_note,
					idle_status, result.idle_frames, result.build_count, result.work.gpu_submits)
				if scenario == .Destroy {
					fmt.printf("destroy_teardown scene=%s n=%d mode=%s retained_nodes=%d tracked_free_calls=%d tracked_live_bytes_after=0 nodes_retired_counter=0\n",
						SCENARIO_NAMES[scenario], n, mode_name(mode), result.retained_nodes, result.alloc.frees)
				}
			}
		}
	}

	if !has_selected || selected_scenario == .Virtual_Scroll {
		run_virtual_report(results, sample_count)
	}
	run_theme_text_probe()

	print_slopes(results, size_values[:], size_count)

	failures := 0
	for scenario in scenario_list {
		for size_index in 0..<size_count {
			for mode in ([3]Mode{.Root, .Region, .App}) {
				result := &results.scenes[mode][size_index][scenario]
				if result.set.count == 0 { continue }
				if !result.correctness_ok {
					fmt.printf("BENCHMARK FAILURE: scene=%s n=%d mode=%s correctness: %s\n",
						SCENARIO_NAMES[scenario], size_values[size_index], mode_name(mode), result.correctness_note)
					failures += 1
				}
				if !result.idle_ok {
					fmt.printf("BENCHMARK FAILURE: scene=%s n=%d mode=%s idle work was not zero\n",
						SCENARIO_NAMES[scenario], size_values[size_index], mode_name(mode))
					failures += 1
				}			}
		}
	}
	if !has_selected || selected_scenario == .Virtual_Scroll {
		for mode in ([3]Mode{.Root, .Region, .App}) {
			result := &results.virtual[mode]
			if !result.correctness_ok {
				fmt.printf("BENCHMARK FAILURE: scene=%s mode=%s correctness: %s\n",
					SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode), result.correctness_note)
				failures += 1
			}
			if !result.idle_ok {
				fmt.printf("BENCHMARK FAILURE: scene=%s mode=%s idle work was not zero\n",
					SCENARIO_NAMES[.Virtual_Scroll], mode_name(mode))
				failures += 1
			}
		}
	}
	if failures > 0 { os.exit(1) }
	if !cross_mode_ok {
		fmt.println("BENCHMARK FAILURE: cross-mode visual parity failed")
		os.exit(1)
	}
	fmt.println("ISSUE 190 SPARSE UPDATES PASS")
}
