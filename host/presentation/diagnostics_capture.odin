#+build !js

package presentation_host

// Best-effort diagnostic screenshot capture for the hosted WebGPU presenter.
//
// Capture deliberately does not use the swapchain: it encodes the current
// retained presentation list (application paint plus host chrome and diagnostic
// overlays) into a host-created offscreen texture and copies it to a mapped
// buffer. That means an F12 capture still produces an image when surface
// acquisition or presentation is failing, which is exactly when a renderer
// investigation needs one.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"
import webgpu_renderer "alicorn:renderer/webgpu"
import "vendor:wgpu"

@(private)
hosted_capture_map_state :: struct {
	done:   bool,
	status: wgpu.MapAsyncStatus,
}

// hosted_surface_presenter_capture_ppm renders the presenter's current display
// into an offscreen target and writes an RGB8 PPM. It returns false and leaves
// no partial file when the renderer rejects the frame or readback fails. The
// presenter's CPU frame state is rolled back; the GPU work is ordered on the
// same queue as presentation and can only be observed before later frames.
hosted_surface_presenter_capture_ppm :: proc(
	presenter: ^Hosted_Surface_Presenter,
	path: string,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
	allocator := context.allocator,
) -> bool {
	state := hosted_surface_state(presenter)
	if state == nil || state.device == nil || state.queue == nil || state.device_lost { return false }
	width := state.configuration.width
	height := state.configuration.height
	if width == 0 || height == 0 { return false }
	format := state.configuration.format
	if format != .BGRA8Unorm && format != .BGRA8UnormSrgb &&
	   format != .RGBA8Unorm && format != .RGBA8UnormSrgb {
		return false
	}
	display, display_status := alicorn.hosted_runtime_presentation_list(state.hosted, allocator)
	if display_status != .Ok || display.revision == 0 { return false }

	texture := wgpu.DeviceCreateTexture(state.device, &wgpu.TextureDescriptor{
		label="Alicorn diagnostics capture target",
		usage={.RenderAttachment, .CopySrc},
		dimension=._2D,
		size={width=width, height=height, depthOrArrayLayers=1},
		format=format,
		mipLevelCount=1,
		sampleCount=1,
	})
	if texture == nil { return false }
	defer wgpu.TextureRelease(texture)
	view := wgpu.TextureCreateView(texture)
	if view == nil { return false }
	defer wgpu.TextureViewRelease(view)

	row_bytes := u64(width)*4
	padded_row_bytes := (row_bytes+255) & ~u64(255)
	readback_size := padded_row_bytes*u64(height)
	buffer := wgpu.DeviceCreateBuffer(state.device, &wgpu.BufferDescriptor{
		label="Alicorn diagnostics capture readback",
		usage={.CopyDst, .MapRead},
		size=readback_size,
	})
	if buffer == nil { return false }
	defer wgpu.BufferRelease(buffer)

	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { return false }
	defer wgpu.CommandEncoderRelease(encoder)
	encoded := webgpu_renderer.WebGPU_Presenter_Encode(
		&state.renderer, display, encoder, view, width, height,
		state.scale_x, state.scale_y, true, clear_color,
	)
	if encoded != .Ok {
		// The presenter may have retained a partial frame. No queue work was
		// submitted, so canceling leaves the next presentation unaffected.
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		fmt.eprintln(
			"[alicorn-diagnostics] capture encode failed",
			"result", encoded, "commands", len(display.commands), "revision", display.revision,
		)
		return false
	}
	source := wgpu.TexelCopyTextureInfo{texture=texture, aspect=.All}
	destination := wgpu.TexelCopyBufferInfo{
		layout=wgpu.TexelCopyBufferLayout{
			bytesPerRow=u32(padded_row_bytes),
			rowsPerImage=height,
		},
		buffer=buffer,
	}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder, &source, &destination,
		&wgpu.Extent3D{width=width, height=height, depthOrArrayLayers=1})
	command := wgpu.CommandEncoderFinish(encoder)
	if command == nil {
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		return false
	}
	defer wgpu.CommandBufferRelease(command)
	wgpu.QueueSubmit(state.queue, {command})
	// The diagnostic frame is GPU-ordered but never acknowledged as an
	// application presentation. Roll back the presenter's speculative CPU state
	// so the next real frame prepares the same resources again.
	_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)

	map_context: hosted_capture_map_state
	wgpu.BufferMapAsync(buffer, {.Read}, 0, uint(readback_size), {
		mode=.AllowProcessEvents,
		callback=hosted_surface_capture_mapped,
		userdata1=rawptr(&map_context),
	})
	deadline := time.tick_now()
	for !map_context.done {
		if state.device != nil { _ = wgpu.DevicePoll(state.device, true) }
		if time.duration_nanoseconds(time.tick_diff(deadline, time.tick_now())) > 2_000_000_000 {
			return false
		}
	}
	if map_context.status != .Success { return false }
	pixels := wgpu.BufferGetMappedRangeSlice(buffer, 0, u8, uint(readback_size))
	if len(pixels) != int(readback_size) {
		wgpu.BufferUnmap(buffer)
		return false
	}
	defer wgpu.BufferUnmap(buffer)
	bgra := format == .BGRA8Unorm || format == .BGRA8UnormSrgb
	builder, builder_err := strings.builder_make_len_cap(0, int(width*height*3)+64)
	if builder_err != nil { return false }
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(&builder, "P6\n%d %d\n255\n", width, height)
	for y in u32(0)..<height {
		row := pixels[u64(y)*padded_row_bytes:]
		for x in u32(0)..<width {
			src := int(x)*4
			if bgra {
				strings.write_byte(&builder, row[src+2])
				strings.write_byte(&builder, row[src+1])
				strings.write_byte(&builder, row[src])
			} else {
				strings.write_byte(&builder, row[src])
				strings.write_byte(&builder, row[src+1])
				strings.write_byte(&builder, row[src+2])
			}
		}
	}
	return os.write_entire_file(path, strings.to_string(builder)) == nil
}

@(private)
hosted_surface_capture_mapped :: proc "c" (
	status: wgpu.MapAsyncStatus,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	state := cast(^hosted_capture_map_state)userdata1
	if state == nil { return }
	state.done = true
	state.status = status
}
