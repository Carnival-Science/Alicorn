package cpu_renderer

import "core:math"
import alicorn "../../runtime"

Pixel_Edge :: proc(logical_edge, scale: f32) -> int {
	pixel := logical_edge*scale
	// Alicorn finalizes shared absolute edges to the nearest device pixel.
	// Repeat that rounding here instead of truncating a float round-trip that
	// can land just below its intended integer edge.
	if pixel < 0 { return -int(math.floor(-pixel+0.5)) }
	return int(math.floor(pixel+0.5))
}

Logical_To_Pixel_Bounds :: proc(bounds: alicorn.Rect, scale_x, scale_y: f32) -> (x0, y0, x1, y1: int) {
	x0 = Pixel_Edge(bounds.x, scale_x)
	y0 = Pixel_Edge(bounds.y, scale_y)
	x1 = Pixel_Edge(bounds.x+bounds.w, scale_x)
	y1 = Pixel_Edge(bounds.y+bounds.h, scale_y)
	return
}

// Pixel_Rect_Translate_Clip moves a physical-pixel scissor into a cropped
// target's local origin and clips it to that target. Widened arithmetic keeps
// bounded large coordinates safe before the final integer conversion.
Pixel_Rect_Translate_Clip :: proc(
	rect: Pixel_Rect,
	origin_x, origin_y, target_width, target_height: int,
) -> Pixel_Rect {
	if rect.w <= 0 || rect.h <= 0 || target_width <= 0 || target_height <= 0 { return {} }
	left := max(i64(rect.x)-i64(origin_x), 0)
	top := max(i64(rect.y)-i64(origin_y), 0)
	right := min(i64(rect.x)+i64(rect.w)-i64(origin_x), i64(target_width))
	bottom := min(i64(rect.y)+i64(rect.h)-i64(origin_y), i64(target_height))
	if right <= left || bottom <= top { return {} }
	return Pixel_Rect{int(left), int(top), int(right-left), int(bottom-top)}
}
