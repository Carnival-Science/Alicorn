#+build js

package presentation_host

import "vendor:wgpu"

@(private)
hosted_surface_present_succeeded :: proc(surface: wgpu.Surface) -> bool {
	// Browser WebGPU presents the canvas when the queue work is submitted.
	// Odin's wgpu.js bridge implements SurfacePresent as a void no-op even
	// though the generated binding declares a Status return, so its apparent
	// return value is always the invalid enum value zero. Queue completion is
	// checked separately by the asynchronous completion callback.
	_ = wgpu.SurfacePresent(surface)
	return true
}

// hosted_surface_presenter_poll is a no-op on the web target. Browser WebGPU
// has no device-poll entry point: Odin's JS bindings do not declare DevicePoll
// because wgpu-native's wgpuDevicePoll(mode, timeout) is a native-only concept.
// In the browser, queue completion arrives through the event loop and the
// QueueOnSubmittedWorkDone callback registered by the shared presenter, and the
// demand-driven scheduler already drains it. Native host loops that block inside
// a platform modal move/resize loop need the explicit poll; browser hosts do
// not block in a foreign message loop, so keeping the symbol as a no-op is the
// correct parity behavior rather than emulating native poll semantics.
hosted_surface_presenter_poll :: proc(presenter: ^Hosted_Surface_Presenter) {
	_ = presenter
}
