#+build !js

package alicorn_host_fonts

import "core:os"
import "core:testing"
import "core:time"
import alicorn "../../runtime"
import runa "../../third_party/Runa"

@(test)
test_optional_fallback_rejects_missing_font :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&rt)
	testing.expect(t, !load_optional_fallback_font(
		&rt,
		.UI,
		"/font-that-does-not-exist-for-alicorn-test.ttf",
		FALLBACK_CODEPOINTS,
	), "an unavailable fallback path must remain optional")
}

@(test)
test_linux_fontconfig_fallback_covers_ui_symbols :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		path := ui_fallback_font_path()
		if path == "" {
			testing.expect(t, !fontconfig_initialize(), "Fontconfig absence should be the only reason Linux fallback discovery is empty")
			return
		}
		data, err := os.read_entire_file_from_path(path, context.allocator)
		defer delete(data)
		testing.expect(t, err == nil && font_data_covers(data, FALLBACK_CODEPOINTS),
			"Fontconfig must resolve a readable font containing every UI fallback symbol")

		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
		defer alicorn.destroy_runtime(&rt)
		testing.expect(t, alicorn.text_engine_load_font(&rt.text_engine, UI_FONT_DATA),
			"the bundled UI face should load for the fallback fixture")
		testing.expect(t, load_optional_fallback_font(&rt, .UI, path, FALLBACK_CODEPOINTS),
			"the resolved Fontconfig face should load through the native fallback path")
		run, ok := alicorn.text_run_build(&rt.text_engine, "ABC ↑ ↓ → ← × —", 16, allocator=context.allocator)
		defer if ok { alicorn.text_run_destroy(&run) }
		primary_glyphs, fallback_glyphs := 0, 0
		if ok {
			for glyph in run.glyphs {
				if glyph.font_source == .Fallback { fallback_glyphs += 1 }
				else { primary_glyphs += 1 }
			}
		}
		testing.expect(t, ok && run.font_source == .Fallback && len(run.glyphs) == 15 && primary_glyphs > 0 && fallback_glyphs > 0,
			"mixed text should retain primary glyphs while selecting the verified fallback only for missing symbols")
	}
}

@(test)
test_windows_directwrite_cjk_fallback_and_optional_color_emoji :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
		defer alicorn.destroy_runtime(&rt)
		testing.expect(t, load_default_fonts(&rt), "Windows primary font initialization should succeed")
		testing.expect(t, alicorn.text_engine_registered_font_face_count(&rt.text_engine) > 0,
			"DirectWrite should register supported system fallback faces")

		value := "日本語 🎉"
		run, ok := alicorn.text_run_build(&rt.text_engine, value, 20, font_role=.Monospace)
		defer if ok { alicorn.text_run_destroy(&run) }
		japanese_fallback_glyphs := 0
		compatible_color_emoji_face := false
		color_emoji_slot := false
		emoji_start := len("日本語 ")
		if ok {
			for glyph in run.glyphs {
				if glyph.cluster_start < emoji_start && glyph.font_face != 0 { japanese_fallback_glyphs += 1 }
				if glyph.cluster_start == emoji_start && glyph.font_face != 0 {
					face, face_found := alicorn.text_engine_font_face(&rt.text_engine, glyph.font_face)
					if !face_found || !runa.font_has_color_layers(&face.font, glyph.glyph_id) { continue }
					compatible_color_emoji_face = true
					slot, drawable, glyph_ok := alicorn.text_engine_glyph(
						&rt.text_engine, glyph.glyph_id, run.size,
						font_role=.Monospace,
						font_source=glyph.font_source,
						font_weight=glyph.font_weight,
						italic=glyph.italic,
						face_id=glyph.font_face,
					)
					color_emoji_slot = glyph_ok && drawable && slot.is_color
				}
			}
		}
		testing.expect(t, ok && japanese_fallback_glyphs > 0,
			"Japanese text should select a registered DirectWrite fallback face")
		if compatible_color_emoji_face {
			testing.expect(t, color_emoji_slot,
				"a mapped COLR face with layers for the sample emoji should rasterize into the RGBA atlas")
		}
	}
}

// The deferred stack must behave exactly like the eager one for text that
// actually needs a platform face, and must not load anything for text the
// bundled Latin faces already cover. This pins both halves of the lazy
// contract: no startup cost, correct first-miss resolution.
@(test)
test_deferred_system_fallbacks_load_only_on_first_uncovered_text :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
		defer alicorn.destroy_runtime(&rt)
		testing.expect(t, load_default_fonts(&rt, defer_system_fallbacks=true),
			"deferred initialization should install the bundled faces")
		testing.expect(t, alicorn.text_engine_registered_font_face_count(&rt.text_engine) == 0,
			"deferred initialization must not resolve system faces during startup")
		testing.expect(t, arm_deferred_system_fallbacks(&rt),
			"deferred initialization must arm the platform loader")

		latin, latin_ok := alicorn.text_run_build(&rt.text_engine, "Hello, Alicorn", 16, allocator=context.allocator)
		defer if latin_ok { alicorn.text_run_destroy(&latin) }
		testing.expect(t, latin_ok && rt.text_engine.system_fallback_faces == 0 &&
			rt.text_engine.system_fallback_ns == 0 && rt.text_engine.system_fallback_fired_at == (time.Tick{}),
			"Latin text covered by the bundled faces must not trigger the platform loader")

		japanese_sample := "日本語 🎉"
		japanese, japanese_ok := alicorn.text_run_build(&rt.text_engine, japanese_sample, 20, allocator=context.allocator)
		defer if japanese_ok { alicorn.text_run_destroy(&japanese) }
		fallback_glyphs := 0
		if japanese_ok {
			for glyph in japanese.glyphs {
				if glyph.font_source == .Fallback && glyph.font_face != 0 { fallback_glyphs += 1 }
			}
		}
		testing.expect(t, japanese_ok && fallback_glyphs > 0,
			"the first uncovered text must resolve through the deferred platform faces")
		testing.expect(t, rt.text_engine.system_fallback_faces > 0 && rt.text_engine.system_fallback_ns > 0 &&
			rt.text_engine.system_fallback_fired_at != (time.Tick{}),
			"the deferred load must record its synchronous cost and fire moment")
		// A CI host may lack faces for part of the sample text. The contract is
		// that the run records exactly what the installed face stack resolved:
		// full coverage means no fallback-generation bit, and partial coverage
		// must set it. Do not require full CJK/emoji coverage from an arbitrary
		// machine.
		non_ascii := 0
		for r in japanese_sample { if r > 0x7F { non_ascii += 1 } }
		if fallback_glyphs >= non_ascii {
			testing.expect(t, japanese.font_generation & alicorn.TEXT_RUN_FALLBACK_GENERATION_MASK == 0,
				"a fully resolved run must not retain unresolved fallback coverage")
		} else {
			testing.expect(t, japanese.font_generation & alicorn.TEXT_RUN_FALLBACK_GENERATION_MASK != 0,
				"a partially resolved run must record unresolved fallback coverage")
		}

		before := rt.text_engine.system_fallback_ns
		chinese, chinese_ok := alicorn.text_run_build(&rt.text_engine, "简体中文", 20, allocator=context.allocator)
		defer if chinese_ok { alicorn.text_run_destroy(&chinese) }
		testing.expect(t, chinese_ok && rt.text_engine.system_fallback_ns == before,
			"later fallback text must reuse the resolved stack instead of reloading it")
	}
}

// U+22EF HORIZONTAL MIDLINE ELLIPSIS is absent from the bundled Atkinson faces.
// Before the shared seeding it was only resolved on the reference host, and only
// because an optional system face happened to cover it. Both hosts now build
// one canonical stack through load_default_fonts; these tests pin the resolved
// face/glyph and the parity of that choice. If a machine's optional faces do not
// cover the codepoint, the run must record unresolved .notdef coverage instead
// of silently rendering a box as if it were resolved.
MIDLINE_ELLIPSIS :: "\u22EF"

@(test)
test_canonical_stack_resolves_midline_ellipsis_when_platform_faces_cover_it :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&rt)
	testing.expect(t, load_default_fonts(&rt), "canonical desktop font initialization should succeed")

	stack := alicorn.text_engine_font_stack(&rt.text_engine, .UI, context.temp_allocator)
	covered := false
	for font in stack {
		if runa.font_lookup_glyph(font, 0x22EF) != 0 { covered = true; break }
	}
	run, ok := alicorn.text_run_build(&rt.text_engine, MIDLINE_ELLIPSIS, 20, allocator=context.allocator)
	defer if ok { alicorn.text_run_destroy(&run) }
	if !covered {
		testing.expect(t, ok && len(run.glyphs) == 1 && run.glyphs[0].glyph_id == 0 &&
			run.font_generation & alicorn.TEXT_RUN_FALLBACK_GENERATION_MASK != 0,
			"without a covering platform face the run must record unresolved .notdef coverage")
		return
	}
	testing.expect(t, ok && len(run.glyphs) == 1 && run.glyphs[0].glyph_id != 0,
		"a codepoint covered by a registered fallback face must shape to a real glyph")
	testing.expect(t, ok && run.font_source == .Fallback && run.glyphs[0].font_source == .Fallback,
		"the midline ellipsis must retain its fallback face provenance")
	if ok && len(run.glyphs) == 1 {
		face_font, _, _, _, _, face_loaded := alicorn.text_engine_font_for_face_id(
			&rt.text_engine, run.glyphs[0].font_face,
		)
		testing.expect(t, face_loaded && face_font != nil && runa.font_lookup_glyph(face_font, 0x22EF) != 0,
			"the recorded face must be the registered face that covers the codepoint")
	}
}

@(test)
test_hosted_and_reference_initialization_choose_the_same_face :: proc(t: ^testing.T) {
	// The hosted WebGPU host and the SDL_GPU reference both call
	// load_default_fonts. Two independent runtimes therefore must expose the
	// same face stack and the same resolved face/glyph for the codepoint.
	hosted := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&hosted)
	reference := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 120})
	defer alicorn.destroy_runtime(&reference)
	testing.expect(t, load_default_fonts(&hosted) && load_default_fonts(&reference),
		"both desktop host initializations should succeed")
	testing.expect(t, alicorn.text_engine_registered_font_face_count(&hosted.text_engine) ==
		alicorn.text_engine_registered_font_face_count(&reference.text_engine),
		"both hosts must register the same number of fallback faces")

	hosted_run, hosted_ok := alicorn.text_run_build(&hosted.text_engine, MIDLINE_ELLIPSIS, 20, allocator=context.allocator)
	defer if hosted_ok { alicorn.text_run_destroy(&hosted_run) }
	reference_run, reference_ok := alicorn.text_run_build(&reference.text_engine, MIDLINE_ELLIPSIS, 20, allocator=context.allocator)
	defer if reference_ok { alicorn.text_run_destroy(&reference_run) }
	if !hosted_ok || !reference_ok || len(hosted_run.glyphs) != 1 || len(reference_run.glyphs) != 1 { return }
	hosted_glyph, reference_glyph := hosted_run.glyphs[0], reference_run.glyphs[0]
	testing.expect(t, hosted_glyph.font_face == reference_glyph.font_face &&
		hosted_glyph.glyph_id == reference_glyph.glyph_id &&
		hosted_glyph.font_source == reference_glyph.font_source,
		"hosted and reference initialization must resolve the same face and glyph")
}
