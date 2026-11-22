package cpu_renderer

import "core:math"
import alicorn "../../runtime"

GPU_SURFACE_MARKER_MASK_SIZE :: 32
GPU_SURFACE_MARKER_MASK_SAMPLES :: 8

// GPU_Surface_Marker_Mask_Alpha returns the same deterministic supersampled
// circle coverage used by the native renderer. Both GPU backends upload this
// mask and draw compact markers as six-vertex quads.
GPU_Surface_Marker_Mask_Alpha :: proc(x, y: int) -> u8 {
	if x < 0 || y < 0 || x >= GPU_SURFACE_MARKER_MASK_SIZE || y >= GPU_SURFACE_MARKER_MASK_SIZE { return 0 }
	inside := 0
	for sample_y in 0..<GPU_SURFACE_MARKER_MASK_SAMPLES {
		local_y := ((f32(y) + (f32(sample_y)+0.5)/f32(GPU_SURFACE_MARKER_MASK_SAMPLES)) /
			f32(GPU_SURFACE_MARKER_MASK_SIZE))*2 - 1
		for sample_x in 0..<GPU_SURFACE_MARKER_MASK_SAMPLES {
			local_x := ((f32(x) + (f32(sample_x)+0.5)/f32(GPU_SURFACE_MARKER_MASK_SAMPLES)) /
				f32(GPU_SURFACE_MARKER_MASK_SIZE))*2 - 1
			if local_x*local_x + local_y*local_y <= 1 { inside += 1 }
		}
	}
	sample_count := GPU_SURFACE_MARKER_MASK_SAMPLES * GPU_SURFACE_MARKER_MASK_SAMPLES
	return cast(u8)(inside * 255 / sample_count)
}

// GPU_Surface_Marker_Mask_RGBA8 fills one tightly packed 32x32 mask texture.
// RGB remains white because sampled color is multiplied by the vertex tint.
GPU_Surface_Marker_Mask_RGBA8 :: proc(pixels: []u8) -> bool {
	expected := GPU_SURFACE_MARKER_MASK_SIZE * GPU_SURFACE_MARKER_MASK_SIZE * 4
	if len(pixels) != expected { return false }
	for y in 0..<GPU_SURFACE_MARKER_MASK_SIZE {
		for x in 0..<GPU_SURFACE_MARKER_MASK_SIZE {
			index := (y*GPU_SURFACE_MARKER_MASK_SIZE+x)*4
			pixels[index+0] = 255
			pixels[index+1] = 255
			pixels[index+2] = 255
			pixels[index+3] = GPU_Surface_Marker_Mask_Alpha(x, y)
		}
	}
	return true
}

GPU_Surface_Vertex_Count :: proc(payload: alicorn.GPU_Surface_Payload_View) -> int {
	geometry_vertices := len(payload.rectangles)*alicorn.GPU_SURFACE_RECTANGLE_VERTICES +
		len(payload.segments)*6 +
		len(payload.circles)*alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3 +
		len(payload.point_markers)*alicorn.GPU_SURFACE_POINT_MARKER_VERTICES
	stroke_vertices := alicorn.GPU_Surface_Stroke_Path_Vertex_Count(len(payload.stroke_path.points))
	if stroke_vertices < 0 || geometry_vertices > alicorn.GPU_SURFACE_MAX_VERTICES-stroke_vertices { return -1 }
	geometry_vertices += stroke_vertices
	waveform_vertices := 0
	if len(payload.samples) > 1 {
		waveform_vertices = (len(payload.samples)-1)*6
	}
	if geometry_vertices > alicorn.GPU_SURFACE_MAX_VERTICES-waveform_vertices { return -1 }
	return geometry_vertices+waveform_vertices
}

GPU_Surface_Append_Segment :: proc(
	vertices: ^[dynamic]Vertex,
	ax, ay, bx, by, scale_x, scale_y, thickness: f32,
	color: [4]f32,
) -> bool {
	dx := bx-ax
	dy := by-ay
	length := math.sqrt(dx*dx+dy*dy)
	if length <= 0.001 { return true }
	if len(vertices^) + 6 > alicorn.GPU_SURFACE_MAX_VERTICES { return false }
	half := thickness*0.5
	nx := -dy/length*half
	ny := dx/length*half
	append(vertices,
		Vertex{[3]f32{(ax-nx)*scale_x, (ay-ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		Vertex{[3]f32{(bx-nx)*scale_x, (by-ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		Vertex{[3]f32{(bx+nx)*scale_x, (by+ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		Vertex{[3]f32{(ax-nx)*scale_x, (ay-ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		Vertex{[3]f32{(bx+nx)*scale_x, (by+ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		Vertex{[3]f32{(ax+nx)*scale_x, (ay+ny)*scale_y, 0}, color, [2]f32{0.5, 0.5}},
	)
	return true
}

// GPU_Surface_Append_Stroke_Path tessellates one connected open stroke. Each
// vertex uses a shared bounded-miter cross-section, preventing the pinholes
// left by independently expanded segment quads. Transparent side fringes and
// butt-cap fringes provide deterministic antialiasing on both GPU backends.
GPU_Surface_Append_Stroke_Path :: proc(
	vertices: ^[dynamic]Vertex,
	bounds: alicorn.Rect,
	scale_x, scale_y: f32,
	path: alicorn.GPU_Surface_Stroke_Path,
	opacity: f32 = 1,
) -> bool {
	point_count := len(path.points)
	vertex_count := alicorn.GPU_Surface_Stroke_Path_Vertex_Count(point_count)
	if vertex_count == 0 { return true }
	if vertex_count < 0 || len(vertices^) > alicorn.GPU_SURFACE_MAX_VERTICES-vertex_count { return false }

	pixel_points := make([][2]f32, point_count, allocator=context.temp_allocator)
	directions := make([][2]f32, point_count-1, allocator=context.temp_allocator)
	normals := make([][2]f32, point_count-1, allocator=context.temp_allocator)
	left := make([][2]f32, point_count, allocator=context.temp_allocator)
	right := make([][2]f32, point_count, allocator=context.temp_allocator)
	left_outer := make([][2]f32, point_count, allocator=context.temp_allocator)
	right_outer := make([][2]f32, point_count, allocator=context.temp_allocator)
	defer delete(pixel_points)
	defer delete(directions)
	defer delete(normals)
	defer delete(left)
	defer delete(right)
	defer delete(left_outer)
	defer delete(right_outer)

	for index in 0..<point_count {
		point := path.points[index]
		pixel_points[index] = {(bounds.x+point.x)*scale_x, (bounds.y+point.y)*scale_y}
	}
	for index in 0..<point_count-1 {
		a, b := pixel_points[index], pixel_points[index+1]
		dx, dy := b[0]-a[0], b[1]-a[1]
		length := math.sqrt(dx*dx+dy*dy)
		if length <= 0.001 { return false }
		directions[index] = {dx/length, dy/length}
		normals[index] = {-dy/length, dx/length}
	}

	half := path.thickness*max(scale_x, scale_y)*0.5
	fringe := f32(VECTOR_ANTIALIAS_FRINGE)
	for index in 0..<point_count {
		offset: [2]f32
		if index == 0 {
			offset = {normals[0][0]*half, normals[0][1]*half}
		} else if index == point_count-1 {
			normal := normals[index-1]
			offset = {normal[0]*half, normal[1]*half}
		} else {
			previous_normal, next_normal := normals[index-1], normals[index]
			bisector := [2]f32{previous_normal[0]+next_normal[0], previous_normal[1]+next_normal[1]}
			bisector_length := math.sqrt(bisector[0]*bisector[0]+bisector[1]*bisector[1])
			if bisector_length <= 0.001 {
				offset = {next_normal[0]*half, next_normal[1]*half}
			} else {
				bisector[0] /= bisector_length
				bisector[1] /= bisector_length
				projection := bisector[0]*next_normal[0]+bisector[1]*next_normal[1]
				if projection < 0.25 { projection = 0.25 }
				miter_length := min(half/projection, half*4)
				offset = {bisector[0]*miter_length, bisector[1]*miter_length}
			}
		}
		left[index] = {pixel_points[index][0]+offset[0], pixel_points[index][1]+offset[1]}
		right[index] = {pixel_points[index][0]-offset[0], pixel_points[index][1]-offset[1]}
		offset_length := math.sqrt(offset[0]*offset[0]+offset[1]*offset[1])
		if offset_length <= 0.001 { return false }
		fringe_x, fringe_y := offset[0]/offset_length*fringe, offset[1]/offset_length*fringe
		left_outer[index] = {left[index][0]+fringe_x, left[index][1]+fringe_y}
		right_outer[index] = {right[index][0]-fringe_x, right[index][1]-fringe_y}
	}

	color := [4]f32{path.color.r, path.color.g, path.color.b, path.color.a*opacity}
	transparent := color
	transparent[3] = 0
	for index in 0..<point_count-1 {
		p0, p1 := left[index], left[index+1]
		q0, q1 := right[index], right[index+1]
		append_triangle(vertices, p0, q0, q1, color, color, color)
		append_triangle(vertices, p0, q1, p1, color, color, color)
		append_triangle(vertices, p0, p1, left_outer[index+1], color, color, transparent)
		append_triangle(vertices, p0, left_outer[index+1], left_outer[index], color, transparent, transparent)
		append_triangle(vertices, q0, right_outer[index+1], q1, color, transparent, color)
		append_triangle(vertices, q0, right_outer[index], right_outer[index+1], color, transparent, transparent)
	}

	first_direction := directions[0]
	start_left := [2]f32{left[0][0]-first_direction[0]*fringe, left[0][1]-first_direction[1]*fringe}
	start_right := [2]f32{right[0][0]-first_direction[0]*fringe, right[0][1]-first_direction[1]*fringe}
	append_triangle(vertices, left[0], right[0], start_right, color, color, transparent)
	append_triangle(vertices, left[0], start_right, start_left, color, transparent, transparent)

	last := point_count-1
	last_direction := directions[point_count-2]
	end_left := [2]f32{left[last][0]+last_direction[0]*fringe, left[last][1]+last_direction[1]*fringe}
	end_right := [2]f32{right[last][0]+last_direction[0]*fringe, right[last][1]+last_direction[1]*fringe}
	append_triangle(vertices, left[last], end_right, right[last], color, transparent, color)
	append_triangle(vertices, left[last], end_left, end_right, color, transparent, transparent)
	return true
}

GPU_Surface_Append_Circle :: proc(
	vertices: ^[dynamic]Vertex,
	cx, cy, scale_x, scale_y, radius: f32,
	color: [4]f32,
) -> bool {
	vertex_count := alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3
	if len(vertices^) + vertex_count > alicorn.GPU_SURFACE_MAX_VERTICES { return false }
	for i in 0..<alicorn.GPU_SURFACE_CIRCLE_SEGMENTS {
		a0 := f32(i)*6.283185307179586/f32(alicorn.GPU_SURFACE_CIRCLE_SEGMENTS)
		a1 := f32(i+1)*6.283185307179586/f32(alicorn.GPU_SURFACE_CIRCLE_SEGMENTS)
		x0 := cx+math.cos(a0)*radius
		y0 := cy+math.sin(a0)*radius
		x1 := cx+math.cos(a1)*radius
		y1 := cy+math.sin(a1)*radius
		append(vertices,
			Vertex{[3]f32{cx*scale_x, cy*scale_y, 0}, color, [2]f32{0.5, 0.5}},
			Vertex{[3]f32{x0*scale_x, y0*scale_y, 0}, color, [2]f32{0.5, 0.5}},
			Vertex{[3]f32{x1*scale_x, y1*scale_y, 0}, color, [2]f32{0.5, 0.5}},
		)
	}
	return true
}

GPU_Surface_Append_Rectangle :: proc(
	vertices: ^[dynamic]Vertex,
	x, y, width, height, scale_x, scale_y: f32,
	color: [4]f32,
) -> bool {
	if len(vertices^) + alicorn.GPU_SURFACE_RECTANGLE_VERTICES > alicorn.GPU_SURFACE_MAX_VERTICES { return false }
	x0, y0 := x*scale_x, y*scale_y
	x1, y1 := (x+width)*scale_x, (y+height)*scale_y
	Append_Quad(vertices, x0, y0, x1, y1, color)
	return true
}

GPU_Surface_Append_Point_Marker :: proc(
	vertices: ^[dynamic]Vertex,
	cx, cy, scale_x, scale_y, diameter: f32,
	color: [4]f32,
) -> bool {
	if len(vertices^) + alicorn.GPU_SURFACE_POINT_MARKER_VERTICES > alicorn.GPU_SURFACE_MAX_VERTICES { return false }
	half := diameter*0.5
	x0, y0 := (cx-half)*scale_x, (cy-half)*scale_y
	x1, y1 := (cx+half)*scale_x, (cy+half)*scale_y
	append(vertices,
		Vertex{[3]f32{x0, y0, 0}, color, [2]f32{0, 0}},
		Vertex{[3]f32{x1, y0, 0}, color, [2]f32{1, 0}},
		Vertex{[3]f32{x1, y1, 0}, color, [2]f32{1, 1}},
		Vertex{[3]f32{x0, y0, 0}, color, [2]f32{0, 0}},
		Vertex{[3]f32{x1, y1, 0}, color, [2]f32{1, 1}},
		Vertex{[3]f32{x0, y1, 0}, color, [2]f32{0, 1}},
	)
	return true
}

GPU_Surface_Append_Primitives :: proc(
	vertices: ^[dynamic]Vertex,
	bounds: alicorn.Rect,
	scale_x, scale_y: f32,
	rectangles: []alicorn.GPU_Surface_Filled_Rectangle,
	segments: []alicorn.GPU_Surface_Line_Segment,
	circles: []alicorn.GPU_Surface_Filled_Circle,
	point_markers: []alicorn.GPU_Surface_Point_Marker,
	opacity: f32 = 1,
	stroke_path: alicorn.GPU_Surface_Stroke_Path = {},
) -> bool {
	for rectangle in rectangles {
		color := [4]f32{rectangle.color.r, rectangle.color.g, rectangle.color.b, rectangle.color.a*opacity}
		if !GPU_Surface_Append_Rectangle(vertices,
			bounds.x+rectangle.bounds.x, bounds.y+rectangle.bounds.y,
			rectangle.bounds.w, rectangle.bounds.h, scale_x, scale_y, color,
		) { return false }
	}
	for segment in segments {
		color := [4]f32{segment.color.r, segment.color.g, segment.color.b, segment.color.a*opacity}
		if !GPU_Surface_Append_Segment(vertices,
			bounds.x+segment.start.x, bounds.y+segment.start.y,
			bounds.x+segment.end.x, bounds.y+segment.end.y,
			scale_x, scale_y, segment.thickness, color,
		) { return false }
	}
	if !GPU_Surface_Append_Stroke_Path(vertices, bounds, scale_x, scale_y, stroke_path, opacity) { return false }
	for circle in circles {
		color := [4]f32{circle.color.r, circle.color.g, circle.color.b, circle.color.a*opacity}
		if !GPU_Surface_Append_Circle(vertices,
			bounds.x+circle.center.x, bounds.y+circle.center.y,
			scale_x, scale_y, circle.radius, color,
		) { return false }
	}
	for marker in point_markers {
		color := [4]f32{marker.color.r, marker.color.g, marker.color.b, marker.color.a*opacity}
		if !GPU_Surface_Append_Point_Marker(vertices,
			bounds.x+marker.center.x, bounds.y+marker.center.y,
			scale_x, scale_y, marker.diameter, color,
		) { return false }
	}
	return true
}

// GPU_Surface_Append_Payload converts explicit retained geometry and waveform
// samples into physical-pixel vertices. Explicit primitives precede waveform
// segments, matching the historical native renderer's paint order.
GPU_Surface_Append_Payload :: proc(
	vertices: ^[dynamic]Vertex,
	command: alicorn.Paint_Command,
	payload: alicorn.GPU_Surface_Payload_View,
	scale_x, scale_y: f32,
) -> bool {
	bounds := command.bounds
	bounds.x += command.translation[0]
	bounds.y += command.translation[1]
	if len(payload.rectangles) > 0 || len(payload.segments) > 0 || len(payload.stroke_path.points) > 1 || len(payload.circles) > 0 || len(payload.point_markers) > 0 {
		if !GPU_Surface_Append_Primitives(
			vertices, bounds, scale_x, scale_y,
			payload.rectangles, payload.segments, payload.circles, payload.point_markers,
			command.opacity, payload.stroke_path,
		) { return false }
	}
	if len(payload.samples) <= 1 { return true }
	line_color := [4]f32{0.30, 0.88, 0.96, command.opacity}
	for i in 0..<len(payload.samples)-1 {
		a, b := payload.samples[i], payload.samples[i+1]
		if a < 0 { a = 0 }; if a > 1 { a = 1 }
		if b < 0 { b = 0 }; if b > 1 { b = 1 }
		x0 := bounds.x+bounds.w*f32(i)/f32(len(payload.samples)-1)
		x1 := bounds.x+bounds.w*f32(i+1)/f32(len(payload.samples)-1)
		y0 := bounds.y+bounds.h*(1-a)
		y1 := bounds.y+bounds.h*(1-b)
		if !GPU_Surface_Append_Segment(vertices, x0, y0, x1, y1, scale_x, scale_y, 2, line_color) { return false }
	}
	return true
}
