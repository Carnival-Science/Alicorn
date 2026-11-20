# wgpu-native device-loss callback patch — Windows

Validated 2026-11-15 on Windows x64 / D3D12, using the WebGPU feasibility
fixture. This is targeted dependency evidence for Phase 0, not production
renderer acceptance.

## Source and build pins

- wgpu-native release: `v29.0.1.1`, commit
  `6aed50955d934ac36049ba8d002034841633ae02`.
- Odin: `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`).
- Rust: `1.93.1`, selected by the release checkout's `rust-toolchain.toml`
  channel `1.93`.
- Native build: Windows x64 MSVC, `wgsl,dx12`, no other backend features.
- Patch: [`wgpu-native-v29.0.1.1-device-lost-callback.patch`](../../dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch),
  SHA-256 `AE569A401C4014B96567F7BF459DF938ECAE96174C2C39E94336D86AE9243D5E`.
- Built `wgpu_native.lib`: SHA-256
  `B1E2660E4FB71FB77566D9997FB8D71BC029B4147F85002B7892E8171C19010B`.
- Bindgen prerequisite used: LLVM 23.1.5 Windows x64 release archive,
  SHA-256 `b2be33385ddc86e83511417a060de927ae8b09d1f3017cc3cdce5c73cd5029d7`.
- Cargo used the release checkout's committed `Cargo.lock`.

## Reproduce the native library

Run from the Alicorn repository root in PowerShell. Install the Rust toolchain
selected by `rust-toolchain.toml`, Visual Studio C++ build tools, and LLVM 23.1.5
with `libclang.dll`. Clone only if the pinned source directory does not already
exist; verify the commit before applying the patch:

```powershell
$source = Join-Path $PWD 'out\wgpu-native-v29.0.1.1'
if (-not (Test-Path -LiteralPath $source)) {
  git clone --recurse-submodules --branch v29.0.1.1 `
    https://github.com/gfx-rs/wgpu-native.git $source
}
if ((git -C $source rev-parse HEAD) -ne '6aed50955d934ac36049ba8d002034841633ae02') {
  throw 'wgpu-native source is not the validated v29.0.1.1 commit'
}
git -C $source apply (Join-Path $PWD 'dependencies\patches\wgpu-native-v29.0.1.1-device-lost-callback.patch')

$env:WGPU_NATIVE_VERSION = '29.0.1.1'
$env:LIBCLANG_PATH = 'C:\path\to\llvm-23.1.5\bin'
cargo build --manifest-path (Join-Path $source 'Cargo.toml') `
  --release --locked --no-default-features --features wgsl,dx12
```

`WGPU_NATIVE_VERSION` is needed because wgpu-native's `wgpuGetVersion` uses it
at compile time. Without it, Odin's version guard rejects the library.

For an isolated Odin collection, copy `C:\odin\vendor\wgpu`,
`C:\odin\vendor\sdl3`, `C:\odin\vendor\vulkan`, and
`C:\odin\vendor\x11` into `out\odin-overlay\vendor`, then replace
`vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.lib` with:

```powershell
Copy-Item (Join-Path $source 'target\release\wgpu_native.lib') `
  'out\odin-overlay\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.lib' -Force
```

The feasibility fixture now exits through its regular teardown path after the
opt-in device-loss callback fires. Build from
`examples\15_webgpu_feasibility`:

```powershell
$collection = (Resolve-Path '..\..\out\odin-overlay\vendor').Path
C:\odin\odin.exe build . -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true `
  "-collection:vendor=$collection" -out:out\device-loss-early.exe
C:\odin\odin.exe build . -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_SPONTANEOUS_CALLBACK=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true `
  "-collection:vendor=$collection" -out:out\device-loss-spontaneous.exe
C:\odin\odin.exe build . -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_RELEASE_BEFORE_POLL=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true `
  "-collection:vendor=$collection" -out:out\device-loss-release-before-poll.exe
C:\odin\odin.exe build . -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true `
  "-collection:vendor=$collection" -out:out\device-loss-after-readback.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\SDL3.dll -Force
```

Run each executable from the fixture directory. The first two exercise the
zero-resource, zero-submission destroy path with `AllowProcessEvents` and
`AllowSpontaneous`. The third releases the final device handle before the host
polls; it should print `device_handle_present=false`, exercising the C API's
nullable-device callback case. The fourth verifies asynchronous offscreen
readback before destroy. Each should exit with code 0 after printing exactly
one `reason=Destroyed` callback line.

## Results

- Patched wgpu-native compiled successfully with the pinned release lockfile;
  `cargo fmt -- --check` passed.
- Both callback modes delivered `reason=Destroyed` for the early destroy
  probe, and exited cleanly through fixture teardown.
- Releasing the device handle before the host poll delivered one callback with
  `device_handle_present=false` and exited cleanly; retaining the handle during
  the other probes reported `device_handle_present=true`.
- The normal GPU fixture produced
  `async RGBA8 readback PASS len=16384 center=242,64,38,255`, then delivered
  `reason=Destroyed` and exited cleanly.
- The release library calls the callback outside the error-sink mutex and
  consumes the registered C callback once. The fixture's teardown calls
  `DeviceDestroy` again; no duplicate notification was observed.

The unmodified Odin package binary still exhibits the original missing callback
on this native path. The validation used a local static library built from the
pinned source plus the checked-in patch; it does not silently replace the
installed Odin package. The browser implementation remains unpatched and the
same fixture's browser destruction callback had already passed.

## Limits

The tests recorded above are the Windows D3D12 validation. Separately, the
macOS arm64 hosted foundation run for [`cde2f08`](https://github.com/samanshaiza004/alicorn/actions/runs/43756274305)
compiled the same patch for Metal and passed all four strict explicit-destroy
callback variants. Neither platform run simulates driver/OS-initiated device
loss, validates recovery or resource recreation, or establishes general
in-flight shutdown safety. Linux remains unvalidated. The patch has not been
submitted upstream; the upstream `trunk` request-device path inspected on
2026-11-15 still lacked core lost-closure registration.

## Induced-removal companion patch (2026-11-19)

The device-loss ladder's third rung reuses this patch and adds a separate,
test-only patch on top:
[`wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch`](../../dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch),
SHA-256 `22CBD1A12355A1DA317EAE1BA636283FF9B4E4EEDD26215184FE1BE5366871AF`.

Apply order is the callback patch, then the error-routing patch, then the
removal patch. The addition contains three things:

- `wgpuDeviceRemoveD3D12ForTesting(WGPUDevice) -> WGPUBool`, which reaches
  `wgpu-core`'s `Context::device_as_hal::<hal::api::Dx12>` →
  `wgpu-hal`'s `raw_device()` → `ID3D12Device5::RemoveDevice()`. The symbol is
  deliberately absent from `ffi/wgpu.h`; the probe resolves it with
  `core:dynlib`. It is a harness affordance, not a WebGPU C API proposal.
- A Windows-only `windows` 0.62 dependency and its `Cargo.lock` edge, so the
  patch can name the D3D12 interface type.
- A per-device `lost: AtomicBool` set by `dispatch_device_lost` and read by
  `wgpuSurfaceConfigure`. A resize that races a backend removal used to call
  `handle_error_fatal` and abort the process; the configure now returns and the
  normal recovery path owns the outcome. Non-loss configure errors still abort.

The callback patch's one-shot registration is unchanged. The companion patch
does not add device pointers to any production interface, and it is exercised
only by `tools/validate_wgpu_native_backend_removal.ps1`. See
[`webgpu-native-backend-removal-windows-2026-11-19.md`](webgpu-native-backend-removal-windows-2026-11-19.md)
for the run sequence, timings, and limits.

