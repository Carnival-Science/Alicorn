package presentation_host

import "vendor:wgpu"

// hosted_presentation_format selects the swapchain format for the hosted WebGPU
// stack from an adapter's surface capabilities.
//
// Alicorn theme values and paint colors are linear-sRGB channels uploaded
// unchanged (see docs/themes.md, "Color and length runtime contract"), and the
// SDL_GPU reference host presents them through a non-sRGB (UNORM) swapchain.
// Configuring an sRGB-encoded WebGPU target applies a second transfer function
// and lightens every hosted color relative to that reference. That difference is
// global - backgrounds, surfaces, and per-glyph syntax paint-span colors - so it
// is an application-parity regression rather than a color-management choice.
//
// This host therefore prefers a non-sRGB BGRA/RGBA format and falls back to the
// sRGB variant only when the adapter offers nothing else. Adopting real sRGB
// output is a deliberate contract change that must land on both hosts together.
hosted_presentation_format :: proc(formats: []wgpu.TextureFormat) -> (format: wgpu.TextureFormat, ok: bool) {
	if len(formats) == 0 { return {}, false }
	fallback: wgpu.TextureFormat
	have_fallback := false
	for candidate in formats {
		#partial switch candidate {
		case .BGRA8Unorm, .RGBA8Unorm:
			return candidate, true
		case .BGRA8UnormSrgb, .RGBA8UnormSrgb:
			if !have_fallback {
				fallback = candidate
				have_fallback = true
			}
		case:
		}
	}
	if have_fallback { return fallback, true }
	return formats[0], true
}
