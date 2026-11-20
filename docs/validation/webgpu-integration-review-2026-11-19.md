# WebGPU branch integration review — 2026-11-19

This review covers merging `origin/master` (`99118f0`, 2026-11-19) into
`codex/webgpu-phase0-feasibility` (`ac5138a`) without rebasing, and the blast
radius of every branch change that touches shared runtime, host, renderer, or
tooling surface. It was produced for the integration PR; it is not new renderer
evidence.

## Merge result

- Merge commit: `0a9267e` (`Merge origin/master into
  codex/webgpu-phase0-feasibility`), first parent `ac5138a`, second parent
  `99118f0`.
- Rebase was deliberately avoided: branch evidence documents cite commit hashes
  as provenance.
- Conflict-free auto-merges covered `CHANGELOG.md`, `docs/guide.md`,
  `docs/reference.md`, `docs/hosted-runtime.md`, `docs/packaging.md`,
  `docs/validation/README.md`, the research records, `runtime/layout*.odin`,
  `runtime/motion_retained*.odin`, `runtime/positioning.odin`,
  `runtime/reconcile.odin`, `runtime/paint*.odin`, `ui/ui.odin`, and
  `native/sdl_gpu/gpu_frame.odin`.

### Conflicts and resolutions

| File | Conflict | Resolution |
| --- | --- | --- |
| `docs/getting-started.md` | Branch pinned SDL 3.4.18 via `tools/setup_macos_sdl3.sh`; master pins 3.4.20 via the pinned source builder | Took master's 3.4.20 instructions. The deleted setup script is no longer referenced anywhere. |
| `tools/common.sh` | Branch added static/shared wgpu selection; master replaced `ALICORN_SDL3_PREFIX` with `ALICORN_SDL_LINK_FLAGS` | Kept the branch's Darwin shared-wgpu selection and master's SDL link-flag block. The two are independent. |
| `tools/build_native_release.sh` | Branch carried its own 3.4.18 SDL build and Homebrew fallback; master moved to `tools/macos_sdl.sh` | Took master's pinned builder, then re-applied the branch's `ALICORN_DARWIN_STATIC_WGPU=1` export, static-wgpu comment, and LC_RPATH fail-fast guard. Removed the obsolete `ALICORN_SKIP_SDL3_PREFIX_LINKER_FLAGS` variable. |
| `.github/workflows/foundation-macos.yml` | Branch installed 3.4.18 plus wgpu-native and wasm-ld; master built pinned 3.4.20 | Kept wgpu-native and wasm-ld steps with master's pinned SDL3 build and `ALICORN_SDL_LINK_FLAGS`. |
| `.github/workflows/native-packaging.yml` | Same SDL pin conflict | Took master's `brew install cmake pkgconf` and pinned-source packaging path. |

`docs/packaging.md` auto-merged but retained a stale 3.4.18/`ALICORN_SDL3_PREFIX`
paragraph from the branch; it was rewritten to describe the pinned 3.4.20
builder. The macOS and Linux hardware runbooks used the same removed script and
were updated to `tools/macos_sdl.sh` / `ALICORN_SDL_LINK_FLAGS`.

### Integration regressions found and fixed

1. **Master's new test files broke `js_wasm32`.** Odin includes `*_test.odin`
   files in ordinary builds; new master tests
   (`runtime/hosted_multisurface_test.odin`,
   `runtime/layout_measure_panel_test.odin`,
   `runtime/positioned_child_test.odin`,
   `ui/ui_fit_content_panel_test.odin`, `ui/ui_positioned_text_test.odin`)
   lacked the `#+build !js` guard used by every other test file in the browser
   import graph. The wasm build failed inside `core:testing` (`core:os` is
   unsupported on `js/wasm`). Adding the guard restored
   `examples/15_webgpu_feasibility` and
   `tools/check_web_ui_package.ps1`. Native test inclusion is unchanged.
2. **Deleted SDL bootstrap script.** The branch's macOS workflows and runbooks
   invoked `tools/setup_macos_sdl3.sh`, which master removed. They now use
   `tools/macos_sdl.sh` and `ALICORN_SDL_LINK_FLAGS`; no stale references
   remain (`git grep ALICORN_SDL3_PREFIX|setup_macos_sdl3` is clean outside
   historical raw logs).
3. **CI trigger scope.** `webgpu-linux.yml` ran on every push and pull request
   because it had no path filter. All three WebGPU workflows now have explicit
   path filters, run on `master` and the integration branch, and keep
   `workflow_dispatch` plus the weekly schedule. Scheduled runs only execute
   from the default branch, so they activate only after merge.
4. **Point-marker validation lost its collection argument.** `native/sdl_gpu`
   now imports `alicorn:host/sdl3`, so master's
   `tools/validate_point_markers.{ps1,sh}` failed with
   "Unknown library collection: 'alicorn'" on both Windows and macOS
   foundation jobs. Both scripts now pass `-collection:alicorn`; the D3D12
   fixture passes locally and both foundation jobs are green.
5. **The CI SDL rpath leaked into the macOS package.** The merged macOS
   workflow exports `ALICORN_SDL_LINK_FLAGS` (with `-Wl,-rpath`) for
   development links. Packaging builds are explicit and should not inherit it;
   the new LC_RPATH guard caught the leak. `tools/common.sh` gained an
   `ALICORN_SKIP_SDL_LINK_FLAGS` opt-out and
   `tools/build_native_release.sh` sets it, so the static-wgpu package no
   longer embeds a runner-local rpath. The macOS WebGPU workflow's packaged-app
   step now passes.

## Shared-surface changes and verdicts

"Shared" means code that non-WebGPU applications also compile or run.

| Change | Commit | Surface | Gating / blast radius | Verdict |
| --- | --- | --- | --- | --- |
| Advertise the `Focus` semantic action on enabled focusable descriptions | `e98d037` | `runtime/semantics.odin` | Additive action in every app's accessibility tree. Gated by `d.focusable && !d.disabled`; routing uses the existing focus path. | **Additive, correct.** UIA now reports `IsKeyboardFocusable=true` for Tab-reachable controls. Runtime suite (382 tests) and the Windows UIA harness pass. |
| Presenter `.Lost`/`.Outdated` and resize guards | `b10029d` | `host/presentation/surface_presenter.odin` | WebGPU presenter only; `host/presentation` is not in the SDL_GPU application path. Guards run only when `state.device_lost` is set, so ordinary WebGPU presentation is unchanged. | **Backward-compatible.** No SDL_GPU code path. |
| Same-step presentation-failure suppression | `b10029d` | `host/sdl3/run.odin` | Native WebGPU host only; requires `device_lost && recovery_active`. SDL_GPU uses `native/sdl_gpu/application_loop.odin` instead. | **Backward-compatible.** Prevents a loss race from becoming `.Presenter_Failed`. |
| Retained renderer counters, per-submission samples, `--smoke-hold-ms` | `8b83662` | `runtime/motion_retained.odin`, `native/sdl_gpu/{application_loop,observability,vertex_buffers,solid,text,surface,icons,images}.odin`, `host/sdl3/run.odin` | Additive fields/tokens. `--smoke-hold-ms` is opt-in; with no argument `smoke_hold_ns == 0` and the three-second smoke exit is byte-for-byte the old condition. SDL_GPU counters are read-only. | **Additive.** Default smoke/host behavior unchanged; verified by native smoke on 3.4.20. |
| Shared CPU mesh extraction (`renderer/cpu/{solid,text,text_mesh,icons,images,material,effects*}`) | `c3082ce`, `416e8c4`, `a829a1b`, `404e9d8`, `3d58c9c`, `2dfabcc`, `b0fa070`, `3b15d9a`, `5f14f17` | `renderer/cpu`, `native/sdl_gpu/{solid,text,icons,images,material,effects_compositor,retained_effects}` | Code moved; SDL_GPU call sites now call the shared assemblers. Default parameters preserve previous bounds/clipping behavior; `material.odin` and effect planning moved without policy changes. | **Refactor, behavior-preserving.** `native/sdl_gpu` suite, `renderer/cpu` suite, and the SDL_GPU native smoke/readback pass. |
| Solid mesh fingerprint excludes translation/clip/target dimensions; optional `unbounded=false` parameter | `aebd636`, `40afdff` | `renderer/cpu/solid.odin`, `renderer/webgpu/solid.odin` | Fingerprint is used only by the WebGPU retained path; `unbounded` defaults to `false`, so SDL_GPU's `Append_Surface_Mesh` output and clipping are unchanged. | **Backward-compatible.** Shared code accepts the new inputs; SDL_GPU path is unaffected. |
| `ui.run` host split into `run_common` / `run_native` / `run_webgpu_*`; host services and clipboard injection | host/UI extraction commits | `ui/*`, `host/clipboard`, `host/sdl3/clipboard.odin` | `ui.run` still imports `alicorn:native/sdl_gpu` by default. The WebGPU runner is a separate opt-in entry point. Clipboard service is injected through an optional interface. | **Backward-compatible.** `ui`, `testui`, and all examples pass; default renderer remains SDL_GPU. |
| Hosted API additions: window service, text-key route, presentation-only repaint, semantic-request wake, `on_host_services` | hosted commits | `runtime/hosted.odin`, `runtime/presentation_outputs.odin`, `runtime/public_queries.odin` | New optional callbacks/fields; existing initializers keep zero values. `hosted_runtime_scroll` now reports handled after an application scroll callback (previously returned `false`). Only hosted consumers (WebGPU hosts, browser, ui runners) see this. | **Additive with one semantic fix.** The scroll change matches host expectations and is covered by `host/presentation` and `ui` tests. |
| macOS native builds default to shared wgpu-native | `5773739`, `1211874`, `3fcf315` | `tools/common.sh`, `tools/build_native_release.sh` | Development/test links on Darwin get `-define:WGPU_SHARED=true` and an absolute rpath; packaging exports `ALICORN_DARWIN_STATIC_WGPU=1` and fails fast on unexpected `LC_RPATH`. Windows/SDL_GPU link mode unchanged. SDL_GPU apps that do not import wgpu are not given a wgpu dependency, though the rpath is present in dev binaries. | **Acceptable, packaging-guarded.** Follow-up: consider adding the wgpu rpath only when wgpu is actually imported. |
| CI workflow additions | `b0adab5`, `db2b750` + integration fixes | `.github/workflows/webgpu-{linux,macos,browser}.yml` | Path-filtered; branch and `master` only; weekly cron; no secrets beyond `GITHUB_TOKEN`. Existing foundation/native-packaging workflows only gained opt-in WebGPU steps on macOS. | **Acceptable.** No unexpected master-path runs after the trigger fix. |

### Test-only export and dependency patches

- `wgpuDeviceRemoveD3D12ForTesting` is referenced only from
  `host/sdl3/run_device_removal_test.odin` inside
  `when ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE` (`#config(..., false)`), and is
  resolved with `core:dynlib` at run time. Default builds compile both branches
  to no-ops and contain no native-device accessor.
- The three patches apply cleanly, in order, to pristine wgpu-native
  `v29.0.1.1` (`6aed5095`) and are now pinned by SHA-256 in
  [`dependencies/webgpu-toolchain.md`](../../dependencies/webgpu-toolchain.md).
  They are applied only by the documented runbooks; there is no automatic
  bootstrap that silently patches the operator's Odin SDK.
- The device-loss ladder probe passes all seven cases on the patched library
  (ordinary smoke, synthetic callback, four primary removals, primary plus
  child removal).

## Follow-ups (not merge blockers)

1. SDL_GPU's solid renderer still rebuilds and re-uploads solid geometry every
   submitted frame. The matched matrix records this as the only two failing
   expectations (129/131). It is a reference-path limitation, not a merge
   regression; bringing SDL_GPU solid retention to parity is a bounded,
   separately testable improvement.
2. The Darwin shared-wgpu rpath is added to every development link made through
   `tools/common.sh`, even for SDL_GPU-only binaries. Packaging strips/rejects
   it, so release artifacts are safe; narrowing the rpath is a convenience
   follow-up.
3. Physical-session acceptance (macOS Metal, Linux Vulkan Wayland/X11, Windows
   mixed-DPI), TDR, IME/Narrator, and production-workload dogfood remain future
   gates and are recorded in the PR body's limitations section.

## Verification performed for this review

- Default renderer: benchmarks, every example, fixtures, and the
  `runtime`, `ui`, `testui`, `theme`, `host/sdl3`, `host/web`,
  `host/presentation`, `native/sdl_gpu`, `native/scroll_capture_tests`,
  `renderer/cpu`, and `tests` suites are green on Windows x64 with Odin
  `08539cd` and SDL 3.4.20.
- WebGPU opt-in: fixture and examples 15/16/17 build; D3D12 and Vulkan readback
  smoke pass; the interactive UIA harness passes both backends; the seven-case
  device-removal ladder passes; `js_wasm32` fixture and
  `tools/check_web_ui_package.ps1` build.
- `pwsh` is not installed in this Windows environment, so
  `tools/test_native_fixture_smoke.ps1` could not launch; its two cases were run
  directly through `tools/native_sdl_gpu.ps1` instead and passed. The
  `tools/test.ps1` AccessKit `verify-uia` flake (upstream AccessKit issue #1)
  was avoided by running the Alicorn suites directly.

### Hosted CI on the merged head

At `6f9ce06` (all green):

| Workflow | Run | Scope |
| --- | --- | --- |
| Alicorn foundation | [44651674196](https://github.com/Carnival-Science/Alicorn/actions/runs/44651674196) | Windows build, suites, D3D12 blending/effects/point markers/presenter, examples, benchmarks |
| Alicorn foundation (macOS) | [44651674302](https://github.com/Carnival-Science/Alicorn/actions/runs/44651674302) | Pinned Odin + SDL3 + wgpu-native, Metal blend/effects/point markers, fixture readback, patched destroy callbacks, TSan teardown |
| Native packaging | [44651674420](https://github.com/Carnival-Science/Alicorn/actions/runs/44651674420) | Windows/macOS static and shared packages, audits |
| WebGPU feasibility (Linux) | [44651674223](https://github.com/Carnival-Science/Alicorn/actions/runs/44651674223) | X11/lavapipe native readback and browser build |
| WebGPU feasibility (macOS arm64) | [44651674347](https://github.com/Carnival-Science/Alicorn/actions/runs/44651674347) | Shared-wgpu fixture, device-loss probe build, static-wgpu packaged app, Metal readback/resize |

The headless-browser workflow passed on `565952c` in run
[44650168542](https://github.com/Carnival-Science/Alicorn/actions/runs/44650168542);
later commits touch only tooling/docs outside its path filter.
