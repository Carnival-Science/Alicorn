# WebGPU feasibility fixture: cross-platform CI matrix — 2026-11-19

Date: 2026-11-19  
Repository head: `b0adab5455fe696ad61f3d243394381dd330a7f8` on
`codex/webgpu-phase0-feasibility`  
Remote: `Carnival-Science/Alicorn` (GitHub Actions, public repository)  
Fixture: `examples/15_webgpu_feasibility` (native SDL3 and `js_wasm32`)  
Compiler pin: Odin `dev-2026-11` (`dev-2026-11-nightly:9a69916` in CI; the
Windows local baseline uses `08539cd`)  
wgpu-native pin: v29.0.1.1, SHA-256 verified by the setup scripts  
AccessKit pin: `dependencies/odin-accesskit.json` (accesskit-c 0.23.1)

The fixture code under test is `b0adab5`. A follow-up `5773739` scopes the
macOS shared-wgpu selection so packaged apps keep the static contract; the
macOS fixture job was re-run and passed on `5773739` with unchanged readback
and counter results. Later commits change the recorded documentation only.

## Scope

This record closes the cross-platform evidence gap left by the Windows-only
fixture runs. Three GitHub-hosted jobs build the committed fixture and execute
its asynchronous readback matrix on:

- macOS arm64 with the Metal backend,
- Linux x64 with Mesa lavapipe (software Vulkan) under Xvfb/X11,
- headless Chromium with Chromium's bundled SwiftShader WebGPU adapter.

The fixture itself is unchanged. The jobs assert the core, compositor, effects,
and accessibility-material readback groups, record the selected adapter, and
upload the complete console/native logs. The browser job also saves a
full-page screenshot.

This is cross-platform execution evidence for the existing fixture. It does
not add a hardware-GPU, production-workload, performance, or genuine
device-loss result, and none of the CI adapters is a physical GPU.

## Workflows and runs

| Target | Workflow | Job | Run | Duration |
| --- | --- | --- | --- | --- |
| macOS arm64 | `.github/workflows/webgpu-macos.yml` | `macos-arm64-metal` | [44550779287](https://github.com/Carnival-Science/Alicorn/actions/runs/44550779287) | 2m51s |
| Linux x64 | `.github/workflows/webgpu-linux.yml` (extended) | `linux-x64-lavapipe` | [44550779384](https://github.com/Carnival-Science/Alicorn/actions/runs/44550779384) | 2m15s |
| Headless browser | `.github/workflows/webgpu-browser.yml` | `chromium-headless` | [44550779291](https://github.com/Carnival-Science/Alicorn/actions/runs/44550779291) | 1m09s |

The macOS and browser workflows are restricted to
`codex/webgpu-phase0-feasibility` by branch and path filters, in addition to
`workflow_dispatch`. The Linux workflow already ran on every push and pull
request; only `workflow_dispatch`, toolchain caching, and log artifacts were
added, so master behavior is unchanged. No workflow pushes or writes to
`master`.

The macOS matrix job was re-run at `5773739` after the packaging guard
(44559079918) and passed with the same adapter and counters.

`workflow_dispatch` was exercised explicitly with
`gh workflow run "WebGPU feasibility (browser)" --ref
codex/webgpu-phase0-feasibility` and
`gh workflow run "WebGPU feasibility (Linux)" --ref
codex/webgpu-phase0-feasibility`; both dispatched runs passed
([browser 44555965831](https://github.com/Carnival-Science/Alicorn/actions/runs/44555965831),
[Linux 44555971836](https://github.com/Carnival-Science/Alicorn/actions/runs/44555971836)).

The macOS job's first scheduled attempt did not acquire an arm64 runner within
15 minutes (`The job was not acquired by Runner of type hosted`). The rerun
acquired a runner and passed. The repository's macOS foundation and packaging
jobs were also blocked by the same arm64 capacity shortage at that time. This
is hosted-runner availability, not a fixture failure, and should be expected
for macOS arm64 CI.

## macOS arm64 / Metal

The job installs the pinned Odin SDK and wgpu-native archive, builds SDL3
3.4.18 from the pinned source archive, and runs
`examples/15_webgpu_feasibility/build.sh --native-only`.

Linkage change required for the build: AccessKit's static library and Odin's
static wgpu-native library each contain a Rust runtime defining
`rust_eh_personality`, and ld64 rejects the duplicate. `tools/common.sh` now
selects `-define:WGPU_SHARED=true` on macOS and embeds an absolute
`-Wl,-rpath` to `libwgpu_native.dylib`; this mirrors the existing Windows and
Unix example policy. The fixture then links and runs without
`DYLD_LIBRARY_PATH` tricks. `tools/build_native_release.sh` sets
`ALICORN_DARWIN_STATIC_WGPU=1` so packaged apps keep the static contract and do
not embed developer-machine rpaths.

Adapter and surface:

```text
adapter info backend=Metal type=IntegratedGPU vendor= architecture=
  device=Apple Paravirtual device description=
surface capabilities query status=Success formats=4 alpha_modes=2
```

`Apple Paravirtual device` is the virtualized Metal device exposed to the
GitHub runner. It exercises the Metal backend and shader path, but it is not a
physical Mac GPU.

Readback result:

```text
async RGBA8 readback core PASS texture=63x64 row_pitch=256 padding_per_row=4
  bytes=262144 clear=true solid=true checker=true partial_texture=true
  partial_buffer=true uniform=true blend=true glyph=true clip=true
  outside_clip=true rounded=true rounded_corner=true last_row=true
async RGBA8 readback compositor PASS display_blend=true clip_x=true clip_y=true
  text=true overlay_order=true offset_text=true icon=true icon_clip=true
  atlas_switch=true image_red=true image_alpha=true image_blue=true
  image_clip=true solid_motion=true crop_a=true crop_b=true
async RGBA8 readback effects PASS backdrop=true backdrop_clip=true
  prefix_reuse=true prefix_invalidation=true resized=true fallback=true
  geometry_rect=true segment=true circle=true marker=true geometry_clip=true
  waveform=true gradient=true raised=true raised_bevel=true recessed=true
  recessed_bevel=true
rounded accessibility-material readback PASS variant=true face=true bevel=true
  corner=true reduced_transparency_shadow=true
custom geometry translation/opacity pixel PASS moved_pixel=[137, 28, 29, 255]
  original_pixel=[20, 31, 46, 255]
```

The resize smoke submitted both reconfigurations:
`during-animation SurfacePresent submitted at 800x450` and
`post-animation SurfacePresent submitted at 720x405`.

Raw log:
`docs/validation/raw/webgpu-feasibility-macos-metal-ci-2026-11-19.txt`.

## Linux x64 / Mesa lavapipe

The existing Linux workflow installs `libsdl3-dev`, `libvulkan-dev`,
`mesa-vulkan-drivers`, `xvfb`, and `lld`; forces the lavapipe ICD with
`VK_ICD_FILENAMES`; selects `SDL_VIDEO_DRIVER=x11`; and runs the smoke under
`xvfb-run`. Adapter and surface:

```text
adapter info backend=Vulkan type=CPU vendor=llvmpipe architecture=
  device=llvmpipe (LLVM 21.1.8, 256 bits)
  description=Mesa 26.0.8-1ubuntu0.3 (LLVM 21.1.8)
surface capabilities query status=Success formats=2 alpha_modes=2
```

All four readback groups passed, including `solid_motion=true`, both cropped
captures, the effects prefix/fallback checks, and the rounded material probe.
Retirement and cache-pressure checks also passed:

```text
backdrop resized texture retirement PASS submitted=5 completed=8 retired=0
  resident=74120 active=74120
image resource retirement PASS submitted_serial=2 completed_serial=2 retired=0
  resident_bytes=64 releases=1
custom geometry buffer retirement PASS submitted_serial=2 completed_serial=2
  retired=0 active_bytes=10752 resident_bytes=10752 retirements=1 releases=1
cache pressure in-flight protection PASS result=Resource_Failure
  first_batch_resources=120 first_batch_serials=true
  partial_second_resources=107 evictions_before=0 evictions_after=0
  resident_bytes=66957312 budget_bytes=67108864
cache pressure bound/LRU PASS status=Success submitted=4 completed=4
  batch_resources=120 resident_bytes=66948096 budget_bytes=67108864
  active_bytes=66948096 evictions=15 oldest_first_batch_evicted=true
  newest_first_batch_retained=true retired=0
```

`moved_pixel` was `[138, 28, 30, 255]`. Lavapipe is a CPU Vulkan
implementation; this is the X11 surface contract and Vulkan software path, not
a physical Linux GPU or Wayland result.

Raw log:
`docs/validation/raw/webgpu-feasibility-linux-lavapipe-ci-2026-11-19.txt`.

## Headless Chromium / SwiftShader

The browser job builds only `js_wasm32` (`build.sh --web-only`), serves the
staged `web/` directory from `python3 -m http.server` on localhost, and runs
`tools/webgpu_browser_smoke.js` with Playwright 1.65.1 (Chromium revision
1255), headless.

The runner was attempted with three profiles. The page loaded in all three,
but the two system-Vulkan attempts ended with
`The WebGPU device was lost; this feasibility fixture does not recreate
devices.` The passing profile uses Chromium's bundled SwiftShader WebGPU
adapter:

```text
profile=chromium-angle-swiftshader
flags=--no-sandbox --disable-gpu-sandbox --disable-dev-shm-usage
  --ignore-gpu-blocklist --enable-unsafe-webgpu --enable-unsafe-swiftshader
  --enable-features=Vulkan --disable-vulkan-surface
  --use-angle=swiftshader --use-webgpu-adapter=swiftshader
VK_ICD_FILENAMES=<playwright chromium>/vk_swiftshader_icd.json
adapter classification fallback=true vendor=google architecture=swiftshader
status=Settled: demand-driven idle (5 frame requests; 2 initialization wake
  frames)
```

The Mesa lavapipe ICD installed on the runner did not produce a usable
Chromium WebGPU device. That is recorded as a browser-WebGPU limitation, not
as a lavapipe failure for the native Vulkan path, which passes above.

All four readback groups passed, the transform/crop checks included, and the
page reached demand-driven idle. The full-page screenshot shows the retained
UI and the diagnostics footer with the PASS lines. The passing attempt
completed initialization and the whole matrix in 669 ms on SwiftShader.

Raw console log:
`docs/validation/raw/webgpu-feasibility-browser-chromium-swiftshader-ci-2026-11-19.txt`.
The screenshot is
`docs/validation/assets/webgpu-feasibility-browser-chromium-swiftshader-ci-2026-11-19.png`
(also uploaded as the `webgpu-browser-chromium` artifact of run 44550779291).

## Counter parity

The renderer counters are CPU-side and therefore directly comparable across
backends. They match the Windows NVIDIA Turing browser run and each other
exactly:

| Counter group | Windows browser (NVIDIA) | macOS Metal | Linux lavapipe | Chromium SwiftShader |
| --- | --- | --- | --- | --- |
| solid mesh rebuilds / vertex uploads | 1 / 1 | 1 / 1 | 1 / 1 | 1 / 1 |
| solid vertex bytes | 648 | 648 | 648 | 648 |
| transform uploads / bytes | 1 / 24 | 1 / 24 | 1 / 24 | 1 / 24 |
| viewport uploads | 1 | 1 | 1 | 1 |
| mixed paint commands | 15 | 15 | 15 | 15 |
| icon atlas pages / bytes | 2 / 1572864 | 2 / 1572864 | 2 / 1572864 | 2 / 1572864 |
| image texture uploads / bytes | 2 / 128 | 2 / 128 | 2 / 128 | 2 / 128 |
| custom surface vertices / instance uploads | 72 / 1 | 72 / 1 | 72 / 1 | 72 / 1 |
| backdrop capture / filters / composite | 3 / 3 / 6 | 3 / 3 / 6 | 3 / 3 / 6 | 3 / 3 / 6 |
| backdrop cache hits / mesh rebuilds | 2 / 2 | 2 / 2 | 2 / 2 | 2 / 2 |
| backdrop texture bytes | 100040 | 100040 | 100040 | 100040 |
| cache-pressure residents / evictions | 66948096 / 15 | 66948096 / 15 | 66948096 / 15 | 66948096 / 15 |

Two backend-visible differences are recorded rather than smoothed over:

- Surface format counts differ: 1 on Chromium, 2 on Linux Vulkan, 4 on
  macOS Metal. The fixture accepts the first supported format; the readback
  matrix uses offscreen RGBA8 targets and is unaffected.
- The custom-geometry `moved_pixel` differs by one least-significant bit in
  red/blue across adapters (`[137, 28, 30, 255]` Windows,
  `[137, 28, 29, 255]` macOS, `[138, 28, 30, 255]` Linux). The probe's
  boolean comparison passes on all three. This is ordinary adapter
  color-precision variation, not a readback failure and not evidence of exact
  cross-adapter pixel identity.

## Known limitations

- **All CI adapters are software or virtualized.** macOS uses
  `Apple Paravirtual device`; Linux uses llvmpipe; Chromium uses SwiftShader
  (`fallback=true`). There is still no hosted hardware-Metal or hardware
  driver-GPU evidence. Driver errata, real GPU timings, and physical display
  behavior remain unverified.
- **Chromium only.** Firefox WebGPU is not enabled by default on the Linux
  runner, and Safari is unavailable there. The "multi-browser" Phase 6 item
  therefore remains open; this run adds one headless Chromium configuration.
- **No Wayland.** Linux surface evidence is X11 through Xvfb. Wayland and a
  compositor's presentation path are still untested.
- **No performance claim.** The jobs do not measure GPU time, submission
  latency, or input-to-photon latency. SwiftShader and lavapipe timings are
  not representative.
- **No genuine device loss.** The fixture intentionally does not recreate
  devices. The browser page reports the lost device honestly; the native
  device-loss patch probes are separate and are not exercised here.
- **macOS runner capacity.** The first macOS attempt never acquired a runner.
  Re-running recovered. Jobs should tolerate this queue behavior.
- **The fixture is not a production workload.** This matrix validates the
  shared renderer and host boundary on additional operating systems; it does
  not instrument Punks/Scratchpad or a shipping application.
- **The broader macOS foundation job still fails later, for a separate
  reason.** With the shared link, its native checks and the fixture smoke now
  pass; `tools/validate_wgpu_native_device_loss_macos.sh` then builds the
  fixture directly with `odin build` and no AccessKit collections, so Odin
  reports `Unknown library collection: 'accesskit'`. That script predates the
  standalone AccessKit pin (the toolchain notes already list its hosted result
  as pending) and is not part of the fixture matrix jobs. It needs the
  AccessKit arguments and a patched dylib before the foundation job can be
  green end to end.

## Reproduction

```sh
# macOS arm64
sh tools/setup_macos_odin.sh "$RUNNER_TEMP/alicorn-odin"
ODIN_ROOT="$RUNNER_TEMP/alicorn-odin" ALICORN_ODIN="$ODIN_ROOT/odin" \
  sh tools/setup_macos_wgpu_native.sh "$ODIN_ROOT"
sh examples/15_webgpu_feasibility/build.sh --native-only
./examples/15_webgpu_feasibility/out/webgpu_feasibility_smoke

# Linux x64 (lavapipe + Xvfb pattern from the workflow)
VK_ICD_FILENAMES=$(find /usr/share/vulkan/icd.d -name 'lvp_icd*.json' -print -quit) \
SDL_VIDEO_DRIVER=x11 \
  xvfb-run -a -s '-screen 0 1280x800x24' \
  ./examples/15_webgpu_feasibility/out/webgpu_feasibility_smoke

# Browser
sh examples/15_webgpu_feasibility/build.sh --web-only
python3 -m http.server 8765 --directory examples/15_webgpu_feasibility/web &
WEBGPU_URL=http://127.0.0.1:8765/ node tools/webgpu_browser_smoke.js
```
