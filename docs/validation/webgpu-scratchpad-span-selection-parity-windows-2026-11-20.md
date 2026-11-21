Scratchpad hosted-WebGPU vs SDL_GPU reference — syntax-span and drag-selection parity
Windows x64, NVIDIA GeForce RTX 2080 SUPER, 2026-11-20
Scratchpad codex/issue-211-webgpu-frontend @ bfb2aed, Alicorn codex/issue-211-scratchpad-webgpu (this slice)

Scene
  Saved Scratchpad session restored with language/detection.go active (Go, 57 lines),
  builtin:cool-light theme, surface_treatment=workbench-relief, 1216x799 window.
  Both hosts used the same session, window size, and scroll position.
  Captures: --diagnostics plus F12 (hosted) / F12 (SDL_GPU) at the settled frame.

1. Hosted text paint spans reach the retained display list (inspector.txt)
   Hosted: `text run: valid=true bytes=27 paint-spans=5 style-spans=0
            [4,8)fg=(0.040,0.058,0.085,1.000) [15,17)fg=(0.018,0.107,0.141,1.000) ...`
   SDL_GPU: identical bytes, span count, byte ranges, and colors (same 93 text-run lines
            in both inspector dumps, identical span tuples).
   Files:
     docs/validation/raw/scratchpad-spans-hosted-d3d12-2026-11-20.txt
     docs/validation/raw/scratchpad-spans-sdl-gpu-2026-11-20.txt

2. Pre-fix color transfer mismatch (hosted vs reference), full-frame diff
   phase                              differing channels   max   mean
   hosted before the format fix        2,694,611 / 2,914,752 (92.45%)   82   10.92
   hosted after the format fix                   0 / 2,914,752 ( 0.00%)    0    0.0000

   Editor text band (y=370..400, x=345..1100), cool-light:
   hosted before: 250,251,254 (bg) 56,68,82 (text) 36,92,105 (token) 96,74,136 (token)
   reference:     244,246,253 (bg) 10,15,22 (text)  4,27,36 (token)  30,17,63 (token)
   hosted after:  244,246,253 (bg) 10,15,22 (text)  4,27,36 (token)  30,17,63 (token)

   Every hosted channel was sRGB-encoded once relative to the reference:
   sRGB_encode(10)=56, sRGB_encode(15)=68, sRGB_encode(22)=82; sRGB_encode(4)=33~36,
   sRGB_encode(27)=92, sRGB_encode(36)=105; sRGB_encode(30)=97~96, sRGB_encode(17)=72~74,
   sRGB_encode(63)=135~136. Background: sRGB_encode(244)=250, (246)=251, (253)=254.

   Cause: the SDL_GPU reference presents through a non-sRGB (UNORM) swapchain
   (SDL_GetGPUSwapchainTextureFormat) and uploads linear-sRGB theme channels
   unchanged, per docs/themes.md. The hosted WebGPU surface preferred
   BGRA8UnormSrgb, so the GPU applied a second transfer function to every color,
   including per-glyph paint-span colors. The result lightened text and compressed
   token-color contrast on light themes — the founder's "plain text colors".
   Fix: host/presentation/surface_format.odin selects a non-sRGB format first for
   the SDL3 host, secondary windows, and the browser host.

   Raw diffs:
     docs/validation/raw/scratchpad-parity-diff-before-2026-11-20.txt
     docs/validation/raw/scratchpad-parity-diff-after-2026-11-20.txt
   Captures (temporary, not committed): out/parity/... screenshot.ppm pairs.

3. Alicorn-side fixtures (all run on Windows x64, Odin dev-2026-11-nightly)
   runtime/hosted_parity_test.odin
     test_hosted_presentation_preserves_text_paint_spans
       Hosted runtime describes an application-owned Root, a scroll region, a Text row
       with three ordered color spans (Scratchpad's syntax shape), and a Text_Field.
       Asserts, for content_inset_top = 0 and 24:
         - exactly one Text_Paint command for the row carries all three spans,
         - byte ranges (0..4, 5..15, 16..20) and colors survive,
         - the inset translates paint geometry only (bounds.y >= inset),
         - retained node.text_paint_spans still holds three spans,
         - a later description that changes only span colors reaches the
           presentation list (a run cache keyed without spans would keep the
           earlier command here).
     test_hosted_pointer_drag_selection_matches_reference
       Loads a shaped font, presses at byte 1 of a runtime-owned Text_Field, moves to
       byte 8, releases through hosted_runtime_pointer; asserts anchor=1/caret=8,
       capture release, and down/move/up callback order. Repeats the identical
       description through process_pointer + application_dispatch_pointer (the
       native/sdl_gpu and testui route) and asserts the same selection.
   renderer/webgpu/text_span_test.odin
     test_webgpu_text_span_colors_survive_the_presentation_list
       Resolves per-glyph colors from the retained command for keyword/function/
       string/unspanned glyph clusters (sorted-disjoint strategy) and asserts the
       exact span color per class and the node text color between spans.
     test_webgpu_text_span_mesh_fingerprint_tracks_span_colors
       Re-describes the same row with only a span color change; asserts the retained
       display command carries the new color and text_mesh_fingerprint changes, so a
       color-blind run cache cannot reuse colorless vertices.
   host/presentation/surface_format_test.odin
     test_hosted_presentation_format_matches_the_sdl_gpu_transfer_contract
       Asserts non-sRGB preference, sRGB-only fallback, unknown-format fallback, and
       empty capability rejection.
   runtime/inspector.odin
     Text/Text_Field nodes now record `text run: valid=... bytes=... paint-spans=N
     style-spans=N [start,end)fg=(...)` so a capture bundle proves span provenance
     without a screenshot.

4. Scratchpad end-to-end
   go run ./cmd/alicorn-dev smoke --renderer webgpu --backend d3d12
   go run ./cmd/alicorn-dev smoke --renderer webgpu --backend vulkan
     both: publication_rendered true, wake_observed true, ordered_shutdown true,
           session_restore true for the clean and unsaved-recovery launches.
   Settled captures on the same Go editor scene: hosted D3D12 frame is byte-identical
   to the SDL_GPU reference frame after the fix (diff above). Dark charcoal-ink theme
   captures agree as well (token colors pink/green/red on both hosts).

5. Manual-interaction limit
   This machine's automation session cannot deliver synthetic OS pointer or text
   input to the Scratchpad window (physical and posted WM_MOUSE messages produce no
   app input; keyboard F10/F11/F12 host shortcuts do). Drag-selection therefore is
   verified at the hosted-runtime API seam against the native/testui route, not by a
   scripted mouse drag in Scratchpad. The founder's hands-on click-drag remains the
   confirming check; no Scratchpad source or lock file was modified.
