#+build windows

package host_menus

import "core:strings"
import "core:sync"
import "core:testing"
import win "core:sys/windows"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

// Port of the native SDL_GPU regression
// (native/sdl_gpu/frame_hit_test_windows_test.odin) to the hosted chrome
// adapter. It drives the real SDL Win32 message path, so it fails if the
// hosted subclass stops intercepting SDL's automatic topmost promotion: every
// mouse re-entry would shift the window up and to the left by the standard
// caption/border inset.
@(test)
test_win32_hosted_topmost_mouse_entry_preserves_native_rectangle :: proc(t: ^testing.T) {
	sync.mutex_lock(&win32_menu_test_mutex)
	defer sync.mutex_unlock(&win32_menu_test_mutex)
	if !sdl3.Init({.VIDEO}) { testing.expect(t, false, "SDL video should initialize"); return }
	defer sdl3.Quit()
	title, title_error := strings.clone_to_cstring("alicorn-hosted-topmost-entry-test", context.temp_allocator)
	if title_error != nil { testing.expect(t, false, "title should allocate"); return }
	window := sdl3.CreateWindow(title, 480, 320, {.HIDDEN, .RESIZABLE})
	if window == nil { testing.expect(t, false, "hidden SDL window creation failed"); return }
	defer sdl3.DestroyWindow(window)
	menus := [?]alicorn.Menu{{label="Tool"}}
	service: Menu_Service
	menu_service_init(&service, menus[:], .Labels, nil, nil)
	adapter: Native_Menu_Adapter
	if !native_menu_adapter_prepare(&adapter, window, &service, Menu_Chrome_Config{
		decorations=.Integrated_Title_Bar,
		title="Alicorn topmost entry regression",
		chrome_height=32,
		menu_presentation=.Labels,
	}) { testing.expect(t, false, "integrated adapter should prepare"); return }
	defer native_menu_adapter_destroy(&adapter)
	state := cast(^Win32_Menu_State)adapter.platform_data
	if state == nil || !state.chrome.frame_enabled {
		testing.expect(t, false, "the hosted integrated frame should be active")
		return
	}
	chrome := &state.chrome
	if !sdl3.SetWindowAlwaysOnTop(window, true) {
		testing.expect(t, false, "topmost transition failed")
		return
	}
	_ = win.SendMessageW(state.hwnd, win.WM_MOUSELEAVE, 0, 0)
	before: win.RECT
	if !win.GetWindowRect(state.hwnd, &before) {
		testing.expect(t, false, "native window rectangle unavailable")
		return
	}
	keyboard_focus := sdl3.GetKeyboardFocus()
	for i in 0..<8 {
		point := win.LPARAM(uintptr(120+i) | uintptr(120)<<16)
		_ = win.SendMessageW(state.hwnd, win.WM_MOUSEMOVE, 0, point)
		testing.expect(t, sdl3.GetMouseFocus() == window,
			"the real SDL mouse-entry path must be exercised")
		after: win.RECT
		_ = win.GetWindowRect(state.hwnd, &after)
		testing.expect_value(t, after, before)
		testing.expect(t, sdl3.GetKeyboardFocus() == keyboard_focus,
			"mouse entry must not activate the window")
		_ = win.SendMessageW(state.hwnd, win.WM_MOUSELEAVE, 0, 0)
	}
	testing.expect_value(t, chrome.topmost_promotions_preserved, u64(8))
	// Caption dragging and explicit placement still move the window.
	move_flags := win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE | win.SWP_NOZORDER)
	testing.expect(t, win.SetWindowPos(state.hwnd, nil, before.left+40, before.top+20, 0, 0, move_flags) != false)
	before.left += 40; before.right += 40; before.top += 20; before.bottom += 20
	moved: win.RECT
	_ = win.GetWindowRect(state.hwnd, &moved)
	testing.expect_value(t, moved, before)
	resize_flags := win.UINT(win.SWP_NOMOVE | win.SWP_NOACTIVATE | win.SWP_NOZORDER)
	testing.expect(t, win.SetWindowPos(
		state.hwnd, nil, 0, 0,
		before.right-before.left+40, before.bottom-before.top+30, resize_flags,
	) != false)
	before.right += 40; before.bottom += 30
	resized: win.RECT
	_ = win.GetWindowRect(state.hwnd, &resized)
	testing.expect_value(t, resized, before)
	// Toggling topmost keeps the rectangle and keeps the guard working.
	topmost_states := [2]bool{false, true}
	for topmost in topmost_states {
		testing.expect(t, sdl3.SetWindowAlwaysOnTop(window, topmost))
		for i in 0..<8 {
			_ = win.SendMessageW(state.hwnd, win.WM_MOUSEMOVE, 0, win.LPARAM(uintptr(140+i) | uintptr(140)<<16))
			after: win.RECT
			_ = win.GetWindowRect(state.hwnd, &after)
			testing.expect_value(t, after, before)
			_ = win.SendMessageW(state.hwnd, win.WM_MOUSELEAVE, 0, 0)
		}
	}
	testing.expect_value(t, chrome.topmost_promotions_preserved, u64(16))
}
