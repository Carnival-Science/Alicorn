#+build !js

package alicorn

import "core:testing"

Hosted_Multi_Output_Test_App :: struct {
	ruler_output, waveform_output: Presentation_Output_ID,
	ruler_value, waveform_value: string,
	show_waveform: bool,
	initialized: bool,
	descriptions: int,
}

Hosted_Multi_Output_Test_Target :: struct {
	root: Node_ID,
	revision: u64,
	attempts, acknowledgements: int,
}

hosted_multi_output_test_post_wake :: proc(data: rawptr) -> bool {
	return true
}

hosted_multi_output_test_initialize :: proc(data: rawptr, rt: ^Runtime) {
	app := (^Hosted_Multi_Output_Test_App)(data)
	ruler_output, ruler_status := presentation_output_register(rt)
	waveform_output, waveform_status := presentation_output_register(rt)
	app.ruler_output = ruler_output
	app.waveform_output = waveform_output
	app.initialized = ruler_status == .Ok && waveform_status == .Ok
}

hosted_multi_output_test_render :: proc(data: rawptr, ui: ^UI, width, height: int, dpi: f32) {
	app := (^Hosted_Multi_Output_Test_App)(data)
	app.descriptions += 1
	ruler_height := f32(height)*0.5
	ruler := container_begin(ui, .Container, key="hosted-output-ruler",
		style=layout_style(.Column, width=f32(width), height=ruler_height))
	if ruler != 0 {
		_ = presentation_output_bind_root(ui.runtime, app.ruler_output, ruler)
		_ = text(ui, app.ruler_value, key="hosted-output-ruler-label")
	}
	container_end(ui)
	if app.show_waveform {
		waveform := container_begin(ui, .Container, key="hosted-output-waveform",
			style=layout_style(.Column, width=f32(width), height=f32(height)-ruler_height))
		if waveform != 0 {
			_ = presentation_output_bind_root(ui.runtime, app.waveform_output, waveform)
			_ = text(ui, app.waveform_value, key="hosted-output-waveform-label")
		}
		container_end(ui)
	}
}

hosted_multi_output_test_open :: proc(
	host: ^Hosted_Runtime,
	app: ^Hosted_Multi_Output_Test_App,
) -> Hosted_Runtime_Status {
	app.ruler_value = "Ruler 0"
	app.waveform_value = "Waveform 0"
	app.show_waveform = true
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=240,
		logical_height=120,
		pixel_width=480,
		pixel_height=240,
		dpi_scale=2,
		render=hosted_multi_output_test_render,
		on_initialize=hosted_multi_output_test_initialize,
		post_wake=hosted_multi_output_test_post_wake,
	})
}

// This host fixture models each native target as a separate submit callback.
// A failed target submission deliberately leaves its Runtime revision pending.
hosted_multi_output_test_submit :: proc(
	host: ^Hosted_Runtime,
	output: Presentation_Output_ID,
	target: ^Hosted_Multi_Output_Test_Target,
	submission_succeeds := true,
) -> bool {
	rt, runtime_status := hosted_runtime_borrow(host)
	if runtime_status != .Ok || target == nil { return false }
	snapshot, snapshot_status := presentation_output_snapshot(rt, output)
	if snapshot_status != .Ok || !snapshot.pending { return false }
	target.attempts += 1
	if !submission_succeeds { return false }
	target.root = snapshot.root
	target.revision = snapshot.revision
	if presentation_output_frame_submission_succeeded(rt, output, snapshot.revision) != .Ok { return false }
	target.acknowledgements += 1
	return true
}

@(test)
test_hosted_runtime_coordinates_two_native_presentation_targets :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Multi_Output_Test_App
	if hosted_multi_output_test_open(&host, &app) != .Ok {
		testing.expect(t, false, "multi-output host fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	if !app.initialized {
		testing.expect(t, false, "host initialization should register both native targets")
		return
	}

	first := hosted_runtime_step(&host, 1)
	rt, runtime_status := hosted_runtime_borrow(&host)
	ruler_target, waveform_target: Hosted_Multi_Output_Test_Target
	ruler, ruler_status := presentation_output_snapshot(rt, app.ruler_output)
	waveform, waveform_status := presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, runtime_status == .Ok && ruler_status == .Ok && waveform_status == .Ok &&
		first.description_built && first.render_required && ruler.pending && waveform.pending,
		"one Hosted_Runtime should publish initial work independently for both native targets")
	if runtime_status != .Ok || ruler_status != .Ok || waveform_status != .Ok { return }
	testing.expect(t, ruler.root != waveform.root, "native targets should have disjoint retained roots")
	// A target that failed submission must not acknowledge its revision.
	testing.expect(t, !hosted_multi_output_test_submit(&host, app.ruler_output, &ruler_target, false),
		"failed native submission should not acknowledge the ruler")
	ruler, _ = presentation_output_snapshot(rt, app.ruler_output)
	testing.expect(t, ruler.pending && ruler_target.acknowledgements == 0,
		"failed submission should leave that exact output revision pending")
	// Present just the ruler. The waveform remains outstanding and keeps the
	// host's aggregate render_required signal asserted.
	testing.expect(t, hosted_multi_output_test_submit(&host, app.ruler_output, &ruler_target),
		"successful ruler submission should acknowledge the ruler revision only")
	after_ruler := hosted_runtime_step(&host, 2)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, after_ruler.render_required && waveform.pending && ruler_target.acknowledgements == 1,
		"the waveform must remain pending after the ruler target presents")
	testing.expect(t, hosted_multi_output_test_submit(&host, app.waveform_output, &waveform_target),
		"successful waveform submission should acknowledge the waveform revision")
	idle := hosted_runtime_step(&host, 3)
	testing.expect(t, !idle.render_required && !idle.has_more_work,
		"the host should become idle after both native targets acknowledge")

	// A source-model update limited to one described subtree must not force its
	// sibling target to repaint.
	app.ruler_value = "Ruler 1"
	invalidate_root(rt, "ruler-only test update")
	ruler_only := hosted_runtime_step(&host, 4)
	ruler, _ = presentation_output_snapshot(rt, app.ruler_output)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, ruler_only.description_built && ruler.pending && !waveform.pending,
		"a ruler-only description change should publish only the ruler output")
	testing.expect(t, hosted_multi_output_test_submit(&host, app.ruler_output, &ruler_target),
		"the ruler-only revision should submit independently")
	idle = hosted_runtime_step(&host, 5)
	testing.expect(t, !idle.render_required, "the ruler-only update should settle without repainting the waveform")

	app.waveform_value = "Waveform 1"
	invalidate_root(rt, "waveform-only test update")
	waveform_only := hosted_runtime_step(&host, 6)
	ruler, _ = presentation_output_snapshot(rt, app.ruler_output)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, waveform_only.description_built && waveform.pending && !ruler.pending,
		"a waveform-only description change should publish only the waveform output")
	testing.expect(t, hosted_multi_output_test_submit(&host, app.waveform_output, &waveform_target),
		"the waveform-only revision should submit independently")
	_ = hosted_runtime_step(&host, 7)

	// A shared surface resize changes both retained output roots.
	if hosted_runtime_resize(&host, 300, 140, 450, 210, 1.5) != .Ok {
		testing.expect(t, false, "shared host resize should be accepted")
		return
	}
	resized := hosted_runtime_step(&host, 8)
	ruler, _ = presentation_output_snapshot(rt, app.ruler_output)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, resized.description_built && ruler.pending && waveform.pending,
		"a shared resize should publish both affected native outputs")
	_ = hosted_multi_output_test_submit(&host, app.ruler_output, &ruler_target)
	_ = hosted_multi_output_test_submit(&host, app.waveform_output, &waveform_target)
	_ = hosted_runtime_step(&host, 9)

	// A hidden output retains its latest content but cannot keep the loop awake
	// or acknowledge work that the hidden native target did not submit.
	old_waveform_revision := waveform.revision
	_ = presentation_output_set_visible(rt, app.waveform_output, false)
	app.waveform_value = "Waveform 2"
	invalidate_root(rt, "hidden waveform-only test update")
	hidden_update := hosted_runtime_step(&host, 10)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, hidden_update.description_built && !hidden_update.render_required && !waveform.pending && !waveform.visible,
		"a hidden target should keep content pending without causing idle rendering")
	testing.expect(t, presentation_output_frame_submission_succeeded(rt, app.waveform_output, old_waveform_revision) == .No_Pending_Frame,
		"a hidden target must reject an acknowledgement as if it had submitted")

	_ = presentation_output_set_visible(rt, app.waveform_output, true)
	restored := hosted_runtime_step(&host, 11)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, restored.render_required && waveform.pending && waveform.revision > old_waveform_revision,
		"restoring the native target should publish its current retained content")
	testing.expect(t, presentation_output_frame_submission_succeeded(rt, app.waveform_output, old_waveform_revision) == .Stale_Revision,
		"an older target revision must not acknowledge the restored output")
	testing.expect(t, hosted_multi_output_test_submit(&host, app.waveform_output, &waveform_target),
		"the restored output should settle after its current revision is submitted")
	_ = hosted_runtime_step(&host, 12)

	// Removing the waveform subtree detaches its output ID; after the remaining
	// visible target settles, the single Runtime returns to idle.
	app.show_waveform = false
	invalidate_root(rt, "remove waveform target")
	removed := hosted_runtime_step(&host, 13)
	waveform, _ = presentation_output_snapshot(rt, app.waveform_output)
	testing.expect(t, removed.description_built && waveform.root == 0 && !waveform.pending,
		"a removed native target should detach its retained root and discard obsolete work")
	ruler, _ = presentation_output_snapshot(rt, app.ruler_output)
	if ruler.pending {
		_ = hosted_multi_output_test_submit(&host, app.ruler_output, &ruler_target)
		_ = hosted_runtime_step(&host, 14)
	}
	testing.expect(t, !frame_needs_submission(rt), "removed or completed targets must not keep the host spinning")
	_ = presentation_output_unregister(rt, app.ruler_output)
	_ = presentation_output_unregister(rt, app.waveform_output)
	removed_output := app.waveform_output
	recreated_output, recreate_status := presentation_output_register(rt)
	old_snapshot, old_output_status := presentation_output_snapshot(rt, removed_output)
	testing.expect(t, recreate_status == .Ok && old_output_status == .Invalid_Output &&
		recreated_output != removed_output && old_snapshot.root == 0 && !frame_needs_submission(rt),
		"a recreated native target should receive a fresh identity without reviving removed work")
	_ = presentation_output_unregister(rt, recreated_output)
}
