package webgpu_renderer

import "vendor:wgpu"

// WebGPU requires dynamic uniform offsets to satisfy the device's minimum
// uniform-buffer offset alignment (256 bytes). Slot zero is the main viewport;
// a bounded set of additional slots lets one retained mesh serve several
// cropped captures in one command submission without overwriting their origins.
VIEW_UNIFORM_CAPTURE_OFFSET :: u32(256)
VIEW_UNIFORM_MAX_CAPTURE_VIEWS :: u32(64)
VIEW_UNIFORM_SLOT_COUNT :: u32(1) + VIEW_UNIFORM_MAX_CAPTURE_VIEWS
VIEW_UNIFORM_BYTES :: u64(size_of([4]f32))
VIEW_UNIFORM_BUFFER_BYTES :: u64(VIEW_UNIFORM_CAPTURE_OFFSET) * u64(VIEW_UNIFORM_SLOT_COUNT-1) + VIEW_UNIFORM_BYTES

webgpu_view_capture_slot_available :: proc(used_mask: u64, view_slot: u32) -> bool {
	if view_slot == 0 || view_slot >= VIEW_UNIFORM_SLOT_COUNT { return false }
	mask := u64(1) << (view_slot-1)
	return (used_mask & mask) == 0
}

webgpu_view_capture_slot_claim :: proc(used_mask: ^u64, view_slot: u32) -> bool {
	if used_mask == nil || !webgpu_view_capture_slot_available(used_mask^, view_slot) { return false }
	used_mask^ |= u64(1) << (view_slot-1)
	return true
}

webgpu_view_bind_group_set :: proc(
	pass: wgpu.RenderPassEncoder,
	group_index: u32,
	bind_group: wgpu.BindGroup,
	view_slot: u32,
) -> bool {
	if pass == nil || bind_group == nil || view_slot >= VIEW_UNIFORM_SLOT_COUNT { return false }
	offset := view_slot * VIEW_UNIFORM_CAPTURE_OFFSET
	wgpu.RenderPassEncoderSetBindGroup(pass, group_index, bind_group, []u32{offset})
	return true
}

webgpu_view_uniform_write :: proc(
	queue: wgpu.Queue,
	buffer: wgpu.Buffer,
	width, height: u32,
	origin_px: [2]int = {},
	view_slot: u32 = 0,
) -> bool {
	if queue == nil || buffer == nil || width == 0 || height == 0 || view_slot >= VIEW_UNIFORM_SLOT_COUNT { return false }
	values := [4]f32{f32(width), f32(height), f32(origin_px[0]), f32(origin_px[1])}
	offset := u64(view_slot) * u64(VIEW_UNIFORM_CAPTURE_OFFSET)
	wgpu.QueueWriteBuffer(queue, buffer, offset, raw_data(values[:]), uint(size_of(values)))
	return true
}
