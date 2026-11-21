#+build windows

package dpi_transition

// End-to-end high-DPI transition acceptance for the hosted WebGPU path.
//
// Without a second monitor (or when both monitors run the same scale) the OS
// will not originate a real WM_DPICHANGED sequence. This fixture therefore
// exercises the two halves of that sequence separately and asserts the same
// invariants a physical monitor drag must satisfy:
//
//   1. It posts WM_DPICHANGED and WM_DISPLAYCHANGE to the hosted window. That
//      runs the native window-proc/chrome branch (titlebar text refresh, frame
//      extension, metrics/layout sync, redraw request) exactly as a real
//      transition would, even though the monitor's DPI is unchanged.
//   2. It adopts the measurement a real transition produces (same logical size,
//      new drawable pixels, new display scale) through
//      sdl3_webgpu_application_apply_metrics. That drives the surface
//      reconfigure, presentation scale, description invalidation, text
//      re-rasterization, and hit-test remap.
//
// It captures a PPM before and after each scale change, asserts the text is
// re-rasterized at the new density rather than a stretched last frame, checks
// logical geometry and pointer targets are invariant, and runs a second window
// at an independent scale to rule out cross-window state contamination.
//
// Run with tools/validate_native_webgpu_dpi.ps1.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import alicorn "alicorn:runtime"
import host "alicorn:host/sdl3"
import host_fonts "alicorn:host/fonts"
import presentation_host "alicorn:host/presentation"
import "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

WINDOW_LOGICAL_WIDTH :: 760
WINDOW_LOGICAL_HEIGHT :: 520
TEXT_FONT_SIZE :: 28

Transition_App :: struct {
	label:          string,
	key_prefix:     string,
	root_key:       string,
	text_key:       string,
	button_key:     string,
	button:         alicorn.Node_ID,
	text:           alicorn.Node_ID,
	descriptions:   int,
	last_dpi:       f32,
	last_width:     int,
	last_height:    int,
	clicks:         int,
	chrome_metrics: int,
	chrome_layouts: int,
	last_header_h:  f32,
}

Transition_Window :: struct {
	window:      ^sdl3.Window,
	surface:     wgpu.Surface,
	configuration: wgpu.SurfaceConfiguration,
	application: host.SDL3_WebGPU_Application,
	app:         Transition_App,
	menus:       [1]alicorn.Menu,
	menu_items:  [1]alicorn.Menu_Item,
	initialized: bool,
}

Transition_Host :: struct {
	instance: wgpu.Instance,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	adapter_done, device_done, failed: bool,
}

state: Transition_Host

Transition_Graphics :: struct {
	description_built: bool,
	render_required:   bool,
	presentation:      presentation_host.Hosted_Surface_Result,
}

transition_render :: proc(data: rawptr, ui: ^alicorn.UI, width, height: int, dpi: f32) {
	app := cast(^Transition_App)data
	app.descriptions += 1
	app.last_dpi = dpi
	app.last_width, app.last_height = width, height
	root := alicorn.container_begin(
		ui,
		.Root,
		label=app.label,
		key=app.root_key,
		style=alicorn.layout_style(.Column, grow=1, padding=24, gap=16),
		color=alicorn.Color{0.04, 0.06, 0.08, 1},
	)
	if root == 0 { return }
	app.text = alicorn.text_ex(
		ui,
		"Resolution probe: assay glyphs 0123456789",
		key=app.text_key,
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_REGULAR, font_size=TEXT_FONT_SIZE},
	)
	button, clicked := alicorn.button_ex(
		ui,
		"Known target",
		key=app.button_key,
		style=alicorn.layout_style(width=160, height=40),
	)
	app.button = button
	if clicked { app.clicks += 1 }
	alicorn.container_end(ui)
}

transition_initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	if !host_fonts.load_default_fonts(rt) {
		fmt.eprintln("dpi_transition: bundled fonts failed to initialize")
	}
}

transition_chrome_metrics :: proc(
	data: rawptr,
	_rt: ^alicorn.Runtime,
	metrics: alicorn.Window_Chrome_Metrics,
) {
	app := cast(^Transition_App)data
	app.chrome_metrics += 1
	app.last_header_h = metrics.header.h
}

transition_chrome_layout :: proc(
	_data: rawptr,
	_rt: ^alicorn.Runtime,
) -> alicorn.Window_Chrome_Layout {
	app := cast(^Transition_App)_data
	app.chrome_layouts += 1
	return {}
}

transition_on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: wgpu.StringView,
	_userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	state.adapter_done = true
	if status != .Success || adapter == nil {
		fmt.eprintln("dpi_transition: adapter request failed", status, message)
		state.failed = true
		return
	}
	state.adapter = adapter
	wgpu.AdapterRequestDevice(adapter, &wgpu.DeviceDescriptor{
		label="Alicorn DPI transition device",
	}, {callback=transition_on_device})
}

transition_on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: wgpu.StringView,
	_userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	state.device_done = true
	if status != .Success || device == nil {
		fmt.eprintln("dpi_transition: device request failed", status, message)
		state.failed = true
		return
	}
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
}

transition_backend :: proc() -> (wgpu.BackendType, bool) {
	for argument in os.args {
		if argument == "--backend=d3d12" { return .D3D12, true }
		if argument == "--backend=vulkan" { return .Vulkan, true }
		if strings.has_prefix(argument, "--backend=") { return .Undefined, false }
	}
	return .Undefined, true
}

transition_wait_for_device :: proc() -> bool {
	deadline := time.tick_now()
	for !state.device_done && !state.failed {
		wgpu.InstanceProcessEvents(state.instance)
		if time.duration_nanoseconds(time.tick_diff(deadline, time.tick_now())) > 15_000_000_000 {
			fmt.eprintln("dpi_transition: adapter/device request timed out")
			return false
		}
		event: sdl3.Event
		_ = sdl3.WaitEventTimeout(&event, 1)
	}
	return !state.failed && state.device != nil && state.queue != nil
}

transition_surface_configuration :: proc(surface: wgpu.Surface) -> (configuration: wgpu.SurfaceConfiguration, ok: bool) {
	capabilities, status := wgpu.SurfaceGetCapabilities(surface, state.adapter)
	if status != .Success || capabilities.formatCount == 0 || capabilities.alphaModeCount == 0 ||
	   capabilities.presentModeCount == 0 {
		if status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(capabilities) }
		return
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)
	configuration.device = state.device
	configuration.usage = {.RenderAttachment}
	configuration.presentMode = .Fifo
	configuration.format = capabilities.formats[0]
	for i in 0..<int(capabilities.formatCount) {
		format := capabilities.formats[i]
		if format == .BGRA8UnormSrgb { configuration.format = format; break }
		if format == .BGRA8Unorm { configuration.format = format }
	}
	configuration.alphaMode = capabilities.alphaModes[0]
	for i in 0..<int(capabilities.alphaModeCount) {
		if capabilities.alphaModes[i] == .Opaque { configuration.alphaMode = .Opaque; break }
	}
	for i in 0..<int(capabilities.presentModeCount) {
		if capabilities.presentModes[i] == .Fifo { configuration.presentMode = .Fifo; break }
	}
	return configuration, true
}

transition_window_open :: proc(
	entry: ^Transition_Window,
	title: string,
	label, key_prefix: string,
	integrated_chrome: bool,
) -> bool {
	flags := sdl3.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN}
	title_cstring, err := strings.clone_to_cstring(title, context.temp_allocator)
	if err != nil { return false }
	entry.window = sdl3.CreateWindow(
		title_cstring, WINDOW_LOGICAL_WIDTH, WINDOW_LOGICAL_HEIGHT, flags,
	)
	if entry.window == nil {
		fmt.eprintln("dpi_transition: window creation failed", sdl3.GetError())
		return false
	}
	entry.surface = sdl3glue.GetSurface(state.instance, entry.window)
	if entry.surface == nil {
		fmt.eprintln("dpi_transition: surface creation failed")
		return false
	}
	configuration, ok := transition_surface_configuration(entry.surface)
	if !ok {
		fmt.eprintln("dpi_transition: surface capabilities unavailable")
		return false
	}
	logical_width, logical_height, pixel_width, pixel_height: i32
	if !sdl3.GetWindowSize(entry.window, &logical_width, &logical_height) ||
	   !sdl3.GetWindowSizeInPixels(entry.window, &pixel_width, &pixel_height) {
		fmt.eprintln("dpi_transition: window metrics unavailable")
		return false
	}
	configuration.width = u32(pixel_width)
	configuration.height = u32(pixel_height)
	entry.configuration = configuration
	entry.app.label = label
	entry.app.key_prefix = key_prefix
	entry.app.root_key = fmt.tprintf("%s-root", key_prefix)
	entry.app.text_key = fmt.tprintf("%s-text", key_prefix)
	entry.app.button_key = fmt.tprintf("%s-button", key_prefix)

	decorations := alicorn.Window_Decoration_Mode.System
	menus: []alicorn.Menu
	menu_presentation := alicorn.Menu_Presentation.Labels
	chrome_height: f32
	chrome_metrics: alicorn.Window_Chrome_Metrics_Proc
	chrome_layout: alicorn.Window_Chrome_Layout_Proc
	if integrated_chrome {
		decorations = .Integrated_Title_Bar
		entry.menu_items[0] = alicorn.Menu_Item{
			kind=.Command,
			label="Probe",
			state=alicorn.Action_State{enabled=true},
		}
		entry.menus[0] = alicorn.Menu{label="File", items=entry.menu_items[:]}
		menus = entry.menus[:]
		chrome_height = 32
		chrome_metrics = transition_chrome_metrics
		chrome_layout = transition_chrome_layout
	}
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&entry.app),
		logical_width=int(logical_width),
		logical_height=int(logical_height),
		pixel_width=int(pixel_width),
		pixel_height=int(pixel_height),
		dpi_scale=1,
		render=transition_render,
		on_initialize=transition_initialize,
		menus=menus,
		menu_presentation=menu_presentation,
		window_decorations=decorations,
		window_chrome_height=chrome_height,
		window_chrome_metrics=chrome_metrics,
		window_chrome_layout=chrome_layout,
	}
	result := host.sdl3_webgpu_application_init(
		&entry.application, config, entry.window, entry.surface,
		state.device, state.queue, entry.configuration,
	)
	if result != .Ok {
		fmt.eprintln("dpi_transition: hosted application init failed", result)
		return false
	}
	entry.initialized = true
	if !sdl3.ShowWindow(entry.window) {
		fmt.eprintln("dpi_transition: window show failed", sdl3.GetError())
		return false
	}
	return true
}

transition_poll_completions :: proc(entry: ^Transition_Window, deadline_ns: u64 = 2_000_000_000) -> bool {
	nodes := u64(0)
	for {
		if !host.sdl3_webgpu_application_has_in_flight(&entry.application) { return true }
		presentation_host.hosted_surface_presenter_poll(&entry.application.presenter)
		_ = wgpu.DevicePoll(state.device, false)
		wgpu.InstanceProcessEvents(state.instance)
		nodes += 1
		if nodes*1_000_000 > deadline_ns {
			fmt.eprintln("dpi_transition: in-flight presentation retirement timed out")
			return false
		}
	}
}

// transition_step presents one bounded opportunity and retires retryable
// presenter states. It returns the runtime step flags plus the final result.
transition_step :: proc(entry: ^Transition_Window, now_ns: u64) -> Transition_Graphics {
	deadline := time.tick_now()
	for {
		step := host.sdl3_webgpu_application_step(&entry.application, now_ns)
		if step.status != .Ok {
			fmt.eprintln("dpi_transition: hosted step failed", step.status)
			return {presentation=.Invalid_Input}
		}
		#partial switch step.presentation {
		case .Ok, .No_Frame, .Suspended, .Hidden:
			return {presentation=step.presentation}
		case .Retry_Later, .Reconfigure_Required:
			presentation_host.hosted_surface_presenter_poll(&entry.application.presenter)
			_ = wgpu.DevicePoll(state.device, false)
			wgpu.InstanceProcessEvents(state.instance)
		case:
			return {presentation=step.presentation}
		}
		if time.duration_nanoseconds(time.tick_diff(deadline, time.tick_now())) > 2_000_000_000 {
			fmt.eprintln("dpi_transition: presentation retry timed out")
			return {presentation=.Retry_Later}
		}
	}
}

transition_pump_events :: proc(primary, secondary: ^Transition_Window) {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {
		_ = host.sdl3_webgpu_application_handle_event(&primary.application, event)
		if secondary != nil {
			_ = host.sdl3_webgpu_application_handle_event(&secondary.application, event)
		}
	}
}

transition_window_hwnd :: proc(entry: ^Transition_Window) -> win.HWND {
	props := sdl3.GetWindowProperties(entry.window)
	return cast(win.HWND)sdl3.GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
}

// transition_post_monitor_messages injects the window messages Windows sends
// around a per-monitor DPI transition. The monitor does not actually change, so
// the chrome path observes the real DPI; the assertions only require that the
// branch runs, re-syncs chrome geometry, and requests a frame.
transition_post_monitor_messages :: proc(entry: ^Transition_Window) -> bool {
	hwnd := transition_window_hwnd(entry)
	if hwnd == nil { return false }
	rect: win.RECT
	if !win.GetWindowRect(hwnd, &rect) { return false }
	dpi := win.GetDpiForWindow(hwnd)
	if dpi == 0 { dpi = 96 }
	_ = win.SendMessageW(
		hwnd, win.WM_DPICHANGED,
		win.WPARAM(win.MAKELONG(int(dpi), int(dpi))),
		win.LPARAM(uintptr(&rect)),
	)
	// WM_DISPLAYCHANGE is broadcast by the system when display settings change.
	// Posting it after the DPI message exercises a host that receives both.
	_ = win.SendMessageW(hwnd, win.WM_DISPLAYCHANGE, 32, 0)
	return true
}

// transition_apply_synthetic_scale adopts the exact metric shape a per-monitor
// transition produces: the logical size is unchanged while the drawable size
// and display scale move. The fixture keeps the real window where it is.
transition_apply_synthetic_scale :: proc(
	entry: ^Transition_Window,
	scale: f32,
) -> presentation_host.Hosted_Surface_Result {
	pixel_width := int(f32(WINDOW_LOGICAL_WIDTH)*scale+0.5)
	pixel_height := int(f32(WINDOW_LOGICAL_HEIGHT)*scale+0.5)
	return host.sdl3_webgpu_application_apply_metrics(
		&entry.application,
		WINDOW_LOGICAL_WIDTH, WINDOW_LOGICAL_HEIGHT,
		pixel_width, pixel_height,
		scale, scale,
	)
}

PPM_Stats :: struct {
	ink:            int,
	midtones:       int,
	min_x, max_x:   int,
	min_y, max_y:   int,
	max_delta:      int,
	total:          int,
}

transition_ppm_stats :: proc(path: string, fg_threshold: int) -> (stats: PPM_Stats, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil { return {}, false }
	defer delete(data)
	// P6\n<w> <h>\n255\n
	text := string(data)
	header_end := 0
	newlines := 0
	for index in 0..<len(text) {
		if text[index] == '\n' {
			newlines += 1
			if newlines == 3 { header_end = index+1; break }
		}
	}
	if header_end == 0 { return {}, false }
	dimensions := strings.split(text[:header_end], "\n", context.temp_allocator)
	if len(dimensions) < 3 { return {}, false }
	size_fields := strings.fields(dimensions[1], context.temp_allocator)
	if len(size_fields) != 2 { return {}, false }
	width, width_ok := parse_int(size_fields[0])
	height, height_ok := parse_int(size_fields[1])
	if !width_ok || !height_ok || width <= 0 || height <= 0 || len(data) < header_end+width*height*3 {
		return {}, false
	}
	pixels := data[header_end:]
	stats.min_x, stats.min_y = width, height
	previous_row := make([]int, width, context.temp_allocator)
	for x in 0..<width { previous_row[x] = -1 }
	for y in 0..<height {
		row := make([]int, width, context.temp_allocator)
		for x in 0..<width {
			offset := (y*width+x)*3
			luma := int(pixels[offset])*3+int(pixels[offset+1])*4+int(pixels[offset+2])
			row[x] = luma
			stats.total += 1
			if luma > fg_threshold*7 {
				stats.ink += 1
				if x < stats.min_x { stats.min_x = x }
				if x > stats.max_x { stats.max_x = x }
				if y < stats.min_y { stats.min_y = y }
				if y > stats.max_y { stats.max_y = y }
			} else if luma > 40*7 && luma <= fg_threshold*7 {
				stats.midtones += 1
			}
			if x > 0 {
				delta := abs(row[x]-row[x-1])
				if delta > stats.max_delta { stats.max_delta = delta }
			}
			if y > 0 {
				delta := abs(row[x]-previous_row[x])
				if delta > stats.max_delta { stats.max_delta = delta }
			}
		}
		for x in 0..<width { previous_row[x] = row[x] }
	}
	return stats, stats.ink > 0
}

parse_int :: proc(value: string) -> (int, bool) {
	result := 0
	if len(value) == 0 { return 0, false }
	for character in value {
		if character < '0' || character > '9' { return 0, false }
		result = result*10+int(character-'0')
	}
	return result, true
}

// transition_assert_scale_acceptance checks one adopted scale:
// presentation/surface follow the drawable, the description receives the
// display scale, logical geometry and hit testing are invariant, text is
// re-rasterized at the new density, and the captured glyphs are not a blurred
// rescale of the previous frame.
transition_assert_scale_acceptance :: proc(
	entry: ^Transition_Window,
	baseline_bounds: alicorn.Rect,
	baseline_scale: f32,
	scale: f32,
	baseline_ink: int,
	capture_path: string,
	expect_new_glyphs: bool,
	ok: ^bool,
) {
	if !transition_poll_completions(entry) { ok^ = false; return }
	before_stats, before_ok := presentation_host.hosted_surface_presenter_renderer_stats(&entry.application.presenter)
	rt, status := alicorn.hosted_runtime_borrow(&entry.application.hosted)
	if status != .Ok { ok^ = false; return }
	rasterizations_before := rt.text_engine.glyph_rasterizations
	inset, _ := alicorn.hosted_runtime_content_inset(&entry.application.hosted)
	graphics := transition_step(entry, u64(sdl3.GetTicksNS()))
	if graphics.presentation != .Ok && graphics.presentation != .No_Frame {
		fmt.eprintln("dpi_transition: presentation failed during scale acceptance", graphics.presentation)
		ok^ = false
		return
	}
	if !transition_poll_completions(entry) { ok^ = false; return }
	rt, status = alicorn.hosted_runtime_borrow(&entry.application.hosted)
	if status != .Ok { ok^ = false; return }
	app := &entry.app
	button := rt.nodes[app.button]
	text := rt.nodes[app.text]
	if button == nil || text == nil { ok^ = false; return }
	if app.last_dpi != scale {
		fmt.eprintf("dpi_transition: FAIL application received dpi %.3f at scale %.3f\n", app.last_dpi, scale)
		ok^ = false
	}
	if rt.presentation_scale_x != scale || rt.presentation_scale_y != scale {
		fmt.eprintf("dpi_transition: FAIL presentation %.3fx%.3f at scale %.3f\n",
			rt.presentation_scale_x, rt.presentation_scale_y, scale)
		ok^ = false
	}
	if configured_logical_w, configured_logical_h, configured_pixel_w, configured_pixel_h,
	   configured_scale_x, configured_scale_y, metrics_ok :=
	   presentation_host.hosted_surface_presenter_metrics(&entry.application.presenter);
	   metrics_ok {
		if configured_pixel_w != entry.application.last_pixel_width ||
		   configured_pixel_h != entry.application.last_pixel_height ||
		   configured_logical_w != entry.application.last_logical_width ||
		   configured_logical_h != entry.application.last_logical_height ||
		   configured_scale_x != scale || configured_scale_y != scale {
			fmt.eprintf(
				"dpi_transition: FAIL surface configured %dx%d (logical %dx%d, %.3fx%.3f) at scale %.3f\n",
				configured_pixel_w, configured_pixel_h, configured_logical_w, configured_logical_h,
				configured_scale_x, configured_scale_y, scale,
			)
			ok^ = false
		}
	}
	if button.bounds != baseline_bounds {
		fmt.eprintf("dpi_transition: FAIL logical button bounds changed at scale %.3f\n", scale)
		ok^ = false
	}
	center_x := button.bounds.x+button.bounds.w*0.5
	center_y := button.bounds.y+button.bounds.h*0.5
	target, target_status := alicorn.hosted_runtime_pointer(
		&entry.application.hosted,
		alicorn.Pointer_Event{kind=.Move, x=center_x, y=center_y+inset},
	)
	if target_status != .Ok || target != app.button {
		fmt.eprintf("dpi_transition: FAIL hit test target %d at scale %.3f\n", target, scale)
		ok^ = false
	}
	after_stats, after_ok := presentation_host.hosted_surface_presenter_renderer_stats(&entry.application.presenter)
	if before_ok && after_ok &&
	   after_stats.text.mesh_rebuilds <= before_stats.text.mesh_rebuilds {
		fmt.eprintf("dpi_transition: FAIL text mesh did not rebuild at scale %.3f\n", scale)
		ok^ = false
	}
	if expect_new_glyphs && rt.text_engine.glyph_rasterizations <= rasterizations_before {
		fmt.eprintf("dpi_transition: FAIL glyphs were not re-rasterized at scale %.3f\n", scale)
		ok^ = false
	}
	if !presentation_host.hosted_surface_presenter_capture_ppm(&entry.application.presenter, capture_path) {
		fmt.eprintln("dpi_transition: capture failed", capture_path)
		ok^ = false
		return
	}
	// Crop to the text node plus a small guard band. The capture is physical
	// pixels; add the host chrome inset in logical units before scaling.
	pad := f32(4)
	x0 := int((text.bounds.x+inset-pad)*scale)
	y0 := int((text.bounds.y+inset-pad)*scale)
	x1 := int((text.bounds.x+text.bounds.w+inset+pad)*scale)
	y1 := int((text.bounds.y+text.bounds.h+inset+pad)*scale)
	crop_path := fmt.tprintf("%s.crop.ppm", capture_path)
	if !transition_crop_ppm(capture_path, crop_path, x0, y0, x1, y1) {
		fmt.eprintln("dpi_transition: crop failed", crop_path)
		ok^ = false
		return
	}
	defer os.remove(crop_path)
	stats, stats_ok := transition_ppm_stats(crop_path, 120)
	if !stats_ok {
		fmt.eprintf("dpi_transition: FAIL no glyph ink captured at scale %.3f\n", scale)
		ok^ = false
		return
	}
	if stats.max_delta < 600 {
		// A sharp raster produces a near-full-contrast pixel step at a glyph
		// stem. Bilinear upscaling of a stale lower-density frame spreads that
		// step across the interpolated pixels and lowers the maximum jump.
		fmt.eprintf("dpi_transition: FAIL soft glyph edges at scale %.3f (max delta %d)\n",
			scale, stats.max_delta)
		ok^ = false
	}
	if scale > baseline_scale*1.2 && baseline_ink > 0 {
		ratio := f32(stats.ink)/f32(baseline_ink)
		expected := scale*scale
		if ratio < expected*0.65 || ratio > expected*1.45 {
			fmt.eprintf("dpi_transition: FAIL ink ratio %.2f at %.3f (expected ~%.2f)\n",
				ratio, scale, expected)
			ok^ = false
		}
	}
	fmt.printf(
		"dpi_transition scale=%.3f dpi=%.3f presentation=%.3f ink=%d midtones=%d max_delta=%d\n",
		scale, app.last_dpi, rt.presentation_scale_x, stats.ink, stats.midtones, stats.max_delta,
	)
}

transition_crop_ppm :: proc(source, destination: string, x0, y0, x1, y1: int) -> bool {
	data, read_err := os.read_entire_file(source, context.allocator)
	if read_err != nil { return false }
	defer delete(data)
	text := string(data)
	header_end := 0
	newlines := 0
	for index in 0..<len(text) {
		if text[index] == '\n' {
			newlines += 1
			if newlines == 3 { header_end = index+1; break }
		}
	}
	if header_end == 0 { return false }
	fields := strings.fields(strings.split(text[:header_end], "\n", context.temp_allocator)[1], context.temp_allocator)
	if len(fields) != 2 { return false }
	width, width_ok := parse_int(fields[0])
	height, height_ok := parse_int(fields[1])
	if !width_ok || !height_ok { return false }
	crop_x0 := clamp(x0, 0, width)
	crop_y0 := clamp(y0, 0, height)
	crop_x1 := clamp(x1, crop_x0, width)
	crop_y1 := clamp(y1, crop_y0, height)
	crop_width := crop_x1-crop_x0
	crop_height := crop_y1-crop_y0
	if crop_width <= 0 || crop_height <= 0 { return false }
	builder, builder_err := strings.builder_make_len_cap(0, crop_width*crop_height*3+32)
	if builder_err != nil { return false }
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(&builder, "P6\n%d %d\n255\n", crop_width, crop_height)
	pixels := data[header_end:]
	for y in crop_y0..<crop_y1 {
		row := pixels[(y*width+crop_x0)*3:]
		for x in 0..<crop_width*3 { strings.write_byte(&builder, row[x]) }
	}
	return os.write_entire_file(destination, strings.to_string(builder)) == nil
}

transition_window_bounds :: proc(entry: ^Transition_Window) -> (alicorn.Rect, bool) {
	rt, status := alicorn.hosted_runtime_borrow(&entry.application.hosted)
	if status != .Ok || entry.app.button == 0 { return {}, false }
	node := rt.nodes[entry.app.button]
	if node == nil { return {}, false }
	return node.bounds, true
}

main :: proc() {
	backend, backend_valid := transition_backend()
	if !backend_valid {
		fmt.eprintln("dpi_transition: unsupported --backend selector")
		os.exit(2)
	}
	if !sdl3.Init({.VIDEO}) {
		fmt.eprintln("dpi_transition: SDL init failed", sdl3.GetError())
		os.exit(1)
	}
	defer sdl3.Quit()
	if !host.sdl3_webgpu_prepare_accessibility_platform() {
		fmt.eprintln("dpi_transition: accessibility platform preparation failed")
		os.exit(1)
	}
	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil { os.exit(1) }
	defer wgpu.InstanceRelease(state.instance)
	// Create a temporary window to choose a compatible surface/adapter.
	probe_window := sdl3.CreateWindow("Alicorn DPI probe", 64, 64, {.HIDDEN})
	if probe_window == nil { os.exit(1) }
	probe_surface := sdl3glue.GetSurface(state.instance, probe_window)
	if probe_surface == nil { os.exit(1) }
	wgpu.InstanceRequestAdapter(state.instance, &wgpu.RequestAdapterOptions{
		compatibleSurface=probe_surface,
		powerPreference=.HighPerformance,
		backendType=backend,
	}, {callback=transition_on_adapter})
	if !transition_wait_for_device() { os.exit(1) }
	wgpu.SurfaceRelease(probe_surface)
	sdl3.DestroyWindow(probe_window)

	primary, secondary: Transition_Window
	if !transition_window_open(&primary, "Alicorn DPI transition primary", "dpi-primary", "dpi-primary", false) {
		os.exit(1)
	}
	if !transition_window_open(&secondary, "Alicorn DPI transition chrome", "dpi-chrome", "dpi-chrome", true) {
		os.exit(1)
	}
	defer {
		for _ in 0..<200 {
			if host.sdl3_webgpu_application_destroy(&secondary.application) { break }
			presentation_host.hosted_surface_presenter_poll(&secondary.application.presenter)
			_ = wgpu.DevicePoll(state.device, true)
		}
		for _ in 0..<200 {
			if host.sdl3_webgpu_application_destroy(&primary.application) { break }
			presentation_host.hosted_surface_presenter_poll(&primary.application.presenter)
			_ = wgpu.DevicePoll(state.device, true)
		}
		wgpu.SurfaceRelease(secondary.surface)
		wgpu.SurfaceRelease(primary.surface)
		sdl3.DestroyWindow(secondary.window)
		sdl3.DestroyWindow(primary.window)
		wgpu.QueueRelease(state.queue)
		wgpu.DeviceRelease(state.device)
		wgpu.AdapterRelease(state.adapter)
	}

	pass := true
	// Settle the initial description and capture the actual-DPI baseline.
	for _ in 0..<4 {
		graphics := transition_step(&primary, u64(sdl3.GetTicksNS()))
		if graphics.presentation == .Invalid_Input { pass = false }
		_ = transition_poll_completions(&primary)
		transition_pump_events(&primary, &secondary)
	}
	_ = transition_step(&secondary, u64(sdl3.GetTicksNS()))
	_ = transition_poll_completions(&secondary)

	baseline_bounds, baseline_ok := transition_window_bounds(&primary)
	if !baseline_ok {
		fmt.eprintln("dpi_transition: FAIL baseline button missing")
		os.exit(1)
	}
	baseline_scale := primary.application.display_scale
	if !(baseline_scale > 0) { baseline_scale = 1 }
	base_capture := "out/dpi-transition-baseline.ppm"
	if !presentation_host.hosted_surface_presenter_capture_ppm(&primary.application.presenter, base_capture) {
		fmt.eprintln("dpi_transition: FAIL baseline capture")
		os.exit(1)
	}
	base_stats, base_stats_ok := transition_ppm_stats(base_capture, 120)
	if !base_stats_ok {
		fmt.eprintln("dpi_transition: FAIL baseline glyph ink")
		os.exit(1)
	}
	inset, _ := alicorn.hosted_runtime_content_inset(&primary.application.hosted)
	rt, _ := alicorn.hosted_runtime_borrow(&primary.application.hosted)
	text := rt.nodes[primary.app.text]
	if text == nil {
		fmt.eprintln("dpi_transition: FAIL text node missing")
		os.exit(1)
	}
	base_crop := "out/dpi-transition-baseline-crop.ppm"
	_ = transition_crop_ppm(
		base_capture, base_crop,
		int((text.bounds.x+inset-4)*baseline_scale), int((text.bounds.y+inset-4)*baseline_scale),
		int((text.bounds.x+text.bounds.w+inset+4)*baseline_scale), int((text.bounds.y+text.bounds.h+inset+4)*baseline_scale),
	)
	base_crop_stats, _ := transition_ppm_stats(base_crop, 120)
	fmt.printf(
		"dpi_transition baseline scale=%.3f logical=%.1fx%.1f ink=%d max_delta=%d\n",
		baseline_scale, baseline_bounds.w, baseline_bounds.h, base_crop_stats.ink, base_crop_stats.max_delta,
	)
	if base_crop_stats.max_delta < 600 {
		fmt.eprintln("dpi_transition: FAIL baseline glyph edges are soft")
		pass = false
	}

	// Synthetic per-monitor transitions on the primary window. Glyphs for a
	// scale are rasterized once; returning to a scale already in the atlas is
	// expected to reuse those slots, so only the first visit requires a
	// rasterization increase.
	seen_scales: [8]f32
	seen_count := 0
	// The baseline capture already rasterized the current scale.
	if seen_count < len(seen_scales) { seen_scales[seen_count] = baseline_scale; seen_count += 1 }
	for scale in ([]f32{1.25, 1.5, 1.75, 1.25, 1.0}) {
		if result := transition_apply_synthetic_scale(&primary, scale); result != .Ok && result != .Suspended {
			fmt.eprintln("dpi_transition: FAIL metric adoption", scale, result)
			pass = false
			break
		}
		first_visit := true
		for index in 0..<seen_count {
			if seen_scales[index] == scale { first_visit = false; break }
		}
		if first_visit && seen_count < len(seen_scales) {
			seen_scales[seen_count] = scale
			seen_count += 1
		}
		capture_path := fmt.tprintf("out/dpi-transition-%.2f.ppm", scale)
		transition_assert_scale_acceptance(
			&primary, baseline_bounds, baseline_scale, scale, base_crop_stats.ink,
			capture_path, first_visit, &pass,
		)
	}

	// Posted WM_DPICHANGED/WM_DISPLAYCHANGE must run the native chrome branch and
	// request a frame even though the monitor scale is unchanged.
	if !transition_poll_completions(&secondary) { pass = false }
	for _ in 0..<4 {
		_ = transition_step(&secondary, u64(sdl3.GetTicksNS()))
		_ = transition_poll_completions(&secondary)
	}
	idle := transition_step(&secondary, u64(sdl3.GetTicksNS()))
	layouts_before := secondary.app.chrome_layouts
	metrics_before := secondary.app.chrome_metrics
	if !transition_post_monitor_messages(&secondary) {
		fmt.eprintln("dpi_transition: FAIL could not post monitor messages")
		pass = false
	} else {
		transition_pump_events(&primary, &secondary)
		after := transition_step(&secondary, u64(sdl3.GetTicksNS()))
		_ = transition_poll_completions(&secondary)
		if idle.presentation != .No_Frame {
			fmt.eprintln("dpi_transition: note chrome window was not idle before the synthetic message",
				idle.presentation)
		}
		if after.presentation != .Ok {
			fmt.eprintln("dpi_transition: FAIL WM_DPICHANGED did not request a chrome redraw",
				after.presentation)
			pass = false
		}
		if secondary.app.chrome_layouts <= layouts_before {
			fmt.eprintln("dpi_transition: FAIL chrome layout did not re-sync after WM_DPICHANGED")
			pass = false
		}
		fmt.printf(
			"dpi_transition posted_messages=WM_DPICHANGED,WM_DISPLAYCHANGE chrome_layouts=%d->%d chrome_metrics=%d->%d header_h=%.1f\n",
			layouts_before, secondary.app.chrome_layouts,
			metrics_before, secondary.app.chrome_metrics, secondary.app.last_header_h,
		)
	}

	// Per-window simultaneous scales: each window keeps its own drawable ratio,
	// display scale, logical geometry, and hit-test mapping.
	primary_bounds, _ := transition_window_bounds(&primary)
	secondary_bounds, secondary_ok := transition_window_bounds(&secondary)
	if !secondary_ok {
		fmt.eprintln("dpi_transition: FAIL chrome window button missing")
		pass = false
	}
	_ = transition_apply_synthetic_scale(&primary, 1.25)
	secondary_pixel_width := f32(WINDOW_LOGICAL_WIDTH)*1.75+0.5
	secondary_pixel_height := f32(WINDOW_LOGICAL_HEIGHT)*1.75+0.5
	_ = host.sdl3_webgpu_application_apply_metrics(
		&secondary.application,
		WINDOW_LOGICAL_WIDTH, WINDOW_LOGICAL_HEIGHT,
		int(secondary_pixel_width), int(secondary_pixel_height),
		1.75, 1.75,
	)
	_ = transition_step(&primary, u64(sdl3.GetTicksNS()))
	_ = transition_step(&secondary, u64(sdl3.GetTicksNS()))
	_ = transition_poll_completions(&primary)
	_ = transition_poll_completions(&secondary)
	primary_runtime, _ := alicorn.hosted_runtime_borrow(&primary.application.hosted)
	secondary_runtime, _ := alicorn.hosted_runtime_borrow(&secondary.application.hosted)
	if primary_runtime.presentation_scale_x != 1.25 || secondary_runtime.presentation_scale_x != 1.75 {
		fmt.eprintf("dpi_transition: FAIL per-window scales primary=%.3f secondary=%.3f\n",
			primary_runtime.presentation_scale_x, secondary_runtime.presentation_scale_x)
		pass = false
	}
	if primary.application.display_scale != 1.25 || secondary.application.display_scale != 1.75 {
		fmt.eprintf("dpi_transition: FAIL per-window display scales primary=%.3f secondary=%.3f\n",
			primary.application.display_scale, secondary.application.display_scale)
		pass = false
	}
	if primary.app.last_dpi != 1.25 || secondary.app.last_dpi != 1.75 {
		fmt.eprintf("dpi_transition: FAIL per-window application scales primary=%.3f secondary=%.3f\n",
			primary.app.last_dpi, secondary.app.last_dpi)
		pass = false
	}
	if p, p_ok := transition_window_bounds(&primary); !p_ok || p != primary_bounds {
		fmt.eprintln("dpi_transition: FAIL primary logical bounds changed across simultaneous scales")
		pass = false
	}
	if s, s_ok := transition_window_bounds(&secondary); !s_ok || s != secondary_bounds {
		fmt.eprintln("dpi_transition: FAIL secondary logical bounds changed across simultaneous scales")
		pass = false
	}
	primary_center_x := primary_bounds.x+primary_bounds.w*0.5
	primary_center_y := primary_bounds.y+primary_bounds.h*0.5
	secondary_center_x := secondary_bounds.x+secondary_bounds.w*0.5
	secondary_center_y := secondary_bounds.y+secondary_bounds.h*0.5
	p_hit, _ := alicorn.hosted_runtime_pointer(&primary.application.hosted, alicorn.Pointer_Event{
		kind=.Move, x=primary_center_x, y=primary_center_y,
	})
	s_hit, _ := alicorn.hosted_runtime_pointer(&secondary.application.hosted, alicorn.Pointer_Event{
		kind=.Move, x=secondary_center_x, y=secondary_center_y,
	})
	if p_hit != primary.app.button || s_hit != secondary.app.button {
		fmt.eprintf("dpi_transition: FAIL per-window hit testing primary=%d secondary=%d\n", p_hit, s_hit)
		pass = false
	}
	fmt.printf(
		"dpi_transition per_window primary scale=%.3f secondary scale=%.3f hit=%d/%d\n",
		primary_runtime.presentation_scale_x, secondary_runtime.presentation_scale_x, p_hit, s_hit,
	)

	if !pass {
		fmt.println("dpi_transition FAIL")
		os.exit(1)
	}
	fmt.println("dpi_transition PASS")
}
