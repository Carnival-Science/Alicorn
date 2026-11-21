#+build !js

package presentation_host

import "core:testing"
import "vendor:wgpu"

@(test)
test_hosted_presentation_format_matches_the_sdl_gpu_transfer_contract :: proc(t: ^testing.T) {
	// The SDL_GPU reference presents linear theme channels through a UNORM
	// swapchain. An sRGB target would apply a second transfer function and
	// lighten every hosted color, including per-glyph syntax paint spans.
	both := []wgpu.TextureFormat{.BGRA8UnormSrgb, .BGRA8Unorm}
	format, ok := hosted_presentation_format(both)
	testing.expect(t, ok && format == .BGRA8Unorm,
		"the hosted stack must prefer the non-sRGB format when the adapter offers it")

	rgba := []wgpu.TextureFormat{.RGBA8UnormSrgb, .RGBA8Unorm}
	format, ok = hosted_presentation_format(rgba)
	testing.expect(t, ok && format == .RGBA8Unorm,
		"RGBA capability sets must resolve to their non-sRGB format too")

	srgb_only := []wgpu.TextureFormat{.BGRA8UnormSrgb}
	format, ok = hosted_presentation_format(srgb_only)
	testing.expect(t, ok && format == .BGRA8UnormSrgb,
		"an sRGB-only adapter must still configure a usable surface")

	other := []wgpu.TextureFormat{.RGBA16Float}
	format, ok = hosted_presentation_format(other)
	testing.expect(t, ok && format == .RGBA16Float,
		"unknown capability lists must fall back to the adapter's first format")

	format, ok = hosted_presentation_format(nil)
	testing.expect(t, !ok, "an empty capability list cannot select a format")
}
