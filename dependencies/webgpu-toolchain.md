# WebGPU feasibility toolchain (Phase 0)

This is the initial, deliberately narrow toolchain pairing for the feasibility
fixture. It is not yet the project-wide supported-platform matrix.

## Pinned pair

- Odin compiler: `dev-2026-11-nightly:08539cd` (Windows x64 installation at
  `C:\odin\odin.exe`).
- Odin `vendor:wgpu`/`vendor:wgpu/sdl3glue`: binding revision shipped with that
  compiler; its package documentation identifies wgpu-native `v29.0.1.1`.
- Native WebGPU implementation: wgpu-native `v29.0.1.1`, release commit
  `6aed50955d934ac36049ba8d002034841633ae02`.
- WASM target: `js_wasm32`; callbacks require
  `-extra-linker-flags:"--export-table"`.
- Native platform integration: Odin `vendor:sdl3` plus
  `vendor:wgpu/sdl3glue`. SDL3 remains the window/input host.

Official package documentation says wgpu-native supplies native platforms and
Odin's WGPU JS wrapper calls browser WebGPU on WASM. It lists `js_wasm32` and
`js_wasm64p32`; this fixture starts with `js_wasm32`. The official SDL3 triangle
example uses one shared renderer module with compile-time-specific SDL and web
surface hosts. Its perpetual example frame loop is not adopted: this project
must schedule only dirty or animated frames.

## Local Windows x64 artifact evidence

The installed binding's static library and shared runtime were hashed locally:

| File | SHA-256 |
| --- | --- |
| `wgpu_native.lib` | `C47ED51546823C02C6D33E24A58E62E0535442CA1897A17D2305B2E55DF35729` |
| `wgpu_native.dll` | `5E26249C40DCDAC43F5ADCA3195FCF40E4EC6C67472B38510165F411FCC198E7` |

Location:
`C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\`.

The compiler distribution currently provides Windows x64 only. The release page
lists Windows MSVC builds for all release architectures, Linux manylinux 2.28
builds, and macOS 10.13+ builds. No macOS/Linux native library is installed in
this environment. Those platforms, architectures, package formats, code-signing
and redistribution still require their own fetch, hash, license and native-build
verification before support is claimed.

Reacquire only from the immutable
[wgpu-native v29.0.1.1 release](https://github.com/gfx-rs/wgpu-native/releases/tag/v29.0.1.1)
and verify the selected archive digest before extracting. The Odin bindings are
version-coupled to this release; do not update the binary independently.

## Binding issue and feasibility constraint

Odin issue [#8174](https://github.com/odin-lang/Odin/issues/8174) reports that
`vendor/wgpu/wgpu.js` offsets `DeviceDescriptor.requiredLimits` by eight bytes
before decoding its `Limits` value. The issue was open when audited. Until a
fixed binding is pinned and proven, the browser fixture requests default limits
(`requiredLimits = nil`) and does not depend on custom requested limits. Adapter
limits may still be queried and logged. This is a scoped feasibility workaround,
not permission to weaken the production device requirements.

The WebGPU bindings expose async adapter/device requests, async buffer mapping,
surface configuration/acquisition, queue uploads/submission, and WGPU JS
callbacks. The shared feasibility fixture has verified asynchronous offscreen
readback on Windows D3D12 and browser WebGPU. Its opt-in `DeviceDestroy` test
delivered the callback in browser WebGPU. The unmodified pinned native library
did not deliver it on Windows; a local patch to the same pinned source now
passes the native probes described below.

The Odin package already exposes the native-only `wgpu.DevicePoll` wrapper;
`InstanceProcessEvents` is also available. The SDL fixture calls both while
async work is pending, without busy waiting. Its opt-in destroy is deferred
until outside the map callback. On the unmodified Windows D3D12 binary, both a
full readback scenario and a zero-resource/zero-submission destroy scenario
failed to deliver the callback. The minimal scenario was tested with both
`AllowProcessEvents` and `AllowSpontaneous`; a blocking poll returned
`queue_empty=true`, and normal release completed without the callback. The
browser delivered `Destroyed` for the same fixture.

This was traced to the pinned wgpu-native C API source rather than an
unresolved Odin symbol: `wgpuAdapterRequestDevice` stored the C callback in its
error sink but did not register a wgpu-core lost closure, while
`wgpuDeviceDestroy` only calls `context.device_destroy`. Core poll-time destroy
notification is driven through that separate closure. The checked-in patch
[`dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch`](patches/wgpu-native-v29.0.1.1-device-lost-callback.patch)
adds that registration and dispatches the one-shot callback outside the
error-sink mutex. It passed Windows D3D12 probes in both callback modes, plus a
probe that releases the device wrapper before polling (callback received with
`device_handle_present=false`), plus full offscreen readback followed by
destroy and clean fixture teardown. See
the [Windows patch validation record](../docs/validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md)
for the exact build and repro commands. The patch SHA-256 is
`AE569A401C4014B96567F7BF459DF938ECAE96174C2C39E94336D86AE9243D5E`; the
validated `wgpu_native.lib` SHA-256 is
`B1E2660E4FB71FB77566D9997FB8D71BC029B4147F85002B7892E8171C19010B`. The
unmodified Odin binary still has the issue; the patch is not upstreamed. See the pinned
[native device request](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1.1/src/lib.rs#L767-L827),
[native destroy function](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1/src/lib.rs#L2399-L2406),
and [core closure/poll path](https://github.com/gfx-rs/wgpu/blob/v29.0.1/wgpu-core/src/device/global.rs#L1847-L1879).
This source finding explains why polling, callback mode, and an empty queue
didn't fix the original binary. No upstream report has been filed.

The Windows patch build used the release checkout's Rust channel `1.93`, Cargo
lockfile, LLVM 23.1.5 for bindgen, and `WGPU_NATIVE_VERSION=29.0.1.1` for Odin's
runtime version guard. It used `--no-default-features --features wgsl,dx12`;
equivalent patched Metal and Vulkan builds have not been compiled or tested.
Pending-callback shutdown safety beyond this explicit-destroy fixture, resource
retirement, and real device recovery remain unproven.

The JS wrapper reports `InstanceProcessEvents` as unimplemented, while browser
async completion uses promises/event-loop callbacks; the browser destruction
callback did arrive in the test. Browser pending-callback shutdown safety,
resource retirement, and actual recovery remain unproven.

## Reproducible local checks

```powershell
C:\odin\odin.exe version
Get-FileHash C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll -Algorithm SHA256
Get-FileHash C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.lib -Algorithm SHA256
```

Browser build must include Odin's `core/sys/wasm/js/odin.js`, WGPU's
`vendor/wgpu/wgpu.js`, an imported WebGPU interface, and WebAssembly memory
wiring. It is served from localhost/HTTPS because WebGPU requires a secure
context. No Emscripten toolchain is part of this setup.
