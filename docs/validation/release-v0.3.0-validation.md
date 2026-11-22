# Alicorn v0.3.0 release validation — local pass, 2026-11-21

Validated source baseline: `e3897ab` (`benchmarks(231): adopt tab-strip/tree
regions and measure Quick Open`) on branch `finish-v030`. This record covers the
local release-profile validation and the documentation pass that consolidates
the v0.3.0 performance evidence. It does **not** cut a release: no tag, package,
or publish step was performed, and no GitHub issue was updated.

The performance evidence itself is in the
[v0.3.0 measured performance ledger](../benchmarks/v030-performance-ledger.md).

## Environment

| Pin | Value |
| --- | --- |
| Host | Windows 10 Home 22H2, build 19045; Ryzen 5 7600X, 12 logical processors; 16 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 |
| Compiler used | `C:\odin\odin.exe` — `dev-2026-11-nightly:08539cd` |
| CI compiler | Official Odin `dev-2026-11` (`laytan/setup-odin@v2`) |
| SDL3 runtime | `C:\odin\vendor\sdl3\SDL3.dll`, staged to `out\SDL3.dll` |
| AccessKit | Pinned standalone binding `e290e5f5da9cfb5e5622e4a9e5be3b691a7b82b`, C ABI 0.23.1 |
| Display | Scale 1.0 |

`odin` on this machine's `PATH` resolves to an older
`dev-2026-09-nightly` distribution without a usable core library. Every step
below passes `C:\odin\odin.exe` explicitly (or uses the value resolved by
`tools/common.ps1`). A bare `odin` invocation fails with `Path does not exist:
core:fmt`.

## Local suite

The repository's `tools/test.ps1` was replicated stage by stage, minus the
external AccessKit binding check (see deviations). Every step passed except the
browser package-boundary check, which is a local toolchain mismatch recorded
below. Counts are the Odin test runner's own tallies.

| Stage | Result | Count |
| --- | --- | ---: |
| `odin build tests` → `out\alicorn_tests.exe` | PASS | foundation executable |
| `odin build native\sdl_gpu_entry` | PASS | native entry |
| `odin test runtime` | PASS | 511 |
| `odin test host\fonts` | PASS | 5 |
| `odin test host\sdl3` | PASS | 8 |
| `odin test host\sdl3\live_resize` | PASS | 11 |
| `odin test host\sdl3\window_frame` | PASS | 1 |
| `odin test host\sdl3\input` | PASS | 10 |
| `odin test host\sdl3\clipboard` | PASS | 3 |
| `odin test host\sdl3\file_drag` | PASS | 3 |
| `odin test host\sdl3\dialogs` | PASS | 5 |
| `odin test host\menus` | PASS | 10 |
| `odin test host\bindings` | PASS | 5 |
| `odin test host\web` | PASS | 14 |
| `odin test host\diagnostics` | PASS | 9 |
| `odin test tests\fixtures\accessibility_contract` | PASS | 1 |
| `odin test ui` | PASS | 57 |
| `tools/check_web_ui_package.ps1` | **BLOCKED locally** | see deviation 2 |
| `odin test testui` (with AccessKit arguments) | PASS | 37 |
| `odin test theme` | PASS | 37 |
| `odin test renderer\cpu` | PASS | 23 |
| `odin test native\sdl_gpu` | PASS | 172 |
| `odin test native\scroll_capture_tests` | PASS | 6 |
| `out\alicorn_tests.exe` | PASS | foundation tests |
| `tools\test_restoration.ps1` | PASS | restart/restoration |
| `out\alicorn_sdl_gpu.exe --text-input-contract-test` | PASS | text/navigation/paint-span contract |
| Theme CLI: `check minimal`, `check extends_base`, `compile minimal`, generated-package `odin check`, `explain`, reject invalid unit | PASS | 6 checks |
| Accessibility contract fixture build | PASS | Windows UIA fixture compiles |

Totals: **891 tests across 19 test packages**, plus 37 `testui` tests, the
foundation executable, six theme CLI checks, the text-input contract, and the
restoration script. Every test stage was green at `e3897ab`; the browser
package-boundary build is the one step that could not pass on the local
compiler, for the reason in deviation 2.

Raw log: `out/v030-validation/suite.log` (git-ignored build output, retained on
the validating machine).

### Harness deviations

1. **External AccessKit binding check skipped.** `tools/test.ps1` first runs
   `<odin-accesskit>\tools\check.ps1`, whose `examples/windows/verify-uia.ps1`
   step needs an interactive desktop and is intermittently broken under Windows
   PowerShell 5.1 (it can select the console or IME window). That check is
   covered by CI and by the standalone binding repository. The Alicorn stages
   after it were run individually with the same
   `-collection:accesskit=...` compiler arguments the script derives.
2. **`check_web_ui_package.ps1` cannot pass on the local nightly.** The fixture
   fails inside the Odin core library:

   ```text
   C:/odin/core/os/wasm.odin(4:1) Error: Compile time panic: core:os is unsupported on js/wasm
   C:/odin/core/testing/logging.odin(84:2) Error: 'do_level_header' is not declared by 'log'
   ```

   Cause: `dev-2026-11-nightly:08539cd` compiles `*_test.odin` files during a
   normal `odin build` (verified with a two-file probe: an invalid test file
   fails a plain build on this compiler). The js/wasm closure then pulls
   `core:testing` and `core:os` through test-only imports. Adding the
   `#+build !js` guard that older runtime test files already carry to
   `runtime/bindings_test.odin`, `runtime/key_event_test.odin`, and
   `runtime/roving_test.odin` makes the wasm package build pass; the experiment
   was reverted immediately and is not part of this commit. CI pins the official
   `dev-2026-11` release, which excludes test files from normal builds, and the
   step passed there for v0.2.2. **Release gate:** confirm this step on the
   official release (or add the three guards in a source commit).
3. **`odin test testui` needs the AccessKit arguments.** The testui package
   transitively imports `host/sdl3/accessibility` through `ui` →
   `native/sdl_gpu`, so it requires the `accesskit` collection. `tools/test.ps1`
   omitted the arguments that the `ui` step passes. This commit adds
   `@($AccessKit.CompilerArguments)` to the testui line; with it the suite is
   37/37. `tools/test.sh` was not exercised on this host and still invokes
   `test testui` without collection or linker flags; verify it on Unix in CI.

## Examples and native smoke

- `tools/build_examples.ps1 -Odin C:\odin\odin.exe` built all **19** example
  executables into `out\examples\`, including `18_composable_select_parts`.
  Example 16 staged `SDL3.dll` and `wgpu_native.dll` as the script requires.
- `tools/native_sdl_gpu.ps1 -Odin C:\odin\odin.exe -Smoke -Speed -CaptureAfter 0`
  built the native host in release profile and ran the fixed 3 s smoke on the
  Windows SDL video driver and the D3D12 backend. Result:

  ```text
  sdl_video_driver windows
  window_metrics initial logical 640 x 480 pixels 640 x 480 pixel_density 1 display_scale 1
  gpu_driver_requested  gpu_driver_selected direct3d12
  SDL3/SDL_GPU retained compositor: PASS resize_iterations 300 submissions 303 ...
  ```

  `--smoke` does not emit a capture bundle; the log is the evidence. The smoke
  exercises resize, text input, composition, glyph caching, and fence
  retirement. It is not a physical input or accessibility session.

Raw log: `out/v030-validation/native_smoke.log` (git-ignored build output).

## Performance evidence

No new benchmark run was performed for this documentation pass. The ledger
reuses the dated v0.3.0 captures and their raw files, all taken on this host and
this nightly compiler:

- [#190 sparse updates](../benchmarks/issue190-sparse-updates-windows-2026-11-21.md)
  with its #227, #228 m1/m2, and #230 m1 addenda;
- [#229 phase 1](../validation/issue-229-phase1-baseline-2026-11-21.md) and
  [phase 2](../validation/issue-229-phase2-description-reuse-2026-11-21.md);
- Scratchpad [A/B](../benchmarks/scratchpad-ab-windows-2026-11-21.md),
  [phase 2 A/B](../benchmarks/scratchpad-ab-phase2-windows-2026-11-21.md),
  [region pilot](../benchmarks/scratchpad-region-pilot-windows-2026-11-21.md),
  and [region adoption](../benchmarks/scratchpad-region-adoption-windows-2026-11-21.md).

The consolidated stage tables, the #231 localization map, the Scratchpad
headline, and the limitation list are in the
[ledger](../benchmarks/v030-performance-ledger.md). The short version:

- Synthetic fixture: large deterministic stage reductions (hover 7,003 → 2
  composition visits; width 2,013 → 11 layout visits; typing description p95
  -20.3% on SDL_GPU; invalidation 175-352×).
- Real Scratchpad: -10.21% cumulative application build during a 24-character
  typing burst (phase 2), -6.24% in the region pilot, -4.41% on the adopted
  two-region capture. No reliable improvement in the nine-action command
  sequence for any of #227, #228, #230, phase 2, or regions.

## Release checklist and remaining gates

`docs/development.md` does not define a separate release checklist; prior
releases used `tools/check`/`tools/test`, the platform runbooks, and a hosted CI
run on the final SHA. Applying that convention:

- [x] Source baseline fixed and recorded (`e3897ab`).
- [x] Full local suite replicated and green (except the local wasm toolchain
      mismatch above).
- [x] All examples build.
- [x] Release-profile native smoke passes on D3D12.
- [x] Performance evidence consolidated into a stage ledger with limits and open
      status.
- [x] Changelog release-candidate section drafted (performance, correctness,
      validation, scope).
- [x] Documentation indexes updated.
- [x] CI run on the final release SHA: Windows foundation, macOS foundation
      (Metal readback), native packaging (Windows static SDL, macOS), icon
      reproducibility, browser WebGPU, Linux WebGPU, macOS WebGPU. All seven
      workflows are green at `ac469a4`; the run table and per-item status are in
      the [#146 matrix final-validation section](issue-146-motion-acceptance-matrix-2026-11-21.md#final-v030-validation-2026-11-22).
- [ ] `tools/test.ps1` and `tools/test.sh` run end to end on the official
      `dev-2026-11` release, confirming the testui argument fix and the wasm
      package check.
- [ ] macOS Metal and Linux legs for the hardware matrices; physical
      macOS/Linux desktop sessions remain outside this pass.
- [ ] Resolve the milestone's open issues or explicitly scope them out:
      #228 (remaining full-pass classes), #229 (frame budget), #230
      (allocator-side layout sparsity), #231 (research close-out and any
      authoring helper), and the open #146 motion release-gate platform items.
- [ ] Decide the Scratchpad region-adoption branch in the Scratchpad
      repository; this pass only records the measurement.
- [ ] Final changelog date and compare URL, `docs/README.md` current-release
      line, tag, packages, and publication — deliberately **not** done here.

## Scope statement

This pass changed documentation and one validation harness line only: the
changelog, the performance ledger, this record, the validation/benchmark/
performance indexes, and the `testui` AccessKit arguments in `tools/test.ps1`.
No file under `runtime/` or `native/` was modified. The temporary build-tag
experiment described in deviation 2 was reverted, and `git status` showed only
the intended documentation and harness changes before the commit.
