# Native SDL_GPU startup attribution — Issue #172 phase 1, Windows

Date: 2026-11-21 (local capture)

This is phase 1 of issue #172: measurement only. It adds startup markers to the
native SDL_GPU host, runs a fresh-process attribution harness against Hello,
Scratchpad and Punks, and publishes the resulting table. It does **not** change
resource lifetimes. No lazy initialization, smaller buffer, or lazy pipeline is
implemented here.

The historical Windows hello capture
([`native-dogfood-windows.md`](native-dogfood-windows.md)) reported about 111 MiB
working set, 154 MiB private bytes and a 0.379 s "post-submit diagnostics"
marker. That marker was not time to first visible pixel and it did not identify
which startup phase spent the time or bytes. The numbers below replace it with
separately named markers and an explicit memory attribution.

## Markers

All times are elapsed nanoseconds from the host startup origin, measured with
the monotonic tick clock (`QueryPerformanceCounter` on Windows). The origin is
the first statement of `native_run_application`, before `SDL_Init`. OS process
creation and the Odin runtime entry stub are outside the origin; the runner
reports that gap separately.

| Marker | Definition |
| --- | --- |
| `window_shown_ns` | `SDL_ShowWindow` + `SDL_RaiseWindow` returned successfully. On Windows this is after the HWND has been shown; it is not an observed first compositor frame. |
| `first_application_submit_ns` | First successful GPU command-buffer submission that consumes an application frame. It is **not** time to first visible pixel, scan-out or presentation completion. SDL_GPU exposes fence completion, not presentation completion, so the host does not claim a first-visible marker. |
| `first_input_ready_ns` | Completion of the first primary-window event-pump iteration after the window is shown. The host has drained OS input at least once. It does not require an input event and is not an input-to-display latency. |
| `first_diagnostics_ns` | First post-submit diagnostics bundle written (the historical marker). Collected only by the dedicated `--diagnostics --capture-after=0` probe launch, not by the measured launches. |
| `sdl_init_ns` | Hints + platform activation + `SDL_Init(VIDEO)`. |
| `window_create_ns` | `SDL_CreateWindow`. |
| `gpu_device_create_ns` | `SDL_CreateGPUDevice` (D3D12 selected). |
| `gpu_claim_window_ns` | `SDL_ClaimWindowForGPUDevice`. |
| `runtime_init_ns` | `new_runtime` (retained runtime, allocators, maps). |
| `host_loop_setup_ns` | Loop prologue before the initial application frame: inspector storage, event registration, scheduler/wakers, accessibility host preparation, services and `on_start`. |
| `app_init_ns` | Application `on_initialize`, when supplied. |
| `fonts_ns` | Bundled Runa faces plus the bounded DirectWrite fallback stack. |
| `renderers_make_ns` | Text + Windows chrome text + surface + solid renderer construction. `solid_renderer_make_ns` also constructs the icon and image renderers, including the icon-atlas GPU upload and `SDL_WaitForGPUIdle`. |
| `text_renderer_make_ns`, `chrome_text_make_ns`, `surface_renderer_make_ns`, `solid_renderer_make_ns` | Per-renderer split of `renderers_make_ns`. |
| `build_initial_ns` | First `native_application_build_until_stable` pass. |

Definition change: earlier host revisions measured
`first_application_submit_ns` from the application-loop origin (after runtime
and renderer construction). This phase keeps the field name but measures it from
the startup origin so it is directly comparable with `window_shown_ns` and
`first_input_ready_ns`. Numbers in older reports that used the loop origin are
therefore not directly comparable.

Per-launch memory sources:

- working set and private bytes: `Process.WorkingSet64` and
  `Process.PrivateMemorySize64` sampled every 10 ms. `PrivateMemorySize64` is the
  `PROCESS_MEMORY_COUNTERS_EX` private-committed view, not allocator-requested
  bytes.
- GPU process memory: `\GPU Process Memory(pid_<pid>*)\Dedicated Usage` and
  `\Shared Usage`, sampled every 500 ms and once at the PASS marker. Values are
  bytes, summed across the process's LUID/phys instances. These are
  driver-managed residency counters, not allocation sizes. Counter reliability
  is recorded in `summary.json` under `counters.reliability`: one sample across
  the 45 launches failed with "The data is not valid."; the runner keeps the
  last good sample rather than writing a fabricated zero.
- runtime requested bytes: the host passes a `Runtime_Allocation_Stats` record
  to `new_runtime` and prints the live/peak requested bytes in the
  `alicorn_startup_attribution` line at exit.
- host-declared eager bytes: buffer/transfer-buffer create sizes and the icon
  atlas upload size printed by the host. These are declared, not measured
  resident bytes; SDL_GPU does not expose per-resource allocation sizes.

## Method

Host: Windows 10 Home build 19045, AMD Ryzen 5 7600X (6 cores, 12 logical),
16 GiB installed (15.2 GiB visible), NVIDIA GeForce RTX 2080 SUPER (driver 32.0.15.9597),
Direct3D 12 through SDL 3.4.20. Other desktop applications (Discord, browsers)
were running; system load was recorded at the start and end of the run. Odin
`dev-2026-11-nightly:08539cd`, Go 1.27.1, Cargo 1.98.1.

Builds:

| App | Source | Build |
| --- | --- | --- |
| Hello | `examples/01_hello` in this worktree | `odin build -o:speed`, `-collection:alicorn=<this worktree>`, SDL_GPU/D3D12 |
| Scratchpad | clone of the current Scratchpad checkout (revision in the manifest) | `go run ./cmd/alicorn-dev build --alicorn-root <this worktree> --allow-alicorn-revision --release --renderer=sdl-gpu` |
| Punks | clone of the current Punks checkout; Odin frontend compiled with `-collection:alicorn=<this worktree>` and its pinned `alicorn-kit` | `cargo build -p punks-caliber --release`, then `odin build punks-standalone/odin -o:speed` |

Punks' vendored Alicorn is v0.2.1-25 (`75d305e`); the app was compiled against
this worktree's Alicorn host through a collection override. The frontend code
is the Punks revision in the manifest. This is a third workload class, not a
test of the vendored host.

Each app ran 15 fresh processes:

1. one `session-first` launch (first process of the script session; the
   executable had just been linked and may already be in the file cache),
2. one unmeasured `file-cache-warmup` launch,
3. 12 measured `warm-order` launches,
4. one `diagnostics-probe` launch with `--diagnostics --capture-after=0`.

Scratchpad received a fresh `APPDATA`/`LOCALAPPDATA` directory per launch and
the generated 193-file A/B workspace. Punks used `--smoke --folder
<crates/punks-audio/tests/fixtures>`, which opens the fixture folder, selects the
first audio file, and renders the waveform before exiting. Hello used
`--idle-validation-seconds=3`; Scratchpad used the same host deadline.

The runner detects the `SDL application PASS` line while the process is still
alive and records working set/private bytes/GPU counters at that point. Shutdown
(`SDL_WaitForGPUIdle`, resource destruction, `SDL_Quit`) follows the PASS line
and is reported separately; it is not startup.

**Warm/cold honesty:** every measured launch is `warm-order`. There was no
reboot, cache purge, page-file change or memory-pressure control. The
`session-first` and `file-cache-warmup` rows are included to show the cache
sensitivity, not to claim cold-start numbers. Measured p50/p95 use only the 12
`warm-order` launches.

## Results

Numbers are p50 / p95 over 12 measured warm-order launches. Times are
milliseconds; memory is MiB. `runtime requested` and the host-declared budget
are single host-reported values (stable across launches).

| Metric | Hello | Scratchpad | Punks |
| --- | ---: | ---: | ---: |
| Window shown (ms) | 807 / 1,658 | 858 / 1,376 | 525 / 715 |
| First application submit (ms) | 811 / 1,661 | 862 / 1,380 | 529 / 718 |
| First input pump (ms) | 808 / 1,658 | 858 / 1,377 | 525 / 715 |
| Diagnostics marker, probe (ms) | 859 | 1,526 | 1,388 |
| SDL GPU device create (ms) | 526 / 682 | 452 / 814 | 368 / 560 |
| Fonts phase (ms) | 122 / 130 | 119 / 124 | 123 / 128 |
| Renderer creation (ms) | 8 / 9 | 12 / 12 | 7 / 8 |
| Initial app build (ms) | 4 / 5 | 1 / 2 | 6 / 6 |
| Host loop setup (ms) | 2 / 31 | 143 / 506 | 2 / 2 |
| Process start to PASS (ms) | 4,651 / 4,658 | 4,917 / 6,946 | 2,576 / 2,584 |
| Pre-origin (ms) | 13.5 / 53.3 | 246.4 / 1,798.9 | 14.2 / 20.1 |
| Idle working set (MiB) | 253.9 / 254.0 | 268.3 / 270.6 | 196.7 / 196.9 |
| Private bytes (MiB) | 317.2 / 319.6 | 382.4 / 389.7 | 268.6 / 271.9 |
| Peak working set (MiB) | 253.9 / 254.0 | 268.5 / 270.6 | 245.4 / 268.7 |
| Peak private bytes (MiB) | 317.5 / 319.6 | 382.4 / 389.7 | 308.1 / 341.0 |
| GPU dedicated (MiB) | 37.7 / 37.7 | 43.3 / 43.3 | 49.5 / 49.5 |
| GPU shared (MiB) | 33.8 / 33.8 | 33.8 / 33.9 | 44.1 / 44.1 |
| Peak GPU dedicated (MiB) | 37.7 / 37.7 | 43.3 / 45.6 | 49.5 / 49.5 |
| Font requested bytes (MiB) | 66.0 | 65.7 | 66.0 |
| Process CPU total (ms) | 406 / 445 | 406 / 523 | 406 / 422 |

`Process CPU total` covers the whole bounded process interval (startup, the
3-second idle/validation window, and shutdown), not startup alone. It is not a
startup CPU claim. `Process start to PASS` is the runner's asynchronous
detection time; it can include up to one 500 ms GPU-counter query or a slow
stdout read, so it is an upper bound and is not used for phase attribution.
The host-tick markers above are authoritative.

Runtime and host-declared eager budget. These are single host-reported values,
not process samples:

| App | Runtime live (MiB) | Runtime peak (MiB) | Scratch peak (MiB) | Host declared (bytes) |
| --- | ---: | ---: | ---: | ---: |
| Hello | 67.1 | 67.1 | 0.4 | 16,994,936 |
| Scratchpad | 67.6 | 67.6 | 0.5 | 16,994,936 |
| Punks | 68.1 | 68.1 | 0.5 | 16,994,936 |

The host-declared budget is the same for all three apps because the host creates
the same eager resources: text 2 × 2,359,296 B + 4,194,304 B atlas transfer,
solid 2 × 2,359,296 B, surface 2 × 294,912 B, icon 2 × 147,456 B + 1,835,008 B
atlas upload, image 2 × 147,456 B, plus 348,792 B of embedded font files. The
icon upload additionally uses a transient staging buffer of the same 1,835,008 B,
created and released inside renderer construction; it is not counted in the
persistent declared total. SDL_GPU does not publish per-resource allocation
sizes, so these are create-time sizes, not resident/committed or driver-heap
bytes.

### Init-phase breakdown

p50 / p95 over 12 measured warm-order launches, milliseconds. Subtotals are
included in `Renderers total`; the four renderer rows sum to it.

| Phase | Hello | Scratchpad | Punks |
| --- | ---: | ---: | ---: |
| SDL init | 4.9 / 5.5 | 5.4 / 44.4 | 5.1 / 5.5 |
| Window create | 7.2 / 73.9 | 7.3 / 44.0 | 7.1 / 7.8 |
| GPU device create | 526.1 / 681.8 | 451.6 / 813.9 | 368.2 / 559.7 |
| GPU claim window | 2.3 / 2.6 | 2.5 / 2.8 | 2.6 / 2.8 |
| Runtime init | 0.04 / 0.04 | 0.03 / 0.04 | 0.04 / 0.05 |
| Host loop setup | 2.0 / 31.4 | 143.2 / 506.1 | 2.0 / 2.2 |
| App initialize | 0.0 / 0.0 | 0.3 / 0.4 | 0.0 / 0.0 |
| Fonts | 122.5 / 130.5 | 119.0 / 124.0 | 122.5 / 127.5 |
| Renderers total | 8.2 / 9.3 | 11.6 / 12.3 | 7.5 / 8.4 |
| &nbsp;&nbsp;Text renderer | 2.0 / 2.2 | 2.0 / 2.1 | 2.0 / 2.1 |
| &nbsp;&nbsp;Chrome text | 0.0 / 0.0 | 3.9 / 4.3 | 0.0 / 0.0 |
| &nbsp;&nbsp;Surface renderer | 0.8 / 0.9 | 0.8 / 1.0 | 0.7 / 0.8 |
| &nbsp;&nbsp;Solid + icons + images | 5.4 / 6.4 | 4.9 / 5.2 | 4.8 / 5.6 |
| Initial app build | 4.2 / 4.6 | 1.5 / 1.6 | 5.5 / 6.5 |

`Window shown` minus the measured phases has a median remainder of about 6 ms
for all three apps, so the phase list accounts for essentially all host work
before the window is shown. The unmeasured remainder is menu/titlebar
preparation, window metric reads, accessibility platform preparation, the
`SDL_ShowWindow` call itself and scheduler/waker setup not included above.

### Cache sensitivity

One uncontrolled launch each, before and after the unmeasured warmup. These are
not cold-start measurements; they show why every measured launch is labelled
warm-order.

| App | Launch | Window shown (ms) | First submit (ms) | Fonts (ms) | GPU device (ms) | Working set (MiB) | Private (MiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Hello | session-first | 554 | 557 | 126 | 371 | 253.8 | 318.7 |
| Hello | file-cache-warmup | 584 | 586 | 122 | 428 | 253.9 | 318.7 |
| Scratchpad | session-first | 1,574 | 1,578 | 123 | 1,029 | 268.1 | 382.5 |
| Scratchpad | file-cache-warmup | 914 | 917 | 121 | 618 | 268.3 | 381.4 |
| Punks | session-first | 500 | 503 | 119 | 336 | 196.6 | 265.7 |
| Punks | file-cache-warmup | 570 | 574 | 120 | 415 | 196.7 | 268.9 |

The single-session samples are noisy: Hello's session-first launch was faster
than its measured p50, Punks' was similar, and Scratchpad's was slower. The
only supported conclusion is that cache/load state is uncontrolled and the
warm-order p50/p95 above must not be read as cold start.

## Interpretation

- `SDL_CreateGPUDevice` is the dominant host init phase on this machine. It is
  driver work: creating the D3D12 device and its queues. The host cannot split
  it further through SDL_GPU. `SDL_ClaimWindowForGPUDevice` is small (single
  digit ms), so swapchain setup is not the cost.
- The DirectWrite fallback stack is the dominant **byte** cost inside the
  runtime. Each app loads about 66 MiB of system fallback faces at startup, and
  `fonts_ns` is about 119–123 ms warm. The bundled faces are only 349 KiB; the
  rest is the 12 locale fallback faces resolved eagerly by
  `load_directwrite_fallback_faces`.
- Renderer creation is cheap warm on this machine: text + chrome + surface +
  solid is about 7–12 ms p50. The solid renderer includes the icon-atlas upload
  and `SDL_WaitForGPUIdle`; it is the largest renderer at about 4.8–5.4 ms p50.
  Hello does not draw an icon yet still pays the upload.
- The initial application build is small (1.5–5.5 ms p50) for these three
  apps. It is not a startup bottleneck at this workload size.
- The process working set at idle is 197–268 MiB; private bytes are 269–382 MiB.
  These are current-master numbers and are not comparable to the 2026-10-03
  v0.1.0 hello capture. The runtime's requested live bytes are about 67–68 MiB,
  almost all of it the eagerly loaded fallback fonts. The difference between
  private bytes and runtime-requested bytes is host renderer resources, SDL,
  AccessKit, driver allocations, stacks, heaps and allocator slack.
- GPU process memory at settle is about 38–50 MiB dedicated and 34–44 MiB
  shared. The counter instances are stable for these event-driven workloads;
  the earlier smoke pass showed occasional under-reporting when an instance was
  absent at the sample, so peak dedicated is the more conservative upper bound.

## What this cannot attribute

- **Driver-managed device creation.** `SDL_CreateGPUDevice` is a single opaque
  call. Driver heaps, internal shader compilers, D3D12 pipeline-library caches
  and command-queue setup cannot be broken out with SDL_GPU.
- **Pipeline compiler internals.** We know each pipeline's creation is inside
  `*_make_ns`, but SDL does not expose how much of that is driver compilation,
  bytecode upload or Vulkan/D3D12 descriptor setup.
- **Shader caches.** The driver may reuse a disk shader cache between launches.
  Cache state was not controlled; the session-first vs warm rows show the
  effect but do not isolate it.
- **Scan-out and presentation.** `first_application_submit_ns` stops at the
  successful GPU submission. Compositor/DWM work and actual first visible
  pixel are not measured. PresentMon or a DXGI frame-statistics trace would be
  needed.
- **OS loader and process creation.** `pre_origin_ms` (process `StartTime` to
  host origin) is about 13–20 ms warm for Hello and Punks and about 246 ms
  (p50) for Scratchpad, which loads its 27 MiB backend DLL before the Odin host
  entry point. It is a separate lower bound, excludes image mapping before
  `StartTime` is observable, and is subject to wall-clock adjustment.
- **Runtime allocator metadata and slack.** `Runtime_Allocation_Stats` records
  requested sizes through its allocator wrapper. It does not include backing
  allocator headers, arena block slack, page rounding or the runtime's own
  static data.
- **GPU "settle" counter instances.** `GPU Process Memory` instances can appear
  or disappear while the process is alive. If the counter has no instance at
  the PASS sample, settle GPU is under-reported; peak values and the per-launch
  CSV show the variance. The counters do not separate swapchain, buffers,
  textures and driver-internal heaps.
- **Application-owned workers.** Scratchpad's Go/Caliber backend and Punks'
  Caliber audio backend run their own threads. Their CPU and memory are part of
  the process numbers but are not host startup work.
- **macOS/Metal.** Not measured. The marker code is platform-neutral and uses
  the monotonic tick clock, but `window_shown_ns` semantics on macOS
  (`SDL_ShowWindow`/`RaiseWindow`) and the Metal driver split would need their
  own capture. No claim is made here.

## Ranked lazy-init candidates for phase 2

The ranking uses measured warm-order data. "Latency" is the phase time that
would move; "bytes" is the host-declared or runtime-requested amount that would
be avoided at startup. A candidate is only worth prototyping if it does not
defer a visible hitch to the first frame or first interaction.

1. **Defer the DirectWrite fallback face stack until a fallback glyph is
   requested.** Save about 66 MiB of runtime-requested bytes and most of the
   ~119–123 ms `fonts_ns` phase per app. The bundled primary faces are already
   embedded and Latin-complete. Risk: the first CJK/Arabic/emoji glyph would
   synchronously load a system face. Bound the load set, keep the common faces
   lazily seeded on the first miss, and measure the first-miss latency before
   adopting. **Phase-2 outcome (2026-11-22): NO-GO as prototyped.** The startup
   win is real (fonts phase 0.00–0.23 ms, runtime requested live −68.9 MiB,
   working set −96 to −165 MiB, 12/12 paired rounds in Hello, Scratchpad and
   Punks), but the first shaping request that needs a platform face pays a
   synchronous 116–121 ms stall, so the change moves a visible hitch to first
   text input. See
   [`native-startup-deferred-fallback-windows-2026-11-22.md`](native-startup-deferred-fallback-windows-2026-11-22.md).
2. **Lazy icon-atlas upload (and its `SDL_WaitForGPUIdle`).** Save the 1.84 MB
   atlas upload and its staging buffer from every app that does not draw an
   icon at startup. Hello draws no icon but pays it inside
   `solid_renderer_make_ns` (4.8–5.4 ms p50 warm; p95 5.2–6.4 ms). Risk: the
   first icon frame would batch upload + idle wait into a visible frame. Prefer
   uploading on the first icon-containing display list, and keep the wait
   bounded.
3. **Lazy surface (GPU surface / waveform) renderer.** Hello and Scratchpad
   report zero surface encodes; Punks uses it. Avoid the surface pipeline and
   its 2 × 294,912-byte buffers at startup for apps that never use GPU
   surfaces. Measured `surface_renderer_make_ns` is small (<1 ms warm), so this
   is a byte/clarity win more than a latency win.
4. **Right-size or defer the 4 MiB text-atlas transfer buffer.** It is created
   eagerly at 4,194,304 bytes; first-frame text uploads are only a few KiB.
   Saving the full 4 MiB is possible with a growable/chunked upload path, but
   the latency win is near zero and a glyph-heavy first frame could resize it.
5. **Grow the 65,536-vertex text and solid buffers from the first display
   list.** Together the text and solid vertex + staging buffers are 9,437,184
   declared bytes, while the Hello first frame used 6,264 + 432 bytes. This is
   the largest static buffer block, but it risks a reallocation hitch on the
   first large Scratchpad/Punks frame. If prototyped, size from the first
   display list plus a bounded headroom and measure the first heavy frame.
6. **Image renderer creation.** Two 4,096-vertex buffers (294,912 declared
   bytes) plus a pipeline. Hello and Scratchpad may use images; the win is
   small. Deprioritize unless a specific app never uses images.
7. **Inspector/overlay resources.** Initialized eagerly inside
   `host_loop_setup_ns`. In this capture the prologue is ~2 ms for Hello and
   Punks and ~143 ms for Scratchpad (Scratchpad's own `on_start` dominates),
   so the inspector itself is not a meaningful phase-2 target.

`SDL_CreateGPUDevice` (368–526 ms p50 warm, 560–814 ms p95) is larger than every
lazy candidate combined. It is not a lazy-init candidate: deferring device
creation would delay the first frame. It is listed as the first item for a
separate driver/back-end investigation, not for phase 2 lazy initialization.

## Reproduction

```powershell
# Hello
.\tools\bench_startup.ps1 -App hello -Runs 12 -SessionFirst

# All three apps with explicit binary paths
.\tools\bench_startup.ps1 -App all -Runs 12 -SessionFirst `
  -ScratchpadExe <work>\scratchpad\out\alicorn\scratchpad-alicorn.exe `
  -ScratchpadWorkspace <work>\workspace `
  -PunksExe <work>\punks\target\windows-x86_64\release\punks.exe `
  -PunksFolder <work>\punks\crates\punks-audio\tests\fixtures
```

Raw evidence, including the runner copy, per-launch CSV/JSON, logs and the
host/build manifest, is in
[`raw/native-startup-attribution-windows-2026-11-21/`](raw/native-startup-attribution-windows-2026-11-21/).

## Checks

- `odin test native\sdl_gpu` — passed (marker struct and host loop only).
- `odin test runtime` — passed.
- Hello, Scratchpad and Punks launch and exit through the normal host paths in
  every measured launch; all 45 measured/probe processes exited 0.
