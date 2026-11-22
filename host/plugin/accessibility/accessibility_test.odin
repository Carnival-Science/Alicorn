#+build windows

package plugin_accessibility

import "base:runtime"
import "core:testing"
import alicorn "alicorn:runtime"
import win "core:sys/windows"

ACCESSIBILITY_TEST_CLASS :: "AlicornPluginAccessibilityTest"

@(private)
accessibility_test_wndproc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = runtime.default_context()
	switch msg {
	case win.WM_ERASEBKGND:
		return 1
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(test)
test_plugin_accessibility_attaches_to_external_child_hwnd :: proc(t: ^testing.T) {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name := win.utf8_to_utf16(ACCESSIBILITY_TEST_CLASS, context.temp_allocator)
	title := win.utf8_to_utf16("Alicorn plugin accessibility test", context.temp_allocator)
	if class_name == nil || title == nil {
		testing.expect(t, false, "test strings should convert to UTF-16")
		return
	}
	class := win.WNDCLASSEXW{
		cbSize=u32(size_of(win.WNDCLASSEXW)),
		lpfnWndProc=accessibility_test_wndproc,
		hInstance=instance,
		hbrBackground=win.CreateSolidBrush(win.RGB(24, 26, 32)),
		lpszClassName=cstring16(&class_name[0]),
	}
	if win.RegisterClassExW(&class) == 0 {
		testing.expect(t, false, "test window class registration failed")
		return
	}
	hwnd := win.CreateWindowExW(
		0,
		cstring16(&class_name[0]),
		cstring16(&title[0]),
		win.WS_OVERLAPPEDWINDOW,
		0, 0, 320, 200,
		nil, nil, instance, nil,
	)
	if hwnd == nil {
		testing.expect(t, false, "test window creation failed")
		return
	}
	defer _ = win.DestroyWindow(hwnd)

	state := new(Editor_Accessibility)
	if state == nil {
		testing.expect(t, false, "accessibility state allocation failed")
		return
	}
	defer free(state)
	access := plugin_accessibility_init(state)
	testing.expect(t, access.attach != nil && state.ready,
		"accessibility host should initialize")
	if !access.attach(rawptr(state), .Windows_HWND, rawptr(hwnd)) {
		testing.expect(t, false, "AccessKit should attach to the external HWND")
		return
	}
	testing.expect(t, plugin_accessibility_ready(state),
		"the per-editor adapter should report ready after attach")

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&rt)
	ctx, should_build := alicorn.begin_frame(&rt)
	if should_build {
		alicorn.container_begin_simple(&ctx, .Root, key="a11y-root", style=alicorn.layout_style(.Column))
		_ = alicorn.button(&ctx, "Embedded action", key="a11y-button")
		alicorn.container_end(&ctx)
		alicorn.end_frame(&ctx)
	}
	access.sync(rawptr(state), &rt, 0, 1, 1)
	access.focus_changed(rawptr(state), true)
	access.focus_changed(rawptr(state), false)
	access.destroy(rawptr(state))
	testing.expect(t, !state.ready, "destroy should retire the adapter")
}
