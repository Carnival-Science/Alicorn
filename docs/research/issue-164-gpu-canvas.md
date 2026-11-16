# Issue #164: embedded GPU canvas experiment

## Decision

**NO NEW PUBLIC CORE API.** Existing retained geometry surfaces express the dogfood workload, preserve ordinary Alicorn layout and slider semantics, survive resize/DPI changes, and participate in the host's render-target effect path. A host-private callback can reduce CPU geometry work, uploads, and passes, but it duplicates GPU resource ownership inside the application boundary. The measured bottleneck belongs in Alicorn's native retained renderer, not in a public raw-GPU callback.

The follow-up worth considering is a renderer-local cache keyed by geometry resource generation, payload revision, resolved bounds/clip, and scale, or an equivalent retained mesh arena. It could keep unchanged waveform peaks on the GPU while updating only a moving playhead. That would preserve the current public API and host ownership. This experiment does not implement that renderer optimization.

## Existing API and dogfood

The selected workload mirrors Punks' waveform timeline in `punks-standalone/odin/waveform.odin` and `library_view.odin` (`WAVEFORM_BARS = 512`): a bounded peak envelope, a filled-circle playhead, a progress fill, a focused outline, and an ordinary slider overlaid in the same layout cell. The Alicorn fixture runs two timelines at once. The fixture reproduces Punks' public composition and update pattern; it does not instrument or launch the Punks executable.

Alicorn already provides the relevant boundary:

- `runtime/gpu_surface_api.odin` declares a layout-owned `gpu_geometry_surface`.
- `runtime/gpu_surface.odin` copies bounded, surface-local geometry into runtime storage, assigns payload revisions, rejects oversized or stale updates, and exposes resolved logical bounds, clip, and pixel dimensions through `gpu_surface_context`.
- `runtime/layout_widgets.odin` and `runtime/input.odin` provide the ordinary slider's range semantics, pointer capture, keyboard behavior, and accessibility representation.
- `native/sdl_gpu/surface.odin` turns retained geometry commands into GPU vertices and draws each command in its own pass. `Native_Surface_Renderer` currently has one `mesh_fingerprint`, one vertex list, one GPU vertex buffer, and one transfer buffer shared across all geometry surfaces. Alternating an unchanged peak surface and a changing playhead therefore rebuilds/uploads each layer on every frame.
- `native/sdl_gpu/effects_compositor.odin` captures retained paint prefixes for the existing render-target blur path.

The prototype custom pass is private validation code in `native/sdl_gpu/gpu_canvas_validation.odin`. It is invoked synchronously by the host, receives the current command buffer only as a borrowed call argument, and is never exposed to application code. Static peak buffers are owned and destroyed by the host after the last-use fences retire. This validates a best-case host implementation; it does **not** establish a safe public callback or frame-token contract.

## Method

Run on Windows with the optimized native fixture:

```powershell
.\tools\native_sdl_gpu.ps1 -GpuCanvasValidation -Speed
```

The selected SDL GPU backend was Direct3D 12 and the offscreen target format was `B8G8R8A8_UNORM`. The fixture compares the retained geometry path with the private host-pass prototype using identical waveform geometry and output dimensions. It includes two simultaneous waveforms, independent seek sliders, 512 peak columns per waveform, and a separately updated playhead.

The fixture includes the waveform bars, Punks-style filled-circle playhead, progress fill, focused outline, and slider in each canvas. It also checks exact pixel readback, a same-runtime resize, a retained blur/render-target effect, 128 coalesced producer updates, a hidden 250 ms idle interval, 64 synthetic pointer-to-app-value samples, and three submitted frames whose GPU buffers are released only after their fences complete. Benchmark samples alternate the retained and host-private pass paths for 64 frames at 100% scale. The optimized executable was run three times; the table reports the median of the three per-run p95s and p99s.

## Results

### Correctness and lifecycle

| Check | Result |
| --- | --- |
| Two simultaneous canvases | Pass |
| Pixel comparison at 100%: 640 x 400 | 0 differing channel bytes; maximum delta 0 |
| Pixel comparison at 125%: 720 x 440 logical, 900 x 550 physical | 0 differing channel bytes; maximum delta 0 |
| Pixel comparison at 150%: 800 x 480 logical, 1200 x 720 physical | 0 differing channel bytes; maximum delta 0 |
| Pixel comparison at 200%: 640 x 400 logical, 1280 x 800 physical | 0 differing channel bytes; maximum delta 0 |
| Resize the same runtime to 720 x 440 at 125% | 0 differing channel bytes; slider semantics retained |
| Retained blur/render-target composition | 0 differing channel bytes between implementations |
| Rapid producer updates | 128 accepted; static peak revision unchanged; latest playhead pixels equal; no UI description requested |
| Accessibility/input fallback | Ordinary `.Slider` remains the input owner with range 0–1 and step 0.01; both implementations produced the same value |
| Hidden static idle | 250 ms wait; 0 persistent allocations; no frame requested; 0 custom-pass invocations |
| Shutdown with GPU work in flight | 3 frames submitted; buffers released after all fences completed |

The DPI cases render into offscreen targets rather than changing the Windows monitor's desktop scaling. The additional resize case changes the existing runtime viewport and presentation scale before rebuilding layout. The effect case wraps each path in Alicorn's existing retained blur compositor; it does not require an application-facing GPU callback.

### Optimized Windows benchmark

Times are host wall-clock nanoseconds. “Submit-to-fence” includes the CPU wait for SDL's GPU fence and is not GPU execution time.

| Metric | Retained geometry | Private cached-peak pass |
| --- | ---: | ---: |
| Producer update p95 / p99 | 1.0 / 1.0 µs | 0.3 / 3.3 µs |
| CPU encode p95 / p99 | 58.8 / 75.8 µs | 22.9 / 31.9 µs |
| Submit-to-fence p95 / p99 | 153.3 / 538.6 µs | 116.1 / 513.5 µs |
| Vertex uploads per frame | 4 | 2 |
| Vertex bytes uploaded per frame | 227,232 B | 5,184 B |
| Geometry render passes per frame | 4 | 2 |
| Extra persistent peak GPU buffers | 0 B | 222,048 B |
| One-time static peak upload | 0 B | 222,048 B |

The private path cuts this fixture's per-frame vertex upload by about 44x and halves its geometry passes. It adds about 217 KiB of requested GPU buffer storage for the two cached peak meshes. These byte counts exclude CPU geometry payloads, driver allocation metadata, pipeline objects, and allocator overhead.

The 64-sample synthetic pointer-to-app-value trace had three-run median p95/p99 of 44.2 / 108.0 µs for the retained path and 44.7 / 74.7 µs for the callback path. Both use the same ordinary Alicorn sliders; these values include synthetic `process_pointer` calls and UI re-description, and do not measure physical device-to-photon latency. The renderer choice is not on the input path, so these small-sample differences are not evidence for a callback API.

## Limits and interpretation

The current SDL3 Odin binding exposes no portable GPU timestamp queries, so this experiment cannot report GPU execution p95/p99. Submit-to-fence timing is useful as an end-to-end queue/driver signal but remains noisy and can include scheduler delays: across the three runs, p99 ranged from 384.5 to 586.0 µs for retained geometry and 499.7 to 564.1 µs for the callback. The ranges overlap, so this experiment does not establish a stable end-to-end GPU latency improvement. The benchmark is one Windows D3D12 machine, one waveform workload, 64 frames per run, and two canvases; it does not generalize to every GPU backend or canvas workload.

The fixture reproduces Punks' public waveform composition and bounded update pattern; it does not instrument the Punks executable itself. Pointer traces are synthetic runtime events. Device loss, separate GPU devices, native multi-window lifetime, and video/image workloads were not part of this experiment. The reported p95/p99 values are the median of each run's percentile across three optimized executions; submit-to-fence includes a CPU wait for the fence and is not a GPU timestamp.

The result is sufficient to reject a general app-owned GPU callback for this use case: the application does not need new rendering semantics or ownership to build the waveform. The strong performance delta points to the single shared native geometry mesh cache as the more direct optimization target. Keep GPU canvases within retained layout and host-owned composition, and pursue a backend-local retained-geometry cache as a separate measured change if real workloads still need it.
