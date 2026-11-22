package alicorn_sdl_gpu

import alicorn "../../runtime"
import host_fonts "alicorn:host/fonts"

// The reference host's platform font seeding lives in alicorn:host/fonts so the
// hosted WebGPU path loads the identical stack. These names stay for the
// native validation fixtures that predate the shared package.
NATIVE_UI_FONT_DATA :: alicorn.DEFAULT_UI_FONT_DATA

native_ui_fallback_font_path :: proc() -> string {
	return host_fonts.ui_fallback_font_path()
}

native_monospace_fallback_font_path :: proc() -> string {
	return host_fonts.monospace_fallback_font_path()
}

native_font_data_covers :: proc(data: []u8, codepoints: []rune) -> bool {
	return host_fonts.font_data_covers(data, codepoints)
}

native_load_optional_fallback_font :: proc(
	rt: ^alicorn.Runtime,
	role: alicorn.Font_Role,
	path: string,
	required_codepoints: []rune = nil,
) -> bool {
	return host_fonts.load_optional_fallback_font(rt, role, path, required_codepoints)
}

native_load_default_fonts :: proc(rt: ^alicorn.Runtime, defer_system_fallbacks := false) -> bool {
	return host_fonts.load_default_fonts(rt, defer_system_fallbacks)
}

// native_arm_deferred_system_fonts arms the lazy platform fallback loader. The
// host then pays the system-face cost only if first-frame text actually needs
// a face the bundled stack does not cover.
native_arm_deferred_system_fonts :: proc(rt: ^alicorn.Runtime) -> bool {
	return host_fonts.arm_deferred_system_fallbacks(rt)
}

when ODIN_OS == .Windows {
	native_load_directwrite_fallback_faces :: proc(rt: ^alicorn.Runtime) -> int {
		return host_fonts.load_directwrite_fallback_faces(rt)
	}
}

when ODIN_OS == .Linux {
	native_fontconfig_initialize :: proc() -> bool {
		return host_fonts.fontconfig_initialize()
	}

	native_fontconfig_find_font :: proc(family: cstring, codepoints: []rune) -> string {
		return host_fonts.fontconfig_find_font(family, codepoints)
	}
}
