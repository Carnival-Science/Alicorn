#+build !js

package presentation_host

import "core:testing"

@(test)
test_hosted_surface_presenter_rejects_uninitialized_operations :: proc(t: ^testing.T) {
	presenter: Hosted_Surface_Presenter

	step, result := hosted_surface_presenter_step(&presenter, 1)
	testing.expect(t, step.status == .Closed)
	testing.expect(t, result == .Invalid_Input)
	testing.expect(t, !hosted_surface_presenter_has_in_flight(&presenter))
	testing.expect(t, hosted_surface_presenter_resize(&presenter, 640, 480, 640, 480, 1) == .Invalid_Input)
	testing.expect(t, hosted_surface_presenter_set_visible(&presenter, false) == .Invalid_Input)
	testing.expect(t, hosted_surface_presenter_destroy(&presenter))
}

@(test)
test_hosted_surface_timing_ring_drains_oldest_first :: proc(t: ^testing.T) {
	buffer: hosted_surface_timing_buffer
	hosted_surface_timing_record(&buffer, Hosted_Surface_Timing_Sample{display_revision=11})
	hosted_surface_timing_record(&buffer, Hosted_Surface_Timing_Sample{display_revision=12})

	output: [2]Hosted_Surface_Timing_Sample
	count := hosted_surface_timing_take(&buffer, output[:1])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, output[0].display_revision, 11)
	count = hosted_surface_timing_take(&buffer, output[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, output[0].display_revision, 12)
	testing.expect_value(t, buffer.count, 0)
}

@(test)
test_hosted_surface_timing_ring_bounds_and_overwrites_oldest :: proc(t: ^testing.T) {
	buffer: hosted_surface_timing_buffer
	for i in 0..<(HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY + 3) {
		hosted_surface_timing_record(&buffer, Hosted_Surface_Timing_Sample{display_revision=u64(i+1)})
	}
	testing.expect_value(t, buffer.count, HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY)
	testing.expect_value(t, buffer.overwritten, 3)

	output: [HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]Hosted_Surface_Timing_Sample
	count := hosted_surface_timing_take(&buffer, output[:])
	testing.expect_value(t, count, HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY)
	testing.expect_value(t, output[0].display_revision, 4)
	testing.expect_value(t, output[count-1].display_revision, u64(HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY+3))
	testing.expect_value(t, buffer.count, 0)
}
