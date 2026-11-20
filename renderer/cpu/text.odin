package cpu_renderer

import "core:math"
import alicorn "../../runtime"

TEXT_SUBPIXEL_BUCKETS :: 4

Vertex_Color :: proc(color: alicorn.Color, opacity: f32, color_glyph: bool) -> [4]f32 {
	if color_glyph {
		return [4]f32{1, 1, 1, color.a*opacity}
	}
	return [4]f32{color.r, color.g, color.b, color.a*opacity}
}

Hash_Rect :: proc(h: u64, rect: alicorn.Rect) -> u64 {
	result := h
	result = alicorn.hash_mix(result, u64(transmute(u32)rect.x))
	result = alicorn.hash_mix(result, u64(transmute(u32)rect.y))
	result = alicorn.hash_mix(result, u64(transmute(u32)rect.w))
	result = alicorn.hash_mix(result, u64(transmute(u32)rect.h))
	return result
}

Hash_Color :: proc(h: u64, color: alicorn.Color) -> u64 {
	result := h
	result = alicorn.hash_mix(result, u64(transmute(u32)color.r))
	result = alicorn.hash_mix(result, u64(transmute(u32)color.g))
	result = alicorn.hash_mix(result, u64(transmute(u32)color.b))
	result = alicorn.hash_mix(result, u64(transmute(u32)color.a))
	return result
}

Hash_Text_Spans :: proc(h: u64, spans: []alicorn.Text_Paint_Span) -> u64 {
	color_count: u64 = 0
	for span in spans { if span.color_set { color_count += 1 } }
	result := alicorn.hash_mix(h, color_count)
	for span in spans {
		if !span.color_set { continue }
		result = alicorn.hash_mix(result, u64(span.start))
		result = alicorn.hash_mix(result, u64(span.end))
		result = Hash_Color(result, span.color)
	}
	return result
}

Text_Span_Strategy :: enum {
	None,
	Single,
	Sorted_Non_Overlapping,
	Segment_Tree,
}

// Most syntax projections are a sorted, non-overlapping list. Keep those out
// of the byte-sized winner map below; the painter can resolve their colors
// directly from shaped cluster ranges. Preserve the span-array ordering as
// the precedence rule for every overlapping/unsorted case.
Span_Strategy :: proc(text_length: int, spans: []alicorn.Text_Paint_Span) -> (strategy: Text_Span_Strategy, single_index: int, starts_sorted: bool) {
	color_count := 0
	previous_color_start := -1
	previous_color_end := -1
	color_spans_sorted := true
	previous_start := -1
	starts_sorted = true
	single_index = -1
	for span, index in spans {
		start := clamp(span.start, 0, text_length)
		end := clamp(span.end, 0, text_length)
		if start < previous_start { starts_sorted = false }
		previous_start = start
		if !span.color_set || start >= end { continue }
		if start < previous_color_start || start < previous_color_end { color_spans_sorted = false }
		previous_color_start = start
		previous_color_end = max(previous_color_end, end)
		color_count += 1
		single_index = index
	}
	if color_count == 0 { return .None, -1, starts_sorted }
	if color_count == 1 { return .Single, single_index, starts_sorted }
	if color_spans_sorted { return .Sorted_Non_Overlapping, -1, starts_sorted }
	return .Segment_Tree, -1, starts_sorted
}

// Produce the last matching span index for each UTF-8 byte. This allocation-
// heavy path is reserved for genuinely overlapping or unsorted spans; a
// max-index segment tree preserves last-span-wins semantics in that case.
Span_Winners :: proc(text: string, spans: []alicorn.Text_Paint_Span, scratch_allocator := context.temp_allocator) -> []int {
	if len(text) == 0 || len(spans) == 0 { return nil }
	has_color := false
	for span in spans { if span.color_set { has_color = true; break } }
	if !has_color { return nil }
	byte_count := len(text)
	start_head := make([]int, byte_count+1, allocator=scratch_allocator)
	end_head := make([]int, byte_count+1, allocator=scratch_allocator)
	start_next := make([]int, len(spans), allocator=scratch_allocator)
	end_next := make([]int, len(spans), allocator=scratch_allocator)
	for i in 0..=byte_count { start_head[i], end_head[i] = -1, -1 }
	for i in 0..<len(spans) {
		start_next[i], end_next[i] = -1, -1
		start := clamp(spans[i].start, 0, byte_count)
		end := clamp(spans[i].end, 0, byte_count)
		if !spans[i].color_set || start >= end { continue }
		start_next[i] = start_head[start]
		start_head[start] = i
		end_next[i] = end_head[end]
		end_head[end] = i
	}
	leaf_count := 1
	for leaf_count < len(spans) { leaf_count *= 2 }
	tree := make([]int, leaf_count*2, allocator=scratch_allocator)
	for i in 0..<len(tree) { tree[i] = -1 }
	winners := make([]int, byte_count, allocator=scratch_allocator)
	for byte in 0..<byte_count {
		for index := end_head[byte]; index >= 0; index = end_next[index] {
			pos := leaf_count + index
			tree[pos] = -1
			for pos /= 2; pos > 0; pos /= 2 { tree[pos] = max(tree[pos*2], tree[pos*2+1]) }
		}
		for index := start_head[byte]; index >= 0; index = start_next[index] {
			pos := leaf_count + index
			tree[pos] = index
			for pos /= 2; pos > 0; pos /= 2 { tree[pos] = max(tree[pos*2], tree[pos*2+1]) }
		}
		winners[byte] = tree[1]
	}
	delete(start_head, scratch_allocator)
	delete(end_head, scratch_allocator)
	delete(start_next, scratch_allocator)
	delete(end_next, scratch_allocator)
	delete(tree, scratch_allocator)
	return winners
}

Color_For_Cluster :: proc(spans: []alicorn.Text_Paint_Span, winners: []int, cluster_start, cluster_end: int, fallback: alicorn.Color) -> alicorn.Color {
	winning_index := -1
	start := clamp(cluster_start, 0, len(winners))
	end := clamp(cluster_end, 0, len(winners))
	for byte in start..<end { winning_index = max(winning_index, winners[byte]) }
	if winning_index >= 0 && winning_index < len(spans) && spans[winning_index].color_set { return spans[winning_index].color }
	return fallback
}

Color_For_Single_Span :: proc(text_length: int, spans: []alicorn.Text_Paint_Span, span_index: int, cluster_start, cluster_end: int, fallback: alicorn.Color) -> alicorn.Color {
	if span_index < 0 || span_index >= len(spans) { return fallback }
	span := spans[span_index]
	if !span.color_set { return fallback }
	start := clamp(cluster_start, 0, text_length)
	end := clamp(cluster_end, 0, text_length)
	span_start := clamp(span.start, 0, text_length)
	span_end := clamp(span.end, 0, text_length)
	if start < span_end && span_start < end { return span.color }
	return fallback
}

// Resolve an ordered source cluster against sorted, disjoint spans. The cursor
// only moves forward when shaped clusters are also source-ordered; bidi runs
// that violate that condition use the general winner map instead.
Color_For_Sorted_Cluster :: proc(
	text_length: int,
	spans: []alicorn.Text_Paint_Span,
	cursor: ^int,
	cluster_start, cluster_end: int,
	fallback: alicorn.Color,
) -> alicorn.Color {
	start := clamp(cluster_start, 0, text_length)
	end := clamp(cluster_end, 0, text_length)
	if start >= end { return fallback }
	for cursor^ < len(spans) {
		span := spans[cursor^]
		span_start := clamp(span.start, 0, text_length)
		span_end := clamp(span.end, 0, text_length)
		if !span.color_set || span_start >= span_end || span_end <= start {
			cursor^ += 1
			continue
		}
		break
	}
	winner := -1
	for index := cursor^; index < len(spans); index += 1 {
		span := spans[index]
		if !span.color_set { continue }
		span_start := clamp(span.start, 0, text_length)
		span_end := clamp(span.end, 0, text_length)
		if span_start >= end { break }
		if span_start < span_end && span_end > start { winner = index }
	}
	if winner >= 0 { return spans[winner].color }
	return fallback
}

// A visual bidi run may visit source clusters out of order. Sorted disjoint
// spans still need no byte-winner array in that case: binary-search the span
// start, then inspect only ranges that can intersect this cluster.
Color_For_Sorted_Cluster_Binary :: proc(
	text_length: int,
	spans: []alicorn.Text_Paint_Span,
	cluster_start, cluster_end: int,
	fallback: alicorn.Color,
) -> alicorn.Color {
	start := clamp(cluster_start, 0, text_length)
	end := clamp(cluster_end, 0, text_length)
	if start >= end { return fallback }
	low, high := 0, len(spans)
	for low < high {
		mid := low + (high-low)/2
		span_start := clamp(spans[mid].start, 0, text_length)
		if span_start < start { low = mid + 1 } else { high = mid }
	}
	first := low
	for first > 0 {
		first -= 1
		if spans[first].color_set { break }
	}
	winner := -1
	for index := first; index < len(spans); index += 1 {
		span := spans[index]
		span_start := clamp(span.start, 0, text_length)
		if span_start >= end { break }
		span_end := clamp(span.end, 0, text_length)
		if span.color_set && span_start < span_end && span_end > start { winner = index }
	}
	if winner >= 0 { return spans[winner].color }
	return fallback
}

Glyph_Clusters_Are_Ordered :: proc(glyphs: []alicorn.Text_Glyph) -> bool {
	previous_start := -1
	previous_end := -1
	for glyph in glyphs {
		if glyph.cluster_start < previous_start || glyph.cluster_end < previous_end { return false }
		previous_start = glyph.cluster_start
		previous_end = glyph.cluster_end
	}
	return true
}

// Runa's mono rasterizer stores the fractional X phase in four quarter-pixel
// variants. Keep the sampled quad origin on an integer physical pixel so the
// phase is supplied by the bitmap rather than by fractional texture
// placement. Rounding to the nearest quarter keeps the positional error below
// 1/8 physical pixel; a rounded fourth bucket carries into the next pixel.
Snap_Text_X :: proc(physical_x: f32) -> (pixel_x: f32, subpixel_bucket: u8) {
	pixel_x = math.floor(physical_x)
	phase := physical_x - pixel_x
	bucket := int(math.floor(phase * f32(TEXT_SUBPIXEL_BUCKETS) + 0.5))
	if bucket >= TEXT_SUBPIXEL_BUCKETS {
		pixel_x += 1
		bucket = 0
	}
	return pixel_x, u8(bucket)
}

Snap_Text_Y :: proc(physical_y: f32) -> f32 {
	return math.floor(physical_y + 0.5)
}

Text_Quad_Visible :: proc(x0, y0, x1, y1: f32, clip: alicorn.Rect, scale_x, scale_y: f32) -> bool {
	if clip.w <= 0 || clip.h <= 0 || x1 <= x0 || y1 <= y0 { return false }
	clip_x0, clip_y0 := clip.x * scale_x, clip.y * scale_y
	clip_x1, clip_y1 := (clip.x + clip.w) * scale_x, (clip.y + clip.h) * scale_y
	return x0 < clip_x1 && x1 > clip_x0 && y0 < clip_y1 && y1 > clip_y0
}

rects_intersect :: proc(a, b: alicorn.Rect) -> bool {
	if a.w <= 0 || a.h <= 0 || b.w <= 0 || b.h <= 0 { return false }
	return a.x < b.x+b.w && a.x+a.w > b.x && a.y < b.y+b.h && a.y+a.h > b.y
}

Text_Command_Intersects_Clip :: proc(command: alicorn.Paint_Command) -> bool {
	// Translation is applied by the command model at draw time. Keep a moving
	// command's full run in the retained mesh so pointer motion stays cheap.
	if command.translation[0] != 0 || command.translation[1] != 0 { return true }
	return rects_intersect(command.bounds, command.clip)
}

// This is a deliberately broad logical bound, not a substitute for the exact
// raster-bounds clip test below. The em-sized margin admits bearings, accents,
// italic overhang, combining marks, and zero-advance glyphs while still
// excluding glyphs far outside a long line's viewport before atlas lookup.
Glyph_May_Intersect_Clip :: proc(
	glyph: alicorn.Text_Glyph,
	run_size: f32,
	command: alicorn.Paint_Command,
	scale_x, scale_y: f32,
) -> bool {
	// A translated command can move after this mesh is built. Its draw scissor
	// remains authoritative, so retain its glyphs without position culling.
	if command.translation[0] != 0 || command.translation[1] != 0 { return true }
	if command.clip.w <= 0 || command.clip.h <= 0 { return false }
	clip_xa := command.clip.x * scale_x
	clip_ya := command.clip.y * scale_y
	clip_xb := (command.clip.x + command.clip.w) * scale_x
	clip_yb := (command.clip.y + command.clip.h) * scale_y
	clip_x0, clip_x1 := min(clip_xa, clip_xb), max(clip_xa, clip_xb)
	clip_y0, clip_y1 := min(clip_ya, clip_yb), max(clip_ya, clip_yb)
	run_size_abs := run_size
	if run_size_abs < 0 { run_size_abs = -run_size_abs }
	scale_x_abs, scale_y_abs := scale_x, scale_y
	if scale_x_abs < 0 { scale_x_abs = -scale_x_abs }
	if scale_y_abs < 0 { scale_y_abs = -scale_y_abs }
	margin_x := max(run_size_abs * scale_x_abs, 1)
	margin_y := max(run_size_abs * scale_y_abs, 1)
	glyph_xa := (command.bounds.x + glyph.x) * scale_x
	glyph_xb := (command.bounds.x + glyph.x + glyph.x_advance) * scale_x
	glyph_ya := (command.bounds.y + glyph.y) * scale_y
	glyph_yb := (command.bounds.y + glyph.y + glyph.y_advance) * scale_y
	x0 := min(glyph_xa, glyph_xb) - margin_x
	x1 := max(glyph_xa, glyph_xb) + margin_x
	y0 := min(glyph_ya, glyph_yb) - margin_y
	y1 := max(glyph_ya, glyph_yb) + margin_y
	return x0 < clip_x1 && x1 > clip_x0 && y0 < clip_y1 && y1 > clip_y0
}
