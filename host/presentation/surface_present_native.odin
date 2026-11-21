#+build !js

package presentation_host

import "vendor:wgpu"

@(private)
hosted_surface_present_succeeded :: proc(surface: wgpu.Surface) -> bool {
	return wgpu.SurfacePresent(surface) == .Success
}

// hosted_surface_presenter_poll retires finished submissions without waiting.
// A host loop that is blocked inside a platform modal move/resize loop calls
// this from its live frame path so queue completion callbacks still run and the
// presenter's two-frame budget does not stay saturated. wgpu-native's
// DevicePoll dispatches those callbacks on the calling thread; the browser has
// no equivalent entry point (see surface_present_web.odin).
hosted_surface_presenter_poll :: proc(presenter: ^Hosted_Surface_Presenter) {
	state := hosted_surface_state(presenter)
	if state == nil || state.device == nil { return }
	_ = wgpu.DevicePoll(state.device, false)
}
