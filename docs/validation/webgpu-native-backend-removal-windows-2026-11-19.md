# Induced D3D12 backend device removal — Windows

Validated 2026-11-19 on Windows x64 / D3D12, using the native SDL3 WebGPU host
(`examples/16_native_webgpu_ui`) and a locally patched wgpu-native. This records
the third rung of the device-loss ladder: a harness-induced backend device
removal through `ID3D12Device5::RemoveDevice()`. It is not an operating-system
or driver-initiated loss, and it is not Windows TDR evidence.

The ladder positions are:

1. Synthetic Alicorn loss notification (`.Unknown` callback injection) —
   recorded in
   [`webgpu-native-synthetic-recovery-windows-2026-11-17.md`](webgpu-native-synthetic-recovery-windows-2026-11-17.md).
2. `wgpuDeviceDestroy` lifecycle callbacks — recorded in
   [`webgpu-device-loss-callback-patch-windows-2026-11-15.md`](webgpu-device-loss-callback-patch-windows-2026-11-15.md).
3. **Induced backend removal (this record)** — the backend's own native device
   is destroyed while wgpu still believes it is live.
4. Windows TDR (`dxcap -forcetd`) — deferred to a dedicated hardware session
   and not attempted here.

## Environment

- Windows 10 22H2 x64, NVIDIA GeForce RTX 2080 SUPER (Turing), driver
  `32.0.15.9597` as reported by `AdapterGetInfo`.
- Odin `dev-2026-11-nightly:08539cd` at `C:\odin\odin.exe`.
- wgpu-native `v29.0.1.1`, commit
  `6aed50955d934ac36049ba8d002034841633ae02`; `wgpu-core`/`wgpu-hal` `29.0.3`.
- Rust `1.93.1` (selected by the release checkout's `rust-toolchain.toml`),
  LLVM 23.1.5 for bindgen.
- Native build: Windows x64 MSVC,
  `--no-default-features --features wgsl,dx12`. Vulkan is **not** in this
  library; the rung-3 build is deliberately D3D12-only.

## Reaching the D3D12 device: what exists in the pinned version

The pinned C API has no generic native-device accessor. `ffi/webgpu.h` and
`ffi/wgpu.h` expose only `wgpuDeviceGetNativeMetalDevice` and its Metal
texture/queue companions. There is no D3D12 equivalent in the C surface.

The route does exist below the C API:

- `wgpu-core` 29.0.3 exposes
  `Context::device_as_hal::<A: hal::Api>(DeviceId)` (used by wgpu-native's own
  `wgpuDeviceGetNativeMetalDevice`).
- `wgpu-hal` 29.0.3's D3D12 `Device::raw_device()` returns
  `&Direct3D12::ID3D12Device`.
- `ID3D12Device5` is reachable with `windows::core::Interface::cast`, the same
  pattern `wgpu-hal` already uses internally for ray-tracing queries.
- In `windows` 0.62.2 the generated `ID3D12Device5::RemoveDevice()` binding takes
  no reason argument, so the reason stored by the runtime is not controllable
  through this binding. The removal itself is unconditional.

So no guessing or vtable poking was needed. The patched library adds a single
test-only export that walks `device_as_hal::<hal::api::Dx12>` →
`raw_device()` → `cast::<ID3D12Device5>()` → `RemoveDevice()`.

## Native library patch

New patch:
[`wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch`](../../dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch),
SHA-256 `22CBD1A12355A1DA317EAE1BA636283FF9B4E4EEDD26215184FE1BE5366871AF`.
It applies after the existing callback and error-routing patches and contains:

- `wgpuDeviceRemoveD3D12ForTesting(WGPUDevice) -> WGPUBool`, marked test-only,
  deliberately absent from `ffi/wgpu.h` and resolved by name at run time.
- A `windows = "0.62"` target dependency (`Win32_Graphics_Direct3D12`) and the
  matching `Cargo.lock` edge. No other dependency changed.
- A per-device `lost: AtomicBool` set by the existing device-lost dispatch path.
  `wgpuSurfaceConfigure` now returns instead of calling `handle_error_fatal`
  when the device is already lost. Without this, a window resize that races
  the removal configured a swapchain on the removed device and aborted the
  process before recovery could run. The flag is set before the callback, so
  it also covers registrations whose C callback is absent.

Built artifacts from this run:

| File | SHA-256 |
| --- | --- |
| `target/release/wgpu_native.dll` | `14EBE97D3445F17B5CF2F42FB0C96A581447670DAA5A2E940A528B0E726D844C` |
| `target/release/wgpu_native.lib` | `743DDD5B586B59994E91719E4BB472D93D58F43ADD2600F05D6D8C1A8FB6A127` |

The import library rehashed identically on a rebuild from a clean checkout; the
DLL hash differs between local rebuilds, so treat the DLL value as the artifact
from this run rather than a reproducible build digest.

The provenance for the earlier callback patch is extended in
[`webgpu-device-loss-callback-patch-windows-2026-11-15.md`](webgpu-device-loss-callback-patch-windows-2026-11-15.md).

## Host hook

`host/sdl3/run_device_removal_test.odin` holds the validation build define
`ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE` (default `false`). When enabled,
`--test-remove-d3d12-device` makes the host, immediately after the first
successful presented frame:

1. resolve `wgpuDeviceRemoveD3D12ForTesting` from the already-loaded
   `wgpu_native.dll` with `core:dynlib`,
2. call it with the live `wgpu.Device`,
3. create and submit one empty command buffer so the removal is observed by the
   same operation class a real loss uses (a submission),
4. report the device-lost callback and elapsed timings, then let the ordinary
   recovery policy run unchanged.

Default builds compile every hook to a no-op and never reference the test
symbol. No native-device accessor was added to the production WebGPU binding,
host interface, or renderer.

Two host/presenter robustness changes were required and are not test-gated:

- `host/presentation/surface_presenter.odin` no longer reconfigures the surface
  in the `.Lost`/`.Outdated` acquire branch once the presenter is marked lost,
  and a resize on a lost presenter returns without configuring.
- `host/sdl3/run.odin` treats primary and child presentation failures as
  expected fallout when a loss was observed during the same step
  (`device_lost && recovery_active`) instead of returning `.Presenter_Failed`.

These match how a real TDR can arrive: a queued resize or an in-flight acquire
can hit the removed device before the application has processed the loss.

## Reproduce

From the repository root in PowerShell. Build the patched library from the
pinned source (the same steps as the callback record, with all three patches):

```powershell
Get-FileHash dependencies\patches\*.patch -Algorithm SHA256
# Expected (dependencies/webgpu-toolchain.md, "Patch pins"):
#   device-lost-callback      AE569A40...9243D5E
#   device-loss-routing       81AB7D4F...C474F5
#   test-remove-d3d12-device  22CBD1A1...6871AF
$source = Join-Path $PWD 'out\wgpu-native-v29.0.1.1'
git -C $source rev-parse HEAD  # must be 6aed50955d934ac36049ba8d002034841633ae02
git -C $source checkout -- .
git -C $source apply dependencies\patches\wgpu-native-v29.0.1.1-device-lost-callback.patch
git -C $source apply dependencies\patches\wgpu-native-v29.0.1.1-device-loss-routing.patch
git -C $source apply dependencies\patches\wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch
$env:WGPU_NATIVE_VERSION = '29.0.1.1'
$env:LIBCLANG_PATH = (Resolve-Path 'out\llvm-toolchain\extracted\clang+llvm-23.1.5-x86_64-pc-windows-msvc\bin').Path
cargo build --manifest-path (Join-Path $source 'Cargo.toml') `
  --release --locked --no-default-features --features wgsl,dx12
```

Then run the probe matrix:

```powershell
.\tools\validate_wgpu_native_backend_removal.ps1
```

The script builds `examples/16_native_webgpu_ui` with
`-define:WGPU_SHARED=true -define:ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE=true`,
stages the patched `wgpu_native.dll` and `SDL3.dll`, and runs seven cases:

| Case | Result |
| --- | --- |
| ordinary `--smoke` | PASS (exit 0, no recovery) |
| synthetic `.Unknown` callback | PASS (exit 0, recovered) |
| primary-window removal × 4 | PASS (exit 0, removal + callback + recovery + post-recovery frame) |
| primary-plus-child removal | PASS (exit 0, removal + callback + recovery + post-recovery frame) |

Logs are written to `out\webgpu-phase0\backend-removal\`.

## Observed sequence and timings

From the four primary-window removal runs and the primary-plus-child run. All
elapsed values are relative to the successful `RemoveDevice` call, measured
with `SDL_GetTicksNS` on the host thread.

| Stage | Observed |
| --- | --- |
| `RemoveDevice` returns | 5.2–5.7 µs after the hook begins |
| wgpu device-lost callback (`reason=Unknown`, `message=Device is lost`) | 79–495 µs |
| replacement device + presenters reattached | 116.9–157.2 ms |
| first post-recovery frame presented | 119.5–162.4 ms |

The callback fired synchronously inside the first operation that touched the
removed device. Recovery used the first of its four attempts
(`recovery attempt 1/4 started`), recreated the SDL surface, acquired a new
adapter/device, reattached the presenters, and printed
`WebGPU device recovered; retained application state preserved`. The
post-recovery frame is asserted by resetting the smoke's presented flag before
the removal and requiring a later successful present to exit.

Primary-plus-child run additionally routed two recovered-after-loss errors
through the uncaptured-error sink rather than aborting:

```text
[alicorn-webgpu] uncaptured device error type=Validation message=Validation Error
Caused by: In wgpuCommandEncoderFinish
  Parent device is lost
[alicorn-webgpu] uncaptured device error type=Validation message=Validation Error
Caused by: In wgpuQueueSubmit
  Parent device is lost
```

These are the child window's in-flight frame discovering the removal. The
device-lost callback had already consumed its one-shot registration, so they
surface as validation errors; recovery still completed and both windows
presented afterwards.

## Fixes exercised

- Reconfiguring a swapchain on a lost device was fatal in wgpu-native. The
  patched library now treats a configure failure on an already-lost device as
  expected and lets the registered recovery own it.
- `hosted_surface_present_pending` no longer calls `SurfaceConfigure` from the
  `.Lost`/`.Outdated` branch after loss is known.
- The host loop no longer converts a presentation failure that occurs in the
  same step as the loss callback into a host failure.
- The recovery path already abandoned device-bound renderer handles and
  recreated primary/secondary SDL surfaces; this run re-validated that ordering
  with a physically removed D3D12 device.

## Limits

- **Harness-induced, not OS/driver-initiated.** The process calls
  `RemoveDevice` itself. It does not exercise driver reset ordering, DXGI
  event queues, TDR recovery timing, or Windows' own device-removed
  notification path. Rung 4 (TDR) remains open.
- **D3D12 only.** Vulkan has no `RemoveDevice` equivalent; the nearest concept
  is a driver-reported `VK_ERROR_DEVICE_LOST`, which is n/a for this rung. The
  patched library in this record is built without Vulkan, so the Vulkan cases
  from the synthetic matrix were not rerun against it.
- **One machine, one GPU, one driver.** No macOS Metal or Linux hardware run.
- **Present-success, not readback.** The post-recovery assertion is a successful
  surface acquisition/submission/present and a clean smoke exit, not a pixel
  readback. The readback matrix lives in the feasibility fixture and was not
  rerun under removal.
- **No physical display-scale changes.** The window was not dragged between
  monitors during the loss; that is covered by the Windows high-DPI runbook.
- **Timings are CPU wall-clock on the host thread**, not GPU execution or
  scanout. They describe recovery latency only.
