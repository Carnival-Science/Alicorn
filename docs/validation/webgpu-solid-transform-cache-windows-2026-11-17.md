# Solid surface translation and clip retention — Windows

Initial validation: 2026-11-17  
Revalidated against the committed fixture head: 2026-11-18  
Platform: Windows x64  
Compiler: Odin `dev-2026-11-nightly:08539cd`  
Hardware: NVIDIA GeForce RTX 2080 SUPER  
Tested backends: D3D12 and Vulkan

## Change

Solid CPU meshes now use local coordinates and are retained independently from
per-surface translation. The WebGPU solid renderer uploads physical-pixel
translations through a compact per-instance vertex buffer. It computes each
command's clip scissor during draw encoding, translating the full-display
scissor into cropped-target coordinates only after deriving it in the source
view. This preserves crop behavior while allowing motion and clip changes to
reuse static geometry.

The solid mesh fingerprint excludes translation, clip, and target dimensions.
Surface payload, command order, scale, and runtime identity continue to govern
mesh validity. Resizing still updates the viewport uniform.

## Commands and results

- `C:\odin\odin.exe test renderer\cpu -out:out\alicorn_cpu_renderer_tests.exe`:
  22 tests passed, including the retained-geometry fingerprint and unbounded
  local-mesh cases.
- `C:\odin\odin.exe check renderer\webgpu -no-entry-point`: passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: built the
  native fixture variants and `js_wasm32` browser fixture.
- `webgpu_feasibility_smoke.exe --backend=d3d12`: passed the full core,
  compositor, effect, resize-cache, transform-pixel, and cropped-capture
  readbacks.
- `webgpu_feasibility_smoke.exe --backend=vulkan`: passed the same full set.
- `node tools/test_webgpu_ui_host.js`, `node tools/test_web_scheduler.js`,
  `node tools/test_odin_wgpu_js_patch.js`, and
  `node tools/test_accessibility_dom.js`: all passed.
- `tools/test.ps1 -Odin C:\odin\odin.exe`: passed every package runner
  (8 accesskit binding, 363 runtime, 11 SDL3 host, 14 web host, 42 UI,
  13 testui, 37 theme, 22 CPU renderer, 172 foundation, and 6 restoration
  tests, all successful).
- `tools/check.ps1 -Odin C:\odin\odin.exe`: passed, including benchmark and
  example builds, fixture builds, and `git diff --check`.
- `git diff --check`: passed.

Both backends reported the same solid counters. The fixture prints:

```text
retained solid cache PASS mesh_rebuilds=1 vertex_uploads=1 vertex_bytes=648 transform_uploads=1 transform_bytes=24 viewport_uploads=1 unchanged_repeat=true
solid target resize cache PASS mesh_rebuilds=0 vertex_uploads=0 transform_uploads=0 viewport_uploads=2
solid translation cache PASS mesh_rebuilds=0 vertex_uploads=0 transform_uploads=1 transform_bytes=24
solid instance transform submitted PASS translation=5,5 clip=5,5,20,20 readback_slot=15
async RGBA8 readback compositor PASS ... image_clip=true solid_motion=true crop_a=true crop_b=true
```

The fixture checks the solid transform using a retained three-surface scene.
Changing one surface's translation and clip keeps mesh rebuilds and vertex
uploads at zero and uploads 24 bytes of transform data. Readback confirms the
surface moved inside the new clip and pixels outside that clip still show the
parent surface. Resizing the target and restoring its dimensions performs two
viewport updates with no mesh rebuild, vertex upload, or transform upload.
Both full-display-to-cropped-target comparisons pass.

## Limits

This validates Windows native D3D12 and Vulkan rendering, not browser GPU
execution. The browser target compiled, but no Chrome or Edge executable was
available in the standard install locations or `PATH` for a local run. macOS
and Linux native runs, physical browser validation, and performance timing
remain outstanding. The counters demonstrate reduced solid vertex traffic;
they are not an end-to-end latency benchmark. SDL_GPU remains in the repository
as a temporary comparison backend during migration.
