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
- Browser: local in-app browser, `http://127.0.0.1:8080/`; the fixture reported
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
python -m http.server 8080 --directory examples/15_webgpu_feasibility/web
~~~

Open `http://127.0.0.1:8080/` for the browser replay. The server is only needed
while the page is open.

## Results

- Both Odin package checks passed.
- The build script produced native interactive, readback, and resize
  executables and the `js_wasm32` fixture.
- Windows D3D12 readback passed all fixture pixels. The effect sequence reported
  `capture=2`, `filters=2/2`, `composite=3`, `cache_hits=1`, `mesh_rebuilds=1`,
  and `texture_bytes=68040` under the 50,331,648-byte effect budget.
- Pixel probes passed for the original red/blue mixed blur, a changed red/green
  prefix after cache invalidation, and unchanged red pixels outside the effect
  clip.
- The same WebGPU fixture readback passed in the browser, including both crop
  comparisons and backdrop mixed-color, clip, unchanged-prefix cache-hit, and
  changed-prefix invalidation checks. The page reported no new animation-frame
  requests for 500 ms after settling. Browser adapter acceleration class was
  not surfaced, so no browser hardware or performance claim is made.
- `odin test renderer/webgpu` passed its capture-slot regression; `odin test
  renderer/cpu` passed all 19 tests.
- `tools/test.ps1 -Odin C:\Users\saman\Documents\odin\dist\odin.exe` passed,
  including 352 Runtime tests, 197 native SDL_GPU tests, AccessKit contracts,
  UIA, foundation and restoration checks. Existing warnings about large stack
  locals in native secondary-window tests remain.
- `git diff --check` passed.

## Limits and follow-up

This validates a single effect marker and one same-size cache entry on one
Windows D3D12 adapter plus browser WebGPU readback. It does not validate
resized-effect texture retirement or budget-fallback pixels, SDR parity across
all output formats, macOS/Linux GPU behavior, application-host presentation,
or production performance. Browser adapter acceleration was not classified.

The validation does not simulate driver/OS-initiated device loss or recovery.
Intentional `DeviceDestroy` callback tests remain distinct from genuine device
loss, and this effect cache has not yet been exercised across device recreation.
