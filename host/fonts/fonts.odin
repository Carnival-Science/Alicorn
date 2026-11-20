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

// load_default_fonts installs the canonical stack every desktop host uses:
// bundled defaults first, then the bounded startup system fallbacks. It is
// deterministic for the machine and is never called during shaping or editing.
load_default_fonts :: proc(rt: ^alicorn.Runtime) -> bool {
	if !alicorn.text_engine_load_default_fonts(rt) { return false }
	when ODIN_OS == .Windows {
		// Seed the bounded fallback stacks from DirectWrite's locale-aware
		// system mappings during startup, never while shaping or editing text.
		_ = load_directwrite_fallback_faces(rt)
	}
	// System faces are optional, script-oriented fallbacks; they do not alter
	// the bundled primary typography for text the default face can render.
	if !rt.text_engine.fallback_font_loaded && !rt.text_engine.application_fallback_font[.UI] {
		_ = load_optional_fallback_font(rt, .UI, ui_fallback_font_path(), FALLBACK_CODEPOINTS)
	}
	if !rt.text_engine.monospace_fallback_font_loaded && !rt.text_engine.application_fallback_font[.Monospace] {
		_ = load_optional_fallback_font(rt, .Monospace, monospace_fallback_font_path(), FALLBACK_CODEPOINTS)
	}
	return true
}
