package alicorn_sdl_gpu

// Shared loader and coverage comparison for wxWidgets reference captures.
// `tools/wx_reference.ps1` builds `tools/wx_reference/main.cpp` against the
// installed wxWidgets and writes one raw RGB24 capture plus a `.meta` header
// for each `.scene` the validation executables emit. The scene is the single
// definition of geometry both renderers consume.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

Wx_Reference :: struct {
	width:  int,
	height: int,
	scale:  f32,
	bg:     [3]u8,
	rgb:    []u8,
	path:   string,
}

wx_reference_pixel :: proc(reference: ^Wx_Reference, x, y: int) -> [3]u8 {
	if reference == nil || x < 0 || y < 0 || x >= reference.width || y >= reference.height { return {} }
	index := (y*reference.width+x)*3
	if index+2 >= len(reference.rgb) { return {} }
	return {reference.rgb[index+0], reference.rgb[index+1], reference.rgb[index+2]}
}

wx_reference_luminance :: proc(reference: ^Wx_Reference, x, y: int) -> f32 {
	pixel := wx_reference_pixel(reference, x, y)
	return f32(int(pixel[0])+int(pixel[1])+int(pixel[2]))/3
}

// wx_reference_load reads `<dir>/<stem>.meta` and `<dir>/<stem>.rgb`. A missing
// capture is not an error: callers report that the wx comparison was skipped.
wx_reference_load :: proc(dir, stem: string) -> (reference: Wx_Reference, ok: bool) {
	meta_path := fmt.tprintf("%s/%s.meta", dir, stem)
	meta, meta_err := os.read_entire_file(meta_path, context.temp_allocator)
	if meta_err != nil { return {}, false }
	lines := strings.split(string(meta), "\n", context.temp_allocator)
	if len(lines) < 2 { return {}, false }
	header := strings.split(lines[0], " ", context.temp_allocator)
	// wx_reference 1 <version> <logical_w> <logical_h> <scale> <px_w> <px_h>
	if len(header) < 8 || header[0] != "wx_reference" { return {}, false }
	logical_w, _ := strconv.parse_int(header[3])
	logical_h, _ := strconv.parse_int(header[4])
	scale_value, _ := strconv.parse_f32(header[5])
	px_w, _ := strconv.parse_int(header[6])
	px_h, _ := strconv.parse_int(header[7])
	payload := strings.split(lines[1], " ", context.temp_allocator)
	if len(payload) < 5 { return {}, false }
	bg_r, _ := strconv.parse_int(payload[0])
	bg_g, _ := strconv.parse_int(payload[1])
	bg_b, _ := strconv.parse_int(payload[2])
	_ = logical_w
	_ = logical_h
	reference = Wx_Reference{
		width=px_w, height=px_h, scale=scale_value,
		bg={u8(bg_r), u8(bg_g), u8(bg_b)},
		path=meta_path,
	}
	capture_path := payload[3]
	capture, capture_err := os.read_entire_file(capture_path, context.temp_allocator)
	if capture_err != nil || len(capture) != px_w*px_h*3 { return {}, false }
	reference.rgb = capture
	return reference, true
}

// wx_reference_coverage normalizes one sampled pixel against the capture's own
// background and full-white ink. It deliberately ignores channel order so a
// BGRA native readback compares against RGB wx data without guessing swizzles.
wx_reference_coverage_of :: proc(r, g, b: int, background: f32) -> f32 {
	value := (f32(r)+f32(g)+f32(b))/3
	span := 255-background
	if span <= 0.001 { return 0 }
	coverage := (value-background)/span
	if coverage < 0 { return 0 }
	if coverage > 1 { return 1 }
	return coverage
}

Wx_Anchor_Metrics :: struct {
	compared_pixels: int,
	wx_area:         f32,
	gpu_area:        f32,
	area_ratio:      f32,
	wx_centroid_x:   f32,
	wx_centroid_y:   f32,
	gpu_centroid_x:  f32,
	gpu_centroid_y:  f32,
	centroid_delta:  f32,
	mean_delta:      f32,
	max_delta:       f32,
	wx_antialiased:  int,
	gpu_antialiased: int,
	wx_covered:      int,
	gpu_covered:     int,
}

wx_anchor_metrics :: proc(
	reference: ^Wx_Reference,
	pixels: []u8,
	pixel_width, pixel_height: int,
	gpu_background: f32,
	center_x, center_y, radius: f32,
) -> (metrics: Wx_Anchor_Metrics, ok: bool) {
	x0 := max(0, int(math.floor(center_x-radius-2)))
	x1 := min(pixel_width, int(math.ceil(center_x+radius+2)))
	y0 := max(0, int(math.floor(center_y-radius-2)))
	y1 := min(pixel_height, int(math.ceil(center_y+radius+2)))
	if x1 <= x0 || y1 <= y0 { return {}, false }
	wx_weight, gpu_weight := f32(0), f32(0)
	wx_x, wx_y, gpu_x, gpu_y := f32(0), f32(0), f32(0), f32(0)
	for y in y0..<y1 {
		for x in x0..<x1 {
			wx_coverage := wx_reference_coverage_of(int(wx_reference_pixel(reference, x, y)[0]),
				int(wx_reference_pixel(reference, x, y)[1]), int(wx_reference_pixel(reference, x, y)[2]),
				f32(int(reference.bg[0])+int(reference.bg[1])+int(reference.bg[2]))/3)
			index := (y*pixel_width+x)*4
			gpu_coverage := wx_reference_coverage_of(int(pixels[index+0]), int(pixels[index+1]),
				int(pixels[index+2]), gpu_background)
			wx_weight += wx_coverage
			gpu_weight += gpu_coverage
			wx_x += wx_coverage*f32(x)+0.5*wx_coverage
			wx_y += wx_coverage*f32(y)+0.5*wx_coverage
			gpu_x += gpu_coverage*f32(x)+0.5*gpu_coverage
			gpu_y += gpu_coverage*f32(y)+0.5*gpu_coverage
			delta := abs(wx_coverage-gpu_coverage)
			metrics.mean_delta += delta
			metrics.max_delta = max(metrics.max_delta, delta)
			metrics.compared_pixels += 1
			if wx_coverage > 0.15 { metrics.wx_covered += 1 }
			if gpu_coverage > 0.15 { metrics.gpu_covered += 1 }
			if wx_coverage > 0.02 && wx_coverage < 0.98 { metrics.wx_antialiased += 1 }
			if gpu_coverage > 0.02 && gpu_coverage < 0.98 { metrics.gpu_antialiased += 1 }
		}
	}
	if metrics.compared_pixels > 0 { metrics.mean_delta /= f32(metrics.compared_pixels) }
	if wx_weight > 0.001 { metrics.wx_centroid_x = wx_x/wx_weight; metrics.wx_centroid_y = wx_y/wx_weight }
	if gpu_weight > 0.001 { metrics.gpu_centroid_x = gpu_x/gpu_weight; metrics.gpu_centroid_y = gpu_y/gpu_weight }
	metrics.wx_area = wx_weight
	metrics.gpu_area = gpu_weight
	if wx_weight > 0.001 { metrics.area_ratio = gpu_weight/wx_weight }
	metrics.centroid_delta = math.sqrt(
		(metrics.wx_centroid_x-metrics.gpu_centroid_x)*(metrics.wx_centroid_x-metrics.gpu_centroid_x)+
		(metrics.wx_centroid_y-metrics.gpu_centroid_y)*(metrics.wx_centroid_y-metrics.gpu_centroid_y),
	)
	return metrics, metrics.compared_pixels > 0
}

// wx_reference_scene_ellipse appends one `ellipse` primitive in wxRect terms.
// Callers express marker geometry exactly as Audacity's WaveformView does, so
// the wx capture cannot drift from the native payload.
wx_reference_scene_ellipse :: proc(builder: ^strings.Builder, x, y, w, h: int, color: [3]u8) {
	fmt.sbprintf(builder, "ellipse %d %d %d %d %d %d %d\n", x, y, w, h, color[0], color[1], color[2])
}

wx_reference_scene_rect :: proc(builder: ^strings.Builder, x, y, w, h: f32, color: [4]f32) {
	fmt.sbprintf(builder, "rect %.3f %.3f %.3f %.3f %d %d %d %d\n", x, y, w, h,
		int(math.round(color[0]*255)), int(math.round(color[1]*255)), int(math.round(color[2]*255)),
		int(math.round(color[3]*255)))
}

wx_reference_scene_header :: proc(builder: ^strings.Builder, width, height: int, scale: f32, background: [3]u8) {
	fmt.sbprintf(builder, "scene 1\nsize %d %d\nscale %.6f\nbg %d %d %d\n",
		width, height, scale, background[0], background[1], background[2])
}

wx_reference_scene_write :: proc(dir, stem, content: string) -> bool {
	path := fmt.tprintf("%s/%s.scene", dir, stem)
	err := os.write_entire_file(path, transmute([]u8)content)
	return err == nil
}
