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
