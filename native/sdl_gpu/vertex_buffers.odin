package alicorn_sdl_gpu

import "core:time"
import "vendor:sdl3"

// Native_Device_Stall_Stats attributes vertex-buffer growth. Growing a buffer
// replaces the GPU resource, so the path synchronously waits for device idle.
// The counters make that first-use stall visible without changing the growth
// policy; they are measurement-only and are reported at host exit and in
// diagnostics captures.
Native_Device_Stall_Stats :: struct {
	growth_events: u64,
	growth_ns:     u64,
	idle_waits:    u64,
	idle_wait_ns:  u64,
	peak_capacity: int,
}

native_white_texture_initialize :: proc(
	device: ^sdl3.GPUDevice,
	texture: ^sdl3.GPUTexture,
	initialized: ^bool,
	command: ^sdl3.GPUCommandBuffer,
) -> bool {
	if initialized^ { return true }
	target := sdl3.GPUColorTargetInfo{
		texture=texture, clear_color=sdl3.FColor{1, 1, 1, 1},
		load_op=.CLEAR, store_op=.STORE,
	}
	pass := sdl3.BeginGPURenderPass(command, &target, 1, nil)
	if pass == nil { return false }
	sdl3.EndGPURenderPass(pass)
	initialized^ = true
	return true
}

native_vertex_buffer_upload :: proc(
	device: ^sdl3.GPUDevice,
	vertex_buffer: ^sdl3.GPUBuffer,
	vertex_transfer: ^sdl3.GPUTransferBuffer,
	vertices: []Native_Text_Vertex,
	vertex_capacity: int,
	upload_pending: bool,
	vertices_uploaded: ^u64,
	command: ^sdl3.GPUCommandBuffer,
	upload_bytes: ^u64 = nil,
) -> bool {
	if !upload_pending { return true }
	if len(vertices) > vertex_capacity { return false }
	mapped := sdl3.MapGPUTransferBuffer(device, vertex_transfer, true)
	if mapped == nil { return false }
	destination := cast([^]Native_Text_Vertex)mapped
	for vertex, i in vertices { destination[i] = vertex }
	sdl3.UnmapGPUTransferBuffer(device, vertex_transfer)
	copy_pass := sdl3.BeginGPUCopyPass(command)
	if copy_pass == nil { return false }
	source := sdl3.GPUTransferBufferLocation{transfer_buffer=vertex_transfer, offset=0}
	destination_region := sdl3.GPUBufferRegion{
		buffer=vertex_buffer,
		offset=0,
		size=sdl3.Uint32(len(vertices) * size_of(Native_Text_Vertex)),
	}
	sdl3.UploadToGPUBuffer(copy_pass, source, destination_region, true)
	sdl3.EndGPUCopyPass(copy_pass)
	vertices_uploaded^ += 1
	if upload_bytes != nil { upload_bytes^ += u64(len(vertices) * size_of(Native_Text_Vertex)) }
	return true
}

// Solid and icon meshes share the same vertex buffer growth and retirement
// contract. Keep the buffer handles and capacity explicit so both renderers
// use the same allocation path.
native_vertex_buffer_ensure_capacity :: proc(
	device: ^sdl3.GPUDevice,
	vertex_buffer: ^^sdl3.GPUBuffer,
	vertex_transfer: ^^sdl3.GPUTransferBuffer,
	vertex_capacity: ^int,
	required: int,
	stats: ^Native_Device_Stall_Stats = nil,
) -> bool {
	maximum := int(sdl3.Uint32(0xFFFFFFFF) / sdl3.Uint32(size_of(Native_Text_Vertex)))
	new_capacity := native_next_vertex_capacity(vertex_capacity^, required, maximum)
	if new_capacity == 0 { return false }
	if new_capacity == vertex_capacity^ { return true }
	growth_start := time.now()
	new_size := sdl3.Uint32(new_capacity * size_of(Native_Text_Vertex))
	new_buffer := sdl3.CreateGPUBuffer(device, sdl3.GPUBufferCreateInfo{
		usage=sdl3.GPUBufferUsageFlags{.VERTEX}, size=new_size,
	})
	if new_buffer == nil { return false }
	new_transfer := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.UPLOAD, size=new_size,
	})
	if new_transfer == nil {
		sdl3.ReleaseGPUBuffer(device, new_buffer)
		return false
	}
	// These buffers are shared by submissions. Wait before replacing them so
	// earlier frames cannot still be reading the old vertex buffer.
	idle_start := time.now()
	if !sdl3.WaitForGPUIdle(device) {
		sdl3.ReleaseGPUTransferBuffer(device, new_transfer)
		sdl3.ReleaseGPUBuffer(device, new_buffer)
		return false
	}
	if stats != nil {
		stats.idle_waits += 1
		stats.idle_wait_ns += u64(time.duration_nanoseconds(time.since(idle_start)))
	}
	sdl3.ReleaseGPUBuffer(device, vertex_buffer^)
	sdl3.ReleaseGPUTransferBuffer(device, vertex_transfer^)
	vertex_buffer^ = new_buffer
	vertex_transfer^ = new_transfer
	vertex_capacity^ = new_capacity
	if stats != nil {
		stats.growth_events += 1
		stats.growth_ns += u64(time.duration_nanoseconds(time.since(growth_start)))
		if new_capacity > stats.peak_capacity { stats.peak_capacity = new_capacity }
	}
	return true
}
