package plugin_host

import "core:testing"
import alicorn "alicorn:runtime"
import win "core:sys/windows"

@(test)
test_plugin_parent_validation_is_typed :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		parent := Plugin_Native_Parent{kind=.Windows_HWND}
		testing.expect_value(t, plugin_status_for_parent(parent), Plugin_Status.Invalid_Argument)
		cocoa := Plugin_Native_Parent{kind=.Cocoa_NSView, window=rawptr(uintptr(1))}
		testing.expect_value(t, plugin_status_for_parent(cocoa), Plugin_Status.Unsupported_Parent)
		wayland := Plugin_Native_Parent{kind=.Wayland_Surface, window=rawptr(uintptr(1))}
		testing.expect_value(t, plugin_status_for_parent(wayland), Plugin_Status.Unsupported_Parent)
	} else {
		wayland := Plugin_Native_Parent{kind=.Wayland_Surface, window=rawptr(uintptr(1))}
		testing.expect_value(t, plugin_status_for_parent(wayland), Plugin_Status.Unsupported_Wayland)
		x11 := Plugin_Native_Parent{kind=.X11_Window, window=rawptr(uintptr(1))}
		testing.expect_value(t, plugin_status_for_parent(x11), Plugin_Status.Unsupported_Platform)
	}
}

@(test)
test_plugin_capabilities_report_the_platform_contract :: proc(t: ^testing.T) {
	caps := plugin_capabilities()
	when ODIN_OS == .Windows {
		testing.expect(t, caps.embedded_surface && caps.surface_from_hwnd && caps.child_window,
			"Windows Phase B should advertise an embedded HWND surface")
		testing.expect(t, caps.scoped_input && caps.device_recovery,
			"Windows Phase B should advertise scoped input and device recovery")
		testing.expect(t, !caps.floating_fallback_only,
			"Windows should not force a floating fallback")
	} else {
		testing.expect(t, caps.floating_fallback_only,
			"non-Windows Phase B should force a floating fallback")
	}
}

@(test)
test_plugin_host_config_defaults_are_explicit :: proc(t: ^testing.T) {
	config := plugin_host_config_clear()
	testing.expect_value(t, config.power_preference, Plugin_Power_Preference.High_Performance)
	testing.expect(t, config.debug_device_label != "", "device label should be non-empty for attribution")
	editor := plugin_editor_config_clear()
	testing.expect_value(t, editor.dpi_scale, f32(1))
	testing.expect_value(t, editor.visible, true)
	testing.expect_value(t, editor.clear_color, PLUGIN_DEFAULT_CLEAR_COLOR)
}

@(test)
test_plugin_status_strings_name_the_floating_fallback :: proc(t: ^testing.T) {
	testing.expect(t, plugin_status_string(.Unsupported_Wayland) != "",
		"Wayland refusal should have a message")
	testing.expect(t, plugin_status_string(.Unsupported_Platform) != "",
		"unsupported platform should have a message")
}

when ODIN_OS == .Windows {
	@(test)
	test_plugin_win32_key_translation_covers_bindings_and_text :: proc(t: ^testing.T) {
		testing.expect_value(t, plugin_key_spec_from_vk(u32(win.VK_A)), alicorn.Key_Spec.A)
		testing.expect_value(t, plugin_key_spec_from_vk(u32(win.VK_5)), alicorn.Key_Spec.Five)
		testing.expect_value(t, plugin_key_spec_from_vk(u32(win.VK_F12)), alicorn.Key_Spec.F12)
		testing.expect_value(t, plugin_key_spec_from_vk(u32(win.VK_LEFT)), alicorn.Key_Spec.Left)
		testing.expect_value(t, plugin_key_spec_from_vk(u32(win.VK_OEM_MINUS)), alicorn.Key_Spec.Minus)
		testing.expect_value(t, plugin_key_spec_from_vk(0x1234), alicorn.Key_Spec.Unknown)
	}

	@(test)
	test_plugin_win32_application_keys_match_platform_conventions :: proc(t: ^testing.T) {
		key, ok := plugin_application_key_from_vk(u32(win.VK_UP), {})
		testing.expect(t, ok && key == .Up, "Up should map to the application vocabulary")
		key, ok = plugin_application_key_from_vk(u32(win.VK_F), {control=true})
		testing.expect(t, ok && key == .Find, "Ctrl+F should map to Find")
		_, ok = plugin_application_key_from_vk(u32(win.VK_F), {shift=true})
		testing.expect(t, !ok, "bare F should not become Find")
	}

	@(test)
	test_plugin_win32_text_keys_are_host_normalized :: proc(t: ^testing.T) {
		key, ok := plugin_text_key_from_vk(u32(win.VK_LEFT), {control=true})
		testing.expect(t, ok && key == .Word_Left, "Ctrl+Left should be a word-left intent")
		key, ok = plugin_text_key_from_vk(u32(win.VK_BACK), {control=true})
		testing.expect(t, ok && key == .Delete_Word_Backward, "Ctrl+Backspace should delete a word")
		key, ok = plugin_text_key_from_vk(u32(win.VK_TAB), {})
		testing.expect(t, ok && key == .Tab, "Tab is an editing intent for a text owner")
	}
}
