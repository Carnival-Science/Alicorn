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
