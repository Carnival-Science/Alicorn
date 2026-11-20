#+build windows

package host_menus

import "base:runtime"
import "core:c"
import "core:mem"
import win "core:sys/windows"
import alicorn "alicorn:runtime"
import cpu_renderer "alicorn:renderer/cpu"
import "vendor:sdl3"

// The Windows integrated-titlebar adapter is the hosted sibling of
// native/sdl_gpu's menus_windows.odin. Menu construction, label painting,
// caption controls, DWM frame extension, non-client hit testing, and chrome
// region routing live behind one HMENU/subclass path so the hosted WebGPU host
// and its menus cannot drift apart.

foreign import dwmapi "system:Dwmapi.lib"
foreign dwmapi {
	DwmDefWindowProc :: proc "system" (hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, result: ^win.LRESULT) -> win.BOOL ---
	DwmGetWindowAttribute :: proc "system" (hwnd: win.HWND, attribute: u32, value: rawptr, value_size: win.DWORD) -> win.HRESULT ---
	DwmExtendFrameIntoClientArea :: proc "system" (hwnd: win.HWND, margins: ^win.MARGINS) -> win.HRESULT ---
	DwmSetWindowAttribute :: proc "system" (hwnd: win.HWND, attribute: u32, value: rawptr, value_size: win.DWORD) -> win.HRESULT ---
}

WIN32_DWMWA_CAPTION_BUTTON_BOUNDS :: u32(5)
WIN32_DWMWA_USE_IMMERSIVE_DARK_MODE :: u32(20)
WIN32_MENU_HOVER_MIX :: 0.10
WIN32_MENU_OPEN_MIX :: 0.14
WIN32_MENU_PRESSED_MIX :: 0.20
WIN32_VK_SPACE :: 0x20
WIN32_VK_F10 :: 0x79
WIN32_VK_RETURN :: 0x0D
WIN32_VK_ESCAPE :: 0x1B
WIN32_VK_LEFT :: 0x25
WIN32_VK_RIGHT :: 0x27

WIN32_CHROME_TITLE_NODE :: alicorn.Node_ID(0xFFFF_FFFF_FFFF_D000)
WIN32_CHROME_ELLIPSIS_NODE :: alicorn.Node_ID(0xFFFF_FFFF_FFFF_D001)
WIN32_CHROME_LABEL_NODE_BASE :: alicorn.Node_ID(0xFFFF_FFFF_FFFF_D100)
WIN32_CHROME_HOST_SOLID_NODE :: alicorn.Node_ID(0xFFFF_FFFF_FFFF_E000)

Win32_Chrome_Label :: struct {
	text:        string,
	popup:       win.HMENU,
	direct_menu: ^alicorn.Menu,
	host_node:   alicorn.Node_ID,
	bounds:      win.RECT,
	run:         alicorn.Text_Run_Handle,
	run_valid:   bool,
}

Win32_Caption_Control :: struct {
	bounds:       win.RECT,
	glyph_bounds: win.RECT,
	hover_bounds: win.RECT,
	hit_test:     win.LRESULT,
}

Win32_Caption_Icon :: enum { Minimize, Maximize, Restore, Close }

Win32_Caption_Mask :: struct { size: int, pixels: []u8 }

Win32_Chrome_Hit_Region :: struct {
	bounds: win.RECT,
	kind:   alicorn.Window_Chrome_Region_Kind,
}

Win32_Chrome_Gesture_Owner :: enum u8 { None, Alicorn, Window, Native_Menu }

Win32_Chrome_Geometry :: struct {
	header:           win.RECT,
	regions:          [alicorn.WINDOW_CHROME_REGION_CAPACITY]Win32_Chrome_Hit_Region,
	region_count:     int,
	application_owned: bool,
}

Win32_Chrome_State :: struct {
	adapter:                 ^Native_Menu_Adapter,
	menu_state:              ^Win32_Menu_State,
	hwnd:                    win.HWND,
	window:                  ^sdl3.Window,
	allocator:               mem.Allocator,
	active:                  bool,
	high_contrast:           bool,
	windows_11:              bool,
	frame_enabled:           bool,
	frame_extended:          bool,
	chrome_height:           f32,
	chrome_height_pixels:    i32,
	pixels_per_unit:         f32,
	dpi:                     u32,
	maximized:               bool,
	caption_button_bounds:   win.RECT,
	caption_bounds_valid:    bool,
	caption_controls:        [3]Win32_Caption_Control,
	caption_hovered:         int,
	caption_pressed:         int,
	caption_masks:           [4]Win32_Caption_Mask,
	caption_mask_dpi:        u32,
	caption_mask_windows_11: bool,
	caption_mask_builds:     u64,
	labels:                  []Win32_Chrome_Label,
	title:                   Win32_Chrome_Label,
	ellipsis:                Win32_Chrome_Label,
	title_text:              string,
	text_scale:              f32,
	font_generation:         u64,
	hovered:                 int,
	active_menu:             int,
	menu_mode:               bool,
	alt_menu_pending:        bool,
	gesture_owner:           Win32_Chrome_Gesture_Owner,
	geometry:                Win32_Chrome_Geometry,
	metrics:                 alicorn.Window_Chrome_Metrics,
	metrics_valid:           bool,
	appearance:              alicorn.Window_Chrome_Appearance,
	appearance_valid:        bool,
	dark_frame:              bool,
	dark_frame_valid:        bool,
	last_inset:              f32,
	last_layout_revision:    u64,
}

win32_chrome_application_owns_header :: proc(state: ^Win32_Chrome_State) -> bool {
	return state != nil && state.adapter != nil && state.adapter.chrome.layout != nil
}

win32_chrome_labels_hidden :: proc(state: ^Win32_Chrome_State) -> bool {
	if state == nil || state.adapter == nil { return false }
	chrome := state.adapter.chrome
	return chrome.decorations == .Integrated_Title_Bar && chrome.menu_presentation == .Hidden
}

win32_chrome_request_redraw :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.adapter == nil { return }
	request := state.adapter.chrome.request_redraw
	if request != nil { request(state.adapter.chrome.request_redraw_data) }
}

win32_chrome_runtime :: proc(state: ^Win32_Chrome_State) -> ^alicorn.Runtime {
	if state == nil || state.adapter == nil || state.adapter.hosted == nil { return nil }
	rt, status := alicorn.hosted_runtime_borrow(state.adapter.hosted)
	if status != .Ok { return nil }
	return rt
}

win32_chrome_rect_to_window :: proc(rect: win.RECT, pixels_per_unit: f32) -> alicorn.Rect {
	scale := 1/(pixels_per_unit if pixels_per_unit > 0 else 1)
	return alicorn.Rect{
		f32(rect.left)*scale, f32(rect.top)*scale,
		f32(max(rect.right-rect.left, 0))*scale, f32(max(rect.bottom-rect.top, 0))*scale,
	}
}

win32_rect_contains :: proc(bounds: win.RECT, x, y: i32) -> bool {
	return x >= i32(bounds.left) && x < i32(bounds.right) &&
		y >= i32(bounds.top) && y < i32(bounds.bottom)
}

win32_rect_intersection :: proc(a, b: win.RECT) -> win.RECT {
	left := max(a.left, b.left)
	top := max(a.top, b.top)
	right := min(a.right, b.right)
	bottom := min(a.bottom, b.bottom)
	return win.RECT{left, top, max(right, left), max(bottom, top)}
}

win32_chrome_point_from_lparam :: proc(value: win.LPARAM) -> win.POINT {
	packed := uintptr(value)
	return win.POINT{
		x=win.LONG(cast(i16)u16(packed & 0xffff)),
		y=win.LONG(cast(i16)u16((packed >> 16) & 0xffff)),
	}
}

win32_screen_point_to_client_pixels :: proc(screen_x, screen_y, client_origin_x, client_origin_y: i32) -> (i32, i32) {
	return screen_x-client_origin_x, screen_y-client_origin_y
}

win32_caption_bounds_to_client_pixels :: proc(
	window_bounds, window_rect: win.RECT,
	client_origin_x, client_origin_y: i32,
) -> win.RECT {
	dx := window_rect.left-win.LONG(client_origin_x)
	dy := window_rect.top-win.LONG(client_origin_y)
	return win.RECT{window_bounds.left+dx, window_bounds.top+dy, window_bounds.right+dx, window_bounds.bottom+dy}
}

win32_caption_control_rects :: proc(bounds: win.RECT, valid: bool) -> [3]win.RECT {
	if !valid || bounds.right <= bounds.left || bounds.bottom <= bounds.top { return {} }
	width := i32(bounds.right-bounds.left)
	first_width := width/3
	second_width := width/3
	third_width := width-first_width-second_width
	return [3]win.RECT{
		{left=bounds.left, top=bounds.top, right=bounds.left+win.LONG(first_width), bottom=bounds.bottom},
		{left=bounds.left+win.LONG(first_width), top=bounds.top, right=bounds.left+win.LONG(first_width+second_width), bottom=bounds.bottom},
		{left=bounds.right-win.LONG(third_width), top=bounds.top, right=bounds.right, bottom=bounds.bottom},
	}
}

win32_caption_layout_controls :: proc(
	dwm_bounds: win.RECT, dwm_valid: bool,
	client_width, chrome_height: i32, dpi: u32, maximized: bool,
) -> [3]Win32_Caption_Control {
	if client_width <= 0 || chrome_height <= 0 { return {} }
	cluster := dwm_bounds
	if !dwm_valid || cluster.right <= cluster.left || cluster.bottom <= cluster.top ||
		cluster.left < 0 || cluster.left >= win.LONG(client_width) {
		button_width := i32(cpu_renderer.Pixel_Edge(46, f32(dpi if dpi != 0 else 96)/96))
		cluster.right = win.LONG(client_width-1 if !maximized else client_width)
		cluster.left = max(cluster.right-win.LONG(3*button_width), 0)
	}
	cluster.right = min(cluster.right, win.LONG(client_width))
	cluster.top = 0 if maximized else 1
	cluster.bottom = win.LONG(chrome_height)
	rects := win32_caption_control_rects(cluster, true)
	if maximized { rects[2].right = win.LONG(client_width) }
	close_glyph := rects[2]
	close_glyph.right = win.LONG(client_width)
	close_hover := close_glyph
	close_hover.top = 0
	return [3]Win32_Caption_Control{
		{bounds=rects[0], glyph_bounds=rects[0], hover_bounds=rects[0], hit_test=win.LRESULT(win.HTMINBUTTON)},
		{bounds=rects[1], glyph_bounds=rects[1], hover_bounds=rects[1], hit_test=win.LRESULT(win.HTMAXBUTTON)},
		{bounds=rects[2], glyph_bounds=close_glyph, hover_bounds=close_hover, hit_test=win.LRESULT(win.HTCLOSE)},
	}
}

win32_caption_control_at :: proc(x, y: i32, controls: []Win32_Caption_Control) -> int {
	for control, i in controls {
		if win32_rect_contains(control.bounds, x, y) { return i }
	}
	return -1
}

win32_integrated_frame_hit_test :: proc(
	x, y, width, height: i32,
	chrome_height, resize_x, resize_y: i32,
	maximized: bool,
	caption_controls: []Win32_Caption_Control,
	labels: []win.RECT,
	chrome_regions: []Win32_Chrome_Hit_Region = nil,
	application_owned_header := false,
	gesture_owner: Win32_Chrome_Gesture_Owner = .None,
) -> win.LRESULT {
	if gesture_owner == .Alicorn || gesture_owner == .Native_Menu { return win.LRESULT(win.HTCLIENT) }
	if gesture_owner == .Window { return win.LRESULT(win.HTCAPTION) }
	for control in caption_controls {
		if win32_rect_contains(control.bounds, x, y) { return control.hit_test }
	}
	if !maximized && resize_x > 0 && resize_y > 0 {
		left := x < resize_x
		right := x >= width-resize_x
		top := y < resize_y
		bottom := y >= height-resize_y
		if top && left { return win.LRESULT(win.HTTOPLEFT) }
		if top && right { return win.LRESULT(win.HTTOPRIGHT) }
		if bottom && left { return win.LRESULT(win.HTBOTTOMLEFT) }
		if bottom && right { return win.LRESULT(win.HTBOTTOMRIGHT) }
		if left { return win.LRESULT(win.HTLEFT) }
		if right { return win.LRESULT(win.HTRIGHT) }
		if top { return win.LRESULT(win.HTTOP) }
		if bottom { return win.LRESULT(win.HTBOTTOM) }
	}
	for label in labels {
		if win32_rect_contains(label, x, y) { return win.LRESULT(win.HTCLIENT) }
	}
	for region in chrome_regions {
		if !win32_rect_contains(region.bounds, x, y) { continue }
		if region.kind == .Interactive { return win.LRESULT(win.HTCLIENT) }
		return win.LRESULT(win.HTCAPTION)
	}
	if y >= 0 && y < chrome_height {
		return win.LRESULT(win.HTCLIENT) if application_owned_header else win.LRESULT(win.HTCAPTION)
	}
	return win.LRESULT(win.HTCLIENT)
}

win32_integrated_frame_resolve_hit_test :: proc(
	frame_result: win.LRESULT,
	dwm_handled: bool,
	dwm_result: win.LRESULT,
) -> win.LRESULT {
	if frame_result == win.LRESULT(win.HTMINBUTTON) || frame_result == win.LRESULT(win.HTMAXBUTTON) ||
		frame_result == win.LRESULT(win.HTCLOSE) { return frame_result }
	if dwm_handled && (dwm_result == win.LRESULT(win.HTMINBUTTON) ||
		dwm_result == win.LRESULT(win.HTMAXBUTTON) || dwm_result == win.LRESULT(win.HTCLOSE)) {
		return dwm_result
	}
	return frame_result
}

win32_integrated_frame_resolve_gesture_hit_test :: proc(
	frame_result: win.LRESULT,
	gesture_owner: Win32_Chrome_Gesture_Owner,
	dwm_handled: bool,
	dwm_result: win.LRESULT,
) -> win.LRESULT {
	if gesture_owner != .None { return frame_result }
	return win32_integrated_frame_resolve_hit_test(frame_result, dwm_handled, dwm_result)
}

win32_caption_windows_11 :: proc() -> bool {
	version := win.OSVERSIONINFOEXW{dwOSVersionInfoSize=u32(size_of(win.OSVERSIONINFOEXW))}
	return win.RtlGetVersion(&version) >= 0 && version.dwMajorVersion >= 10 && version.dwBuildNumber >= 22000
}

win32_caption_inside_round_rect :: proc(x, y, left, top, width, height, radius: f32) -> bool {
	if width <= 0 || height <= 0 || x < left || y < top || x >= left+width || y >= top+height { return false }
	r := min(max(radius, 0), min(width, height)/2)
	if r == 0 { return true }
	dx := max(max(left+r-x, x-(left+width-r)), 0)
	dy := max(max(top+r-y, y-(top+height-r)), 0)
	return dx*dx+dy*dy <= r*r
}

win32_caption_on_outline :: proc(x, y, left, top, width, height, radius, stroke: f32) -> bool {
	return win32_caption_inside_round_rect(x, y, left, top, width, height, radius) &&
		!win32_caption_inside_round_rect(x, y, left+stroke, top+stroke, width-2*stroke, height-2*stroke, max(radius-stroke, 0))
}

win32_caption_symbol_sample :: proc(icon: Win32_Caption_Icon, x, y, size, stroke, radius, separation: f32) -> bool {
	switch icon {
	case .Minimize:
		top := f32(int(size)/2-int(stroke)/2)
		return y >= top && y < top+stroke
	case .Maximize:
		return win32_caption_on_outline(x, y, 0, 0, size, size, radius, stroke)
	case .Restore:
		extent := size-separation
		front := win32_caption_on_outline(x, y, 0, separation, extent, extent, radius, stroke)
		back := win32_caption_on_outline(x, y, separation, 0, extent, extent, radius, stroke) &&
			!win32_caption_inside_round_rect(x, y, 0, separation, extent, extent, radius)
		return front || back
	case .Close:
		half_width := stroke*0.70710678118
		return abs(x-y) <= half_width || abs(x+y-size) <= half_width
	}
	return false
}

win32_caption_build_mask :: proc(icon: Win32_Caption_Icon, dpi: u32, windows_11: bool, allocator: mem.Allocator) -> Win32_Caption_Mask {
	scale := f32(dpi if dpi != 0 else 96)/96
	size := max(cpu_renderer.Pixel_Edge(10, scale), 1)
	stroke := f32(max(cpu_renderer.Pixel_Edge(1, scale), 1))
	radius := f32(int(1.5*scale)) if windows_11 else 0
	separation := f32(max(cpu_renderer.Pixel_Edge(2, scale), 1))
	mask := Win32_Caption_Mask{size=size, pixels=make([]u8, size*size, allocator=allocator)}
	if mask.pixels == nil { return {} }
	samples := 4 if icon == .Close || (windows_11 && icon != .Minimize) else 1
	for y in 0..<size {
		for x in 0..<size {
			coverage := 0
			for sy in 0..<samples {
				for sx in 0..<samples {
					px := f32(x)+(f32(sx)+0.5)/f32(samples)
					py := f32(y)+(f32(sy)+0.5)/f32(samples)
					if win32_caption_symbol_sample(icon, px, py, f32(size), stroke, radius, separation) { coverage += 1 }
				}
			}
			mask.pixels[y*size+x] = u8((coverage*255+samples*samples/2)/(samples*samples))
		}
	}
	return mask
}

win32_chrome_destroy_masks :: proc(state: ^Win32_Chrome_State) {
	for &mask in state.caption_masks {
		if mask.pixels != nil { delete(mask.pixels, state.allocator) }
		mask = {}
	}
	state.caption_mask_dpi = 0
}

win32_chrome_sync_masks :: proc(state: ^Win32_Chrome_State) -> bool {
	dpi := state.dpi if state.dpi != 0 else 96
	if state.caption_mask_dpi == dpi && state.caption_mask_windows_11 == state.windows_11 { return true }
	next: [4]Win32_Caption_Mask
	for icon in Win32_Caption_Icon {
		next[int(icon)] = win32_caption_build_mask(icon, dpi, state.windows_11, state.allocator)
		if next[int(icon)].pixels == nil {
			for mask in next { if mask.pixels != nil { delete(mask.pixels, state.allocator) } }
			return false
		}
	}
	win32_chrome_destroy_masks(state)
	state.caption_masks = next
	state.caption_mask_dpi = dpi
	state.caption_mask_windows_11 = state.windows_11
	state.caption_mask_builds += 1
	return true
}

win32_chrome_append_glyph :: proc(
	commands: ^[dynamic]alicorn.Paint_Command, state: ^Win32_Chrome_State,
	index: int, color: alicorn.Color, clip: alicorn.Rect, maximized: bool,
) {
	if state == nil || index < 0 || index >= 3 { return }
	icon := Win32_Caption_Icon.Minimize
	if index == 1 { icon = .Restore if maximized else .Maximize }
	if index == 2 { icon = .Close }
	mask := state.caption_masks[int(icon)]
	if mask.size == 0 { return }
	control := state.caption_controls[index].glyph_bounds
	x0 := int(control.left)+(int(control.right-control.left)-mask.size)/2
	y0 := int(control.top)+(int(control.bottom-control.top)-mask.size)/2
	scale := 1/(state.pixels_per_unit if state.pixels_per_unit > 0 else 1)
	owner := WIN32_CHROME_HOST_SOLID_NODE+alicorn.Node_ID(1024*(index+1))
	for y in 0..<mask.size {
		for x := 0; x < mask.size; {
			coverage := mask.pixels[y*mask.size+x]
			end := x+1
			for end < mask.size && mask.pixels[y*mask.size+end] == coverage { end += 1 }
			if coverage != 0 {
				fill := color
				fill.a *= f32(coverage)/255
				append(commands, alicorn.paint_surface_command(owner,
					alicorn.Rect{f32(x0+x)*scale, f32(y0+y)*scale, f32(end-x)*scale, scale}, clip, fill))
				owner += 1
			}
			x = end
		}
	}
}

win32_chrome_color_ref :: proc(value: win.COLORREF) -> alicorn.Color {
	color := u32(value)
	return alicorn.Color{f32(color&0xff)/255, f32((color>>8)&0xff)/255, f32((color>>16)&0xff)/255, 1}
}

win32_chrome_color_rgb :: proc(red, green, blue: u8) -> alicorn.Color {
	return alicorn.Color{f32(red)/255, f32(green)/255, f32(blue)/255, 1}
}

win32_chrome_color_mix :: proc(background, foreground: alicorn.Color, amount: f32) -> alicorn.Color {
	mix := clamp(amount, 0, 1)
	return alicorn.Color{
		background.r+(foreground.r-background.r)*mix,
		background.g+(foreground.g-background.g)*mix,
		background.b+(foreground.b-background.b)*mix,
		background.a+(foreground.a-background.a)*mix,
	}
}

win32_chrome_feedback_colors :: proc(background, foreground: alicorn.Color) -> (hover, open, pressed: alicorn.Color) {
	hover = win32_chrome_color_mix(background, foreground, WIN32_MENU_HOVER_MIX)
	open = win32_chrome_color_mix(background, foreground, WIN32_MENU_OPEN_MIX)
	pressed = win32_chrome_color_mix(background, foreground, WIN32_MENU_PRESSED_MIX)
	return
}

win32_chrome_colors :: proc(state: ^Win32_Chrome_State) -> (background, foreground: alicorn.Color) {
	if state != nil && !state.high_contrast && state.appearance.defined {
		background = state.appearance.background
		foreground = state.appearance.foreground
		if !state.active { foreground = win32_chrome_color_mix(background, foreground, 0.72) }
		return
	}
	background = win32_chrome_color_ref(win.GetSysColor(win.COLOR_MENU))
	foreground_index := i32(win.COLOR_MENUTEXT)
	if !state.active && !state.high_contrast { foreground_index = i32(win.COLOR_GRAYTEXT) }
	foreground = win32_chrome_color_ref(win.GetSysColor(foreground_index))
	return
}

win32_chrome_high_contrast_selection_colors :: proc() -> (background, foreground: alicorn.Color) {
	return win32_chrome_color_ref(win.GetSysColor(win.COLOR_HIGHLIGHT)),
		win32_chrome_color_ref(win.GetSysColor(win.COLOR_HIGHLIGHTTEXT))
}

win32_chrome_resolve_appearance :: proc(state: ^Win32_Chrome_State) -> bool {
	if state == nil || state.adapter == nil { return false }
	appearance := state.adapter.chrome.appearance
	if appearance == nil { return false }
	rt := win32_chrome_runtime(state)
	if rt == nil { return false }
	next := appearance(state.adapter.chrome.callback_state, rt)
	changed := !state.appearance_valid || state.appearance.defined != next.defined ||
		(state.appearance.defined && (state.appearance.background != next.background || state.appearance.foreground != next.foreground))
	state.appearance = next
	state.appearance_valid = true
	if changed { win32_chrome_apply_dark_frame(state) }
	return changed
}

win32_chrome_apply_dark_frame :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.hwnd == nil || !state.appearance.defined { return }
	// The native SDL_GPU host paints its band but never adjusts DWM's frame
	// attribute. The hosted host mirrors that paint exactly and additionally
	// asks DWM to match the authored theme so resize borders and the maximized
	// frame do not flash a light title on a dark application. Failure is
	// non-fatal: the client band is already the authoritative appearance.
	luminance := 0.2126*state.appearance.background.r +
		0.7152*state.appearance.background.g +
		0.0722*state.appearance.background.b
	dark := luminance < 0.5
	if state.dark_frame_valid && state.dark_frame == dark { return }
	value := win.BOOL(dark)
	_ = DwmSetWindowAttribute(state.hwnd, WIN32_DWMWA_USE_IMMERSIVE_DARK_MODE, rawptr(&value), win.DWORD(size_of(value)))
	state.dark_frame = dark
	state.dark_frame_valid = true
}

win32_chrome_update_caption_button_bounds :: proc(state: ^Win32_Chrome_State, client_width_pixels: i32) -> bool {
	if state == nil || state.hwnd == nil { return false }
	state.caption_bounds_valid = false
	window_bounds: win.RECT
	if DwmGetWindowAttribute(state.hwnd, WIN32_DWMWA_CAPTION_BUTTON_BOUNDS, rawptr(&window_bounds), win.DWORD(size_of(window_bounds))) < 0 {
		return false
	}
	window_rect: win.RECT
	client_origin := win.POINT{}
	if !win.GetWindowRect(state.hwnd, &window_rect) || !win.ClientToScreen(state.hwnd, &client_origin) { return false }
	bounds := win32_caption_bounds_to_client_pixels(window_bounds, window_rect, i32(client_origin.x), i32(client_origin.y))
	button_width := i32(bounds.right-bounds.left)
	if bounds.right <= bounds.left || bounds.bottom <= bounds.top ||
		button_width > i32(cpu_renderer.Pixel_Edge(320, f32(state.dpi)/96)) { return false }
	if bounds.left < 0 || bounds.left >= win.LONG(client_width_pixels) { return false }
	state.caption_button_bounds = bounds
	state.caption_bounds_valid = true
	return true
}

win32_chrome_layout_labels :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.adapter == nil || !state.frame_enabled { return }
	state.dpi = win.GetDpiForWindow(state.hwnd)
	if state.dpi == 0 { state.dpi = 96 }
	scale := f32(state.dpi)/96
	state.pixels_per_unit = sdl3.GetWindowPixelDensity(state.window)
	if state.pixels_per_unit <= 0 { state.pixels_per_unit = 1 }
	state.maximized = win.IsZoomed(state.hwnd) != false
	client: win.RECT
	if !win.GetClientRect(state.hwnd, &client) { return }
	client_width := i32(client.right-client.left)
	caption_h := i32(win.GetSystemMetricsForDpi(win.SM_CYCAPTION, state.dpi))
	frame_y := i32(win.GetSystemMetricsForDpi(win.SM_CYSIZEFRAME, state.dpi)+win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, state.dpi))
	state.chrome_height_pixels = max(caption_h+frame_y, i32(cpu_renderer.Pixel_Edge(32, scale)))
	state.chrome_height = f32(state.chrome_height_pixels)/state.pixels_per_unit
	win32_chrome_update_caption_button_bounds(state, client_width)
	state.caption_controls = win32_caption_layout_controls(
		state.caption_button_bounds, state.caption_bounds_valid,
		client_width, state.chrome_height_pixels, state.dpi, state.maximized,
	)
	win32_chrome_layout_label_bounds(state)
	win32_chrome_publish_inset(state)
}

win32_chrome_layout_label_bounds :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.adapter == nil { return }
	scale := f32(state.dpi if state.dpi != 0 else 96)/96
	usable_right := max(i32(state.caption_controls[0].bounds.left)-i32(cpu_renderer.Pixel_Edge(8, scale)), 0)
	left := i32(cpu_renderer.Pixel_Edge(8, scale))
	rt := win32_chrome_runtime(state)
	state.title.bounds = {}
	if !win32_chrome_application_owns_header(state) && rt != nil && state.title.run_valid {
		if run, ok := alicorn.runtime_host_text_run_resolve(rt, state.title.run); ok && run != nil && state.title_text != "" {
			title_width := i32(cpu_renderer.Pixel_Edge(run.width, state.pixels_per_unit)+cpu_renderer.Pixel_Edge(16, scale))
			state.title.bounds = win.RECT{left=win.LONG(min(left, usable_right)), top=0,
				right=win.LONG(min(left+title_width, usable_right)), bottom=win.LONG(state.chrome_height_pixels)}
			left += title_width+i32(cpu_renderer.Pixel_Edge(8, scale))
		}
	}
	if win32_chrome_labels_hidden(state) {
		for &label in state.labels { label.bounds = win.RECT{} }
		return
	}
	if rt == nil { return }
	for i in 0..<len(state.labels) {
		label := &state.labels[i]
		label.bounds = win.RECT{}
		if left >= usable_right || !label.run_valid { continue }
		run, ok := alicorn.runtime_host_text_run_resolve(rt, label.run)
		if !ok || run == nil { continue }
		width := i32(cpu_renderer.Pixel_Edge(run.width, state.pixels_per_unit)+cpu_renderer.Pixel_Edge(24, scale))
		label.bounds = win.RECT{left=win.LONG(left), top=0,
			right=win.LONG(min(left+width, usable_right)), bottom=win.LONG(state.chrome_height_pixels)}
		left += width
	}
}

win32_chrome_publish_inset :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.adapter == nil || state.adapter.hosted == nil { return }
	inset := f32(0)
	if !win32_chrome_application_owns_header(state) { inset = state.chrome_height }
	if inset == state.last_inset { return }
	state.last_inset = inset
	_ = alicorn.hosted_runtime_set_content_inset(state.adapter.hosted, inset)
}

win32_chrome_refresh_text :: proc(state: ^Win32_Chrome_State, rt: ^alicorn.Runtime) -> bool {
	if state == nil || state.adapter == nil || rt == nil { return false }
	scale := (f32(state.dpi if state.dpi != 0 else 96)/96)/(state.pixels_per_unit if state.pixels_per_unit > 0 else 1)
	font_generation := rt.text_engine.font_generation
	if state.text_scale == scale && state.font_generation == font_generation { return true }
	// Shape every chrome run into a Runtime host resource. Replacing a run
	// releases the previous shaped resource; ids are stable across refreshes.
	title_text := state.title_text
	if win32_chrome_application_owns_header(state) { title_text = "" }
	if handle, ok := alicorn.runtime_host_text_run_set(
		rt, u64(WIN32_CHROME_TITLE_NODE), title_text, 14*scale,
		allocator=state.allocator,
	); ok {
		state.title.run = handle
		state.title.run_valid = true
	} else { state.title.run_valid = false }
	if handle, ok := alicorn.runtime_host_text_run_set(
		rt, u64(WIN32_CHROME_ELLIPSIS_NODE), "…", 14*scale,
		allocator=state.allocator,
	); ok {
		state.ellipsis.run = handle
		state.ellipsis.run_valid = true
	} else { state.ellipsis.run_valid = false }
	for i in 0..<len(state.labels) {
		label := &state.labels[i]
		if handle, ok := alicorn.runtime_host_text_run_set(
			rt, u64(WIN32_CHROME_LABEL_NODE_BASE+alicorn.Node_ID(i)), label.text, 14*scale,
			allocator=state.allocator,
		); ok {
			label.run = handle
			label.run_valid = true
		} else { label.run_valid = false }
	}
	state.text_scale = scale
	state.font_generation = font_generation
	win32_chrome_layout_labels(state)
	win32_chrome_request_redraw(state)
	return true
}

win32_chrome_sync_metrics :: proc(state: ^Win32_Chrome_State, rt: ^alicorn.Runtime) -> bool {
	if state == nil || state.adapter == nil || rt == nil || state.adapter.chrome.metrics == nil { return false }
	client: win.RECT
	if !win.GetClientRect(state.hwnd, &client) { return false }
	client_width := i32(client.right-client.left)
	client_height := i32(client.bottom-client.top)
	density := state.pixels_per_unit if state.pixels_per_unit > 0 else 1
	scale := f32(state.dpi if state.dpi != 0 else 96)/96
	content_start_pixels := i32(cpu_renderer.Pixel_Edge(8, scale))
	for label in state.labels {
		if label.bounds.right > label.bounds.left {
			content_start_pixels = max(content_start_pixels,
				i32(label.bounds.right)+i32(cpu_renderer.Pixel_Edge(8, scale)))
		}
	}
	content_end_pixels := max(i32(state.caption_controls[0].bounds.left)-
		i32(cpu_renderer.Pixel_Edge(8, scale)), 0)
	content_start_pixels = min(content_start_pixels, content_end_pixels)
	next := alicorn.Window_Chrome_Metrics{
		header=alicorn.Rect{0, 0, f32(client_width)/density, min(f32(state.chrome_height_pixels)/density, f32(client_height)/density)},
		content_start_x=f32(content_start_pixels)/density,
		content_end_x=f32(content_end_pixels)/density,
		display_scale=sdl3.GetWindowDisplayScale(state.window),
		fullscreen=(sdl3.GetWindowFlags(state.window) & sdl3.WindowFlags{.FULLSCREEN}) != sdl3.WindowFlags{},
	}
	for control in state.caption_controls {
		if control.bounds.right <= control.bounds.left || control.bounds.bottom <= control.bounds.top { continue }
		if next.native_control_count >= len(next.native_controls) { break }
		next.native_controls[next.native_control_count] = win32_chrome_rect_to_window(control.bounds, density)
		next.native_control_count += 1
	}
	changed := !state.metrics_valid || !alicorn.window_chrome_metrics_equal(state.metrics, next)
	state.metrics = next
	state.metrics_valid = true
	if !changed { return true }
	state.adapter.chrome.metrics(state.adapter.chrome.callback_state, rt, next)
	alicorn.invalidate_root(rt, "measured Windows titlebar geometry changed")
	return true
}

win32_chrome_resolve_geometry :: proc(
	rt: ^alicorn.Runtime,
	layout: alicorn.Window_Chrome_Layout,
	native_header: win.RECT,
	density: f32,
) -> Win32_Chrome_Geometry {
	geometry := Win32_Chrome_Geometry{application_owned=true}
	header, header_ok := alicorn.node_info(rt, layout.header)
	if header_ok && header.active {
		x0, y0, x1, y1 := cpu_renderer.Logical_To_Pixel_Bounds(header.bounds, density, density)
		retained_header := win.RECT{win.LONG(x0), win.LONG(y0), win.LONG(x1), win.LONG(y1)}
		geometry.header = win32_rect_intersection(retained_header, native_header)
	}
	if geometry.header.right <= geometry.header.left || geometry.header.bottom <= geometry.header.top { return geometry }
	for region in layout.regions {
		if region.node == 0 || geometry.region_count >= len(geometry.regions) { continue }
		node, ok := alicorn.node_info(rt, region.node)
		if !ok || !node.active { continue }
		region_bounds := node.bounds
		if region.kind == .Interactive && node.kind == .Split_Handle { region_bounds = node.hit_bounds }
		x0, y0, x1, y1 := cpu_renderer.Logical_To_Pixel_Bounds(region_bounds, density, density)
		bounds := win32_rect_intersection(
			win.RECT{win.LONG(x0), win.LONG(y0), win.LONG(x1), win.LONG(y1)},
			geometry.header,
		)
		if bounds.right <= bounds.left || bounds.bottom <= bounds.top { continue }
		geometry.regions[geometry.region_count] = Win32_Chrome_Hit_Region{bounds, region.kind}
		geometry.region_count += 1
	}
	return geometry
}

win32_chrome_sync_layout :: proc(state: ^Win32_Chrome_State, rt: ^alicorn.Runtime) -> bool {
	if state == nil || state.adapter == nil || rt == nil || state.adapter.chrome.layout == nil { return false }
	layout := state.adapter.chrome.layout(state.adapter.chrome.callback_state, rt)
	client: win.RECT
	if !win.GetClientRect(state.hwnd, &client) { return false }
	native_header := win.RECT{left=0, top=0, right=client.right,
		bottom=win.LONG(min(state.chrome_height_pixels, i32(client.bottom)))}
	next := win32_chrome_resolve_geometry(rt, layout, native_header, state.pixels_per_unit)
	if next.header != state.geometry.header || next.region_count != state.geometry.region_count {
		state.geometry = next
	} else {
		same := true
		for i in 0..<next.region_count {
			if next.regions[i] != state.geometry.regions[i] { same = false; break }
		}
		if !same { state.geometry = next }
	}
	return true
}

win32_chrome_sync :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || adapter.platform_data == nil || !adapter.chrome_active { return false }
	state := cast(^Win32_Menu_State)adapter.platform_data
	rt := win32_chrome_runtime(&state.chrome)
	if rt == nil { return false }
	_ = win32_chrome_resolve_appearance(&state.chrome)
	_ = win32_chrome_refresh_text(&state.chrome, rt)
	win32_chrome_layout_labels(&state.chrome)
	_ = win32_chrome_sync_layout(&state.chrome, rt)
	_ = win32_chrome_sync_metrics(&state.chrome, rt)
	return true
}

win32_chrome_extend_frame :: proc(state: ^Win32_Chrome_State) -> bool {
	if state == nil || state.hwnd == nil || !state.frame_enabled { return false }
	margins := win.MARGINS{0, 0, -1, 0}
	if DwmExtendFrameIntoClientArea(state.hwnd, &margins) < 0 { return false }
	state.frame_extended = true
	return true
}

win32_chrome_frame_changed :: proc(state: ^Win32_Chrome_State) -> bool {
	if state == nil || state.hwnd == nil { return false }
	flags := win.UINT(win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED)
	return win.SetWindowPos(state.hwnd, nil, 0, 0, 0, 0, flags) != false
}

win32_chrome_reapply_frame :: proc(state: ^Win32_Chrome_State) -> bool {
	if state == nil || !state.frame_enabled { return true }
	if !win32_chrome_extend_frame(state) { return false }
	if !win32_chrome_frame_changed(state) { return false }
	win32_chrome_layout_labels(state)
	win32_chrome_request_redraw(state)
	return true
}

win32_chrome_disable_frame :: proc(state: ^Win32_Chrome_State) {
	if state == nil { return }
	state.frame_enabled = false
	state.frame_extended = false
	state.chrome_height = 0
	state.last_inset = -1
	win32_chrome_publish_inset(state)
	if state.hwnd != nil {
		margins := win.MARGINS{}
		_ = DwmExtendFrameIntoClientArea(state.hwnd, &margins)
		_ = win32_chrome_frame_changed(state)
	}
	win32_chrome_request_redraw(state)
}

win32_chrome_activate :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || adapter.platform_data == nil { return true }
	state := cast(^Win32_Menu_State)adapter.platform_data
	chrome := &state.chrome
	if !chrome.frame_enabled { return true }
	rt := win32_chrome_runtime(chrome)
	if rt == nil { return false }
	chrome.title_text = adapter.chrome.title
	if win32_chrome_application_owns_header(chrome) { chrome.title_text = "" }
	if !win32_chrome_refresh_text(chrome, rt) || !win32_chrome_sync_masks(chrome) { return false }
	win32_chrome_layout_labels(chrome)
	_ = win32_chrome_sync_metrics(chrome, rt)
	_ = win32_chrome_sync_layout(chrome, rt)
	adapter.chrome_active = true
	win32_chrome_request_redraw(chrome)
	return true
}

win32_chrome_paint :: proc(
	adapter: ^Native_Menu_Adapter,
	width, height: f32,
	allocator: mem.Allocator,
) -> []alicorn.Paint_Command {
	if adapter == nil || adapter.platform_data == nil || !adapter.chrome_active { return nil }
	state := cast(^Win32_Menu_State)adapter.platform_data
	chrome := &state.chrome
	if !chrome.frame_enabled || chrome.chrome_height <= 0 { return nil }
	if !win32_chrome_sync_masks(chrome) { return nil }
	rt := win32_chrome_runtime(chrome)
	if rt != nil {
		_ = win32_chrome_resolve_appearance(chrome)
		_ = win32_chrome_refresh_text(chrome, rt)
	}
	commands := make([dynamic]alicorn.Paint_Command, 0, len(chrome.labels)*2+96, allocator=allocator)
	background, foreground := win32_chrome_colors(chrome)
	hover_background, open_background, pressed_background := win32_chrome_feedback_colors(background, foreground)
	full := alicorn.Rect{0, 0, width, min(chrome.chrome_height, height)}
	application_chrome := win32_chrome_application_owns_header(chrome)
	if !application_chrome {
		append(&commands, alicorn.paint_surface_command(WIN32_CHROME_HOST_SOLID_NODE, full, full, background))
	}
	active_index := chrome.hovered
	if chrome.menu_mode && chrome.active_menu >= 0 { active_index = chrome.active_menu }
	selection_background, selection_foreground := alicorn.Color{}, alicorn.Color{}
	if chrome.high_contrast {
		selection_background, selection_foreground = win32_chrome_high_contrast_selection_colors()
	}
	if active_index >= 0 && active_index < len(chrome.labels) {
		bounds := chrome.labels[active_index].bounds
		if bounds.right > bounds.left {
			label_background := hover_background
			if chrome.menu_mode && chrome.active_menu == active_index { label_background = open_background }
			if chrome.high_contrast { label_background = selection_background }
			append(&commands, alicorn.paint_surface_command(
				WIN32_CHROME_HOST_SOLID_NODE+1,
				win32_chrome_rect_to_window(bounds, chrome.pixels_per_unit),
				full, label_background,
			))
		}
	}
	for label in chrome.labels {
		if label.direct_menu == nil || !label.direct_menu.state.checked || label.bounds.right <= label.bounds.left { continue }
		selected_background := open_background
		if chrome.high_contrast { selected_background = selection_background }
		append(&commands, alicorn.paint_surface_command(
			WIN32_CHROME_HOST_SOLID_NODE+1,
			win32_chrome_rect_to_window(label.bounds, chrome.pixels_per_unit),
			full, selected_background,
		))
	}
	maximized := chrome.maximized
	for control, index in chrome.caption_controls {
		if control.bounds.right <= control.bounds.left || control.bounds.bottom <= control.bounds.top { continue }
		button_foreground := foreground
		if index == chrome.caption_hovered {
			hover_color := hover_background
			if index == 2 && !chrome.high_contrast {
				hover_color = win32_chrome_color_rgb(232, 17, 35)
				button_foreground = win32_chrome_color_rgb(255, 255, 255)
				if index == chrome.caption_pressed { hover_color = win32_chrome_color_mix(background, hover_color, 0.60) }
			} else if chrome.high_contrast {
				hover_color = selection_background
				button_foreground = selection_foreground
			} else if index == chrome.caption_pressed { hover_color = pressed_background }
			append(&commands, alicorn.paint_surface_command(
				WIN32_CHROME_HOST_SOLID_NODE+2+alicorn.Node_ID(index),
				win32_chrome_rect_to_window(control.hover_bounds, chrome.pixels_per_unit),
				full, hover_color,
			))
		}
		win32_chrome_append_glyph(&commands, chrome, index, button_foreground, full, maximized)
	}
	if !application_chrome { win32_chrome_append_text(&commands, chrome, chrome.title, 8, foreground, ellipsis=true) }
	for label, i in chrome.labels {
		if label.bounds.right <= label.bounds.left { continue }
		label_color := foreground
		if label.direct_menu != nil {
			if !label.direct_menu.state.enabled {
				if chrome.high_contrast { label_color = win32_chrome_color_ref(win.GetSysColor(win.COLOR_GRAYTEXT)) }
				else { label_color = win32_chrome_color_mix(background, foreground, 0.48) }
			} else if i == active_index && chrome.high_contrast ||
				(label.direct_menu.state.checked && chrome.high_contrast) {
				label_color = selection_foreground
			}
		} else if i == active_index && chrome.high_contrast { label_color = selection_foreground }
		win32_chrome_append_text(&commands, chrome, label, 12, label_color)
	}
	return commands[:]
}

win32_chrome_append_text :: proc(
	commands: ^[dynamic]alicorn.Paint_Command, state: ^Win32_Chrome_State,
	label: Win32_Chrome_Label, padding: f32, color: alicorn.Color, ellipsis := false,
) {
	rt := win32_chrome_runtime(state)
	if rt == nil || !label.run_valid || label.bounds.right <= label.bounds.left { return }
	run, ok := alicorn.runtime_host_text_run_resolve(rt, label.run)
	if !ok || run == nil { return }
	bounds := label.bounds
	inset := win.LONG(cpu_renderer.Pixel_Edge(padding, f32(state.dpi if state.dpi != 0 else 96)/96))
	bounds.left = min(bounds.left+inset, bounds.right)
	bounds.right = max(bounds.right-inset, bounds.left)
	clip := win32_chrome_rect_to_window(bounds, state.pixels_per_unit)
	if clip.w <= 0 { return }
	y := clip.y+max((clip.h-run.height)/2, 0)
	text_clip := clip
	if ellipsis && run.width > clip.w && state.ellipsis.run_valid {
		if mark, mark_ok := alicorn.runtime_host_text_run_resolve(rt, state.ellipsis.run); mark_ok && mark != nil {
			text_clip.w = max(clip.w-mark.width, 0)
			append(commands, alicorn.paint_text_command(state.ellipsis.host_node,
				alicorn.Rect{clip.x+text_clip.w, y, mark.width, mark.height}, clip,
				state.ellipsis.run, color))
		}
	}
	if text_clip.w > 0 {
		append(commands, alicorn.paint_text_command(label.host_node,
			alicorn.Rect{clip.x, y, run.width, run.height}, text_clip, label.run, color))
	}
}

win32_chrome_label_at :: proc(state: ^Win32_Chrome_State, x, y: i32) -> int {
	if state == nil || win32_chrome_labels_hidden(state) { return -1 }
	for label, i in state.labels {
		if win32_rect_contains(label.bounds, x, y) { return i }
	}
	return -1
}

win32_chrome_screen_to_window :: proc(state: ^Win32_Chrome_State, screen_x, screen_y: i32) -> (i32, i32, bool) {
	origin := win.POINT{}
	if !win.ClientToScreen(state.hwnd, &origin) { return 0, 0, false }
	x, y := win32_screen_point_to_client_pixels(screen_x, screen_y, i32(origin.x), i32(origin.y))
	return x, y, true
}

win32_chrome_caption_control_at_screen :: proc(state: ^Win32_Chrome_State, screen_x, screen_y: i32) -> int {
	x, y, ok := win32_chrome_screen_to_window(state, screen_x, screen_y)
	if !ok { return -1 }
	return win32_caption_control_at(x, y, state.caption_controls[:])
}

win32_chrome_frame_hit_test :: proc(state: ^Win32_Chrome_State, screen_x, screen_y: i32) -> win.LRESULT {
	if state == nil || !state.frame_enabled { return win.LRESULT(win.HTCLIENT) }
	client: win.RECT
	if !win.GetClientRect(state.hwnd, &client) { return win.LRESULT(win.HTCLIENT) }
	origin := win.POINT{}
	if !win.ClientToScreen(state.hwnd, &origin) { return win.LRESULT(win.HTCLIENT) }
	dpi := win.GetDpiForWindow(state.hwnd)
	if dpi == 0 { dpi = 96 }
	x, y := win32_screen_point_to_client_pixels(screen_x, screen_y, i32(origin.x), i32(origin.y))
	width := i32(client.right-client.left)
	height := i32(client.bottom-client.top)
	resize_x := i32(win.GetSystemMetricsForDpi(win.SM_CXSIZEFRAME, dpi)+win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi))
	resize_y := i32(win.GetSystemMetricsForDpi(win.SM_CYSIZEFRAME, dpi)+win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi))
	labels := make([]win.RECT, len(state.labels), allocator=context.temp_allocator)
	for label, i in state.labels { labels[i] = label.bounds }
	defer delete(labels, context.temp_allocator)
	return win32_integrated_frame_hit_test(x, y, width, height, state.chrome_height_pixels,
		resize_x, resize_y, state.maximized, state.caption_controls[:], labels,
		state.geometry.regions[:state.geometry.region_count], state.geometry.application_owned,
		state.gesture_owner)
}

win32_chrome_update_caption_pointer :: proc(state: ^Win32_Chrome_State, message: win.UINT, lparam: win.LPARAM) {
	if message == win.WM_NCMOUSELEAVE {
		if state.caption_hovered >= 0 {
			state.caption_hovered = -1
			win32_chrome_request_redraw(state)
		}
		return
	}
	point := win32_chrome_point_from_lparam(lparam)
	index := win32_chrome_caption_control_at_screen(state, i32(point.x), i32(point.y))
	if message == win.WM_NCMOUSEMOVE {
		if state.caption_hovered != index {
			state.caption_hovered = index
			win32_chrome_request_redraw(state)
		}
		if index >= 0 {
			track := win.TRACKMOUSEEVENT{cbSize=win.DWORD(size_of(win.TRACKMOUSEEVENT)),
				dwFlags=win.TME_LEAVE | win.TME_NONCLIENT, hwndTrack=state.hwnd}
			_ = win.TrackMouseEvent(&track)
		}
	} else if message == win.WM_NCLBUTTONDOWN {
		if state.caption_pressed != index {
			state.caption_pressed = index
			win32_chrome_request_redraw(state)
		}
	} else if message == win.WM_NCLBUTTONUP {
		if state.caption_pressed >= 0 {
			state.caption_pressed = -1
			win32_chrome_request_redraw(state)
		}
	}
}

win32_chrome_exit_mode :: proc(state: ^Win32_Chrome_State, hovered_index: int) {
	state.menu_mode = false
	state.alt_menu_pending = false
	state.active_menu = -1
	state.hovered = hovered_index
	win32_chrome_request_redraw(state)
}

win32_chrome_hovered_label_at_cursor :: proc(state: ^Win32_Chrome_State) -> int {
	point := win.POINT{}
	if !win.GetCursorPos(&point) { return -1 }
	x, y, ok := win32_chrome_screen_to_window(state, i32(point.x), i32(point.y))
	if !ok { return -1 }
	return win32_chrome_label_at(state, x, y)
}

win32_chrome_popup_anchor :: proc(state: ^Win32_Chrome_State, index: int) -> win.POINT {
	if index < 0 || index >= len(state.labels) { return {} }
	if win32_chrome_labels_hidden(state) {
		scale := f32(state.dpi if state.dpi != 0 else 96)/96
		return win.POINT{win.LONG(cpu_renderer.Pixel_Edge(8, scale)), win.LONG(state.chrome_height_pixels)}
	}
	return win.POINT{state.labels[index].bounds.left, state.labels[index].bounds.bottom}
}

win32_chrome_open_popup :: proc(state: ^Win32_Chrome_State, index: int) {
	if index < 0 || index >= len(state.labels) { return }
	label := state.labels[index]
	if label.popup == nil { return }
	native_menu_adapter_refresh(state.adapter)
	origin := win.POINT{}
	if !win.ClientToScreen(state.hwnd, &origin) { return }
	anchor := win32_chrome_popup_anchor(state, index)
	flags := win.UINT(win.TPM_RETURNCMD | win.TPM_NONOTIFY | win.TPM_LEFTALIGN | win.TPM_TOPALIGN)
	command := win.TrackPopupMenu(label.popup, flags,
		win.INT(origin.x+anchor.x), win.INT(origin.y+anchor.y), 0, state.hwnd, nil)
	hovered_index := -1
	if command == 0 { hovered_index = win32_chrome_hovered_label_at_cursor(state) }
	if command != 0 {
		u32_command := u32(command)
		if u32_command > 0 && state.menu_state != nil && int(u32_command) < len(state.menu_state.commands) {
			native_menu_adapter_queue(state.adapter, state.menu_state.commands[u32_command])
		}
	}
	win32_chrome_exit_mode(state, hovered_index)
	_ = win.PostMessageW(state.hwnd, win.WM_NULL, 0, 0)
}

win32_chrome_label_activate :: proc(state: ^Win32_Chrome_State, index: int) {
	if index < 0 || index >= len(state.labels) { return }
	state.alt_menu_pending = false
	label := &state.labels[index]
	if label.direct_menu != nil {
		if label.direct_menu.state.enabled {
			native_menu_adapter_queue(state.adapter, label.direct_menu.command)
		}
		win32_chrome_exit_mode(state, -1)
		return
	}
	state.active_menu = index
	win32_chrome_open_popup(state, index)
}

win32_chrome_handle_keydown :: proc(adapter: ^Native_Menu_Adapter, keycode: int, modifiers: sdl3.Keymod) -> bool {
	if adapter == nil || adapter.platform_data == nil || adapter.chrome.decorations != .Integrated_Title_Bar { return false }
	state := cast(^Win32_Menu_State)adapter.platform_data
	chrome := &state.chrome
	alt := modifiers&sdl3.KMOD_ALT != {}
	control := modifiers&sdl3.KMOD_CTRL != {}
	super := modifiers&sdl3.KMOD_GUI != {}
	if alt && keycode == int(sdl3.K_SPACE) { chrome.alt_menu_pending = false; return false }
	if (keycode == int(sdl3.K_LALT) || keycode == int(sdl3.K_RALT)) && !control && !super {
		if len(chrome.labels) == 0 { return false }
		if win32_chrome_labels_hidden(chrome) { chrome.alt_menu_pending = true; return true }
		chrome.menu_mode = true
		chrome.active_menu = 0
		chrome.hovered = -1
		win32_chrome_request_redraw(chrome)
		return true
	}
	chrome.alt_menu_pending = false
	if alt && !control && !super {
		upper := keycode
		if upper >= 'a' && upper <= 'z' { upper -= ('a' - 'A') }
		for label, i in chrome.labels {
			if len(label.text) > 0 {
				first := int(label.text[0])
				if first >= 'a' && first <= 'z' { first -= ('a' - 'A') }
				if first == upper {
					chrome.menu_mode = true
					chrome.active_menu = i
					chrome.hovered = -1
					win32_chrome_label_activate(chrome, i)
					return true
				}
			}
		}
	}
	if !chrome.menu_mode { return false }
	if keycode == int(sdl3.K_ESCAPE) {
		win32_chrome_exit_mode(chrome, win32_chrome_hovered_label_at_cursor(chrome))
		return true
	}
	if keycode == int(sdl3.K_LEFT) || keycode == int(sdl3.K_RIGHT) {
		count := len(chrome.labels)
		if count == 0 { return true }
		delta := 1
		if keycode == int(sdl3.K_LEFT) { delta = count-1 }
		chrome.active_menu = (chrome.active_menu+delta)%count
		win32_chrome_request_redraw(chrome)
		return true
	}
	if !alt && !control && !super {
		upper := keycode
		if upper >= 'a' && upper <= 'z' { upper -= ('a' - 'A') }
		for label, i in chrome.labels {
			if len(label.text) > 0 {
				first := int(label.text[0])
				if first >= 'a' && first <= 'z' { first -= ('a' - 'A') }
				if first == upper {
					chrome.active_menu = i
					chrome.hovered = -1
					win32_chrome_label_activate(chrome, i)
					return true
				}
			}
		}
	}
	if keycode == int(sdl3.K_RETURN) || keycode == int(sdl3.K_KP_ENTER) || keycode == int(sdl3.K_SPACE) {
		win32_chrome_label_activate(chrome, chrome.active_menu)
		return true
	}
	return false
}

win32_chrome_take_alt_popup :: proc(state: ^Win32_Chrome_State) -> int {
	pending := state.alt_menu_pending
	state.alt_menu_pending = false
	if pending && win32_chrome_labels_hidden(state) {
		for label, index in state.labels {
			if label.popup != nil && label.direct_menu == nil { return index }
		}
	}
	return -1
}

win32_chrome_cancel_input :: proc(state: ^Win32_Chrome_State) {
	if state == nil { return }
	state.gesture_owner = .None
	state.alt_menu_pending = false
}

// win32_chrome_handle_message returns handled=true when the chrome adapter
// consumed the message. Callers run DwmDefWindowProc first for non-client
// messages and pass its result in for hit-test merging.
win32_chrome_handle_message :: proc(
	state: ^Win32_Chrome_State,
	message: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	dwm_handled: bool,
	dwm_result: win.LRESULT,
) -> (result: win.LRESULT, handled: bool) {
	if state == nil || !state.frame_enabled { return 0, false }
	integrated := true
	if message == win.WM_CANCELMODE || message == win.WM_CAPTURECHANGED || message == win.WM_KILLFOCUS {
		win32_chrome_cancel_input(state)
	} else if message == win.WM_LBUTTONUP &&
		(state.gesture_owner == .Alicorn || state.gesture_owner == .Native_Menu) {
		state.gesture_owner = .None
	} else if message == win.WM_NCLBUTTONUP && state.gesture_owner == .Window {
		state.gesture_owner = .None
	} else if (message == win.WM_NCLBUTTONDOWN || message == win.WM_NCLBUTTONDBLCLK) &&
		wparam == win.WPARAM(win.HTCAPTION) {
		state.gesture_owner = .Window
	}

	if integrated && message == win.WM_NCCALCSIZE {
		if win.IsZoomed(state.hwnd) != false {
			monitor := win.MonitorFromWindow(state.hwnd, .MONITOR_DEFAULTTONEAREST)
			monitor_info := win.MONITORINFO{cbSize=win.DWORD(size_of(win.MONITORINFO))}
			if monitor != nil && win.GetMonitorInfoW(monitor, &monitor_info) {
				if wparam != 0 {
					params := cast(^win.NCCALCSIZE_PARAMS)uintptr(lparam)
					if params != nil { params.rgrc[0] = monitor_info.rcWork }
				} else {
					rect := cast(^win.RECT)uintptr(lparam)
					if rect != nil { rect^ = monitor_info.rcWork }
				}
			}
		}
		return 0, true
	}
	if integrated && (message == win.WM_NCMOUSEMOVE || message == win.WM_NCLBUTTONDOWN ||
		message == win.WM_NCRBUTTONDOWN || message == win.WM_NCLBUTTONUP || message == win.WM_NCRBUTTONUP) {
		win32_chrome_cancel_app_pointer(state)
	}
	if integrated && (message == win.WM_NCMOUSEMOVE || message == win.WM_NCMOUSELEAVE ||
		message == win.WM_NCLBUTTONDOWN || message == win.WM_NCLBUTTONUP) {
		win32_chrome_update_caption_pointer(state, message, lparam)
	}
	if integrated && message == win.WM_NCHITTEST {
		point := win32_chrome_point_from_lparam(lparam)
		hit := win32_chrome_frame_hit_test(state, i32(point.x), i32(point.y))
		return win32_integrated_frame_resolve_gesture_hit_test(hit, state.gesture_owner, dwm_handled, dwm_result), true
	}
	if dwm_handled { return dwm_result, true }

	if integrated {
		if message == win.WM_LBUTTONDOWN || message == win.WM_RBUTTONDOWN ||
			message == win.WM_NCLBUTTONDOWN || message == win.WM_NCRBUTTONDOWN {
			state.alt_menu_pending = false
		}
		if message == win.WM_LBUTTONUP && state.caption_pressed >= 0 {
			state.caption_pressed = -1
			win32_chrome_request_redraw(state)
		} else if message == win.WM_LBUTTONDOWN {
			state.gesture_owner = .Alicorn
			point := win32_chrome_point_from_lparam(lparam)
			if index := win32_chrome_label_at(state, i32(point.x), i32(point.y)); index >= 0 {
				state.gesture_owner = .Native_Menu
				win32_chrome_cancel_app_pointer(state)
				if state.labels[index].direct_menu != nil {
					win32_chrome_label_activate(state, index)
				} else {
					state.menu_mode = true
					state.active_menu = index
					win32_chrome_open_popup(state, index)
				}
				state.gesture_owner = .None
				return 0, true
			}
			if state.menu_mode { win32_chrome_exit_mode(state, state.hovered) }
		} else if message == win.WM_MOUSEMOVE {
			if state.caption_hovered >= 0 {
				state.caption_hovered = -1
				win32_chrome_request_redraw(state)
			}
			point := win32_chrome_point_from_lparam(lparam)
			index := win32_chrome_label_at(state, i32(point.x), i32(point.y))
			if index >= 0 && state.gesture_owner != .Alicorn { win32_chrome_cancel_app_pointer(state) }
			if index != state.hovered {
				state.hovered = index
				win32_chrome_request_redraw(state)
			}
			track := win.TRACKMOUSEEVENT{cbSize=win.DWORD(size_of(win.TRACKMOUSEEVENT)), dwFlags=win.TME_LEAVE, hwndTrack=state.hwnd}
			_ = win.TrackMouseEvent(&track)
		} else if message == win.WM_MOUSELEAVE {
			if state.hovered >= 0 {
				state.hovered = -1
				win32_chrome_request_redraw(state)
			}
		} else if message == win.WM_SYSKEYDOWN {
			key := int(uintptr(wparam) & 0xff)
			alt_context := (uintptr(lparam) & (uintptr(1) << 29)) != 0
			if key == win.VK_MENU {
				if len(state.labels) > 0 {
					if win32_chrome_labels_hidden(state) {
						state.alt_menu_pending = win.GetKeyState(win.VK_CONTROL) >= 0 &&
							win.GetKeyState(win.VK_LWIN) >= 0 && win.GetKeyState(win.VK_RWIN) >= 0
						if state.alt_menu_pending { return 0, true }
						return 0, false
					}
					state.menu_mode = true
					state.active_menu = 0
					state.hovered = -1
					win32_chrome_request_redraw(state)
					return 0, true
				}
			} else if key != WIN32_VK_SPACE && alt_context {
				state.alt_menu_pending = false
				for label, index in state.labels {
					if len(label.text) > 0 {
						first := int(label.text[0])
						if first >= 'a' && first <= 'z' { first -= ('a' - 'A') }
						if first == key {
							state.menu_mode = true
							state.active_menu = index
							state.hovered = -1
							win32_chrome_request_redraw(state)
							win32_chrome_label_activate(state, index)
							return 0, true
						}
					}
				}
			} else { state.alt_menu_pending = false }
		} else if message == win.WM_SYSKEYUP && int(uintptr(wparam) & 0xff) == win.VK_MENU {
			if index := win32_chrome_take_alt_popup(state); index >= 0 {
				win32_chrome_label_activate(state, index)
				return 0, true
			}
		}
	}
	return 0, false
}

// win32_chrome_post_message runs after DefSubclassProc for state transitions
// that depend on the default window behavior having run.
win32_chrome_post_message :: proc(state: ^Win32_Chrome_State, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) {
	if state == nil { return }
	integrated := state.frame_enabled
	if message == win.WM_DWMCOMPOSITIONCHANGED && integrated {
		if !win32_chrome_reapply_frame(state) { win32_chrome_disable_frame(state) }
	} else if message == win.WM_NCACTIVATE || message == win.WM_ACTIVATE {
		active := wparam != 0
		if message == win.WM_ACTIVATE { active = (u16(uintptr(wparam)) & 0xffff) != 0 }
		if state.active != active {
			state.active = active
			state.caption_hovered = -1
			state.caption_pressed = -1
			win32_chrome_request_redraw(state)
		}
	} else if message == win.WM_DPICHANGED && integrated {
		state.dpi = win.GetDpiForWindow(state.hwnd)
		if rt := win32_chrome_runtime(state); rt != nil {
			_ = win32_chrome_refresh_text(state, rt)
			_ = win32_chrome_sync_metrics(state, rt)
		}
		if !win32_chrome_extend_frame(state) { win32_chrome_disable_frame(state) } else { win32_chrome_layout_labels(state) }
		win32_chrome_request_redraw(state)
	} else if (message == win.WM_WINDOWPOSCHANGED || message == win.WM_SIZE) && integrated {
		position := cast(^win.WINDOWPOS)uintptr(lparam)
		if message == win.WM_SIZE || (position != nil &&
			((position.flags & win.SWP_NOSIZE) == 0 || (position.flags & win.SWP_SHOWWINDOW) != 0)) {
			was_maximized := state.maximized
			win32_chrome_layout_labels(state)
			// A caption double-click changes zoom without a matching
			// WM_NCLBUTTONUP on every system, which would leave the drag gesture
			// latched and make every later hit test report HTCAPTION.
			if state.maximized != was_maximized { state.gesture_owner = .None }
			if rt := win32_chrome_runtime(state); rt != nil {
				_ = win32_chrome_sync_metrics(state, rt)
				_ = win32_chrome_sync_layout(state, rt)
			}
		}
		win32_chrome_request_redraw(state)
	} else if (message == win.WM_THEMECHANGED || message == win.WM_SETTINGCHANGE ||
		message == win.WM_SYSCOLORCHANGE) && integrated {
		win32_chrome_layout_labels(state)
		win32_chrome_request_redraw(state)
	} else if message == win.WM_KILLFOCUS && integrated {
		win32_chrome_exit_mode(state, -1)
		state.caption_hovered = -1
		state.caption_pressed = -1
	}
}

// win32_chrome_cancel_app_pointer mirrors the native host's pointer-capture
// cancellation when native chrome takes ownership of a gesture.
win32_chrome_cancel_app_pointer :: proc(state: ^Win32_Chrome_State) {
	if state == nil || state.adapter == nil || state.adapter.hosted == nil { return }
	_ = alicorn.hosted_runtime_pointer_cancel(state.adapter.hosted)
}
