package diagnostics

import alicorn "alicorn:runtime"

// emit_bounds outlines every visible display command with four thin edges.
// Geometry is host inspection data: it is never retained in Alicorn and
// disappears when the diagnostic mode is disabled. scale_x/scale_y map the
// command's logical units into the target's paint units; target_width/height
// clip the outline so a command translated off-screen draws nothing.
emit_bounds :: proc(
	target: Quad_Target,
	display: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	target_width, target_height: int,
) {
	if target.emit == nil || target_width <= 0 || target_height <= 0 { return }
	color := [4]f32{1.0, 0.78, 0.16, 0.72}
	target_w := f32(target_width)
	target_h := f32(target_height)
	for draw in display {
		left := (draw.bounds.x+draw.translation[0])*scale_x
		top := (draw.bounds.y+draw.translation[1])*scale_y
		right := (draw.bounds.x+draw.bounds.w+draw.translation[0])*scale_x
		bottom := (draw.bounds.y+draw.bounds.h+draw.translation[1])*scale_y
		if left < 0 { left = 0 }
		if top < 0 { top = 0 }
		if right > target_w { right = target_w }
		if bottom > target_h { bottom = target_h }
		if right <= left || bottom <= top { continue }
		thickness := f32(1)
		if scale_x > thickness { thickness = scale_x }
		if scale_y > thickness { thickness = scale_y }
		if !quad_target_begin(target) { continue }
		quad_target_emit(target, Quad{left, top, right-left, min(top+thickness, bottom)-top, color})
		quad_target_emit(target, Quad{left, max(bottom-thickness, top), right-left, bottom-max(bottom-thickness, top), color})
		quad_target_emit(target, Quad{left, top, min(left+thickness, right)-left, bottom-top, color})
		quad_target_emit(target, Quad{max(right-thickness, left), top, right-max(right-thickness, left), bottom-top, color})
		quad_target_end(target)
	}
}
