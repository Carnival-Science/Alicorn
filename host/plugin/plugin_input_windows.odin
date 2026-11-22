#+build windows

package plugin_host

import "base:runtime"
import "core:unicode/utf8"
import alicorn "alicorn:runtime"
import presentation_host "alicorn:host/presentation"
import win "core:sys/windows"

// Scoped Win32 input translation for one embedded child HWND.
//
// The child window owns its own message identity, so the host does not need a
// global filter or a shared pointer stream: WM_MOUSE*/WM_KEY* arriving on this
// hwnd belong to this editor, and the host's normal message pump dispatches
// them here. No global keyboard hook and no SDL event loop are involved.

PLUGIN_DLGC_WANTARROWS :: win.LONG_PTR(0x0001)
PLUGIN_DLGC_WANTTAB     :: win.LONG_PTR(0x0002)
PLUGIN_DLGC_WANTALLKEYS :: win.LONG_PTR(0x0004)
PLUGIN_DLGC_WANTCHARS   :: win.LONG_PTR(0x0080)
PLUGIN_MA_ACTIVATE      :: win.LONG_PTR(1)

@(private)
plugin_editor_from_hwnd :: proc(hwnd: win.HWND) -> ^Plugin_Editor {
	value := win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)
	if value == 0 { return nil }
	return cast(^Plugin_Editor)(uintptr(value))
}

@(private)
plugin_modifier_down :: proc(vk: i32) -> bool {
	return (u16(win.GetAsyncKeyState(vk)) & 0x8000) != 0
}

@(private)
plugin_input_modifiers :: proc() -> alicorn.Input_Modifiers {
	return {
		shift=plugin_modifier_down(win.VK_SHIFT),
		control=plugin_modifier_down(win.VK_CONTROL),
		alt=plugin_modifier_down(win.VK_MENU),
		super=plugin_modifier_down(win.VK_LWIN) || plugin_modifier_down(win.VK_RWIN),
	}
}

@(private)
plugin_key_modifiers :: proc(modifiers: alicorn.Input_Modifiers) -> alicorn.Key_Modifiers {
	result: alicorn.Key_Modifiers
	if modifiers.shift { result += {.Shift} }
	if modifiers.alt { result += {.Alt} }
	if modifiers.control { result += {.Primary} }
	if modifiers.super { result += {.Super} }
	return result
}

@(private)
plugin_key_spec_from_vk :: proc(vk: u32) -> alicorn.Key_Spec {
	switch vk {
	case u32(win.VK_LEFT): return .Left
	case u32(win.VK_RIGHT): return .Right
	case u32(win.VK_UP): return .Up
	case u32(win.VK_DOWN): return .Down
	case u32(win.VK_PRIOR): return .Page_Up
	case u32(win.VK_NEXT): return .Page_Down
	case u32(win.VK_HOME): return .Home
	case u32(win.VK_END): return .End
	case u32(win.VK_INSERT): return .Insert
	case u32(win.VK_SPACE): return .Space
	case u32(win.VK_RETURN): return .Return
	case u32(win.VK_ESCAPE): return .Escape
	case u32(win.VK_TAB): return .Tab
	case u32(win.VK_BACK): return .Backspace
	case u32(win.VK_DELETE): return .Delete
	case u32(win.VK_OEM_MINUS): return .Minus
	case u32(win.VK_OEM_PLUS): return .Equal
	case u32(win.VK_OEM_4): return .Left_Bracket
	case u32(win.VK_OEM_6): return .Right_Bracket
	case u32(win.VK_OEM_5): return .Backslash
	case u32(win.VK_OEM_1): return .Semicolon
	case u32(win.VK_OEM_7): return .Apostrophe
	case u32(win.VK_OEM_COMMA): return .Comma
	case u32(win.VK_OEM_PERIOD): return .Period
	case u32(win.VK_OEM_2): return .Slash
	case u32(win.VK_OEM_3): return .Grave
	case u32(win.VK_F1)..=u32(win.VK_F12):
		return alicorn.Key_Spec(int(alicorn.Key_Spec.F1) + int(vk-u32(win.VK_F1)))
	case u32(win.VK_A)..=u32(win.VK_Z):
		return alicorn.Key_Spec(int(alicorn.Key_Spec.A) + int(vk-u32(win.VK_A)))
	case u32(win.VK_0)..=u32(win.VK_9):
		return alicorn.Key_Spec(int(alicorn.Key_Spec.Zero) + int(vk-u32(win.VK_0)))
	case:
		return .Unknown
	}
}

@(private)
plugin_application_key_from_vk :: proc(
	vk: u32,
	modifiers: alicorn.Input_Modifiers,
) -> (alp: alicorn.Application_Key, ok: bool) {
	switch vk {
	case u32(win.VK_LEFT): return .Left, true
	case u32(win.VK_RIGHT): return .Right, true
	case u32(win.VK_UP): return .Up, true
	case u32(win.VK_DOWN): return .Down, true
	case u32(win.VK_PRIOR): return .Page_Up, true
	case u32(win.VK_NEXT): return .Page_Down, true
	case u32(win.VK_HOME): return .Home, true
	case u32(win.VK_END): return .End, true
	case u32(win.VK_ESCAPE): return .Escape, true
	case u32(win.VK_RETURN): return .Return, true
	}
	if modifiers.control {
		if modifiers.shift {
			switch vk {
			case u32(win.VK_F): return .Find_Previous, true
			case u32(win.VK_P): return .Open_Command_Palette, true
			}
		}
		switch vk {
		case u32(win.VK_F): return .Find, true
		case u32(win.VK_O): return .Open_Repository, true
		case u32(win.VK_OEM_PLUS): return .Zoom_In, true
		case u32(win.VK_OEM_MINUS): return .Zoom_Out, true
		case u32(win.VK_0): return .Zoom_Reset, true
		}
	}
	return {}, false
}

@(private)
plugin_text_key_from_vk :: proc(
	vk: u32,
	modifiers: alicorn.Input_Modifiers,
) -> (key: alicorn.Application_Text_Navigation_Key, ok: bool) {
	switch vk {
	case u32(win.VK_LEFT):
		return .Word_Left if modifiers.control else .Left, true
	case u32(win.VK_RIGHT):
		return .Word_Right if modifiers.control else .Right, true
	case u32(win.VK_HOME):
		return .Document_Start if modifiers.control else .Line_Start, true
	case u32(win.VK_END):
		return .Document_End if modifiers.control else .Line_End, true
	case u32(win.VK_UP): return .Up, true
	case u32(win.VK_DOWN): return .Down, true
	case u32(win.VK_PRIOR): return .Page_Up, true
	case u32(win.VK_NEXT): return .Page_Down, true
	case u32(win.VK_BACK):
		return .Delete_Word_Backward if modifiers.control else .Backspace, true
	case u32(win.VK_DELETE):
		return .Delete_Word_Forward if modifiers.control else .Delete, true
	case u32(win.VK_TAB): return .Tab, true
	}
	return {}, false
}

@(private)
plugin_editor_text_focused :: proc(editor: ^Plugin_Editor) -> bool {
	if editor == nil { return false }
	rt, status := alicorn.hosted_runtime_borrow(&editor.hosted)
	if status != .Ok { return false }
	owner := alicorn.focused_node(rt)
	if owner == 0 { return false }
	info, ok := alicorn.node_info(rt, owner)
	if !ok || !info.active || info.disabled { return false }
	return info.kind == .Text_Field || info.text_input_target || alicorn.select_wants_text_input(rt)
}

@(private)
plugin_editor_pointer :: proc(
	editor: ^Plugin_Editor,
	kind: alicorn.Pointer_Kind,
	x, y: int,
	button: int,
	click_count: u8,
) {
	event := alicorn.Pointer_Event{
		kind=kind,
		x=f32(x),
		y=f32(y),
		button=button,
		modifiers=plugin_input_modifiers(),
		click_count=click_count,
		timestamp_ns=plugin_monotonic_now_ns(),
	}
	_, _ = alicorn.hosted_runtime_pointer(&editor.hosted, event)
}

@(private)
plugin_editor_key_down :: proc(editor: ^Plugin_Editor, vk: u32, repeat: bool) {
	modifiers := plugin_input_modifiers()
	key := plugin_key_spec_from_vk(vk)
	text_focused := plugin_editor_text_focused(editor)
	app_key, has_app := plugin_application_key_from_vk(vk, modifiers)
	event := alicorn.Key_Event{
		scancode=vk,
		key=key,
		modifiers=plugin_key_modifiers(modifiers),
		repeat=repeat,
		composition_active=false,
		text_input_focused=text_focused,
		produces_text=alicorn.key_event_produces_text(key, plugin_key_modifiers(modifiers)),
		timestamp_ns=plugin_monotonic_now_ns(),
		application_key=app_key,
		has_application_key=has_app,
	}
	handled, status := alicorn.hosted_runtime_key_event(&editor.hosted, event)
	if status != .Ok { return }
	if handled { return }

	if vk == u32(win.VK_TAB) {
		direction := alicorn.Focus_Direction.Next
		if modifiers.shift { direction = .Previous }
		focused, focus_status := alicorn.hosted_runtime_focus_traverse(&editor.hosted, direction)
		if focus_status == .Ok && focused != 0 { return }
	}
	if text_focused {
		if text_key, ok := plugin_text_key_from_vk(vk, modifiers); ok {
			_, _ = alicorn.hosted_runtime_text_key(&editor.hosted, alicorn.Application_Text_Key_Event{
				key=text_key,
				shift=modifiers.shift,
				control=modifiers.control,
				alt=modifiers.alt,
				super=modifiers.super,
			})
			return
		}
		return
	}
	if !modifiers.control && !modifiers.alt && !modifiers.super && !modifiers.shift {
		if vk == u32(win.VK_RETURN) {
			_, _ = alicorn.hosted_runtime_activate(&editor.hosted, .Enter)
		} else if vk == u32(win.VK_SPACE) {
			_, _ = alicorn.hosted_runtime_activate(&editor.hosted, .Space)
		}
	}
}

@(private)
plugin_editor_text_char :: proc(editor: ^Plugin_Editor, unit: u16) {
	impl := editor.impl
	if impl == nil { return }
	value := rune(unit)
	if unit >= 0xD800 && unit <= 0xDBFF {
		impl.pending_high_surrogate = unit
		return
	}
	if unit >= 0xDC00 && unit <= 0xDFFF {
		if impl.pending_high_surrogate == 0 { return }
		high := u32(impl.pending_high_surrogate)
		low := u32(unit)
		impl.pending_high_surrogate = 0
		value = rune(0x10000 + (high-0xD800)*0x400 + (low-0xDC00))
	} else {
		impl.pending_high_surrogate = 0
	}
	if value < 32 || value == 127 { return }
	buf, size := utf8.encode_rune(value)
	text := string(buf[:size])
	if rt, status := alicorn.hosted_runtime_borrow(&editor.hosted); status == .Ok {
		if alicorn.select_wants_text_input(rt) && alicorn.select_typeahead(rt, text) { return }
	}
	_ = alicorn.hosted_runtime_text_input(&editor.hosted, 0, .Commit, text)
}

@(private)
plugin_editor_set_visible_from_window :: proc(editor: ^Plugin_Editor, visible: bool) {
	impl := editor.impl
	if impl == nil || impl.closed { return }
	impl.visible = visible
	impl.renderable = visible
	if impl.presenter_attached {
		_ = presentation_host.hosted_surface_presenter_set_visible(&impl.presenter, visible)
	}
	if visible {
		_ = plugin_editor_request_presentation(editor)
	}
}

plugin_editor_wndproc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = runtime.default_context()
	editor := plugin_editor_from_hwnd(hwnd)
	if editor == nil || editor.impl == nil {
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	impl := editor.impl
	switch msg {
	case win.WM_ERASEBKGND:
		return 1
	case win.WM_PAINT:
		paint: win.PAINTSTRUCT
		_ = win.BeginPaint(hwnd, &paint)
		_ = win.EndPaint(hwnd, &paint)
		return 0
	case win.WM_SIZE:
		width := int(win.LOWORD(win.DWORD(lparam)))
		height := int(win.HIWORD(win.DWORD(lparam)))
		if width > 0 && height > 0 {
			dpi := win.GetDpiForWindow(hwnd)
			scale := f32(1)
			if dpi != 0 { scale = f32(dpi)/96 }
			_ = plugin_editor_resize_pixels(editor, width, height, scale)
		}
		return 0
	case win.WM_SHOWWINDOW:
		plugin_editor_set_visible_from_window(editor, wparam != 0)
		return 0
	case win.WM_SETFOCUS:
		_ = alicorn.hosted_runtime_focus_changed(&editor.hosted, true, true)
		if impl.accessibility_attached {
			impl.config.accessibility.focus_changed(impl.config.accessibility.data, true)
		}
		return 0
	case win.WM_KILLFOCUS:
		_ = alicorn.hosted_runtime_focus_changed(&editor.hosted, false)
		if impl.accessibility_attached {
			impl.config.accessibility.focus_changed(impl.config.accessibility.data, false)
		}
		if impl.capture_active {
			impl.capture_active = false
			_ = win.ReleaseCapture()
			_ = alicorn.hosted_runtime_pointer_cancel(&editor.hosted)
		}
		return 0
	case win.WM_MOUSEMOVE:
		plugin_editor_pointer(
			editor, .Move,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			0, 0,
		)
		return 0
	case win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK:
		_ = win.SetFocus(hwnd)
		impl.capture_active = true
		_ = win.SetCapture(hwnd)
		count: u8 = 1
		if msg == win.WM_LBUTTONDBLCLK { count = 2 }
		plugin_editor_pointer(
			editor, .Down,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_PRIMARY, count,
		)
		return 0
	case win.WM_LBUTTONUP:
		plugin_editor_pointer(
			editor, .Up,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_PRIMARY, 0,
		)
		if impl.capture_active {
			impl.capture_active = false
			_ = win.ReleaseCapture()
		}
		return 0
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK:
		_ = win.SetFocus(hwnd)
		impl.capture_active = true
		_ = win.SetCapture(hwnd)
		count: u8 = 1
		if msg == win.WM_RBUTTONDBLCLK { count = 2 }
		plugin_editor_pointer(
			editor, .Down,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_SECONDARY, count,
		)
		return 0
	case win.WM_RBUTTONUP:
		plugin_editor_pointer(
			editor, .Up,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_SECONDARY, 0,
		)
		if impl.capture_active {
			impl.capture_active = false
			_ = win.ReleaseCapture()
		}
		return 0
	case win.WM_MBUTTONDOWN:
		_ = win.SetFocus(hwnd)
		impl.capture_active = true
		_ = win.SetCapture(hwnd)
		plugin_editor_pointer(
			editor, .Down,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_MIDDLE, 1,
		)
		return 0
	case win.WM_MBUTTONUP:
		plugin_editor_pointer(
			editor, .Up,
			int(win.GET_X_LPARAM(lparam)), int(win.GET_Y_LPARAM(lparam)),
			alicorn.POINTER_BUTTON_MIDDLE, 0,
		)
		if impl.capture_active {
			impl.capture_active = false
			_ = win.ReleaseCapture()
		}
		return 0
	case win.WM_CAPTURECHANGED:
		if impl.capture_active {
			impl.capture_active = false
			_ = alicorn.hosted_runtime_pointer_cancel(&editor.hosted)
		}
		return 0
	case win.WM_MOUSEWHEEL:
		delta := i32(win.GET_WHEEL_DELTA_WPARAM(wparam))
		point := win.POINT{
			x=win.LONG(win.GET_X_LPARAM(lparam)),
			y=win.LONG(win.GET_Y_LPARAM(lparam)),
		}
		_ = win.ScreenToClient(hwnd, &point)
		ticks := delta/120
		event := alicorn.Scroll_Event{
			delta_x=0,
			delta_y=-f32(ticks),
			ticks_x=0,
			ticks_y=-int(ticks),
			x=f32(point.x),
			y=f32(point.y),
			modifiers=plugin_input_modifiers(),
		}
		if ticks != 0 {
			_, _ = alicorn.hosted_runtime_scroll(&editor.hosted, event)
		}
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		repeat := (u32(lparam) & (1 << 30)) != 0
		plugin_editor_key_down(editor, u32(wparam), repeat)
		return 0
	case win.WM_CHAR, win.WM_IME_CHAR:
		plugin_editor_text_char(editor, u16(wparam))
		return 0
	case win.WM_MOUSEACTIVATE:
		return PLUGIN_MA_ACTIVATE
	case win.WM_GETDLGCODE:
		return PLUGIN_DLGC_WANTARROWS | PLUGIN_DLGC_WANTTAB |
			PLUGIN_DLGC_WANTALLKEYS | PLUGIN_DLGC_WANTCHARS
	case win.WM_SETCURSOR:
		_ = win.SetCursor(PLUGIN_ARROW_CURSOR())
		return 1
	case PLUGIN_WAKE_MESSAGE:
		_ = alicorn.hosted_runtime_deliver_wake(&editor.hosted)
		return 0
	case win.WM_DPICHANGED:
		rect: win.RECT
		if win.GetClientRect(hwnd, &rect) != false {
			dpi := win.GetDpiForWindow(hwnd)
			scale := f32(1)
			if dpi != 0 { scale = f32(dpi)/96 }
			_ = plugin_editor_resize_pixels(editor, int(rect.right-rect.left), int(rect.bottom-rect.top), scale)
		}
		return 0
	case:
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
}
