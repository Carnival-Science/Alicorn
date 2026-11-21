package testui

// Headless coverage for the issue #229 Scratchpad-shaped workload. The scene
// package is the same one compiled into the native SDL_GPU and hosted WebGPU
// benchmarks, so this test also proves the benchmark fixture exercises
// ordinary, backend-neutral retained work.

import "core:testing"
import alicorn "alicorn:runtime"
import scratchpad "alicorn:benchmarks/scratchpad_scene"
import ui "alicorn:ui"

SCRATCHPAD_TEST_LINES :: 10_000

Scratchpad_Scene_App :: struct {
	scene: scratchpad.Scene,
	theme_ready: bool,
}

scratchpad_scene_test_render :: proc(app: ^Scratchpad_Scene_App, ctx: ^ui.UI) {
	scratchpad.scene_describe(&app.scene, ctx)
}

scratchpad_scene_test_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Scratchpad_Scene_App)state
	app.theme_ready = scratchpad.register_theme(&app.scene, rt)
}

@(test)
test_headless_scratchpad_scene_drives_interactions_and_stage_timings :: proc(t: ^testing.T) {
	app := Scratchpad_Scene_App{}
	if !testing.expect(t, scratchpad.scene_init(&app.scene, .Typing, context.allocator),
		"the Scratchpad-shaped scene should initialize") { return }
	defer scratchpad.scene_destroy(&app.scene)

	handle, status := open(
		&app,
		scratchpad_scene_test_render,
		width=scratchpad.SCRATCHPAD_WIDTH,
		height=scratchpad.SCRATCHPAD_HEIGHT,
		initialize=scratchpad_scene_test_initialize,
	)
	defer close(&handle)
	if !testing.expectf(t, status == .Ok, "the Scratchpad-shaped scene should stabilize headlessly: %v", status) {
		return
	}
	testing.expect(t, app.theme_ready, "the gradient accent theme should register")
	initial := last_turn(&handle)
	testing.expectf(t, initial.work.stage_timings_ns[.Description] > 0,
		"the initial description should report an attributed duration: %v", initial.message)
	testing.expect(t, initial.work.stage_timings_ns[.Reconcile] > 0)
	testing.expect(t, initial.work.stage_timings_ns[.Layout] > 0)
	testing.expect(t, initial.work.descriptions_emitted > 0 && initial.work.descriptions_emitted < SCRATCHPAD_TEST_LINES,
		"the editor must virtualize its 10,000 logical lines")
	testing.expect(t, app.scene.tree_visible_count > 0 && app.scene.tree_visible_count < scratchpad.TREE_NODE_COUNT,
		"the workspace tree should virtualize a collapsed subtree")

	field := app.scene.field_node
	if !testing.expect(t, field != 0, "the command field should be described") { return }
	info, found := alicorn.node_info(handle.runtime, field)
	if !testing.expect(t, found && info.active && info.bounds.w > 0,
		"the command field should have realized geometry") { return }
	status = click_at(&handle, info.bounds.x+info.bounds.w*0.5, info.bounds.y+info.bounds.h*0.5)
	if !testing.expectf(t, status == .Ok, "clicking the command field should stabilize: %v", status) { return }
	testing.expect(t, alicorn.focused_node(handle.runtime) == field,
		"the command field should take focus through the ordinary pointer path")
	_ = alicorn.set_text_selection(handle.runtime, field, 0, 5)
	interaction, interaction_ok := alicorn.text_field_interaction(handle.runtime, field)
	testing.expect(t, interaction_ok && interaction.has_selection && interaction.selection_end == 5,
		"the command field should carry a selection")

	// Typing mutates the application-owned buffer and requests a fresh
	// description. The retained field consumes its model text on that pass.
	if testing.expect(t, scratchpad.scene_apply_step(&app.scene, handle.runtime, 0),
		"typing should request a description") {
		status = step(&handle, Input{kind=.Time_Advance, delta_ns=1_000_000})
		testing.expectf(t, status == .Ok, "a typing turn should stabilize: %v", status)
		typing_work := last_turn(&handle).work
		testing.expect(t, typing_work.descriptions_emitted > 0)
		testing.expectf(t, typing_work.stage_timings_ns[.Reconcile] > 0,
			"a typing turn should attribute reconcile work: %v", last_turn(&handle).message)
		testing.expect(t, typing_work.measure_nodes_executed > 0 || typing_work.measure_nodes_examined > 0,
			"the changed field text should enter the measure path")
	}

	// Scrolling the virtualized editor and tree keeps the description small.
	before_scroll := alicorn.frame_stats_snapshot(handle.runtime)
	scratchpad.scene_set_interaction(&app.scene, .Scroll)
	if testing.expect(t, scratchpad.scene_apply_step(&app.scene, handle.runtime, 4),
		"scroll should request a description") {
		status = step(&handle, Input{kind=.Time_Advance, delta_ns=2_000_000})
		testing.expectf(t, status == .Ok, "a scroll turn should stabilize: %v", status)
		after_scroll := alicorn.frame_stats_snapshot(handle.runtime)
		testing.expect(t, after_scroll.layout_nodes_visited > before_scroll.layout_nodes_visited ||
			after_scroll.descriptions_reused > before_scroll.descriptions_reused,
			"scroll should either relayout retained rows or reuse their descriptions")
		testing.expect(t, after_scroll.descriptions_retained_match > before_scroll.descriptions_retained_match,
			"scroll should take the exact description-reuse gate for unchanged rows")
	}

	// Tab switching changes application state and repaints retained tabs.
	previous_tab := app.scene.active_tab
	scratchpad.scene_set_interaction(&app.scene, .Tabs)
	if testing.expect(t, scratchpad.scene_apply_step(&app.scene, handle.runtime, 5),
		"tab switching should request a description") {
		status = step(&handle, Input{kind=.Time_Advance, delta_ns=3_000_000})
		testing.expectf(t, status == .Ok, "a tab turn should stabilize: %v", status)
		testing.expect(t, app.scene.active_tab != previous_tab,
			"the application-owned active tab should advance")
	}

	// A logical viewport resize exercises the full measure/layout path.
	scratchpad.scene_set_interaction(&app.scene, .Resize)
	if testing.expect(t, scratchpad.scene_apply_step(&app.scene, handle.runtime, 6),
		"a resize should request a description") {
		status = step(&handle, Input{kind=.Time_Advance, delta_ns=4_000_000})
		testing.expectf(t, status == .Ok, "a resize turn should stabilize: %v", status)
		resize_work := last_turn(&handle).work
		testing.expect(t, resize_work.layout_nodes_visited > 0 || resize_work.measure_nodes_examined > 0,
			"a logical resize should visit layout or measure")
		testing.expect(t, resize_work.stage_timings_ns[.Description] > 0,
			"a resize turn should report a description duration")
	}

	// An idle presentation turn must not manufacture retained work.
	idle_before := alicorn.frame_stats_snapshot(handle.runtime)
	status = step(&handle, Input{kind=.Time_Advance, delta_ns=5_000_000})
	testing.expectf(t, status == .Ok, "an idle turn should remain stable: %v", status)
	idle_after := alicorn.frame_stats_snapshot(handle.runtime)
	testing.expect(t, idle_before.reconcile_nodes_visited == idle_after.reconcile_nodes_visited &&
		idle_before.layout_nodes_visited == idle_after.layout_nodes_visited &&
		idle_before.paint_nodes_visited == idle_after.paint_nodes_visited,
		"the settled scene should perform no retained stage work")
}
