#+build !js

package alicorn

import "core:testing"

// Hosted_Contract_Test_App proves the hosted runtime matches native/sdl_gpu's
// description contract: the application owns its root and describes overlays
// as siblings of that root. The after-frame callback proves post-layout work
// runs after end_frame of the same pass, before presentation, without relying
// on another frame being scheduled.
Hosted_Contract_Test_App :: struct {
	root, overlay, overlay_panel, child: Node_ID,
	descriptions, after_frames: int,
	sequence: [dynamic]u8,
	after_frame_frame_open: bool,
	after_frame_layout_pending: bool,
	after_frame_root_bounds: Rect,
	after_frame_root_is_top_level: bool,
	invalidate_in_after_frame: bool,
}

hosted_contract_test_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_contract_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Contract_Test_App)data
	app.descriptions += 1
	append(&app.sequence, 'd')
	root := container_begin(
		ui,
		.Root,
		label="app-root",
		key="app-root",
		style=layout_style(.Column, grow=1, padding=8, gap=6),
	)
	if root == 0 { return }
	app.root = root
	app.child, _ = button_ex(
		ui, "App child", key="app-child", style=layout_style(width=120, height=32),
	)
	container_end(ui)

	// A modal overlay is a top-level sibling of the application root, just as
	// it is under native/sdl_gpu. Describe it only after closing the root.
	overlay := modal_overlay_begin(
		ui, key_string("app-overlay"), style=layout_style(.Column, grow=1, align=.Center),
	)
	if overlay != 0 {
		app.overlay = overlay
		app.overlay_panel = container_begin(
			ui,
			.Container,
			label="app-overlay-panel",
			key="app-overlay-panel",
			style=layout_style(.Column, width=200, height=120, padding=10),
		)
		text(ui, "Overlay", key="overlay-text")
		container_end(ui)
		modal_overlay_end(ui)
	}
}

hosted_contract_test_after_frame :: proc(data: rawptr, rt: ^Runtime) {
	app := cast(^Hosted_Contract_Test_App)data
	app.after_frames += 1
	append(&app.sequence, 'a')
	app.after_frame_frame_open = rt.frame_open
	app.after_frame_layout_pending = rt.layout_pending
	if node, found := rt.nodes[app.root]; found {
		app.after_frame_root_bounds = node.bounds
		app.after_frame_root_is_top_level = node.parent == 0
	}
	if app.invalidate_in_after_frame {
		app.invalidate_in_after_frame = false
		invalidate_root(rt, "contract after-frame mutation")
	}
}

hosted_contract_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Contract_Test_App,
	height := 200,
	inset_top: f32 = 0,
) -> Hosted_Runtime_Status {
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=300,
		logical_height=height,
		pixel_width=600,
		pixel_height=height*2,
		dpi_scale=2,
		content_inset_top=inset_top,
		post_wake_data=rawptr(app),
		post_wake=hosted_contract_test_post,
		render=hosted_contract_test_render,
		on_after_frame=hosted_contract_test_after_frame,
	})
}

@(test)
test_hosted_application_root_is_the_window_root :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Contract_Test_App
	if hosted_contract_test_open(&host, &app) != .Ok {
		testing.expect(t, false, "contract fixture should initialize")
		return
	}
	defer {
		delete(app.sequence)
		hosted_runtime_destroy(&host)
	}

	step := hosted_runtime_step(&host, 1)
	testing.expect(t, step.status == .Ok && step.description_built, "the fixture should describe its first frame")
	rt, borrow_status := hosted_runtime_borrow(&host)
	if borrow_status != .Ok {
		testing.expect(t, false, "the contract fixture should borrow its Runtime")
		return
	}

	root, root_found := rt.nodes[app.root]
	overlay, overlay_found := rt.nodes[app.overlay]
	panel, panel_found := rt.nodes[app.overlay_panel]
	testing.expect(t,
		step.root == app.root && root_found && root.kind == .Root,
		"the hosted step must report the application's root, not a host wrapper")
	testing.expect(t,
		root.parent == 0 && root.bounds == Rect{0, 0, 300, 200},
		"the application root must be a top-level node with exactly the window content bounds")
	testing.expect(t,
		overlay_found && overlay.kind == .Modal_Overlay && overlay.parent == 0 &&
		overlay.bounds == Rect{0, 0, 300, 200},
		"a modal overlay must resolve against the application root's window, not a host wrapper column")
	testing.expect(t,
		panel_found && panel.parent == app.overlay && panel.bounds.w == 200 && panel.bounds.h == 120,
		"overlay descendants must lay out inside the top-level overlay layer")
	testing.expect(t,
		len(rt.top_level) == 2 && rt.top_level[0] == app.root && rt.top_level[1] == app.overlay,
		"the application root and its overlay must be the only top-level layers")
}

@(test)
test_hosted_application_root_respects_host_content_inset :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Contract_Test_App
	if hosted_contract_test_open(&host, &app, height=200, inset_top=40) != .Ok {
		testing.expect(t, false, "inset contract fixture should initialize")
		return
	}
	defer {
		delete(app.sequence)
		hosted_runtime_destroy(&host)
	}

	step := hosted_runtime_step(&host, 1)
	testing.expect(t, step.status == .Ok && step.description_built, "the inset fixture should describe its first frame")
	rt, borrow_status := hosted_runtime_borrow(&host)
	if borrow_status != .Ok {
		testing.expect(t, false, "the inset fixture should borrow its Runtime")
		return
	}
	root, found := rt.nodes[app.root]
	testing.expect(t,
		found && root.bounds == Rect{0, 0, 300, 160} && rt.viewport == Rect{0, 0, 300, 160},
		"host-owned chrome must reduce the application root/viewport instead of adding a wrapper")
	testing.expect(t,
		rt.nodes[app.overlay].bounds == Rect{0, 0, 300, 160},
		"overlays must use the inset-reduced application viewport")
}

@(test)
test_hosted_after_frame_runs_after_end_frame_every_description :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Contract_Test_App
	if hosted_contract_test_open(&host, &app) != .Ok {
		testing.expect(t, false, "after-frame fixture should initialize")
		return
	}
	defer {
		delete(app.sequence)
		hosted_runtime_destroy(&host)
	}

	first := hosted_runtime_step(&host, 1)
	testing.expect(t,
		first.description_built && app.descriptions == 1 && app.after_frames == 1,
		"after_frame must run once for the first described frame")
	testing.expect(t,
		!app.after_frame_frame_open,
		"after_frame must run after end_frame has closed the frame")
	testing.expect(t,
		!app.after_frame_layout_pending && app.after_frame_root_bounds == Rect{0, 0, 300, 200} &&
		app.after_frame_root_is_top_level,
		"after_frame must observe finalized post-layout geometry for the application root")
	testing.expect(t,
		len(app.sequence) == 2 && app.sequence[0] == 'd' && app.sequence[1] == 'a',
		"the per-frame order must be describe then after_frame")

	// No further frame is scheduled. after_frame must not wait for the next
	// description to run.
	second := hosted_runtime_step(&host, 2)
	testing.expect(t,
		second.status == .Ok && !second.description_built && app.descriptions == 1 && app.after_frames == 1,
		"after_frame must not be deferred into a later description")

	rt, _ := hosted_runtime_borrow(&host)
	invalidate_root(rt, "after-frame contract second description")
	third := hosted_runtime_step(&host, 3)
	testing.expect(t,
		third.description_built && app.descriptions == 2 && app.after_frames == 2 &&
		len(app.sequence) == 4 && app.sequence[2] == 'd' && app.sequence[3] == 'a',
		"every described frame, including the last before idle, must run after_frame in the same step")
}

@(test)
test_hosted_after_frame_can_request_same_step_correction :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Contract_Test_App
	app.invalidate_in_after_frame = true
	if hosted_contract_test_open(&host, &app) != .Ok {
		testing.expect(t, false, "after-frame correction fixture should initialize")
		return
	}
	defer {
		delete(app.sequence)
		hosted_runtime_destroy(&host)
	}

	step := hosted_runtime_step(&host, 1)
	testing.expect(t,
		step.status == .Ok && step.description_built && step.root == app.root,
		"an after-frame invalidation must be corrected within the same step")
	testing.expect(t,
		app.descriptions == 2 && app.after_frames == 2 && !app.invalidate_in_after_frame,
		"after_frame must run on each stabilization pass and settle without a following host step")
}
