#+build !js

package presentation_host

import "vendor:wgpu"

@(private)
hosted_surface_present_succeeded :: proc(surface: wgpu.Surface) -> bool {
	return wgpu.SurfacePresent(surface) == .Success
}
