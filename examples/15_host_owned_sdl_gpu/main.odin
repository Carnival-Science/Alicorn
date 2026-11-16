package main

// 15 · Host-Owned SDL_GPU Presentation demonstrates that a host can own the
// SDL window, GPU device, command buffer, target, and event loop while Alicorn
// supplies the retained UI and native GPU renderer.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import "vendor:sdl3"

FAIL :: proc(message: string) -> ! {
	fmt.eprintln("host-owned SDL_GPU fixture failed:", message, "SDL:", sdl3.GetError())
	os.exit(1)
}

build_fixture_display :: proc(rt: ^alicorn.Runtime) {
	alicorn.invalidate_root(rt, "external host fixture description")
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { FAIL("Runtime did not accept the fixture description") }
	alicorn.container_begin(
		&ui,
		.Root,
		label="external-host-root",
		style=alicorn.layout_style(.Column, -1, -1, 0, -1, 0, -1, 0, 24, 16, .Stretch, true),
		color=alicorn.Color{0.035, 0.045, 0.065, 1},
	)
	alicorn.text(&ui, "Alicorn native presentation", style=alicorn.layout_style(.Column, -1, 36, 0, -1, 0, -1, 0, 0, 0, .Stretch, false))
	alicorn.text(&ui, "The host owns this window and GPU frame.")
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
}

main :: proc() {
	if !sdl3.Init(sdl3.INIT_VIDEO) { FAIL("SDL_Init failed") }
	defer sdl3.Quit()

	title, title_err := strings.clone_to_cstring("Alicorn Host-Owned Presentation", context.temp_allocator)
	if title_err != nil { FAIL("window title allocation failed") }
	window := sdl3.CreateWindow(title, c.int(960), c.int(640), sdl3.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil { FAIL("SDL_CreateWindow failed") }
	defer sdl3.DestroyWindow(window)

	device := sdl3.CreateGPUDevice(sdl3.GPUShaderFormat{.SPIRV, .DXIL, .MSL}, false, nil)
	if device == nil { FAIL("SDL_CreateGPUDevice failed") }
	defer sdl3.DestroyGPUDevice(device)
	if !sdl3.ClaimWindowForGPUDevice(device, window) { FAIL("SDL_ClaimWindowForGPUDevice failed") }
	defer sdl3.ReleaseWindowFromGPUDevice(device, window)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 960, 640})
	defer alicorn.destroy_runtime(&rt)
	if !alicorn.text_engine_load_default_fonts(&rt) { FAIL("default font initialization failed") }
	build_fixture_display(&rt)

	format := sdl3.GetGPUSwapchainTextureFormat(device, window)
	presenter, presenter_ok := host.Sdl_GPU_Presenter_Create(device, format, &rt)
	if !presenter_ok { FAIL("Alicorn SDL_GPU renderer initialization failed") }

	if !sdl3.ShowWindow(window) { FAIL("SDL_ShowWindow failed") }
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { FAIL("SDL_AcquireGPUCommandBuffer failed") }
	pixel_width, pixel_height: c.int
	if !sdl3.GetWindowSizeInPixels(window, &pixel_width, &pixel_height) || pixel_width <= 0 || pixel_height <= 0 {
		_ = sdl3.CancelGPUCommandBuffer(command)
		FAIL("SDL window pixel size unavailable")
	}
	if !host.Sdl_GPU_Presenter_Encode_Window(
		&presenter,
		command,
		window,
		f32(pixel_width)/960,
		f32(pixel_height)/640,
	) {
		_ = sdl3.CancelGPUCommandBuffer(command)
		_ = host.Sdl_GPU_Presenter_Cancel_Frame(&presenter)
		FAIL("Alicorn display-list preparation or swapchain acquisition failed")
	}
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil { FAIL("SDL_GPU frame submission failed") }
	submission, submitted := host.Sdl_GPU_Presenter_Submission_Succeeded(&presenter, fence)
	if !submitted {
		fences := [1]^sdl3.GPUFence{fence}
		_ = sdl3.WaitForGPUFences(device, true, &fences[0], 1)
		sdl3.ReleaseGPUFence(device, fence)
		FAIL("Alicorn rejected the successful host submission")
	}
	if !host.Sdl_GPU_Presenter_Wait(&presenter, submission) { FAIL("Alicorn presenter fence wait failed") }
	fmt.println("host_owned_sdl_gpu_frame", "serial", submission.serial, "display_revision", submission.display_revision)

	// No frame is submitted while idle. The host continues to own event waiting
	// and decides when input, resize, or expose events require a new Runtime frame.
	for {
		event: sdl3.Event
		if !sdl3.WaitEvent(&event) { FAIL("SDL_WaitEvent failed") }
		if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED { break }
	}
	if !host.Sdl_GPU_Presenter_Destroy(&presenter) { FAIL("presenter could not retire its GPU work") }
}
