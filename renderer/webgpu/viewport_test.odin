#+build !js
package webgpu_renderer

import "core:testing"

@(test)
test_webgpu_capture_view_slots_are_unique_until_submission :: proc(t: ^testing.T) {
	used: u64 = 0
	testing.expect(t, !webgpu_view_capture_slot_available(used, 0), "slot zero belongs to the main viewport")
	testing.expect(t, !webgpu_view_capture_slot_available(used, VIEW_UNIFORM_SLOT_COUNT), "out-of-range capture slot is rejected")
	testing.expect(t, webgpu_view_capture_slot_claim(&used, 1), "first capture slot should be claimable")
	testing.expect(t, !webgpu_view_capture_slot_available(used, 1), "a capture slot cannot be overwritten before submission")
	testing.expect(t, !webgpu_view_capture_slot_claim(&used, 1), "duplicate capture slot claim should fail")
	testing.expect(t, webgpu_view_capture_slot_claim(&used, VIEW_UNIFORM_MAX_CAPTURE_VIEWS), "last bounded capture slot should be claimable")
	testing.expect(t, VIEW_UNIFORM_EFFECT_CAPTURE_SLOT == VIEW_UNIFORM_MAX_CAPTURE_VIEWS+1, "the compositor effect capture has its own reserved slot")
	testing.expect(t, webgpu_view_capture_slot_claim(&used, VIEW_UNIFORM_EFFECT_CAPTURE_SLOT), "reserved effect capture slot should not collide with public crops")
	testing.expect(t, VIEW_UNIFORM_BUFFER_BYTES >= u64(VIEW_UNIFORM_EFFECT_CAPTURE_SLOT)*u64(VIEW_UNIFORM_CAPTURE_OFFSET)+VIEW_UNIFORM_BYTES,
		"uniform buffer must include the reserved effect capture slot")
	testing.expect(t, webgpu_view_capture_slot_available(used, 2), "independent captures use distinct uniform slots")
	used = 0 // Submission allows the bounded per-frame slots to be reused.
	testing.expect(t, webgpu_view_capture_slot_claim(&used, 1), "submitted capture slots become reusable")
}
