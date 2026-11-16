#+build !js
package webgpu_renderer

import "core:testing"

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
