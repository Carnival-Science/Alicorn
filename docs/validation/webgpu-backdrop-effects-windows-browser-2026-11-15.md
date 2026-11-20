# WebGPU backdrop effects: Windows and browser validation

Date: 2026-11-15

## Scope

This validation covers Alicorn's first WebGPU execution path for one retained
backdrop-effect marker in `renderer/webgpu/`. The compositor captures the
prepared paint prefix into a renderer-owned sampleable crop, runs the shared
CPU-planned Gaussian mesh through horizontal and vertical WGSL passes, then
composites the result at the marker's original paint-order position. The host
still owns the presentation target, encoder, submission, and completion
callback.

The fixture also checks the effect output cache. Repeating the same prefix must
reuse the completed result without another capture or filter pass. Changing a
surface color behind the marker must invalidate the pixels, trigger a fresh
capture and both filters, and reuse the existing shared mesh.

## Environment

- Windows x64
- Odin `dev-2026-09-nightly:a2fb372` from
  `C:\Users\saman\Documents\odin\dist\odin.exe`
- Native adapter: NVIDIA GeForce RTX 2080 SUPER, D3D12
- Browser: local in-app browser, `http://127.0.0.1:8766/`; the fixture reported
  the requested native backend as `Undefined` as expected for browser WebGPU.
  The exposed status did not classify the browser adapter as hardware or
  software-backed.

## Commands

From the repository root:

~~~powershell
& 'C:\Users\saman\Documents\odin\dist\odin.exe' check renderer/webgpu -no-entry-point
& 'C:\Users\saman\Documents\odin\dist\odin.exe' check examples/15_webgpu_feasibility
& '.\examples\15_webgpu_feasibility\build.ps1' -Odin 'C:\Users\saman\Documents\odin\dist\odin.exe'
.\examples\15_webgpu_feasibility\out\webgpu_feasibility_smoke.exe --backend=d3d12
.\examples\15_webgpu_feasibility\out\webgpu_feasibility_resize_smoke.exe --backend=d3d12
python -m http.server 8766 --directory examples/15_webgpu_feasibility/web
~~~

Open `http://127.0.0.1:8766/` for the browser replay. The server is only needed
while the page is open.

## Results

- Both Odin package checks passed.
- The build script produced native interactive, readback, and resize
  executables and the `js_wasm32` fixture.
- Windows D3D12 readback passed all fixture pixels. Across the effect sequence
  it reported `capture=3`, `filters=3/3`, `composite=4`, `cache_hits=1`, and
  `mesh_rebuilds=2`. The active 40×40 set plus its retained mesh used 74,120
  bytes. Total residency was 100,040 bytes while the retired set remained in
  flight, below the 50,331,648-byte effect budget.
- Pixel probes passed for the original red/blue mixed blur, changed red/green
  prefix invalidation, resized output, and unchanged pixels outside the effect
  clip.
- Resize was prepared before the prior effect submission completed. The old
  36×36 set (25,920 bytes) remained retired behind serial 3 while the 40×40 set
  was created. Completion at serial 6 released the retired set; residency
  returned to 74,120 bytes with no retired entries.
- The D3D12 resize smoke also presented during animation at 800×450 and after
  settling at 720×405.
- A valid 1,612×1,612 effect plan required 52,013,000 bytes including the mesh,
  exceeding the 50,331,648-byte budget. The renderer skipped only the effect
  marker, preserved resources, and produced a readback identical at every RGBA
  pixel to ordinary paint with the marker removed.
- The same WebGPU fixture readback passed in the browser, including both crop
  comparisons and backdrop mixed-color, clip, unchanged-prefix cache-hit,
  changed-prefix invalidation, resized-output, and over-budget fallback parity
  checks. The page reported no new animation-frame requests for 500 ms after
  settling. Browser adapter acceleration class was not surfaced, so no browser
  hardware or performance claim is made.
- `odin test renderer/webgpu` passed its capture-slot regression; `odin test
  renderer/cpu` passed all 19 tests.
- `tools/test.ps1 -Odin C:\Users\saman\Documents\odin\dist\odin.exe` passed,
  including 352 Runtime tests, 197 native SDL_GPU tests, AccessKit contracts,
  UIA, foundation and restoration checks. Existing warnings about large stack
  locals in native secondary-window tests remain.
- `git diff --check` passed.

## Limits and follow-up

The initial one-marker validation above covered resized texture retirement on
one Windows D3D12 adapter, plus browser WebGPU readback including over-budget
fallback parity. The bounded multiple-marker coverage below supersedes its
marker-count limitation. Neither section validates SDR parity across all
output formats, macOS/Linux GPU behavior, application-host presentation, or
production performance. Browser adapter acceleration was not classified.

The validation does not simulate driver/OS-initiated device loss or recovery.
Intentional `DeviceDestroy` callback tests remain distinct from genuine device
loss, and this effect cache has not yet been exercised across device recreation.

## Bounded multiple-marker follow-up (2026-11-15)

The compositor now supports up to four backdrop entries under one aggregate
48 MiB tracked mesh+texture allocation budget. It prepares and composites
markers in paint order. A later marker's offscreen prefix pass recursively
composes earlier markers before running its filters; earlier marker sigma and
fallback policy are part of downstream prefix identity.

The two-marker regression renders overlapping effects, then renders the same
commands with only the first effect marker omitted. The fixture compares every
pixel inside the later effect's clipped region. On this run, 288 pixels differ,
showing that the later effect sampled the earlier effect's composed output.
The ordinary paint readback after an over-budget effect remains pixel-identical
to a display with that marker removed.

Validation results:

- `odin check renderer/webgpu -no-entry-point`, the native and `js_wasm32`
  fixture builds, and all 20 `renderer/cpu` tests passed.
- Full Windows readback smoke passed on D3D12 and Vulkan using the NVIDIA
  GeForce RTX 2080 SUPER.
- A live browser WebGPU replay passed the two-marker pixel assertion and
  reported no additional animation-frame requests after settling for 500 ms.
  Browser adapter acceleration remains unclassified.
- `tools/test.ps1 -Odin C:\Users\saman\Documents\odin\dist\odin.exe` passed,
  including 352 Runtime tests, 197 SDL_GPU integration tests, AccessKit ABI/UIA,
  foundation, restoration, and native host-contract checks. Existing large
  stack-local warnings in native secondary-window tests remain.

This is renderer fixture coverage, not production application-window
presentation or cross-platform parity. Genuine device loss/recreation,
secondary-window lifecycle, SDR output-format parity, and performance remain
open. The earlier intentional-destruction callback tests are not driver-loss
tests and are not counted toward recovery evidence.
