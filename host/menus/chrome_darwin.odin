#+build darwin

package host_menus

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:math"
import NS "vendor:darwin/AppKit"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

// macOS full-size-content coordination for Content_Title_Bar. AppKit keeps the
// native traffic lights; Alicorn renders content beneath them and declares the
// interactive/drag regions that the SDL hit-test callback consumes. This is a
// compile-checked port of native/sdl_gpu's titlebar_darwin.odin; it has not been
// exercised on a physical Mac in this slice.

Darwin_Titlebar_Gesture_Owner :: enum u8 { None, Client, Alicorn, Native_Control, Window }

DARWIN_TITLEBAR_POINTER_SAMPLE_CAPACITY :: 64

// SDL invokes the Cocoa hit-test callback before it queues the matching SDL
// pointer event, and during a window drag the SDL event can carry a stale
// location. Native macOS therefore pairs each hit-test point with the incoming
// event. The hosted port keeps the same sample ring so drag distance and region
// ownership do not drift on a physical Mac.
Darwin_Titlebar_Pointer_Samples :: struct {
	points:  [DARWIN_TITLEBAR_POINTER_SAMPLE_CAPACITY]sdl3.Point,
	buttons: [DARWIN_TITLEBAR_POINTER_SAMPLE_CAPACITY]sdl3.MouseButtonFlags,
	head:    int,
	count:   int,
}

Darwin_Titlebar_Geometry :: struct {
	header:                alicorn.Rect,
	native_controls:       [3]alicorn.Rect,
	native_control_count:  int,
	interactive:           [alicorn.WINDOW_CHROME_REGION_CAPACITY]alicorn.Rect,
	interactive_count:     int,
	drag_regions:          [alicorn.WINDOW_CHROME_REGION_CAPACITY]alicorn.Rect,
	drag_region_count:     int,
}

Darwin_Titlebar_State :: struct {
	active:                bool,
	header_height:         f32,
	geometry:              Darwin_Titlebar_Geometry,
	metrics:               alicorn.Window_Chrome_Metrics,
	metrics_valid:         bool,
	metrics_delivered:     bool,
	gesture_owner:         Darwin_Titlebar_Gesture_Owner,
	hit_test_calls:        u64,
	draggable_calls:       u64,
	style_reapplies:       u64,
	pointer_samples:       Darwin_Titlebar_Pointer_Samples,
	last_sdl_pointer_point: sdl3.Point,
	last_sdl_pointer_valid: bool,
}

darwin_titlebar_pointer_sample_push :: proc(
	samples: ^Darwin_Titlebar_Pointer_Samples,
	point: sdl3.Point,
	buttons: sdl3.MouseButtonFlags,
) {
	if samples == nil || samples.count >= len(samples.points) { return }
	index := (samples.head+samples.count) % len(samples.points)
	samples.points[index] = point
	samples.buttons[index] = buttons
	samples.count += 1
}

darwin_titlebar_pointer_sample_pop_with_buttons :: proc(
	samples: ^Darwin_Titlebar_Pointer_Samples,
) -> (point: sdl3.Point, buttons: sdl3.MouseButtonFlags, ok: bool) {
	if samples == nil || samples.count <= 0 { return }
	point = samples.points[samples.head]
	buttons = samples.buttons[samples.head]
	samples.head = (samples.head+1) % len(samples.points)
	samples.count -= 1
	ok = true
	return
}

darwin_titlebar_pointer_sample_pop :: proc(samples: ^Darwin_Titlebar_Pointer_Samples) -> (point: sdl3.Point, ok: bool) {
	point, _, ok = darwin_titlebar_pointer_sample_pop_with_buttons(samples)
	return
}

darwin_titlebar_gesture_cancel :: proc(owner: ^Darwin_Titlebar_Gesture_Owner) {
	if owner != nil { owner^ = .None }
}

darwin_titlebar_consume_hit_test_sample :: proc(
	samples: ^Darwin_Titlebar_Pointer_Samples,
	owner: ^Darwin_Titlebar_Gesture_Owner,
) -> bool {
	_, buttons, ok := darwin_titlebar_pointer_sample_pop_with_buttons(samples)
	if ok && !(sdl3.MouseButtonFlag.LEFT in buttons) {
		// Cocoa can consume mouse-up while performing its window drag. The app
		// must still release its latched gesture owner without SDL's up event.
		darwin_titlebar_gesture_cancel(owner)
	}
	return ok
}

// SDL queues the corresponding pointer event after invoking Cocoa's hit-test
// callback, but an initial hover callback can have no SDL event. For press,
// drag, and release events, match by the native left-button snapshot and drop
// any earlier unpaired hover samples. This preserves the actual drag distance.
darwin_titlebar_pointer_sample_pop_matching :: proc(
	samples: ^Darwin_Titlebar_Pointer_Samples,
	left_down: bool,
) -> (point: sdl3.Point, ok: bool) {
	if samples == nil { return }
	for samples.count > 0 {
		index := samples.head
		point = samples.points[index]
		buttons := sdl3.MouseButtonFlag.LEFT in samples.buttons[index]
		samples.head = (samples.head+1) % len(samples.points)
		samples.count -= 1
		if buttons == left_down {
			ok = true
			return
		}
	}
	return
}

darwin_titlebar_pointer_use_hit_test_point :: proc(
	pointer: alicorn.Pointer_Event,
	point: sdl3.Point,
	point_valid: bool,
) -> alicorn.Pointer_Event {
	result := pointer
	if point_valid {
		result.x = f32(point[0])
		result.y = f32(point[1])
	}
	return result
}

darwin_titlebar_translate_pointer :: proc(
	adapter: ^Native_Menu_Adapter,
	pointer: alicorn.Pointer_Event,
	event: sdl3.Event,
) -> alicorn.Pointer_Event {
	if adapter == nil || adapter.platform_data == nil { return pointer }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return pointer }
	left_down := false
	match_buttons := true
	if event.type == .MOUSE_MOTION {
		left_down = sdl3.MouseButtonFlag.LEFT in event.motion.state
	} else if event.type == .MOUSE_BUTTON_DOWN {
		left_down = event.button.button == sdl3.BUTTON_LEFT
	} else if event.type != .MOUSE_BUTTON_UP {
		match_buttons = false
	}
	point, found := darwin_titlebar_pointer_sample_pop_matching(&state.titlebar.pointer_samples, left_down)
	if !match_buttons { point, found = darwin_titlebar_pointer_sample_pop(&state.titlebar.pointer_samples) }
	if !found {
		point = state.titlebar.last_sdl_pointer_point
		found = state.titlebar.last_sdl_pointer_valid
	}
	return darwin_titlebar_pointer_use_hit_test_point(pointer, point, found)
}

native_menu_adapter_translate_pointer :: proc(
	adapter: ^Native_Menu_Adapter,
	pointer: alicorn.Pointer_Event,
	event: sdl3.Event,
) -> alicorn.Pointer_Event {
	if adapter == nil || adapter.platform_data == nil { return pointer }
	return darwin_titlebar_translate_pointer(adapter, pointer, event)
}

native_menu_adapter_note_window_hit_test :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil || adapter.platform_data == nil { return }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return }
	_ = darwin_titlebar_consume_hit_test_sample(
		&state.titlebar.pointer_samples,
		&state.titlebar.gesture_owner,
	)
	state.titlebar.last_sdl_pointer_valid = false
}

darwin_titlebar_rect_to_window_logical :: proc(rect, content_bounds: NS.Rect, content_is_flipped: bool) -> alicorn.Rect {
	left := f32(rect.origin.x-content_bounds.origin.x)
	bottom_from_top := f32(content_bounds.origin.y+content_bounds.size.height-(rect.origin.y+rect.size.height))
	top := bottom_from_top
	if content_is_flipped { top = f32(rect.origin.y-content_bounds.origin.y) }
	right := left+f32(rect.size.width)
	bottom := top+f32(rect.size.height)
	left = f32(math.floor(f64(left)))
	top = f32(math.floor(f64(top)))
	right = f32(math.ceil(f64(right)))
	bottom = f32(math.ceil(f64(bottom)))
	return alicorn.Rect{left, top, max(right-left, 0), max(bottom-top, 0)}
}

darwin_titlebar_rect_contains :: proc(rect: alicorn.Rect, point: sdl3.Point) -> bool {
	x := f32(point[0])
	y := f32(point[1])
	return rect.w > 0 && rect.h > 0 && x >= rect.x && y >= rect.y &&
		x < rect.x+rect.w && y < rect.y+rect.h
}

darwin_titlebar_resolve_geometry :: proc(
	viewport, safe_area: alicorn.Rect,
	header_height: f32,
	visible_controls: []alicorn.Rect,
) -> (geometry: Darwin_Titlebar_Geometry, content_start_x: f32) {
	top := clamp(safe_area.y, 0, viewport.h)
	geometry.header = alicorn.Rect{0, top, viewport.w, min(max(header_height, 0), max(viewport.h-top, 0))}
	content_start_x = max(safe_area.x, 0)
	for bounds in visible_controls {
		if bounds.w <= 0 || bounds.h <= 0 || bounds.x >= viewport.w || bounds.x+bounds.w <= 0 ||
			bounds.y >= top+geometry.header.h || bounds.y+bounds.h <= top { continue }
		if geometry.native_control_count < len(geometry.native_controls) {
			geometry.native_controls[geometry.native_control_count] = bounds
			geometry.native_control_count += 1
		}
		content_start_x = max(content_start_x, bounds.x+bounds.w+12)
	}
	return
}

darwin_titlebar_set_style_mask :: proc(window: ^NS.Window, style_mask: NS.WindowStyleMask, preserve_frame: bool) {
	if window == nil { return }
	frame := NS.Window_frame(window)
	content_view := NS.Window_contentView(window)
	if content_view == nil {
		NS.Window_setStyleMask(window, style_mask)
		if preserve_frame { NS.Window_setFrame(window, frame, false) }
		return
	}
	view_responder := cast(^NS.Responder)content_view
	previous_responder := intrinsics.objc_send(^NS.Responder, view_responder, "nextResponder")
	if previous_responder != nil {
		intrinsics.objc_send(nil, view_responder, "setNextResponder:", cast(^NS.Responder)nil)
	}
	NS.Window_setStyleMask(window, style_mask)
	current_responder := intrinsics.objc_send(^NS.Responder, view_responder, "nextResponder")
	if previous_responder != nil && previous_responder != current_responder {
		intrinsics.objc_send(nil, view_responder, "setNextResponder:", previous_responder)
	}
	if preserve_frame { NS.Window_setFrame(window, frame, false) }
}

darwin_titlebar_apply_style :: proc(
	window: ^NS.Window,
	force := false,
	allow_style_mask_change := true,
	preserve_frame := true,
) -> bool {
	if window == nil { return false }
	style_mask := intrinsics.objc_send(NS.WindowStyleMask, window, "styleMask")
	fullscreen := NS.WindowStyleMaskFlag.FullScreen in style_mask
	has_full_size := NS.WindowStyleMaskFlag.FullSizeContentView in style_mask
	style_changed := allow_style_mask_change && !has_full_size && !fullscreen
	if style_changed {
		style_mask += {.FullSizeContentView}
		darwin_titlebar_set_style_mask(window, style_mask, preserve_frame)
	}
	if force || style_changed {
		NS.Window_setTitlebarAppearsTransparent(window, true)
		NS.Window_setTitleVisibility(window, .Hidden)
	}
	return style_changed
}

darwin_titlebar_hit_test :: proc(
	geometry: Darwin_Titlebar_Geometry,
	point: sdl3.Point,
	buttons: sdl3.MouseButtonFlags,
	owner: ^Darwin_Titlebar_Gesture_Owner,
) -> sdl3.HitTestResult {
	if owner == nil { return .NORMAL }
	left_down := sdl3.MouseButtonFlag.LEFT in buttons
	if owner^ != .None {
		if !left_down {
			owner^ = .None
			return .NORMAL
		}
		return .DRAGGABLE if owner^ == .Window else .NORMAL
	}
	if left_down {
		for i in 0..<min(geometry.native_control_count, len(geometry.native_controls)) {
			if darwin_titlebar_rect_contains(geometry.native_controls[i], point) {
				owner^ = .Native_Control
				return .NORMAL
			}
		}
		for i in 0..<min(geometry.interactive_count, len(geometry.interactive)) {
			if darwin_titlebar_rect_contains(geometry.interactive[i], point) {
				owner^ = .Alicorn
				return .NORMAL
			}
		}
		for i in 0..<min(geometry.drag_region_count, len(geometry.drag_regions)) {
			if darwin_titlebar_rect_contains(geometry.drag_regions[i], point) {
				owner^ = .Window
				return .DRAGGABLE
			}
		}
		owner^ = .Client
		return .NORMAL
	}
	if !darwin_titlebar_rect_contains(geometry.header, point) { return .NORMAL }
	for i in 0..<min(geometry.drag_region_count, len(geometry.drag_regions)) {
		if darwin_titlebar_rect_contains(geometry.drag_regions[i], point) { return .DRAGGABLE }
	}
	return .NORMAL
}

darwin_titlebar_intersection :: proc(a, b: alicorn.Rect) -> alicorn.Rect {
	x := max(a.x, b.x)
	y := max(a.y, b.y)
	return alicorn.Rect{x, y, max(min(a.x+a.w, b.x+b.w)-x, 0), max(min(a.y+a.h, b.y+b.h)-y, 0)}
}

darwin_titlebar_native_button_bounds :: proc(
	window: ^NS.Window,
	content_view: ^NS.View,
	content_bounds: NS.Rect,
	content_is_flipped: bool,
	button_kind: NS.UInteger,
) -> (bounds: alicorn.Rect, ok, visible: bool) {
	button := intrinsics.objc_send(^NS.View, window, "standardWindowButton:", button_kind)
	if button == nil { return }
	parent := intrinsics.objc_send(^NS.View, button, "superview")
	if parent == nil { return }
	frame := intrinsics.objc_send(NS.Rect, button, "frame")
	content_frame := intrinsics.objc_send(NS.Rect, content_view, "convertRect:fromView:", frame, parent)
	bounds = darwin_titlebar_rect_to_window_logical(content_frame, content_bounds, content_is_flipped)
	ok = bounds.w > 0 && bounds.h > 0
	visible = intrinsics.objc_send(^NS.Window, button, "window") == window &&
		!intrinsics.objc_send(NS.BOOL, button, "isHiddenOrHasHiddenAncestor")
	return
}

darwin_titlebar_apply_mobility :: proc(window: ^NS.Window, result: sdl3.HitTestResult) {
	if window == nil { return }
	desired := result == .DRAGGABLE
	if intrinsics.objc_send(NS.BOOL, window, "isMovable") != desired {
		NS.Window_setMovable(window, desired)
	}
}

darwin_titlebar_sdl_hit_test :: proc "c" (
	_window: ^sdl3.Window,
	area: ^sdl3.Point,
	data: rawptr,
) -> sdl3.HitTestResult {
	context = runtime.default_context()
	if area == nil || data == nil { return .NORMAL }
	adapter := cast(^Native_Menu_Adapter)data
	if adapter == nil || adapter.platform_data == nil { return .NORMAL }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return .NORMAL }
	state.titlebar.hit_test_calls += 1
	buttons := sdl3.GetGlobalMouseState(nil, nil)
	state.titlebar.last_sdl_pointer_point = area^
	state.titlebar.last_sdl_pointer_valid = true
	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, area^, buttons)
	result := darwin_titlebar_hit_test(state.titlebar.geometry, area^, buttons, &state.titlebar.gesture_owner)
	darwin_titlebar_apply_mobility(state.window, result)
	if result == .DRAGGABLE { state.titlebar.draggable_calls += 1 }
	return result
}

darwin_titlebar_sync_layout :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || adapter.platform_data == nil || adapter.hosted == nil || adapter.chrome.layout == nil { return false }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return false }
	rt, status := alicorn.hosted_runtime_borrow(adapter.hosted)
	if status != .Ok { return false }
	layout := adapter.chrome.layout(adapter.chrome.callback_state, rt)
	header, header_ok := alicorn.node_info(rt, layout.header)
	geometry := &state.titlebar.geometry
	geometry.interactive_count = 0
	geometry.drag_region_count = 0
	if !header_ok || !header.active {
		geometry.header = {}
		return true
	}
	geometry.header = darwin_titlebar_intersection(header.bounds, state.titlebar.metrics.header)
	for region in layout.regions {
		if region.node == 0 { continue }
		node, ok := alicorn.node_info(rt, region.node)
		if !ok || !node.active { continue }
		region_bounds := node.bounds
		if region.kind == .Interactive && node.kind == .Split_Handle { region_bounds = node.hit_bounds }
		bounds := darwin_titlebar_intersection(region_bounds, geometry.header)
		if bounds.w <= 0 || bounds.h <= 0 { continue }
		if region.kind == .Interactive {
			if geometry.interactive_count < len(geometry.interactive) {
				geometry.interactive[geometry.interactive_count] = bounds
				geometry.interactive_count += 1
			}
		} else if geometry.drag_region_count < len(geometry.drag_regions) {
			geometry.drag_regions[geometry.drag_region_count] = bounds
			geometry.drag_region_count += 1
		}
	}
	return true
}

darwin_titlebar_refresh :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || adapter.platform_data == nil || adapter.hosted == nil { return false }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active || state.window == nil { return true }
	if darwin_titlebar_apply_style(state.window) { state.titlebar.style_reapplies += 1 }
	style_mask := intrinsics.objc_send(NS.WindowStyleMask, state.window, "styleMask")
	fullscreen := NS.WindowStyleMaskFlag.FullScreen in style_mask
	content_view := NS.Window_contentView(state.window)
	if content_view == nil { return false }
	content_bounds := NS.View_bounds(content_view)
	content_is_flipped := NS.View_isFlipped(content_view)
	button_kinds := [3]NS.UInteger{0, 1, 2}
	measured: [3]alicorn.Rect
	visible_controls: [3]alicorn.Rect
	visible_count := 0
	for kind, index in button_kinds {
		bounds, ok, visible := darwin_titlebar_native_button_bounds(state.window, content_view, content_bounds, content_is_flipped, kind)
		if !ok { continue }
		measured[index] = bounds
		if visible {
			visible_controls[visible_count] = bounds
			visible_count += 1
		}
	}
	window_width, window_height: c.int
	if !sdl3.GetWindowSize(adapter.window, &window_width, &window_height) { return false }
	safe_area: sdl3.Rect
	if !sdl3.GetWindowSafeArea(adapter.window, &safe_area) { return false }
	next, content_start_x := darwin_titlebar_resolve_geometry(
		alicorn.Rect{0, 0, f32(window_width), f32(window_height)},
		alicorn.Rect{f32(safe_area.x), f32(safe_area.y), f32(safe_area.w), f32(safe_area.h)},
		state.titlebar.header_height,
		visible_controls[:visible_count],
	)
	metrics := alicorn.Window_Chrome_Metrics{
		header=next.header,
		native_controls=next.native_controls,
		native_control_count=next.native_control_count,
		content_start_x=content_start_x,
		content_end_x=f32(window_width),
		display_scale=sdl3.GetWindowDisplayScale(adapter.window),
		fullscreen=fullscreen,
	}
	changed := !state.titlebar.metrics_valid || !alicorn.window_chrome_metrics_equal(state.titlebar.metrics, metrics)
	next.interactive = state.titlebar.geometry.interactive
	next.interactive_count = state.titlebar.geometry.interactive_count
	next.drag_regions = state.titlebar.geometry.drag_regions
	next.drag_region_count = state.titlebar.geometry.drag_region_count
	state.titlebar.geometry = next
	if changed {
		state.titlebar.metrics = metrics
		state.titlebar.metrics_valid = true
		state.titlebar.metrics_delivered = false
		rt, status := alicorn.hosted_runtime_borrow(adapter.hosted)
		if status == .Ok {
			if adapter.chrome.metrics != nil {
				adapter.chrome.metrics(adapter.chrome.callback_state, rt, metrics)
				state.titlebar.metrics_delivered = true
			}
			alicorn.invalidate_root(rt, "measured macOS titlebar geometry changed")
		}
	}
	return true
}

native_menu_adapter_activate_chrome :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || adapter.platform_data == nil { return true }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if adapter.chrome.decorations != .Content_Title_Bar { return true }
	if state.window == nil { return false }
	state.titlebar.header_height = max(adapter.chrome.chrome_height, 0)
	_ = darwin_titlebar_apply_style(state.window, force=true, preserve_frame=false)
	NS.Window_setMovableByWindowBackground(state.window, false)
	state.titlebar.active = true
	adapter.chrome_active = true
	if !sdl3.SetWindowHitTest(adapter.window, darwin_titlebar_sdl_hit_test, rawptr(adapter)) { return false }
	return darwin_titlebar_refresh(adapter)
}

native_menu_adapter_sync_chrome :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil || adapter.platform_data == nil || !adapter.chrome_active { return }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return }
	_ = darwin_titlebar_refresh(adapter)
	_ = darwin_titlebar_sync_layout(adapter)
}

native_menu_adapter_chrome_paint :: proc(
	adapter: ^Native_Menu_Adapter,
	width, height: f32,
	allocator := context.temp_allocator,
) -> []alicorn.Paint_Command {
	return nil
}

native_menu_adapter_handle_keydown :: proc(
	adapter: ^Native_Menu_Adapter,
	keycode: int,
	modifiers: sdl3.Keymod,
) -> bool {
	return false
}

darwin_titlebar_destroy :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil || adapter.platform_data == nil { return }
	state := cast(^Darwin_Menu_State)adapter.platform_data
	if !state.titlebar.active { return }
	_ = sdl3.SetWindowHitTest(adapter.window, nil, nil)
	if state.window != nil {
		NS.Window_setMovableByWindowBackground(state.window, false)
		NS.Window_setMovable(state.window, true)
	}
	state.titlebar.gesture_owner = .None
	state.titlebar.pointer_samples = {}
	state.titlebar.last_sdl_pointer_valid = false
	state.titlebar.active = false
}
