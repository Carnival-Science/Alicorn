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
