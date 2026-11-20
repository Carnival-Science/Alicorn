# Hardware validation runbook — physical Linux

Use this runbook on a physical Linux machine with a real Vulkan driver. It
upgrades the hosted X11/lavapipe evidence (software Vulkan under Xvfb) to a
maintainer-run session. Lavapipe/llvmpipe is never a pass for this runbook.

Baseline:
[`webgpu-feasibility-ci-crossplatform-2026-11-19.md`](webgpu-feasibility-ci-crossplatform-2026-11-19.md)
(hosted Linux x64, llvmpipe) and the existing
[`linux-native-acceptance.md`](linux-native-acceptance.md) rules.

## Prerequisites

- x86_64 Linux (Ubuntu 24.04/26.04, Fedora, or NixOS) with a physical GPU and a
  real Vulkan ICD:
  - Intel: Mesa ANV (`mesa-vulkan-drivers`, `intel_icd*.json`)
  - AMD: Mesa RADV (`vulkan-radeon`, `radeon_icd*.json`)
  - NVIDIA: proprietary driver (`nvidia-driver-*`, `nvidia_icd.json`)
- `vulkaninfo --summary` identifies the physical GPU, not `llvmpipe`.
- Both a Wayland session and an X11 session must be available. Wayland is
  required explicitly; X11 is the fallback comparison.
- Toolchain:
  - Odin: `sh tools/setup_linux_odin.sh /absolute/fresh/odin` installs the
    pinned Linux x64 nightly (`dev-2026-11-nightly:9a69916`, SHA-256
    `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618`).
    Export `ALICORN_ODIN=/absolute/fresh/odin/odin`.
  - wgpu-native: `sh tools/setup_linux_wgpu_native.sh "$("$ALICORN_ODIN" root)"`
    hash-verifies `wgpu-linux-x86_64-release.zip` (`95a4d90c…ec5a`).
  - SDL3: distro package (`libsdl3-dev`) or a shared build of 3.4.20. If you
    build your own, export `ALICORN_SDL_LINK_FLAGS` with the `-L`/`rpath` flags;
    `tools/common.sh` appends them to every native link.
  - `lld`/`wasm-ld` only for the optional browser target.
- For the native UI binary, AccessKit's Linux release is resolved by
  `tools/common.sh` (`alicorn_accesskit_linker_flags`).

## Build

```sh
export ALICORN_ODIN=/absolute/fresh/odin/odin
export ALICORN_ODIN
. tools/common.sh

sh examples/15_webgpu_feasibility/build.sh --odin "$ALICORN_ODIN"

mkdir -p out/linux-validation
alicorn_odin_with_linker_flags "$ALICORN_ODIN" \
  "$(alicorn_accesskit_linker_flags)" \
  build examples/16_native_webgpu_ui -collection:alicorn="$PWD" \
  -define:WGPU_SHARED=true -out:out/linux-validation/native_webgpu_ui
```

The native UI path needs the shared wgpu-native library; `tools/common.sh` adds
`-define:WGPU_SHARED=true` automatically on macOS (Darwin) when it is not
already set. On Linux pass it explicitly, as above.

## Wayland session (required)

Log into a Wayland session, then confirm the environment before running:

```sh
echo "$XDG_SESSION_TYPE $WAYLAND_DISPLAY $XDG_RUNTIME_DIR"
vulkaninfo --summary
export SDL_VIDEO_DRIVER=wayland

./examples/15_webgpu_feasibility/out/webgpu_feasibility_smoke
./examples/15_webgpu_feasibility/out/webgpu_feasibility_resize_smoke
./out/linux-validation/native_webgpu_ui --smoke --backend=vulkan
./out/linux-validation/native_webgpu_ui --child-smoke --backend=vulkan
./out/linux-validation/native_webgpu_ui --smoke \
  --test-simulate-unexpected-device-loss --backend=vulkan
```

Record the compositor and version (GNOME Shell/Mutter, KWin, Sway/wlroots,
Hyprland, etc.). Wayland fractional scaling behaves differently across
compositors; name it.

## X11 session (comparison)

Repeat the same commands in an X11 session with:

```sh
export SDL_VIDEO_DRIVER=x11
```

If the machine only exposes XWayland, say so; that is not an X11 session
result.

## High-DPI checks

1. Set a fractional desktop scale: GNOME 125% or 150%, KDE 1.25 or 1.5. With
   mixed-scale monitors, place the window on each output.
2. Run the interactive UI with motion and timings:

   ```sh
   ./out/linux-validation/native_webgpu_ui --timing-motion --timings --backend=vulkan
   ```

3. While the motion probe is moving, drag the window between monitors of
   different scale, then resize across the boundary.
4. Expected: motion continues, hit targets track content, no blank-frame burst,
   and `[alicorn-webgpu-workload]` shows no mesh rebuilds on a pure scale
   change. Viewport uploads are expected; text/icon/image geometry uploads are
   not.
5. Record the logical size, framebuffer size, and scale reported by the host for
   each transition. SDL window coordinates are logical; framebuffer pixels are
   the configured surface extent; the ratio is the display scale.

## What to record

Copy into a dated `docs/validation/` document:

- Distribution, kernel, GPU model and driver, Vulkan ICD and version, session
  type, compositor/version, output layout and scales, commit SHA, Odin version,
  SDL3 and wgpu-native versions.
- `vulkaninfo --summary` output (or enough of it to identify the physical
  device and driver).
- Adapter block: `backend=Vulkan`, a physical vendor/device string, and
  `type=DiscreteGPU`/`IntegratedGPU`. A `CPU`/`llvmpipe`/`lavapipe` adapter is
  a fail for this runbook.
- Readback groups (`core`, `compositor`, `effects`, accessibility-material) and
  resize smoke lines, in both Wayland and X11.
- Counter deltas for settled, transform-only motion, and scroll, compared with
  the Windows matched-description matrix.
- Fractional-scale and mixed-monitor transitions with before/after counters and
  timings.
- Synthetic loss result per backend/session, plus any validation errors.
- Explicit limits: rung 3 (`ID3D12Device5::RemoveDevice`) is D3D12-specific and
  n/a on Linux; the Vulkan analogue is a driver-reported
  `VK_ERROR_DEVICE_LOST`, which is not induced by this runbook.

## Pass/fail expectations

| Check | Pass |
| --- | --- |
| Adapter identity | physical Vulkan GPU and real ICD in both sessions |
| Fixture readback | core, compositor, effects, accessibility-material all PASS |
| Resize smoke | both sizes present; no validation error |
| Wayland | smoke, child smoke, and synthetic recovery exit 0 |
| X11 | same as Wayland |
| Fractional scaling | no crash, no mesh rebuilds on pure scale change, motion continues |
| Synthetic loss | callback fires, device/presenters recover, frame presents |
| Lavapipe/Xvfb | may be recorded as CI parity only, never as this runbook's pass |

A validation error, a lost surface without recovery, or an adapter fallback to a
software device is a fail; record the full log.
