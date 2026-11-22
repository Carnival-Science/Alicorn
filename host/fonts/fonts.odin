#+build !js

// Platform font seeding shared by every desktop Alicorn host.
//
// The bundled Atkinson faces are the primary typography for both the SDL_GPU
// reference host and the hosted WebGPU host. System and script fallbacks are
// optional additions on top of that stack. Keeping the seeding here means a
// host cannot load a different font stack by forgetting one startup call: the
// reference host, `ui.run`'s native path, and the hosted WebGPU path all invoke
// `load_default_fonts`.
package alicorn_host_fonts

import "core:os"
import alicorn "../../runtime"
import runa "../../third_party/Runa"

// UI_FONT_DATA keeps the bundled fixture face available to host validation
// code that loads the same bytes the Runtime and headless test host use.
UI_FONT_DATA :: alicorn.DEFAULT_UI_FONT_DATA

FALLBACK_CODEPOINTS :: []rune{'↑', '↓', '→', '←', '×', '—'}

ui_fallback_font_path :: proc() -> string {
	when ODIN_OS == .Windows {
		// Prefer a broad Japanese face for symbols outside the bundled
		// Latin-focused default face, then the platform UI face.
		japanese_font := "C:/Windows/Fonts/NotoSansJP-VF.ttf"
		if os.exists(japanese_font) { return japanese_font }
		return "C:/Windows/Fonts/segoeui.ttf"
	} else when ODIN_OS == .Darwin {
		return "/System/Library/Fonts/SFNS.ttf"
	} else when ODIN_OS == .Linux {
		return fontconfig_find_font("sans-serif", FALLBACK_CODEPOINTS)
	} else {
		return ""
	}
}

monospace_fallback_font_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "C:/Windows/Fonts/consola.ttf"
	} else when ODIN_OS == .Darwin {
		return "/System/Library/Fonts/SFNSMono.ttf"
	} else when ODIN_OS == .Linux {
		return fontconfig_find_font("monospace", FALLBACK_CODEPOINTS)
	} else {
		return ""
	}
}

font_data_covers :: proc(data: []u8, codepoints: []rune) -> bool {
	if len(data) == 0 || len(codepoints) == 0 { return false }
	font, err := runa.font_load(data, context.temp_allocator)
	if err != .None { return false }
	defer runa.font_destroy(&font)
	for codepoint in codepoints {
		if runa.font_lookup_glyph(&font, codepoint) == 0 { return false }
	}
	return true
}

load_optional_fallback_font :: proc(
	rt: ^alicorn.Runtime,
	role: alicorn.Font_Role,
	path: string,
	required_codepoints: []rune = nil,
) -> bool {
	if !os.exists(path) { return false }
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return false }
	defer delete(data)
	if len(required_codepoints) > 0 && !font_data_covers(data, required_codepoints) { return false }
	return alicorn.text_engine_load_fallback_font_role(&rt.text_engine, role, data)
}

// load_system_fallback_fonts resolves the bounded platform fallback stack:
// DirectWrite's locale-aware mappings on Windows plus the optional UI and
// monospace faces. It is the whole deferred unit for hosts that arm a lazy
// loader, and the tail of load_default_fonts for hosts that do not. Each face
// is validated before registration, so a missing platform font stays optional.
load_system_fallback_fonts :: proc(rt: ^alicorn.Runtime) -> int {
	added := 0
	when ODIN_OS == .Windows {
		added += load_directwrite_fallback_faces(rt)
	}
	if !rt.text_engine.fallback_font_loaded && !rt.text_engine.application_fallback_font[.UI] {
		if load_optional_fallback_font(rt, .UI, ui_fallback_font_path(), FALLBACK_CODEPOINTS) { added += 1 }
	}
	if !rt.text_engine.monospace_fallback_font_loaded && !rt.text_engine.application_fallback_font[.Monospace] {
		if load_optional_fallback_font(rt, .Monospace, monospace_fallback_font_path(), FALLBACK_CODEPOINTS) { added += 1 }
	}
	return added
}

deferred_system_fallback_thunk :: proc(ctx: rawptr) -> int {
	return load_system_fallback_fonts((^alicorn.Runtime)(ctx))
}

// arm_deferred_system_fallbacks makes the runtime resolve the platform stack on
// the first shaping request that no loaded face covers. The load is
// synchronous on the shaping thread; the runtime records its cost and never
// schedules idle work for it. Call this only after load_default_fonts with
// defer_system_fallbacks=true.
arm_deferred_system_fallbacks :: proc(rt: ^alicorn.Runtime) -> bool {
	if rt == nil { return false }
	return alicorn.text_engine_arm_system_fallback_loader(
		&rt.text_engine,
		rawptr(rt),
		deferred_system_fallback_thunk,
	)
}

// load_default_fonts installs the canonical stack every desktop host uses:
// bundled defaults first, then the bounded system fallbacks. With
// defer_system_fallbacks the bundled faces are installed and the platform
// stack is left for arm_deferred_system_fallbacks; otherwise it is resolved
// here during startup.
load_default_fonts :: proc(rt: ^alicorn.Runtime, defer_system_fallbacks := false) -> bool {
	if !alicorn.text_engine_load_default_fonts(rt) { return false }
	if defer_system_fallbacks { return true }
	_ = load_system_fallback_fonts(rt)
	return true
}
