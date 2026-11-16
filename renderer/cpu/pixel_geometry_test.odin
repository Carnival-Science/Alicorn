#+build !js
package cpu_renderer

import "core:testing"

@(test)
test_pixel_rect_translate_clip_localizes_and_bounds_capture_scissor :: proc(t: ^testing.T) {
	localized := Pixel_Rect_Translate_Clip(Pixel_Rect{6, 5, 10, 8}, 4, 3, 8, 8)
	testing.expect(t, localized == Pixel_Rect{2, 2, 6, 6},
		"capture scissor should shift by its physical origin and clamp to the cropped target")
	clipped := Pixel_Rect_Translate_Clip(Pixel_Rect{0, 0, 3, 2}, 4, 3, 8, 8)
	testing.expect(t, clipped == Pixel_Rect{}, "scissors outside the cropped target should become empty")
	negative := Pixel_Rect_Translate_Clip(Pixel_Rect{2, 1, 9, 8}, 4, 3, 8, 8)
	testing.expect(t, negative == Pixel_Rect{0, 0, 7, 6},
		"partially intersecting scissors should clamp both negative edges")
}
