package main

// Minimal external plugin-host fixture for Alicorn issue #121.
//
// This is a plain Win32 application: RegisterClassExW + CreateWindowExW create
// the outer host window, and that window hosts one or two Alicorn-powered
// "scope" editors as WS_CHILD windows. Alicorn never creates a top-level
// window here. The parent owns the message loop, the child HWNDs receive
// scoped input, and the shared WebGPU device presents into each child surface.
//
// Run:
//   plugin_host_fixture.exe --self-test
//   plugin_host_fixture.exe --self-test --backend=vulkan --hold-ms=2500
//   plugin_host_fixture.exe                (interactive, two editors)

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import alicorn "alicorn:runtime"
import host_fonts "alicorn:host/fonts"
import plugin "alicorn:host/plugin"
import win "core:sys/windows"


SCOPE_SEGMENTS :: 96
SCOPE_GRID_LINES :: 8
PARENT_CLASS :: "AlicornPluginHostFixture"
PARENT_TITLE :: "Alicorn plugin host acceptance (#121)"

Scope_State :: struct {
	label:       string,
	clicks:      int,
	surface:     alicorn.Node_ID,
	drawn_clicks: int,
	drawn_width: f32,
	drawn_height: f32,
}

Editor_Slot :: struct {
	editor:  plugin.Plugin_Editor,
	state:   Scope_State,
	label:   string,
	created: u64,
	memory_delta: i64,
}

Fixture :: struct {
	instance:       win.HINSTANCE,
	hwnd:           win.HWND,
	host:           plugin.Plugin_Host,
	slots:          [8]^Editor_Slot,
	count:          int,
	running:        bool,
	self_test:      bool,
	hold_ms:        int,
	backend:        plugin.Plugin_Backend,
	steps:          u64,
	presentations:  u64,
	idle_steps:     u64,
	checks_passed:  int,
	checks_failed:  int,
	checks:         [64]string,
	check_results:  [64]bool,
	check_count:    int,
}

@(private)
fixture_instance :: proc() -> win.HINSTANCE {
	return win.HINSTANCE(win.GetModuleHandleW(nil))
}

@(private)
fixture_memory_private :: proc() -> u64 {
	counters: win.PROCESS_MEMORY_COUNTERS_EX
	counters.cb = u32(size_of(win.PROCESS_MEMORY_COUNTERS_EX))
	if win.GetProcessMemoryInfo(
		win.GetCurrentProcess(),
		cast(win.PPROCESS_MEMORY_COUNTERS)&counters,
		counters.cb,
	) == false {
		return 0
	}
	return u64(counters.PrivateUsage)
}

@(private)
fixture_record :: proc(fx: ^Fixture, name: string, passed: bool, detail := "") {
	if fx.check_count >= len(fx.checks) { return }
	fx.checks[fx.check_count] = name
	fx.check_results[fx.check_count] = passed
	fx.check_count += 1
	if passed {
		fx.checks_passed += 1
		fmt.printf("[plugin-fixture] PASS %s%s%s\n", name, " " if len(detail) > 0 else "", detail)
	} else {
		fx.checks_failed += 1
		fmt.printf("[plugin-fixture] FAIL %s%s%s\n", name, " " if len(detail) > 0 else "", detail)
	}
}

// ---------------------------------------------------------------------------
// Application scene. Each editor owns one of these states; the callbacks run
// on that editor's UI thread with that editor's Hosted_Runtime.

@(private)
scope_on_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	_ = state
	if !host_fonts.load_default_fonts(rt) {
		fmt.eprintln("[plugin-fixture] default font seeding failed")
	}
}

@(private)
scope_render :: proc(state: rawptr, ctx: ^alicorn.UI, logical_width, logical_height: int, dpi_scale: f32) {
	app := cast(^Scope_State)state
	if ctx == nil || app == nil { return }
	root := alicorn.container_begin(
		ctx, .Root, label="scope-root", key="scope-root",
		style=alicorn.layout_style(.Column, grow=1, padding=14, gap=10, clip=true),
	)
	if root == 0 { return }
	heading := alicorn.DEFAULT_TEXT_STYLE
	heading.font_size = 18
	_ = alicorn.text(ctx, app.label, key="scope-title", text_style=heading)
	_ = alicorn.text(
		ctx,
		fmt.tprintf("Pings: %d   DPI: %.2f   Pane: %dx%d", app.clicks, dpi_scale, logical_width, logical_height),
		key="scope-status",
	)
	button_style := alicorn.layout_style(.Row, width=150, height=30)
	if alicorn.button(ctx, fmt.tprintf("Ping (%d)", app.clicks), key="scope-ping", style=button_style) {
		app.clicks += 1
	}
	panel_style := alicorn.layout_style(.Column, grow=1, height=-1, padding=8, clip=true)
	if alicorn.container_begin(
		ctx, .Container, label="scope-trace-panel", key="scope-trace-panel",
		style=panel_style,
		color=alicorn.Color{0.043, 0.071, 0.125, 1},
	) != 0 {
		app.surface = alicorn.gpu_geometry_surface(
			ctx,
			fmt.tprintf("%s-trace", app.label),
			alicorn.layout_style(grow=1, width=-1, height=-1),
			dpi_scale,
		)
		alicorn.container_end(ctx)
	}
	_ = alicorn.text(ctx, "Embedded WS_CHILD surface owned by the external host", key="scope-foot")
	alicorn.container_end(ctx)
}

@(private)
scope_after_frame :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Scope_State)state
	if app == nil || app.surface == 0 { return }
	surface, ok := alicorn.gpu_surface_context(rt, app.surface)
	if !ok || surface.logical_bounds.w < 2 || surface.logical_bounds.h < 2 { return }
	width := surface.logical_bounds.w
	height := surface.logical_bounds.h
	size_changed := width != app.drawn_width || height != app.drawn_height
	content_changed := app.drawn_clicks != app.clicks
	if !size_changed && !content_changed { return }

	segments: [SCOPE_SEGMENTS+24]alicorn.GPU_Surface_Line_Segment
	count := 0
	grid := alicorn.Color{0.16, 0.22, 0.31, 0.75}
	for guide in 0..=SCOPE_GRID_LINES {
		x := width * f32(guide) / SCOPE_GRID_LINES
		segments[count] = alicorn.GPU_Surface_Line_Segment{
			start={x, 0}, end={x, height}, thickness=1, color=grid,
		}
		count += 1
	}
	phase := f32(app.clicks) * 0.42
	wave := alicorn.Color{0.26, 0.86, 0.98, 1}
	previous := alicorn.GPU_Surface_Point{}
	for point in 0..=SCOPE_SEGMENTS {
		x := width * f32(point) / SCOPE_SEGMENTS
		normalized := f32(point) / SCOPE_SEGMENTS
		angle := normalized * 6.2831853 * 2 + phase
		y := height * (0.5 - 0.31*math.sin(angle) - 0.10*math.sin(angle*2.7))
		current := alicorn.GPU_Surface_Point{x, y}
		if point > 0 {
			segments[count] = alicorn.GPU_Surface_Line_Segment{
				start=previous, end=current, thickness=2, color=wave,
			}
			count += 1
		}
		previous = current
	}
	circles := [1]alicorn.GPU_Surface_Filled_Circle{{
		center=previous, radius=3.5, color=alicorn.Color{1, 0.74, 0.28, 1},
	}}
	if alicorn.gpu_surface_update_geometry(rt, app.surface, segments[:count], circles[:]) {
		app.drawn_clicks = app.clicks
		app.drawn_width = width
		app.drawn_height = height
	}
}

// ---------------------------------------------------------------------------
// Parent window and editor slots.

@(private)
fixture_dpi_scale :: proc(fx: ^Fixture) -> f32 {
	dpi := win.GetDpiForWindow(fx.hwnd)
	if dpi == 0 { return 1 }
	return f32(dpi) / 96
}

@(private)
fixture_layout :: proc(fx: ^Fixture) {
	if fx == nil || fx.hwnd == nil { return }
	rect: win.RECT
	if win.GetClientRect(fx.hwnd, &rect) == false { return }
	width := int(rect.right - rect.left)
	height := int(rect.bottom - rect.top)
	active := 0
	for slot in fx.slots { if slot != nil { active += 1 } }
	if active == 0 { return }
	gap := 8
	pane_width := (width - gap*(active-1)) / active
	if pane_width < 32 { pane_width = 32 }
	scale := fixture_dpi_scale(fx)
	index := 0
	for slot in fx.slots {
		if slot == nil { continue }
		x := index * (pane_width + gap)
		hwnd := win.HWND(plugin.plugin_editor_native_window(&slot.editor))
		if hwnd != nil {
			_ = win.MoveWindow(hwnd, win.INT(x), 0, win.INT(pane_width), win.INT(height), true)
		}
		_ = plugin.plugin_editor_resize_pixels(&slot.editor, pane_width, height, scale)
		index += 1
	}
}

@(private)
fixture_add_editor :: proc(fx: ^Fixture, label: string) -> ^Editor_Slot {
	if fx == nil || fx.count >= len(fx.slots) { return nil }
	index := -1
	for slot, i in fx.slots {
		if slot == nil { index = i; break }
	}
	if index < 0 { return nil }
	memory_before := fixture_memory_private()
	slot := new(Editor_Slot)
	if slot == nil { return nil }
	slot.label = strings.clone(label)
	slot.state.label = slot.label
	slot.state.drawn_clicks = -1
	slot.created = plugin.plugin_monotonic_now_ns()
	rect: win.RECT
	_ = win.GetClientRect(fx.hwnd, &rect)
	width := int(rect.right - rect.left)
	height := int(rect.bottom - rect.top)
	active := fx.count + 1
	pane_width := max(320, (width - 8*(active-1)) / active)
	scale := fixture_dpi_scale(fx)
	config := plugin.plugin_editor_config_clear()
	config.parent = plugin.Plugin_Native_Parent{
		kind=.Windows_HWND,
		window=rawptr(fx.hwnd),
		display=rawptr(fx.instance),
	}
	config.logical_width = pane_width
	config.logical_height = max(240, height)
	config.dpi_scale = scale
	config.visible = true
	config.debug_name = fmt.tprintf("Alicorn plugin editor %s", slot.label)
	config.hosted.state = rawptr(&slot.state)
	config.hosted.render = scope_render
	config.hosted.on_initialize = scope_on_initialize
	config.hosted.on_after_frame = scope_after_frame
	status := plugin.plugin_host_create_editor(&fx.host, &slot.editor, config)
	if status != .Ok {
		fmt.eprintf("[plugin-fixture] create editor '%s' failed: %s\n", slot.label, plugin.plugin_status_string(status))
		free(slot)
		return nil
	}
	fx.slots[index] = slot
	fx.count += 1
	fixture_layout(fx)
	if !fixture_wait_for_frame(fx, slot, 2_000_000_000) {
		fmt.eprintln("[plugin-fixture] editor did not present its first frame")
	}
	memory_after := fixture_memory_private()
	slot.memory_delta = i64(memory_after) - i64(memory_before)
	metrics, _ := plugin.plugin_editor_metrics(&slot.editor)
	fmt.printf(
		"[plugin-fixture] created %s hwnd=%p logical=%dx%d pixel=%dx%d dpi=%.2f memory_delta=%d bytes configure=%d\n",
		slot.label,
		plugin.plugin_editor_native_window(&slot.editor),
		metrics.logical_width, metrics.logical_height,
		metrics.pixel_width, metrics.pixel_height, metrics.dpi_scale,
		slot.memory_delta, metrics.configure_count,
	)
	return slot
}

@(private)
fixture_remove_editor :: proc(fx: ^Fixture, slot: ^Editor_Slot) -> bool {
	if fx == nil || slot == nil { return false }
	for candidate, index in fx.slots {
		if candidate != slot { continue }
		status := plugin.plugin_host_destroy_editor(&fx.host, &slot.editor)
		fx.slots[index] = nil
		fx.count -= 1
		fixture_layout(fx)
		if status != .Ok {
			fmt.eprintf("[plugin-fixture] destroy editor failed: %s\n", plugin.plugin_status_string(status))
			return false
		}
		delete(slot.label)
		free(slot)
		return true
	}
	return false
}

@(private)
fixture_metrics :: proc(slot: ^Editor_Slot) -> plugin.Plugin_Editor_Metrics {
	metrics, _ := plugin.plugin_editor_metrics(&slot.editor)
	return metrics
}

// ---------------------------------------------------------------------------
// Host loop.

@(private)
fixture_drain_messages :: proc(fx: ^Fixture) -> bool {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) != false {
		if msg.message == win.WM_QUIT {
			fx.running = false
			return false
		}
		_ = win.TranslateMessage(&msg)
		_ = win.DispatchMessageW(&msg)
	}
	return true
}

@(private)
fixture_wait_timeout_ms :: proc(fx: ^Fixture, now_ns: u64, result: plugin.Plugin_Step_Result, remaining_ms: int) -> int {
	if result.has_more_work { return 0 }
	if plugin.plugin_host_has_in_flight(&fx.host) { return 1 }
	if result.next_wake_ns != 0 {
		if result.next_wake_ns <= now_ns { return 0 }
		until := int((result.next_wake_ns - now_ns + 999_999) / 1_000_000)
		if until < remaining_ms { return until }
	}
	if remaining_ms < 0 { return 0 }
	return remaining_ms
}

@(private)
fixture_loop :: proc(fx: ^Fixture, duration_ns: u64, stop_on_frame := false, slot: ^Editor_Slot = nil) -> (frames: int, steps: int) {
	deadline := plugin.plugin_monotonic_now_ns() + duration_ns
	target_presentations := u64(0)
	if stop_on_frame && slot != nil { target_presentations = fixture_metrics(slot).presentations + 1 }
	for fx.running {
		if !fixture_drain_messages(fx) { break }
		now := plugin.plugin_monotonic_now_ns()
		if now >= deadline { break }
		result := plugin.plugin_host_step(&fx.host, now)
		fx.steps += 1
		steps += 1
		fx.presentations += u64(result.presentations)
		frames += result.presentations
		if result.status == .Device_Lost {
			if status := plugin.plugin_host_recover(&fx.host, now); status != .Ok {
				fmt.eprintf("[plugin-fixture] device recovery failed: %s\n", plugin.plugin_status_string(status))
				fx.running = false
				break
			}
			continue
		}
		if stop_on_frame && slot != nil && fixture_metrics(slot).presentations >= target_presentations {
			plugin.plugin_host_poll(&fx.host)
			return
		}
		remaining_ns := u64(0)
		if deadline > now { remaining_ns = deadline - now }
		remaining_ms := int((remaining_ns + 999_999) / 1_000_000)
		timeout := fixture_wait_timeout_ms(fx, now, result, remaining_ms)
		if timeout > 0 {
			_ = win.MsgWaitForMultipleObjects(0, nil, false, win.DWORD(timeout), win.QS_ALLINPUT)
		}
		plugin.plugin_host_poll(&fx.host)
	}
	return
}

@(private)
fixture_wait_for_frame :: proc(fx: ^Fixture, slot: ^Editor_Slot, timeout_ns: u64) -> bool {
	deadline := plugin.plugin_monotonic_now_ns() + timeout_ns
	before := fixture_metrics(slot).presentations
	for fx.running && plugin.plugin_monotonic_now_ns() < deadline {
		fixture_loop(fx, 10_000_000)
		if fixture_metrics(slot).presentations > before { return true }
	}
	return false
}

@(private)
fixture_send_key :: proc(slot: ^Editor_Slot, vk: u32) {
	hwnd := win.HWND(plugin.plugin_editor_native_window(&slot.editor))
	if hwnd == nil { return }
	_ = win.SendMessageW(hwnd, win.WM_KEYDOWN, win.WPARAM(vk), 0)
	_ = win.SendMessageW(hwnd, win.WM_KEYUP, win.WPARAM(vk), 0)
}

// ---------------------------------------------------------------------------
// Parent window procedure.

@(private)
fixture_parent_wndproc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = runtime.default_context()
	fx := cast(^Fixture)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	if fx == nil { return win.DefWindowProcW(hwnd, msg, wparam, lparam) }
	switch msg {
	case win.WM_SIZE:
		fixture_layout(fx)
		return 0
	case win.WM_DESTROY:
		fx.running = false
		win.PostQuitMessage(0)
		return 0
	case win.WM_KEYDOWN:
		ctrl := (u16(win.GetAsyncKeyState(win.VK_CONTROL)) & 0x8000) != 0
		if ctrl {
			switch u32(wparam) {
			case u32(win.VK_N):
				_ = fixture_add_editor(fx, fmt.tprintf("Scope %c", 'A' + rune(fx.count)))
				return 0
			case u32(win.VK_W):
				if fx.count > 0 {
					for i := len(fx.slots)-1; i >= 0; i -= 1 {
						if fx.slots[i] != nil { _ = fixture_remove_editor(fx, fx.slots[i]); break }
					}
				}
				return 0
			case u32(win.VK_H):
				if fx.count > 0 {
					slot := fx.slots[0]
					for candidate in fx.slots { if candidate != nil { slot = candidate; break } }
					metrics := fixture_metrics(slot)
					if metrics.visible {
						_ = plugin.plugin_editor_hide(&slot.editor)
					} else {
						_ = plugin.plugin_editor_show(&slot.editor)
					}
				}
				return 0
			case u32(win.VK_L):
				_ = plugin.plugin_host_simulate_device_loss(&fx.host)
				return 0
			}
		}
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private)
fixture_register_parent :: proc(fx: ^Fixture) -> bool {
	class_name := win.utf8_to_utf16(PARENT_CLASS, context.temp_allocator)
	if class_name == nil { return false }
	wc := win.WNDCLASSEXW{
		cbSize=u32(size_of(win.WNDCLASSEXW)),
		style=win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc=fixture_parent_wndproc,
		hInstance=fx.instance,
		hCursor=win.LoadCursorW(nil, cstring16(win.MAKEINTRESOURCEW(32512))),
		hbrBackground=win.CreateSolidBrush(win.RGB(21, 24, 31)),
		lpszClassName=cstring16(&class_name[0]),
	}
	return win.RegisterClassExW(&wc) != 0
}

@(private)
fixture_create_parent :: proc(fx: ^Fixture, width, height: int, visible: bool) -> bool {
	class_name := win.utf8_to_utf16(PARENT_CLASS, context.temp_allocator)
	title := win.utf8_to_utf16(PARENT_TITLE, context.temp_allocator)
	if class_name == nil || title == nil { return false }
	style := win.WS_OVERLAPPEDWINDOW
	rect := win.RECT{0, 0, win.LONG(width), win.LONG(height)}
	_ = win.AdjustWindowRectExForDpi(&rect, style, false, 0, 96)
	hwnd := win.CreateWindowExW(
		0,
		cstring16(&class_name[0]),
		cstring16(&title[0]),
		style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT,
		win.INT(rect.right-rect.left), win.INT(rect.bottom-rect.top),
		nil, nil, fx.instance, nil,
	)
	if hwnd == nil { return false }
	fx.hwnd = hwnd
	win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(rawptr(fx))))
	if visible {
		_ = win.ShowWindow(hwnd, win.SW_SHOW)
		_ = win.UpdateWindow(hwnd)
		_ = win.SetForegroundWindow(hwnd)
	}
	return true
}

@(private)
fixture_print_screenshot_marker :: proc(fx: ^Fixture) {
	// Give the compositor a stable, unobscured frame for an external capture.
	_ = win.ShowWindow(fx.hwnd, win.SW_RESTORE)
	_ = win.BringWindowToTop(fx.hwnd)
	_ = win.SetForegroundWindow(fx.hwnd)
	_ = win.SetWindowPos(
		fx.hwnd, win.HWND_TOPMOST, 0, 0, 0, 0,
		win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE,
	)
	_ = win.SetWindowPos(
		fx.hwnd, win.HWND_NOTOPMOST, 0, 0, 0, 0,
		win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE,
	)
	rect: win.RECT
	if win.GetWindowRect(fx.hwnd, &rect) == false { return }
	client: win.RECT
	if win.GetClientRect(fx.hwnd, &client) == false { return }
	origin := win.POINT{x=0, y=0}
	if win.ClientToScreen(fx.hwnd, &origin) == false { return }
	fmt.printf(
		"SCREENSHOT_READY hwnd=%p left=%d top=%d right=%d bottom=%d client_left=%d client_top=%d client_right=%d client_bottom=%d\n",
		rawptr(fx.hwnd), rect.left, rect.top, rect.right, rect.bottom,
		origin.x, origin.y, origin.x+client.right, origin.y+client.bottom,
	)
}

// ---------------------------------------------------------------------------
// Self-test.

@(private)
fixture_self_test :: proc(fx: ^Fixture) -> bool {
	fmt.println("[plugin-fixture] self-test begin")
	plugin_config := plugin.plugin_host_config_clear()
	plugin_config.backend = fx.backend
	if status := plugin.plugin_host_init(&fx.host, plugin_config); status != .Ok {
		fmt.eprintf("[plugin-fixture] plugin host init failed: %s\n", plugin.plugin_status_string(status))
		return false
	}
	defer _ = plugin.plugin_host_destroy(&fx.host)
	fx.running = true

	slot_a := fixture_add_editor(fx, "Scope A")
	fixture_record(fx, "editor-a-created-and-presented", slot_a != nil &&
		fixture_metrics(slot_a).presentations > 0)
	if slot_a == nil { return false }

	// Settled idle window: one explicit step at the beginning and one at the
	// end, no submissions, no immediate-work spin.
	fixture_loop(fx, 150_000_000)
	before := fixture_metrics(slot_a).presentations
	steps_before := fx.steps
	fixture_loop(fx, 750_000_000)
	idle_frames := fixture_metrics(slot_a).presentations - before
	idle_steps := fx.steps - steps_before
	fixture_record(fx, "settled-idle-zero-presentations", idle_frames == 0,
		fmt.tprintf("frames=%d steps=%d", idle_frames, idle_steps))

	// Resize through the host-owned child geometry.
	resized_before := fixture_metrics(slot_a).presentations
	_ = plugin.plugin_editor_resize(&slot_a.editor, 520, 360, 1.0)
	fixture_loop(fx, 400_000_000)
	resized := fixture_metrics(slot_a)
	fixture_record(fx, "resize-adopts-drawable",
		resized.pixel_width == 520 && resized.pixel_height == 360 &&
		resized.presentations > resized_before,
		fmt.tprintf("pixel=%dx%d presentations=%d", resized.pixel_width, resized.pixel_height,
			resized.presentations-resized_before))

	// Hide/show. Hidden editors keep model state but present nothing.
	hidden_before := fixture_metrics(slot_a).presentations
	_ = plugin.plugin_editor_hide(&slot_a.editor)
	fixture_loop(fx, 500_000_000)
	hidden_frames := fixture_metrics(slot_a).presentations - hidden_before
	fixture_record(fx, "hidden-editor-zero-presentations", hidden_frames == 0,
		fmt.tprintf("frames=%d", hidden_frames))
	_ = plugin.plugin_editor_show(&slot_a.editor)
	fixture_record(fx, "show-restores-presentation", fixture_wait_for_frame(fx, slot_a, 2_000_000_000))

	// A DPI-scale change adopts both the logical and drawable size.
	_ = plugin.plugin_editor_resize(&slot_a.editor, 640, 400, 1.5)
	fixture_loop(fx, 400_000_000)
	dpi_metrics := fixture_metrics(slot_a)
	fixture_record(fx, "dpi-resize-adopts-scale",
		dpi_metrics.pixel_width == 960 && dpi_metrics.pixel_height == 600 &&
		dpi_metrics.logical_width == 640 && dpi_metrics.logical_height == 400 &&
		dpi_metrics.dpi_scale == 1.5,
		fmt.tprintf("logical=%dx%d pixel=%dx%d dpi=%.2f",
			dpi_metrics.logical_width, dpi_metrics.logical_height,
			dpi_metrics.pixel_width, dpi_metrics.pixel_height, dpi_metrics.dpi_scale))
	fixture_layout(fx)
	fixture_loop(fx, 120_000_000)

	// Keyboard input is scoped to the child window that received it.
	clicks_before := slot_a.state.clicks
	fixture_send_key(slot_a, u32(win.VK_TAB))
	fixture_send_key(slot_a, u32(win.VK_SPACE))
	fixture_loop(fx, 200_000_000)
	fixture_record(fx, "scoped-keyboard-activates-editor-a",
		slot_a.state.clicks == clicks_before+1,
		fmt.tprintf("clicks=%d->%d", clicks_before, slot_a.state.clicks))

	slot_b := fixture_add_editor(fx, "Scope B")
	fixture_record(fx, "editor-b-created-and-presented",
		slot_b != nil && fixture_metrics(slot_b).presentations > 0)
	if slot_b == nil { return false }
	fixture_record(fx, "two-independent-editors-coexist", fx.count == 2)

	// A click in B must not touch A.
	a_clicks := slot_a.state.clicks
	b_clicks := slot_b.state.clicks
	fixture_send_key(slot_b, u32(win.VK_TAB))
	fixture_send_key(slot_b, u32(win.VK_SPACE))
	fixture_loop(fx, 200_000_000)
	fixture_record(fx, "input-isolation-between-instances",
		slot_b.state.clicks == b_clicks+1 && slot_a.state.clicks == a_clicks,
		fmt.tprintf("a=%d->%d b=%d->%d", a_clicks, slot_a.state.clicks, b_clicks, slot_b.state.clicks))
	for slot in fx.slots {
		if slot == nil { continue }
		if timing, ok := plugin.plugin_editor_timing_summary(&slot.editor); ok {
			fmt.printf(
				"[plugin-fixture] dual-latency label=%s samples=%d p50_us=%.1f p95_us=%.1f max_us=%.1f\n",
				slot.label, timing.samples,
				f64(timing.p50_ns)/1000.0, f64(timing.p95_ns)/1000.0, f64(timing.max_ns)/1000.0,
			)
		}
	}

	if fx.hold_ms > 0 {
		fixture_print_screenshot_marker(fx)
		fixture_loop(fx, u64(fx.hold_ms)*1_000_000)
	}

	// Close A; B must keep presenting and retain its state.
	fixture_record(fx, "close-a-succeeds", fixture_remove_editor(fx, slot_a))
	b_present_before := fixture_metrics(slot_b).presentations
	b_state := slot_b.state.clicks
	_ = plugin.plugin_editor_request_presentation(&slot_b.editor)
	fixture_loop(fx, 300_000_000)
	fixture_record(fx, "b-survives-a-close",
		slot_b.state.clicks == b_state && fixture_metrics(slot_b).presentations > b_present_before,
		fmt.tprintf("frames=%d", fixture_metrics(slot_b).presentations-b_present_before))

	// Repeated open/close of the same editor slot.
	reopen_ok := true
	for round in 0..<2 {
		reopened := fixture_add_editor(fx, fmt.tprintf("Reopen %d", round))
		if reopened == nil {
			reopen_ok = false
			break
		}
		if fixture_metrics(reopened).presentations == 0 { reopen_ok = false }
		if !fixture_remove_editor(fx, reopened) { reopen_ok = false; break }
	}
	fixture_record(fx, "repeated-open-close", reopen_ok && fx.count == 1)

	// Device-loss simulation: presenters are detached and rebuilt, the
	// editor HWND and retained Runtime survive, and the next frame presents.
	clicks_before_loss := slot_b.state.clicks
	fixture_record(fx, "device-loss-injection", plugin.plugin_host_simulate_device_loss(&fx.host) == .Ok)
	loss_before := fixture_metrics(slot_b).presentations
	fixture_loop(fx, 1_000_000_000)
	loss_after := fixture_metrics(slot_b)
	fixture_record(fx, "device-loss-recovery-presents",
		!plugin.plugin_host_device_lost(&fx.host) && loss_after.presentations > loss_before,
		fmt.tprintf("frames=%d", loss_after.presentations-loss_before))
	fixture_record(fx, "device-loss-preserves-retained-state",
		slot_b.state.clicks == clicks_before_loss,
		fmt.tprintf("clicks=%d", slot_b.state.clicks))

	// Final idle after recovery.
	fixture_loop(fx, 150_000_000)
	settled_before := fixture_metrics(slot_b).presentations
	fixture_loop(fx, 500_000_000)
	settled_frames := fixture_metrics(slot_b).presentations - settled_before
	fixture_record(fx, "post-recovery-settled-idle", settled_frames == 0,
		fmt.tprintf("frames=%d", settled_frames))

	// Metrics summary for the validation record.
	final := fixture_metrics(slot_b)
	slot_memory := i64(0)
	for slot in fx.slots { if slot != nil { slot_memory += slot.memory_delta } }
	fmt.printf(
		"[plugin-fixture] metrics backend=%v steps=%d presentations=%d editors=%d private_delta_total=%d bytes last_configure_ns=%d\n",
		fx.backend, fx.steps, fx.presentations, fx.count, slot_memory, final.configure_last_ns,
	)
	for slot in fx.slots {
		if slot == nil { continue }
		metrics := fixture_metrics(slot)
		timing, timing_ok := plugin.plugin_editor_timing_summary(&slot.editor)
		fmt.printf(
			"[plugin-fixture] instance label=%s frames_built=%d presentations=%d configure=%d logical=%dx%d pixel=%dx%d dpi=%.2f memory_delta=%d\n",
			slot.label, metrics.frames_built, metrics.presentations, metrics.configure_count,
			metrics.logical_width, metrics.logical_height, metrics.pixel_width, metrics.pixel_height,
			metrics.dpi_scale, slot.memory_delta,
		)
		if timing_ok {
			fmt.printf(
				"[plugin-fixture] latency label=%s samples=%d step_to_present_p50_us=%.1f p95_us=%.1f max_us=%.1f\n",
				slot.label, timing.samples,
				f64(timing.p50_ns)/1000.0, f64(timing.p95_ns)/1000.0, f64(timing.max_ns)/1000.0,
			)
		}
	}

	// Teardown while editors are live.
	for slot in fx.slots { if slot != nil { _ = fixture_remove_editor(fx, slot) } }
	fixture_record(fx, "teardown-clean", fx.count == 0)
	fmt.printf("[plugin-fixture] self-test end passed=%d failed=%d\n", fx.checks_passed, fx.checks_failed)
	return fx.checks_failed == 0
}

// ---------------------------------------------------------------------------

@(private)
fixture_interactive :: proc(fx: ^Fixture) -> bool {
	plugin_config := plugin.plugin_host_config_clear()
	plugin_config.backend = fx.backend
	if status := plugin.plugin_host_init(&fx.host, plugin_config); status != .Ok {
		fmt.eprintf("[plugin-fixture] plugin host init failed: %s\n", plugin.plugin_status_string(status))
		return false
	}
	defer _ = plugin.plugin_host_destroy(&fx.host)
	fx.running = true
	_ = fixture_add_editor(fx, "Scope A")
	_ = fixture_add_editor(fx, "Scope B")
	fmt.println("[plugin-fixture] Ctrl+N new editor, Ctrl+W close editor, Ctrl+H hide/show, Ctrl+L simulate device loss")
	for fx.running {
		fixture_loop(fx, 20_000_000)
	}
	for slot in fx.slots { if slot != nil { _ = fixture_remove_editor(fx, slot) } }
	return true
}

main :: proc() {
	fx := Fixture{instance=fixture_instance(), backend=.D3D12}
	fx.self_test = false
	for argument in os.args {
		if argument == "--self-test" { fx.self_test = true }
		else if strings.has_prefix(argument, "--backend=") {
			value := argument[len("--backend="):]
			switch value {
			case "d3d12": fx.backend = .D3D12
			case "vulkan": fx.backend = .Vulkan
			case "d3d11": fx.backend = .D3D11
			case: fmt.eprintf("[plugin-fixture] unknown backend %q\n", value)
			}
		} else if strings.has_prefix(argument, "--hold-ms=") {
			if value, ok := strconv.parse_int(argument[len("--hold-ms="):], 10); ok { fx.hold_ms = value }
		}
	}
	if !fixture_register_parent(&fx) {
		fmt.eprintln("[plugin-fixture] parent class registration failed")
		os.exit(2)
	}
	if !fixture_create_parent(&fx, 1120, 680, true) {
		fmt.eprintln("[plugin-fixture] parent window creation failed")
		os.exit(2)
	}
	ok := false
	if fx.self_test {
		ok = fixture_self_test(&fx)
	} else {
		ok = fixture_interactive(&fx)
	}
	if fx.hwnd != nil { _ = win.DestroyWindow(fx.hwnd) }
	if !ok { os.exit(1) }
}
