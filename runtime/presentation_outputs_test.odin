#+build !js

package alicorn

import "core:testing"

Presentation_Output_Test_Nodes :: struct {
	left_root:  Node_ID,
	right_root: Node_ID,
	left_text:  Node_ID,
	right_text: Node_ID,
	left_bind_status:  Presentation_Output_Status,
	right_bind_status: Presentation_Output_Status,
}

presentation_outputs_test_describe :: proc(
	rt: ^Runtime,
	left_output, right_output: Presentation_Output_ID,
	include_right := true,
	left_value := "left",
	right_value := "right",
) -> Presentation_Output_Test_Nodes {
	nodes := Presentation_Output_Test_Nodes{}
	ui, should_build := begin_frame(rt)
	if !should_build { return nodes }
	container_begin(&ui, .Root, key="presentation-output-test-root", style=layout_style(.Row, width=240, height=120))
	nodes.left_root = container_begin(&ui, .Container, key="presentation-output-left", style=layout_style(.Column, width=120, height=120))
	nodes.left_bind_status = presentation_output_bind_root(rt, left_output, nodes.left_root)
	nodes.left_text = text(&ui, left_value, key="presentation-output-left-text")
	container_end(&ui)
	if include_right {
		nodes.right_root = container_begin(&ui, .Container, key="presentation-output-right", style=layout_style(.Column, width=120, height=120))
		nodes.right_bind_status = presentation_output_bind_root(rt, right_output, nodes.right_root)
		nodes.right_text = text(&ui, right_value, key="presentation-output-right-text")
		container_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)
	return nodes
}

presentation_outputs_test_flush :: proc(rt: ^Runtime) {
	ui, ready := begin_presentation_frame(rt)
	if ready { end_presentation_frame(&ui) }
}

@(test)
test_presentation_outputs_publish_and_acknowledge_independently :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	left, left_status := presentation_output_register(&rt)
	right, right_status := presentation_output_register(&rt)
	testing.expect(t, left_status == .Ok && right_status == .Ok, "both native outputs should register")
	nodes := presentation_outputs_test_describe(&rt, left, right)
	testing.expect(t, nodes.left_root != 0 && nodes.right_root != 0, "both output subtrees should be described")
	testing.expect(t, nodes.left_bind_status == .Ok && nodes.right_bind_status == .Ok,
		"disjoint output roots should bind successfully")

	left_snapshot, left_snapshot_status := presentation_output_snapshot(&rt, left)
	right_snapshot, right_snapshot_status := presentation_output_snapshot(&rt, right)
	testing.expect(t, left_snapshot_status == .Ok && right_snapshot_status == .Ok && left_snapshot.pending && right_snapshot.pending,
		"initially bound outputs should each need one successful submission")
	if left_snapshot_status != .Ok || right_snapshot_status != .Ok { return }
	testing.expect(t, presentation_output_frame_submission_succeeded(&rt, left, left_snapshot.revision) == .Ok,
		"a successful left output submit should acknowledge its exact revision")
	testing.expect(t, frame_needs_submission(&rt), "right output work should remain pending after left acknowledgement")
	testing.expect(t, presentation_output_frame_submission_succeeded(&rt, right, right_snapshot.revision) == .Ok,
		"a successful right output submit should acknowledge its exact revision")
	testing.expect(t, !frame_needs_submission(&rt), "all visible outputs should return the Runtime to idle")

	invalidate_interaction_paint(&rt, nodes.left_text, "test left subtree update")
	presentation_outputs_test_flush(&rt)
	left_snapshot, _ = presentation_output_snapshot(&rt, left)
	right_snapshot, _ = presentation_output_snapshot(&rt, right)
	testing.expect(t, left_snapshot.pending && !right_snapshot.pending,
		"a retained update inside the left root should not dirty the right output")
	testing.expect(t, frame_needs_submission(&rt), "the dirty left output should request a frame")

	stale_revision := left_snapshot.revision
	invalidate_interaction_paint(&rt, nodes.left_text, "newer left subtree update")
	presentation_outputs_test_flush(&rt)
	left_snapshot, _ = presentation_output_snapshot(&rt, left)
	testing.expect(t, left_snapshot.revision > stale_revision, "a newer left update should publish a newer revision")
	testing.expect(t,
		presentation_output_frame_submission_succeeded(&rt, left, stale_revision) == .Stale_Revision,
		"an acknowledgement from an earlier left frame must not clear newer work")
	testing.expect(t, frame_needs_submission(&rt), "stale acknowledgement must leave the newer frame pending")
	testing.expect(t,
		presentation_output_frame_submission_succeeded(&rt, left, left_snapshot.revision) == .Ok,
		"the current left revision should be acknowledged")
	testing.expect(t, !frame_needs_submission(&rt), "acknowledging the current left revision should restore idle")
}

@(test)
test_presentation_outputs_global_invalidation_visibility_and_retirement :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	left, _ := presentation_output_register(&rt)
	right, _ := presentation_output_register(&rt)
	_ = presentation_outputs_test_describe(&rt, left, right)
	left_snapshot, _ := presentation_output_snapshot(&rt, left)
	right_snapshot, _ := presentation_output_snapshot(&rt, right)
	_ = presentation_output_frame_submission_succeeded(&rt, left, left_snapshot.revision)
	_ = presentation_output_frame_submission_succeeded(&rt, right, right_snapshot.revision)

	request_presentation(&rt, "shared chrome changed")
	presentation_outputs_test_flush(&rt)
	left_snapshot, _ = presentation_output_snapshot(&rt, left)
	right_snapshot, _ = presentation_output_snapshot(&rt, right)
	testing.expect(t, left_snapshot.pending && right_snapshot.pending,
		"a shared presentation invalidation should dirty every output")
	testing.expect(t, presentation_output_set_visible(&rt, right, false) == .Ok,
		"the host should be able to hide the right output")
	testing.expect(t, frame_needs_submission(&rt), "visible left output should remain schedulable")
	testing.expect(t,
		presentation_output_frame_submission_succeeded(&rt, right, right_snapshot.revision) == .No_Pending_Frame,
		"a hidden output must not accept an acknowledgement without a submitted frame")
	_ = presentation_output_frame_submission_succeeded(&rt, left, left_snapshot.revision)
	testing.expect(t, !frame_needs_submission(&rt),
		"a hidden output must not keep the host spinning after visible work is acknowledged")

	testing.expect(t, presentation_output_set_visible(&rt, right, true) == .Ok,
		"the host should be able to restore the right output")
	presentation_outputs_test_flush(&rt)
	right_snapshot, _ = presentation_output_snapshot(&rt, right)
	testing.expect(t, right_snapshot.pending && frame_needs_submission(&rt),
		"restoring visibility should publish the retained output as pending")
	_ = presentation_output_frame_submission_succeeded(&rt, right, right_snapshot.revision)
	testing.expect(t, !frame_needs_submission(&rt), "restored output should return to idle after submission")

	invalidate_root(&rt, "remove right output subtree")
	_ = presentation_outputs_test_describe(&rt, left, right, include_right=false)
	right_snapshot, _ = presentation_output_snapshot(&rt, right)
	testing.expect(t, right_snapshot.root == 0 && !right_snapshot.pending,
		"retiring an output root should detach it and discard its obsolete pending frame")
	testing.expect(t, !frame_needs_submission(&rt), "a removed output must not leave presentation work spinning")
	_ = presentation_output_unregister(&rt, left)
	_ = presentation_output_unregister(&rt, right)
}

@(test)
test_presentation_output_gpu_geometry_update_is_local_to_its_root :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	left, _ := presentation_output_register(&rt)
	right, _ := presentation_output_register(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "geometry output fixture should build"); return }
	container_begin(&ui, .Root, key="geometry-output-root", style=layout_style(.Row, width=240, height=120))
	left_root := container_begin(&ui, .Container, key="geometry-output-left", style=layout_style(.Column, width=120, height=120))
	_ = presentation_output_bind_root(&rt, left, left_root)
	left_surface := gpu_geometry_surface(&ui, "geometry-output-left-surface", layout_style(width=120, height=120), 1)
	container_end(&ui)
	right_root := container_begin(&ui, .Container, key="geometry-output-right", style=layout_style(.Column, width=120, height=120))
	_ = presentation_output_bind_root(&rt, right, right_root)
	_ = gpu_geometry_surface(&ui, "geometry-output-right-surface", layout_style(width=120, height=120), 1)
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)

	left_snapshot, _ := presentation_output_snapshot(&rt, left)
	right_snapshot, _ := presentation_output_snapshot(&rt, right)
	_ = presentation_output_frame_submission_succeeded(&rt, left, left_snapshot.revision)
	_ = presentation_output_frame_submission_succeeded(&rt, right, right_snapshot.revision)
	segment := GPU_Surface_Line_Segment{start={2, 2}, end={90, 90}, thickness=2, color={0.3, 0.7, 0.9, 1}}
	testing.expect(t, gpu_surface_update_geometry(&rt, left_surface, []GPU_Surface_Line_Segment{segment}, nil),
		"the left geometry surface should accept its update")
	testing.expect(t, rt.presentation_pending,
		"custom geometry updates should also open the retained presentation-only path")
	presentation_outputs_test_flush(&rt)
	left_snapshot, _ = presentation_output_snapshot(&rt, left)
	right_snapshot, _ = presentation_output_snapshot(&rt, right)
	testing.expect(t, left_snapshot.pending && !right_snapshot.pending,
		"a GPU geometry payload update should schedule only the output containing that surface")
}

@(test)
test_presentation_outputs_reject_overlapping_roots_and_preserve_legacy_path :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	left, _ := presentation_output_register(&rt)
	right, _ := presentation_output_register(&rt)
	ui, build := begin_frame(&rt)
	if !build { testing.expect(t, false, "root fixture should build"); return }
	outer := container_begin(&ui, .Root, key="output-overlap-root", style=layout_style(.Column))
	inner := container_begin(&ui, .Container, key="output-overlap-inner", style=layout_style(.Column))
	_ = presentation_output_bind_root(&rt, left, outer)
	testing.expect(t, presentation_output_bind_root(&rt, right, inner) == .Root_Overlap,
		"overlapping retained roots must be rejected")
	text(&ui, "content", key="output-overlap-text")
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)

	legacy := new_runtime(Rect{0, 0, 20, 20})
	defer destroy_runtime(&legacy)
	legacy.presentation_revision = 2
	legacy.submitted_revision = 1
	testing.expect(t, frame_needs_submission(&legacy), "runtimes without bound outputs should retain whole-frame scheduling")
	frame_submission_succeeded(&legacy)
	testing.expect(t, !frame_needs_submission(&legacy), "legacy whole-frame acknowledgement should still return to idle")
}
