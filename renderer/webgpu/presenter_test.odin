#+build !js
package webgpu_renderer

import "core:testing"
import alicorn "../../runtime"

@(test)
test_webgpu_presenter_bounded_async_submission_capacity :: proc(t: ^testing.T) {
	testing.expect(t, webgpu_presenter_capacity_available(0, 0, 3), "an idle presenter accepts a frame")
	testing.expect(t, webgpu_presenter_capacity_available(2, 1, 3), "one completed queue slot becomes reusable")
	testing.expect(t, !webgpu_presenter_capacity_available(3, 0, 3), "a full presenter reports backpressure")
	testing.expect(t, !webgpu_presenter_capacity_available(2, 3, 3), "invalid completion counters cannot permit work")
	testing.expect(t, !webgpu_presenter_capacity_available(0, 0, 0), "zero capacity is invalid")
}

@(test)
test_webgpu_presenter_submission_tokens_are_generation_and_serial_scoped :: proc(t: ^testing.T) {
	valid := WebGPU_Submission{presenter_generation=7, serial=3, display_revision=11}
	testing.expect(t, webgpu_presenter_token_is_valid(7, 3, valid), "the owning presenter accepts its submitted token")
	testing.expect(t, !webgpu_presenter_token_is_valid(8, 3, valid), "a different presenter rejects the token")
	testing.expect(t, !webgpu_presenter_token_is_valid(7, 2, valid), "unsubmitted future serials are rejected")
	invalid := WebGPU_Submission{presenter_generation=7, serial=0}
	testing.expect(t, !webgpu_presenter_token_is_valid(7, 3, invalid), "zero serial is never a submission")
}

@(test)
test_webgpu_presenter_output_id_accepts_legacy_or_complete_runtime_identity :: proc(t: ^testing.T) {
	testing.expect(t,
		webgpu_presenter_output_id_is_well_formed({}),
		"an absent output keeps the legacy whole-runtime submission path")
	testing.expect(t,
		webgpu_presenter_output_id_is_well_formed(alicorn.Presentation_Output_ID{runtime_identity=7, sequence=2}),
		"an output ID must include both runtime identity and sequence")
	testing.expect(t,
		!webgpu_presenter_output_id_is_well_formed(alicorn.Presentation_Output_ID{runtime_identity=7}),
		"a partial output ID is rejected")
	testing.expect(t,
		!webgpu_presenter_output_id_is_well_formed(alicorn.Presentation_Output_ID{sequence=2}),
		"an output sequence without Runtime identity is rejected")
}

@(test)
test_webgpu_presenter_submission_acknowledges_only_its_runtime_output :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 240, 120})
	defer alicorn.destroy_runtime(&rt)
	left, left_status := alicorn.presentation_output_register(&rt)
	right, right_status := alicorn.presentation_output_register(&rt)
	if left_status != .Ok || right_status != .Ok {
		testing.expect(t, false, "two presentation outputs should register")
		return
	}
	ui, build := alicorn.begin_frame(&rt)
	if !build { testing.expect(t, false, "output-root test frame should build"); return }
	_ = alicorn.container_begin(&ui, .Root, key="webgpu-presenter-output-root", style=alicorn.layout_style(.Row))
	left_root := alicorn.container_begin(&ui, .Container, key="webgpu-presenter-left", style=alicorn.layout_style(.Column, width=120))
	_ = alicorn.presentation_output_bind_root(&rt, left, left_root)
	alicorn.text(&ui, "left", key="webgpu-presenter-left-text")
	alicorn.container_end(&ui)
	right_root := alicorn.container_begin(&ui, .Container, key="webgpu-presenter-right", style=alicorn.layout_style(.Column, width=120))
	_ = alicorn.presentation_output_bind_root(&rt, right, right_root)
	alicorn.text(&ui, "right", key="webgpu-presenter-right-text")
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	left_snapshot, left_snapshot_status := alicorn.presentation_output_snapshot(&rt, left)
	right_snapshot, right_snapshot_status := alicorn.presentation_output_snapshot(&rt, right)
	if left_snapshot_status != .Ok || right_snapshot_status != .Ok {
		testing.expect(t, false, "both output snapshots should be available")
		return
	}
	left_acked := webgpu_presenter_ack_submission(&rt, left, true, left_snapshot.revision)
	left_after, _ := alicorn.presentation_output_snapshot(&rt, left)
	right_after, _ := alicorn.presentation_output_snapshot(&rt, right)
	testing.expect(t, left_acked && !left_after.pending,
		"the submitted left output revision should be acknowledged")
	testing.expect(t, right_after.pending,
		"acknowledging one output must preserve independent work on the right output")
	testing.expect(t, alicorn.frame_needs_submission(&rt),
		"the remaining visible output must still request presentation")
}
