package alicorn_sdl_gpu

// Native SDL3/SDL_GPU host entry point. Subsystems are kept in neighboring
// same-package files so the host wiring stays easy to follow.
import "core:fmt"
import "core:os"
import "core:c"
import "core:strconv"
import "core:strings"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

// Run owns the complete SDL3/SDL_GPU application shell.
// Applications supply their state and callbacks.
Run :: proc(application: Application, smoke := false) {
	native_run_application(application, smoke)
}

native_run_application :: proc(
	application: Application,
	smoke := false,
	macos_titlebar_fixture := false,
	windows_titlebar_fixture := false,
) {
	// Startup attribution origin. Everything below is measurement-only; marker
	// timestamps are elapsed nanoseconds from this point unless named otherwise.
	startup_origin := time.now()
	startup_origin_tick := time.tick_now()
	startup: Native_Startup_Timing
	startup.origin_unix_ns = u64(time.time_to_unix_nano(startup_origin))
	phase_start := startup_origin_tick
	input_debug := macos_titlebar_fixture || windows_titlebar_fixture
	validation_timeout_seconds := 0
	deferred_system_fonts := false
	fallback_probe := false
	for argument in os.args {
		if argument == "--input-debug" { input_debug = true }
		// Shipped default: resolve the system fallback stack during startup,
		// exactly as before the issue #172 phase-2 prototype. The deferred path
		// is opt-in for future pairing and per-need face-mapping work.
		if argument == "--deferred-system-fonts" { deferred_system_fonts = true }
		if argument == "--fallback-probe-after-first-frame" { fallback_probe = true }
		prefix := "--idle-validation-seconds="
		legacy_prefix := "--idle-proof-seconds="
		if strings.has_prefix(argument, legacy_prefix) { prefix = legacy_prefix }
		if strings.has_prefix(argument, prefix) {
			parsed, ok := strconv.parse_int(argument[len(prefix):])
			if ok && parsed > 0 { validation_timeout_seconds = int(parsed) }
		}
	}
	// The probe is measurement-only and exists to observe the deferred load, so
	// it enables the deferred path itself. Without the probe the lazy path is
	// only active when --deferred-system-fonts is passed.
	if fallback_probe { deferred_system_fonts = true }
	when ODIN_OS == .Darwin {
		// SDL disables momentum wheel events by default on macOS. Preserve
		// the trackpad's native inertial scrolling; environment overrides
		// retain SDL's higher-priority opt-out behavior.
		if !sdl3.SetHint(sdl3.HINT_MAC_SCROLL_MOMENTUM, "1") &&
			sdl3.GetHint(sdl3.HINT_MAC_SCROLL_MOMENTUM) == nil {
			fail("SDL_MAC_SCROLL_MOMENTUM hint could not be set")
		}
	}
	if !sdl3.SetHint(sdl3.HINT_IME_IMPLEMENTED_UI, "composition") {
		fail("SDL_IME_IMPLEMENTED_UI hint could not be set")
	}
	configure_platform_activation()
	if !sdl3.Init(sdl3.INIT_VIDEO) { fail("SDL_Init failed") }
	startup.sdl_init_ns = native_startup_elapsed_ns(phase_start)
	defer sdl3.Quit()
	fmt.println("sdl_video_driver", sdl3.GetCurrentVideoDriver())
	linked_sdl_version := sdl3.GetVersion()
	fmt.println(
		"sdl3_version",
		sdl3.VERSIONNUM_MAJOR(linked_sdl_version),
		sdl3.VERSIONNUM_MINOR(linked_sdl_version),
		sdl3.VERSIONNUM_MICRO(linked_sdl_version),
	)
	when ODIN_OS == .Darwin {
		if linked_sdl_version != sdl3.VERSIONNUM(3, 4, 20) {
			fail("macOS requires SDL3 3.4.20")
		}
	}
	title := application.title
	if title == "" { title = "Alicorn application" }
	width := application.width
	if width <= 0 { width = 960 }
	height := application.height
	if height <= 0 { height = 640 }
	title_cstring, title_err := strings.clone_to_cstring(title, context.temp_allocator)
	if title_err != nil { fail("application title allocation failed") }
	if !native_accessibility_prepare_platform() { fail("native accessibility platform preparation failed") }
	// Windows requires AccessKit's subclassing adapter to be installed before
	// the HWND is first shown or focused. run_application_loop builds the initial
	// semantic snapshot and installs the adapter before showing this window.
	phase_start = time.tick_now()
	window := sdl3.CreateWindow(title_cstring, c.int(width), c.int(height), sdl3.WindowFlags{.HIDDEN, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	startup.window_create_ns = native_startup_elapsed_ns(phase_start)
	if window == nil { fail("SDL_CreateWindow failed") }
	defer sdl3.DestroyWindow(window)
	menu_application := application
	native_menu := Native_Menu_Runtime{window=window, application=&menu_application}
	defer native_menu_destroy(&native_menu)
	if !native_menu_prepare(&native_menu) {
		fail("native application menu or integrated title bar setup failed")
	}
	if input_debug {
		fmt.println("sdl_input_debug", "window_flags", sdl3.GetWindowFlags(window))
	}
	metrics: Window_Metrics
	if !read_window_metrics(window, &metrics, native_menu.content_inset_top) { fail("initial application window metrics unavailable") }
	when ODIN_OS == .Darwin {
		if windows_titlebar_fixture { fail("the integrated Windows titlebar fixture is Windows-only") }
		if application.window_decorations == .Content_Title_Bar {
			if application.window_chrome_height <= 0 || application.window_chrome_metrics == nil || application.window_chrome_layout == nil {
				fail("Content_Title_Bar requires a positive window_chrome_height and both chrome callbacks")
			}
			if !native_darwin_titlebar_prepare(&native_menu, application.window_chrome_height) {
				fail("macOS content title bar could not configure the native window")
			}
			if !read_window_metrics(window, &metrics, native_menu.content_inset_top) {
				fail("window metrics unavailable after enabling full-size macOS content")
			}
		}
	} else {
		if macos_titlebar_fixture { fail("the macOS titlebar fixture is macOS-only") }
		when ODIN_OS == .Windows {
			if windows_titlebar_fixture && application.window_decorations != .Integrated_Title_Bar {
				fail("the Windows titlebar fixture requires Integrated_Title_Bar")
			}
		} else {
			if windows_titlebar_fixture { fail("the integrated Windows titlebar fixture is Windows-only") }
		}
		if application.window_decorations == .Content_Title_Bar {
			fail("Content_Title_Bar is currently supported only on macOS")
		}
		if application.window_decorations == .Integrated_Title_Bar &&
			((application.window_chrome_metrics == nil) != (application.window_chrome_layout == nil)) {
			fail("Windows Integrated_Title_Bar requires both window chrome callbacks when either is supplied")
		}
	}
	formats := sdl3.GPUShaderFormat{.SPIRV, .DXIL, .MSL}
	gpu_driver_name: cstring = nil
	when ODIN_OS == .Darwin { gpu_driver_name = "metal" }
	phase_start = time.tick_now()
	device := sdl3.CreateGPUDevice(formats, false, gpu_driver_name)
	startup.gpu_device_create_ns = native_startup_elapsed_ns(phase_start)
	if device == nil { fail("SDL_CreateGPUDevice failed") }
	defer sdl3.DestroyGPUDevice(device)
	selected_driver := sdl3.GetGPUDeviceDriver(device)
	fmt.println("gpu_driver_requested", gpu_driver_name, "gpu_driver_selected", selected_driver)
	when ODIN_OS == .Darwin {
		if selected_driver == nil || string(selected_driver) != "metal" {
			fail("macOS SDL_GPU did not select the requested Metal driver")
		}
	}
	phase_start = time.tick_now()
	if !sdl3.ClaimWindowForGPUDevice(device, window) { fail("SDL_ClaimWindowForGPUDevice failed") }
	startup.gpu_claim_window_ns = native_startup_elapsed_ns(phase_start)
	defer sdl3.ReleaseWindowFromGPUDevice(device, window)
	// The reusable desktop host favors interaction latency. The foundation
	// stress fixture below intentionally uses three frames; ordinary apps use
	// two unless they explicitly opt into throughput-oriented stress behavior.
	if !sdl3.SetGPUAllowedFramesInFlight(device, 2) { fail("SDL_SetGPUAllowedFramesInFlight failed") }
	// The host owns the allocation-stats record used by the startup
	// attribution output. Passing it in does not change allocation behavior.
	startup_allocation_stats: alicorn.Runtime_Allocation_Stats
	phase_start = time.tick_now()
	rt := alicorn.new_runtime(
		alicorn.Rect{0, 0, f32(metrics.logical_width), f32(metrics.logical_height)},
		config=alicorn.Runtime_Config{allocation_stats=&startup_allocation_stats},
	)
	startup.runtime_init_ns = native_startup_elapsed_ns(phase_start)
	defer alicorn.destroy_runtime(&rt)
	phase_start = time.tick_now()
	live_before := rt.allocation_stats.persistent_requested_bytes_live
	if application.on_initialize != nil { application.on_initialize(application.state, &rt) }
	startup.app_init_requested_bytes = rt.allocation_stats.persistent_requested_bytes_live - live_before
	startup.app_init_ns = native_startup_elapsed_ns(phase_start)
	phase_start = time.tick_now()
	live_before = rt.allocation_stats.persistent_requested_bytes_live
	// Shipped default: eager system fallbacks, as before the phase-2 prototype.
	// --deferred-system-fonts (and the measurement-only fallback probe) defers
	// the DirectWrite/optional stack to the first shaping request that no
	// loaded face covers.
	if !native_load_default_fonts(&rt, deferred_system_fonts) {
		fail("application bundled Runa fonts could not be initialized")
	}
	if deferred_system_fonts && !native_arm_deferred_system_fonts(&rt) {
		fail("deferred system font fallback loader could not be armed")
	}
	startup.fonts_requested_bytes = rt.allocation_stats.persistent_requested_bytes_live - live_before
	startup.fonts_ns = native_startup_elapsed_ns(phase_start)
	phase_start = time.tick_now()
	renderers_start := phase_start
	text_renderer, text_ok := native_text_make(device, sdl3.GetGPUSwapchainTextureFormat(device, window), &rt)
	startup.text_renderer_make_ns = native_startup_elapsed_ns(phase_start)
	if !text_ok { fail("application GPU text pipeline initialization failed") }
	defer native_text_destroy(&text_renderer)
	phase_start = time.tick_now()
	when ODIN_OS == .Windows {
		if !native_menu_prepare_gpu(&native_menu, &rt, &text_renderer) {
			fail("integrated title bar GPU text initialization failed")
		}
	}
	startup.chrome_text_make_ns = native_startup_elapsed_ns(phase_start)
	phase_start = time.tick_now()
	surface_renderer, surface_ok := native_surface_make(device, sdl3.GetGPUSwapchainTextureFormat(device, window), &rt)
	startup.surface_renderer_make_ns = native_startup_elapsed_ns(phase_start)
	if !surface_ok { fail("application GPU surface pipeline initialization failed") }
	defer native_surface_destroy(&surface_renderer)
	phase_start = time.tick_now()
	solid_renderer, solid_ok := native_solid_make(device, sdl3.GetGPUSwapchainTextureFormat(device, window), &rt)
	startup.solid_renderer_make_ns = native_startup_elapsed_ns(phase_start)
	if !solid_ok { fail("application solid rectangle pipeline initialization failed") }
	defer native_solid_destroy(&solid_renderer)
	startup.renderers_make_ns = native_startup_elapsed_ns(renderers_start)
	run_application_loop(window, device, &rt, &text_renderer, &surface_renderer, &solid_renderer, &metrics, application, smoke, input_debug, string(selected_driver), validation_timeout_seconds=validation_timeout_seconds, native_menu=&native_menu, startup=startup, startup_origin=startup_origin_tick, fallback_probe=fallback_probe)
}
