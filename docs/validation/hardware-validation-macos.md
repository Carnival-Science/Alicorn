# Hardware validation runbook — physical Apple Silicon macOS

Use this runbook on a physical Apple Silicon Mac (M1 or newer). It upgrades the
hosted CI evidence to a maintainer-run Metal session. Do not use a virtualized
macOS runner: the CI job reports `Apple Paravirtual device`, which is not a
physical GPU result.

Baseline for comparison:
[`webgpu-feasibility-ci-crossplatform-2026-11-19.md`](webgpu-feasibility-ci-crossplatform-2026-11-19.md)
(hosted arm64 Metal) and
[`webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md`](webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md)
(counter definitions and the Windows parity matrix).

## Prerequisites

- macOS 14 or newer on Apple Silicon, with a physical display attached.
- Xcode Command Line Tools: `xcode-select --install`.
- Homebrew, `cmake`, `pkg-config`, `curl`, and `unzip`.
- Odin, pinned. `sh tools/setup_macos_odin.sh /absolute/fresh/odin` installs the
  macOS arm64 November nightly (`dev-2026-11-nightly:9a69916`, SHA-256
  `fa10eee280c8786758e3ff0b8fdd9355e1c9447b1f0b8c72764e25ee4ebc3e22`). Export
  `ALICORN_ODIN=/absolute/fresh/odin/odin`. The Windows record uses a different
  nightly (`08539cd`); record the exact compiler version in your evidence.
- SDL3 3.4.18, shared: `sh tools/setup_macos_sdl3.sh`. It installs under
  `out/native-package/sdl-3.4.18/shared/prefix`; export
  `ALICORN_SDL3_PREFIX="$PWD/out/native-package/sdl-3.4.18/shared/prefix"`.
- wgpu-native `v29.0.1.1`: `sh tools/setup_macos_wgpu_native.sh "$("$ALICORN_ODIN" root)"`.
  It hash-verifies `wgpu-macos-aarch64-release.zip`
  (`a5797a37…3e`) and installs the static archive **and** dylib package.
- Optional, only for rebuilding the patched wgpu-native used by the
  explicit-destroy/loss probes: Rust `1.93` (rustup) and Homebrew LLVM for
  `libclang.dylib` (`brew install llvm`; `LIBCLANG_PATH="$(brew --prefix llvm)/lib"`).

## Link contract (important)

Native consumers that link AccessKit's static archive must use the **shared**
wgpu-native dylib. AccessKit and static wgpu-native each ship a Rust runtime
that defines `rust_eh_personality`, and ld64 rejects the duplicate. Use
`-define:WGPU_SHARED=true`; `tools/common.sh` adds
`-Wl,-rpath,<odin>/vendor/wgpu/lib/wgpu-macos-aarch64-release/lib` and the
AccessKit binding collection.

`ALICORN_DARWIN_STATIC_WGPU=1` is the release-packaging opt-out that selects the
static archive. Do **not** set it for these validation builds, and do not use
`tools/build_native_release.sh` to produce the probe binaries.

## Build and run

From the repository root:

```sh
export ALICORN_ODIN=/absolute/fresh/odin/odin
. tools/common.sh
sh tools/setup_macos_sdl3.sh
export ALICORN_SDL3_PREFIX="$PWD/out/native-package/sdl-3.4.18/shared/prefix"
sh tools/setup_macos_wgpu_native.sh "$("$ALICORN_ODIN" root)"

sh examples/15_webgpu_feasibility/build.sh --odin "$ALICORN_ODIN"
```

Readback smoke (must print the four readback groups and the adapter block):

```sh
./examples/15_webgpu_feasibility/out/webgpu_feasibility_smoke
./examples/15_webgpu_feasibility/out/webgpu_feasibility_resize_smoke
./examples/15_webgpu_feasibility/out/native_hosted_feasibility
```

Native UI smoke and motion:

```sh
mkdir -p out/macos-validation
alicorn_odin_with_linker_flags "$ALICORN_ODIN" \
  "$(alicorn_accesskit_linker_flags)" \
  build examples/16_native_webgpu_ui -collection:alicorn="$PWD" \
  -define:WGPU_SHARED=true -out:out/macos-validation/native_webgpu_ui

./out/macos-validation/native_webgpu_ui --smoke
./out/macos-validation/native_webgpu_ui --child-smoke
./out/macos-validation/native_webgpu_ui --timing-motion --timings
```

Synthetic loss and explicit-destroy callback paths (rung 1/2; Metal has no
`RemoveDevice` equivalent, so rung 3 is n/a):

```sh
./out/macos-validation/native_webgpu_ui --smoke --test-simulate-unexpected-device-loss
sh tools/validate_wgpu_native_device_loss_macos.sh
```

## High-DPI / Retina checks

Run the interactive binary with `--timing-motion`:

```sh
./out/macos-validation/native_webgpu_ui --timing-motion --timings
```

1. On a built-in Retina display, let the motion probe run for several seconds,
   then note `[alicorn-webgpu-workload]` counters and `[alicorn-webgpu-timing]`
   percentiles.
2. If an external 1× display is attached, drag the window from Retina to the
   external display **while the probe is moving** and back. If none is
   attached, change the display's "Looks like" scaled resolution mid-motion.
3. Observe: motion continues, controls remain correctly sized, no blank frame
   burst, no assertion, and counters show no mesh rebuilds on a pure scale
   change (`*_mesh_rebuilds` unchanged; a viewport upload is expected).
4. Resize the window across the scale boundary and confirm the retained
   content reflows once per resize, not per frame.

## What to record

Copy this into a dated `docs/validation/` document:

- Machine: Mac model, chip (M1/M2/M3/M4), macOS version, display layout and
  scales, commit SHA, Odin version, SDL3 and wgpu-native versions.
- Adapter block. It must show `backend=Metal` and a physical Apple GPU name
  (for example `device=Apple M2`). **`Apple Paravirtual device` is a fail** for
  this runbook; that is hosted-CI evidence only.
- The four readback lines (`core`, `compositor`, `effects`, rounded
  accessibility-material) and their pixel values. Compare with the Windows
  matrix; the fixture records channel order, so compare booleans and the
  documented red/blue note rather than raw tuples across adapters.
- Resize smoke lines for both sizes.
- Counter deltas for a settled frame, a transform-only motion, and a scroll, to
  compare against the Windows matched-description matrix.
- Retina/external-display transitions with the counter and timing samples
  before/after each transition.
- Synthetic recovery result (callback reason, adapter/device recreation,
  post-recovery frame) and explicit-destroy callback probe result.
- Any crash, validation error, or device-loss event with the full log.

## Pass/fail expectations

| Check | Pass |
| --- | --- |
| Adapter identity | Metal backend, physical Apple GPU, no Paravirtual fallback |
| Fixture readback | core, compositor, effects, accessibility-material all PASS |
| Resize smoke | both configured sizes present without validation errors |
| Native UI smoke | exit 0; `--child-smoke` presents primary and auxiliary windows |
| Retained counters | text/icon/image geometry retained on identical and transform-only frames; solid may follow the documented Windows finding |
| Scale transitions | no mesh rebuilds on pure scale change; motion and presentation continue |
| Synthetic loss | callback fires, device/presenters recover, post-recovery frame presents |
| Explicit destroy | one `reason=Destroyed` callback per probe; clean exit |
| Rung 3 (RemoveDevice) | n/a on Metal |

Any failure with a validation error, blank window, or missing post-recovery
frame is a fail; record the log verbatim and do not downgrade it to a note.
