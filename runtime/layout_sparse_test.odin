#+build !js
package alicorn

import "core:fmt"
import "core:testing"

// Issue #230, milestone 1: sparse column placement.
//
// The fixtures below are ordinary retained descriptions. The oracle is the
// same description sequence driven through a Runtime with force_full_layout,
// i.e. the reference placement walk. Every asserted geometry, finalized
// geometry, measure result, and measurement constraint is compared exactly by
// layout_allocation_test_geometry_matches. Visit probes and sparse counters
// prove the dependency-bounded path actually ran.

LAYOUT_SPARSE_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

LAYOUT_SPARSE_ROWS :: 18
LAYOUT_SPARSE_SHORT_TEXT :: "Short."
LAYOUT_SPARSE_LONG_TEXT :: "A longer message that wraps across several lines of the fixed-width column and therefore changes the row's measured height. This paragraph is deliberately long enough to occupy more than one line at the fixture width."

Layout_Sparse_Fixture :: struct {
	text:        string,
	row_count:   int,
	row_height:  f32,
	scale:       f32,
	selected:    [LAYOUT_SPARSE_ROWS]bool,
	order:       [LAYOUT_SPARSE_ROWS]int,
	middle_tint: u64,
}

Layout_Sparse_Ids :: struct {
	root:        Node_ID,
	middle:      Node_ID,
	middle_text: Node_ID,
	rows:        [LAYOUT_SPARSE_ROWS]Node_ID,
}

layout_sparse_fixture_init :: proc(fixture: ^Layout_Sparse_Fixture) {
	fixture^ = {}
	fixture.text = LAYOUT_SPARSE_SHORT_TEXT
	fixture.row_count = LAYOUT_SPARSE_ROWS
	fixture.row_height = 20
	fixture.scale = 1
	for index in 0..<LAYOUT_SPARSE_ROWS { fixture.order[index] = index }
}

layout_sparse_middle_slot :: proc(fixture: ^Layout_Sparse_Fixture) -> int {
	return fixture.row_count/2
}

layout_sparse_row_key :: proc(logical: int) -> UI_Key {
	return key_u64(0x2300+u64(logical))
}

layout_sparse_row_label_key :: proc(logical: int) -> UI_Key {
	return key_u64(0x2400+u64(logical))
}

layout_sparse_describe :: proc(rt: ^Runtime, fixture: ^Layout_Sparse_Fixture) -> Layout_Sparse_Ids {
	invalidate_root(rt, "layout sparse fixture description")
	ui, build := begin_frame(rt)
	if !build { return {} }
	ids: Layout_Sparse_Ids
	ids.root = container_begin(
		&ui, .Root, key=key_string("layout-sparse-root"),
		style=layout_style(.Column, width=-1, height=-1, gap=4),
	)
	scope := style_environment_push(&ui, Style_Environment{text_scale=fixture.scale})
	middle_slot := layout_sparse_middle_slot(fixture)
	for slot in 0..<fixture.row_count {
		if slot == middle_slot {
			ids.middle = container_begin(
				&ui, .Container, key=key_pair(0x2301, fixture.middle_tint),
				style=layout_style(.Column, width=-1, height=LAYOUT_SIZE_FIT_CONTENT),
			)
			ids.middle_text = text(
				&ui, fixture.text, key=key_string("layout-sparse-middle-text"),
				style=layout_style(width=-1), text_style=Text_Style{overflow=.Wrap},
			)
			container_end(&ui)
			ids.rows[slot] = ids.middle
			continue
		}
		logical := fixture.order[slot]
		ids.rows[slot] = container_begin(
			&ui, .Container, key=layout_sparse_row_key(logical), selected=fixture.selected[logical],
			style=layout_style(.Row, width=-1, height=fixture.row_height, padding=2),
		)
		text(&ui, "row", key=layout_sparse_row_label_key(logical), style=layout_style(.Row, width=60, height=12))
		container_end(&ui)
	}
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
	return ids
}

// A held-back Column sibling for the independent-subtree fixture. The outer
// height is fixed, so a wrapped-text height change stays inside the panel.
Layout_Sparse_Panels :: struct {
	left, right, left_text, right_text: Node_ID,
}

layout_sparse_panels_describe :: proc(rt: ^Runtime, left_text: string) -> Layout_Sparse_Panels {
	invalidate_root(rt, "layout sparse panel fixture description")
	ui, build := begin_frame(rt)
	if !build { return {} }
	ids: Layout_Sparse_Panels
	root := container_begin(&ui, .Root, key=key_string("layout-sparse-panel-root"),
		style=layout_style(.Column, width=-1, height=-1, gap=6))
	ids.left = container_begin(&ui, .Container, key=key_string("layout-sparse-panel-left"),
		style=layout_style(.Column, width=200, height=100, padding=4))
	ids.left_text = text(&ui, left_text, key=key_string("layout-sparse-panel-left-text"),
		style=layout_style(width=-1), text_style=Text_Style{overflow=.Wrap})
	container_end(&ui)
	ids.right = container_begin(&ui, .Container, key=key_string("layout-sparse-panel-right"),
		style=layout_style(.Column, width=200, height=100, padding=4))
	ids.right_text = text(&ui, "Unaffected panel", key=key_string("layout-sparse-panel-right-text"),
		style=layout_style(width=-1), text_style=Text_Style{overflow=.Wrap})
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	_ = root
	return ids
}

layout_sparse_assert_matches_oracle :: proc(t: ^testing.T, rt, oracle: ^Runtime, label: string) -> bool {
	if !layout_allocation_test_geometry_matches(rt, oracle) {
		testing.expectf(t, false,
			"%s: sparse layout must match the forced-full reference geometry, finalized geometry, and measurements", label)
		return false
	}
	return true
}

// Test/dev-only consistency check (#227 discipline): every retained placement
// entry still names a live parent and exactly that parent's current children,
// in order, with the bounds and clip the children currently hold.
@(private)
layout_sparse_is_consistent :: proc(rt: ^Runtime) -> bool {
	if rt == nil || !rt.layout_sparse_sidecar_initialized { return true }
	for parent_id, placement in rt.layout_sparse_placements {
		parent, found := rt.nodes[parent_id]
		if !found || parent == nil { return false }
		if len(placement.entries) != len(parent.children) { return false }
		for child_id, index in parent.children {
			entry := placement.entries[index]
			if entry.id != child_id { return false }
			child, child_found := rt.nodes[child_id]
			if !child_found || child == nil { return false }
			if !rect_equal(entry.bounds, child.bounds) || !rect_equal(entry.clip, child.clip) { return false }
		}
	}
	return true
}

layout_sparse_new_runtime :: proc(width: f32 = 420, height: f32 = 640) -> Runtime {
	rt := new_runtime(Rect{0, 0, width, height})
	_ = text_engine_load_font(&rt.text_engine, LAYOUT_SPARSE_TEST_FONT)
	return rt
}

// ---------------------------------------------------------------------------
// a. A single main-axis size change skips the unchanged leading siblings, the
// suffix is processed, and the final geometry equals the forced-full oracle.
// ---------------------------------------------------------------------------

@(test)
test_layout_sparse_column_suffix_skips_leading_siblings_and_matches_oracle :: proc(t: ^testing.T) {
	rt := layout_sparse_new_runtime()
	defer destroy_runtime(&rt)
	oracle := layout_sparse_new_runtime()
	defer destroy_runtime(&oracle)
	oracle.force_full_layout = true

	fixture := Layout_Sparse_Fixture{}
	layout_sparse_fixture_init(&fixture)
	ids := layout_sparse_describe(&rt, &fixture)
	reference := layout_sparse_describe(&oracle, &fixture)
	if ids.root == 0 || ids.middle == 0 || ids.middle_text == 0 || reference.root == 0 {
		testing.expect(t, false, "sparse fixture should retain root, middle row, and wrapped text")
		return
	}
	testing.expect(t, ids == reference, "fixture identities must match the oracle")
	middle_slot := layout_sparse_middle_slot(&fixture)
	testing.expect(t, rt.nodes[ids.middle].bounds.h < 40,
		"the short middle text should start at one wrapped line")

	for id in ids.rows { rt.layout_visit_probe[id] = 0 }
	reference_visits := oracle.stats.layout_nodes_visited

	visits_before := rt.stats.layout_nodes_visited
	suffix_before := rt.stats.layout_sparse_suffix_skips
	fixture.text = LAYOUT_SPARSE_LONG_TEXT
	next := layout_sparse_describe(&rt, &fixture)
	next_reference := layout_sparse_describe(&oracle, &fixture)
	if next != ids || next_reference != ids {
		testing.expect(t, false, "the text change must preserve every keyed identity")
		return
	}
	visits := rt.stats.layout_nodes_visited-visits_before
	full_visits := oracle.stats.layout_nodes_visited-reference_visits
	testing.expect(t, rt.nodes[ids.middle].bounds.h > 40,
		"the long middle text must grow the middle row's main size")
	for slot in 0..<middle_slot {
		testing.expectf(t, rt.layout_visit_probe[ids.rows[slot]] == 0,
			"leading sibling %d must not be visited by a suffix-only placement pass", slot)
	}
	testing.expect(t, rt.layout_visit_probe[ids.middle] > 0, "the changed middle row must be visited")
	testing.expect(t, rt.layout_visit_probe[ids.rows[middle_slot+1]] > 0,
		"the following suffix must be visited because its bounds shifted")
	testing.expectf(t, rt.stats.layout_sparse_suffix_skips-suffix_before >= u64(middle_slot),
		"the pass must skip at least the %d leading siblings (%d skipped)", middle_slot,
		rt.stats.layout_sparse_suffix_skips-suffix_before)
	testing.expectf(t, visits < full_visits,
		"suffix placement must visit fewer nodes than the full reference (%d < %d)", visits, full_visits)
	testing.expect(t, layout_sparse_is_consistent(&rt),
		"retained sparse placement entries must agree with the live tree")
	_ = layout_sparse_assert_matches_oracle(t, &rt, &oracle, "single main-axis change")
}

// ---------------------------------------------------------------------------
// b. Randomized seeded mutation sequences: every op is compared against a
// runtime that forcibly takes the full reference path.
// ---------------------------------------------------------------------------

Layout_Sparse_Op :: enum {
	Text_Short,
	Text_Long,
	Selection,
	Reorder,
	Insert,
	Remove,
	Text_Scale,
	All_Row_Height,
	Hover,
	Identical,
}

layout_sparse_apply_op :: proc(fixture: ^Layout_Sparse_Fixture, op: Layout_Sparse_Op, value: int) {
	switch op {
	case .Text_Short: fixture.text = LAYOUT_SPARSE_SHORT_TEXT
	case .Text_Long: fixture.text = LAYOUT_SPARSE_LONG_TEXT
	case .Selection:
		logical := value%LAYOUT_SPARSE_ROWS
		fixture.selected[logical] = !fixture.selected[logical]
	case .Reorder:
		first := value%fixture.row_count
		second := (value+1)%fixture.row_count
		fixture.order[first], fixture.order[second] = fixture.order[second], fixture.order[first]
	case .Insert:
		if fixture.row_count < LAYOUT_SPARSE_ROWS {
			fixture.order[fixture.row_count] = fixture.row_count
			fixture.row_count += 1
		}
	case .Remove:
		if fixture.row_count > 4 { fixture.row_count -= 1 }
	case .Text_Scale:
		fixture.scale = 1 if fixture.scale > 1 else 1.25
	case .All_Row_Height:
		// A description change on every direct child: no leading sibling can be
		// skipped, so the pass must do the full reference-sized work.
		fixture.row_height = 20 if fixture.row_height > 20 else 26
	case .Hover, .Identical:
	}
}

@(test)
test_layout_sparse_randomized_sequences_match_full_reference :: proc(t: ^testing.T) {
	rt := layout_sparse_new_runtime()
	defer destroy_runtime(&rt)
	oracle := layout_sparse_new_runtime()
	defer destroy_runtime(&oracle)
	oracle.force_full_layout = true

	fixture := Layout_Sparse_Fixture{}
	layout_sparse_fixture_init(&fixture)
	ids := layout_sparse_describe(&rt, &fixture)
	reference := layout_sparse_describe(&oracle, &fixture)
	if ids.root == 0 || reference.root == 0 {
		testing.expect(t, false, "randomized sparse fixture should retain its root")
		return
	}
	testing.expect(t, layout_sparse_is_consistent(&rt), "initial sparse sidecar must be consistent")

	seed: u64 = 0x5eed_0230
	random := seed
	ops := []Layout_Sparse_Op{
		.Text_Long, .Selection, .Hover, .Text_Short, .Reorder, .Text_Long, .Identical,
		.Insert, .Text_Short, .Selection, .Text_Scale, .Text_Long, .Remove, .Reorder,
		.All_Row_Height, .Text_Short, .Insert, .Hover, .Remove, .Text_Long,
	}
	sparse_passes := u64(0)
	suffix_skips := u64(0)
	for iteration in 0..<20 {
		op := ops[iteration%len(ops)]
		random = random*6364136223846793005+1442695040888963407
		value := int((random>>33)%4096)
		previous_text := fixture.text
		previous_row_height := fixture.row_height
		layout_sparse_apply_op(&fixture, op, value)
		text_changed := fixture.text != previous_text
		row_height_changed := fixture.row_height != previous_row_height
		if op == .Hover {
			// Move the pointer over an unchanged row: interaction-only work must
			// not schedule layout.
			hover_id := ids.rows[0]
			if node, ok := rt.nodes[hover_id]; ok {
				visits_before := rt.stats.layout_nodes_visited
				passes_before := rt.stats.layout_sparse_passes
				_ = process_pointer(&rt, Pointer_Event{kind=.Move,
					x=node.bounds.x+node.bounds.w*0.5, y=node.bounds.y+node.bounds.h*0.5, button=0})
				if oracle_node, oracle_ok := oracle.nodes[hover_id]; oracle_ok {
					_ = process_pointer(&oracle, Pointer_Event{kind=.Move,
						x=oracle_node.bounds.x+oracle_node.bounds.w*0.5,
						y=oracle_node.bounds.y+oracle_node.bounds.h*0.5, button=0})
				}
				testing.expect(t, rt.stats.layout_nodes_visited == visits_before &&
					rt.stats.layout_sparse_passes == passes_before,
					"hover must not schedule or visit layout")
			}
		}
		visits_before := rt.stats.layout_nodes_visited
		passes_before := rt.stats.layout_sparse_passes
		skips_before := rt.stats.layout_sparse_suffix_skips
		ids = layout_sparse_describe(&rt, &fixture)
		reference = layout_sparse_describe(&oracle, &fixture)
		if ids != reference {
			testing.expectf(t, false, "iteration %d op %v: retained identities diverged from the oracle", iteration, op)
			return
		}
		if !layout_sparse_assert_matches_oracle(t, &rt, &oracle, fmt.tprintf("iteration %d op %v", iteration, op)) {
			return
		}
		sparse_passes += rt.stats.layout_sparse_passes-passes_before
		suffix_skips += rt.stats.layout_sparse_suffix_skips-skips_before
		switch op {
		case .Selection, .Identical:
			testing.expect(t, rt.stats.layout_nodes_visited == visits_before,
				"selection and identical descriptions must not schedule or visit layout")
		case .Text_Scale:
			// A typography change dirties measurement for all text, but only the
			// wrapped row's measured output changes this fixture's geometry. The
			// oracle comparison below is the correctness claim.
		case .All_Row_Height:
			testing.expect(t, rt.stats.layout_sparse_suffix_skips == skips_before,
				"a change on every direct child must not skip any leading sibling")
			testing.expect(t, row_height_changed, "the all-row height op must change every row")
		case .Reorder, .Insert, .Remove:
			// Child-set changes invalidate the retained child order and take the
			// reference walk, but must still produce identical geometry.
		case .Text_Short, .Text_Long:
			if text_changed {
				testing.expect(t, rt.stats.layout_sparse_suffix_skips > skips_before,
					"a middle-row height change must skip unchanged leading siblings")
			}
		case .Hover:
		}
		testing.expectf(t, layout_sparse_is_consistent(&rt),
			"iteration %d op %v: sparse sidecar must agree with the live tree", iteration, op)
	}
	testing.expect(t, sparse_passes > 0 && suffix_skips > 0,
		"randomized sequence should exercise sparse passes and suffix skips")
}

// ---------------------------------------------------------------------------
// c. Independent subtree: an unchanged fixed sibling is not visited at all.
// ---------------------------------------------------------------------------

@(test)
test_layout_sparse_independent_subtree_is_not_visited :: proc(t: ^testing.T) {
	rt := layout_sparse_new_runtime()
	defer destroy_runtime(&rt)
	oracle := layout_sparse_new_runtime()
	defer destroy_runtime(&oracle)
	oracle.force_full_layout = true

	ids := layout_sparse_panels_describe(&rt, LAYOUT_SPARSE_SHORT_TEXT)
	reference := layout_sparse_panels_describe(&oracle, LAYOUT_SPARSE_SHORT_TEXT)
	if ids.left == 0 || ids.right == 0 || reference.right == 0 {
		testing.expect(t, false, "panel fixture should retain both fixed siblings")
		return
	}
	testing.expect(t, ids == reference, "panel identities must match the oracle")
	rt.layout_visit_probe[ids.left] = 0
	rt.layout_visit_probe[ids.right] = 0
	rt.layout_visit_probe[ids.right_text] = 0
	unchanged_before := rt.stats.layout_sparse_unchanged_skips
	left_bounds := rt.nodes[ids.left].bounds
	right_bounds := rt.nodes[ids.right].bounds
	_ = layout_sparse_panels_describe(&rt, LAYOUT_SPARSE_LONG_TEXT)
	_ = layout_sparse_panels_describe(&oracle, LAYOUT_SPARSE_LONG_TEXT)
	testing.expect(t, rt.nodes[ids.left].bounds == left_bounds && rt.nodes[ids.right].bounds == right_bounds,
		"fixed panel bounds must not move when wrapped text inside one panel changes height")
	testing.expect(t, rt.layout_visit_probe[ids.left] > 0, "the changed subtree must be visited")
	testing.expect(t, rt.layout_visit_probe[ids.right] == 0 && rt.layout_visit_probe[ids.right_text] == 0,
		"an unchanged independent sibling and its subtree must not be visited")
	testing.expect(t, rt.stats.layout_sparse_unchanged_skips > unchanged_before,
		"the unchanged sibling should be skipped by the unchanged-input fast path")
	_ = layout_sparse_assert_matches_oracle(t, &rt, &oracle, "independent subtree")
}

// ---------------------------------------------------------------------------
// d. A root viewport change is a container-input change and stays on the full
// reference path.
// ---------------------------------------------------------------------------

@(test)
test_layout_sparse_viewport_change_takes_full_path :: proc(t: ^testing.T) {
	rt := layout_sparse_new_runtime()
	defer destroy_runtime(&rt)
	oracle := layout_sparse_new_runtime()
	defer destroy_runtime(&oracle)
	oracle.force_full_layout = true

	fixture := Layout_Sparse_Fixture{}
	layout_sparse_fixture_init(&fixture)
	ids := layout_sparse_describe(&rt, &fixture)
	_ = layout_sparse_describe(&oracle, &fixture)
	if ids.root == 0 { testing.expect(t, false, "viewport fixture should retain its root"); return }
	for id in ids.rows { rt.layout_visit_probe[id] = 0 }
	passes_before := rt.stats.layout_sparse_passes
	skips_before := rt.stats.layout_sparse_suffix_skips

	rt.viewport = Rect{0, 0, 500, 600}
	oracle.viewport = Rect{0, 0, 500, 600}
	ids = layout_sparse_describe(&rt, &fixture)
	_ = layout_sparse_describe(&oracle, &fixture)
	testing.expect(t, rt.stats.layout_sparse_passes == passes_before,
		"a viewport resize must not run a sparse placement pass")
	testing.expect(t, rt.stats.layout_sparse_suffix_skips == skips_before,
		"a viewport resize must not skip leading siblings")
	for slot in 0..<fixture.row_count {
		if ids.rows[slot] != 0 {
			testing.expectf(t, rt.layout_visit_probe[ids.rows[slot]] > 0,
				"viewport resize must visit child %d on the full path", slot)
		}
	}
	_ = layout_sparse_assert_matches_oracle(t, &rt, &oracle, "viewport resize")
}

// ---------------------------------------------------------------------------
// e/g. Sidecar lifecycle: retirement removes entries, child-set changes
// replace them, and destruction releases the map.
// ---------------------------------------------------------------------------
@(test)
test_layout_sparse_sidecar_lifecycle_and_true_idle :: proc(t: ^testing.T) {
	rt := layout_sparse_new_runtime()
	fixture := Layout_Sparse_Fixture{}
	layout_sparse_fixture_init(&fixture)
	ids := layout_sparse_describe(&rt, &fixture)
	if ids.root == 0 { destroy_runtime(&rt); testing.expect(t, false, "lifecycle fixture should retain its root"); return }
	testing.expect(t, rt.layout_sparse_sidecar_initialized,
		"the first eligible column pass should initialize the sparse sidecar")
	placement, found := rt.layout_sparse_placements[ids.root]
	testing.expect(t, found && len(placement.entries) == len(rt.nodes[ids.root].children),
		"the root column should retain one entry per child")
	testing.expect(t, layout_sparse_is_consistent(&rt), "fresh sidecar must be consistent")

	// Child-set changes replace the retained slice; the live tree and cache stay
	// aligned and retiring the removed rows releases their storage.
	live_before := rt.allocation_stats.persistent_requested_bytes_live
	fixture.row_count = 4
	_ = layout_sparse_describe(&rt, &fixture)
	testing.expect(t, layout_sparse_is_consistent(&rt),
		"after removing children the sparse sidecar must describe only live children")
	testing.expectf(t, rt.allocation_stats.persistent_requested_bytes_live < live_before,
		"retiring rows must release tracked persistent storage (%d before, %d after)",
		live_before, rt.allocation_stats.persistent_requested_bytes_live)
	placement, found = rt.layout_sparse_placements[ids.root]
	testing.expect(t, found && len(placement.entries) == len(rt.nodes[ids.root].children),
		"the child-set change must republish the retained entry slice")

	// Changing the middle row's key retires the old subtree and rebuilds it
	// without leaving stale entries behind.
	retired_middle := ids.middle
	layout_sparse_fixture_init(&fixture)
	fixture.middle_tint = 7
	ids = layout_sparse_describe(&rt, &fixture)
	if _, still_present := rt.layout_sparse_placements[retired_middle]; still_present {
		testing.expect(t, false, "retiring a container must release its sparse placement entry")
	}
	testing.expect(t, layout_sparse_is_consistent(&rt), "key changes must leave the sidecar consistent")

	// A settled runtime stays truly idle for 200 frames: no description, measure,
	// layout, or sparse bookkeeping work.
	before := rt.stats
	for _ in 0..<200 {
		ui, build := begin_frame(&rt)
		if build { end_frame(&ui) }
	}
	testing.expect(t, rt.stats.frames_built == before.frames_built,
		"idle frames must not build the application")
	testing.expect(t, rt.stats.stage_visits == before.stage_visits &&
		rt.stats.layout_nodes_visited == before.layout_nodes_visited &&
		rt.stats.layout_sparse_passes == before.layout_sparse_passes &&
		rt.stats.layout_sparse_suffix_skips == before.layout_sparse_suffix_skips &&
		rt.stats.layout_sparse_unchanged_skips == before.layout_sparse_unchanged_skips,
		"idle frames must perform no layout or sparse placement work")

	destroy_runtime(&rt)
	testing.expect(t, !rt.layout_sparse_sidecar_initialized && rt.layout_sparse_placements == nil,
		"runtime destruction must release the sparse placement sidecar")
}

// ---------------------------------------------------------------------------
// h. Layout-stage scaling measurement for the issue #230 report. Correctness
// assertions are deterministic (visits must fall); timings are printed, not
// asserted, because the test runner executes unrelated tests concurrently.
// ---------------------------------------------------------------------------

LAYOUT_SPARSE_BENCH_ROWS :: [2]int{1000, 3000}
LAYOUT_SPARSE_BENCH_SAMPLES :: 8

Layout_Sparse_Bench_Scenario :: enum { Main_Height, Cross_Width }

Layout_Sparse_Bench_State :: struct {
	scenario:    Layout_Sparse_Bench_Scenario,
	middle_text: string,
	wide_row:    bool,
}

layout_sparse_bench_describe :: proc(rt: ^Runtime, count: int, state: ^Layout_Sparse_Bench_State) {
	invalidate_root(rt, "layout sparse bench description")
	ui, build := begin_frame(rt)
	if !build { return }
	root := container_begin(&ui, .Root, key=key_string("layout-sparse-bench-root"),
		style=layout_style(.Column, width=-1, height=-1, gap=1))
	middle := count/2
	width_row := count/3
	for index in 0..<count {
		if index == middle {
			container_begin(&ui, .Container, key=key_string("layout-sparse-bench-middle"),
				style=layout_style(.Column, width=-1, height=LAYOUT_SIZE_FIT_CONTENT))
			text(&ui, state.middle_text, key=key_string("layout-sparse-bench-middle-text"),
				style=layout_style(width=-1), text_style=Text_Style{overflow=.Wrap})
			container_end(&ui)
			continue
		}
		row_width: f32 = 240
		if state.scenario == .Cross_Width && index == width_row && state.wide_row { row_width = 320 }
		container_begin(&ui, .Container, key=key_u64(0x2500+u64(index)),
			style=layout_style(.Row, width=row_width, height=20, padding=2))
		text(&ui, "row", key=key_u64(0x2600+u64(index)), style=layout_style(.Row, width=60, height=12))
		container_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)
	_ = root
}

layout_sparse_bench_median :: proc(values: [LAYOUT_SPARSE_BENCH_SAMPLES]u64, count: int) -> u64 {
	sorted := values
	for index in 1..<count {
		key := sorted[index]
		position := index-1
		for position >= 0 && sorted[position] > key {
			sorted[position+1] = sorted[position]
			position -= 1
		}
		sorted[position+1] = key
	}
	return sorted[count/2]
}

layout_sparse_bench_scenario :: proc(t: ^testing.T, count: int, scenario: Layout_Sparse_Bench_Scenario) {
	sparse := layout_sparse_new_runtime()
	oracle := layout_sparse_new_runtime()
	oracle.force_full_layout = true
	state := Layout_Sparse_Bench_State{scenario=scenario, middle_text=LAYOUT_SPARSE_SHORT_TEXT}
	layout_sparse_bench_describe(&sparse, count, &state)
	layout_sparse_bench_describe(&oracle, count, &state)

	sparse_visits := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	full_visits := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	sparse_layout_ns := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	full_layout_ns := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	sparse_frame_ns := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	full_frame_ns := [LAYOUT_SPARSE_BENCH_SAMPLES]u64{}
	for sample in 0..<LAYOUT_SPARSE_BENCH_SAMPLES {
		switch scenario {
		case .Main_Height:
			state.middle_text = LAYOUT_SPARSE_LONG_TEXT if sample%2 == 0 else LAYOUT_SPARSE_SHORT_TEXT
		case .Cross_Width:
			state.wide_row = sample%2 == 0
		}
		sparse_changed := sparse.stats.layout_nodes_visited
		sparse_layout_mark := sparse.stats.stage_timings_ns[Runtime_Timing_Stage.Layout]
		mark := perf_mark_begin()
		layout_sparse_bench_describe(&sparse, count, &state)
		sparse_frame_ns[sample] = perf_mark_elapsed_ns(mark)
		sparse_visits[sample] = sparse.stats.layout_nodes_visited-sparse_changed
		sparse_layout_ns[sample] = sparse.stats.stage_timings_ns[Runtime_Timing_Stage.Layout]-sparse_layout_mark

		full_changed := oracle.stats.layout_nodes_visited
		full_layout_mark := oracle.stats.stage_timings_ns[Runtime_Timing_Stage.Layout]
		mark = perf_mark_begin()
		layout_sparse_bench_describe(&oracle, count, &state)
		full_frame_ns[sample] = perf_mark_elapsed_ns(mark)
		full_visits[sample] = oracle.stats.layout_nodes_visited-full_changed
		full_layout_ns[sample] = oracle.stats.stage_timings_ns[Runtime_Timing_Stage.Layout]-full_layout_mark
	}
	sparse_visit_median := layout_sparse_bench_median(sparse_visits, LAYOUT_SPARSE_BENCH_SAMPLES)
	full_visit_median := layout_sparse_bench_median(full_visits, LAYOUT_SPARSE_BENCH_SAMPLES)
	fmt.printf("SPARSE_M1_BENCH rows=%d scenario=%v sparse_visits=%d full_visits=%d sparse_layout_p50_ns=%d full_layout_p50_ns=%d sparse_frame_p50_ns=%d full_frame_p50_ns=%d\n",
		count, scenario,
		sparse_visit_median,
		full_visit_median,
		layout_sparse_bench_median(sparse_layout_ns, LAYOUT_SPARSE_BENCH_SAMPLES),
		layout_sparse_bench_median(full_layout_ns, LAYOUT_SPARSE_BENCH_SAMPLES),
		layout_sparse_bench_median(sparse_frame_ns, LAYOUT_SPARSE_BENCH_SAMPLES),
		layout_sparse_bench_median(full_frame_ns, LAYOUT_SPARSE_BENCH_SAMPLES))
	testing.expectf(t, sparse_visit_median < full_visit_median,
		"%d rows scenario %v: sparse visits (%d) must be proportional to the changed suffix, below the full reference (%d)",
		count, scenario, sparse_visit_median, full_visit_median)
	destroy_runtime(&oracle)
	destroy_runtime(&sparse)
}

@(test)
test_layout_sparse_layout_stage_scaling :: proc(t: ^testing.T) {
	for count in LAYOUT_SPARSE_BENCH_ROWS {
		layout_sparse_bench_scenario(t, count, .Main_Height)
		layout_sparse_bench_scenario(t, count, .Cross_Width)
	}
	testing.expect(t, true, "layout-stage scaling measurements printed")
}
