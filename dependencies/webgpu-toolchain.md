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
delivered the loss callback in the browser, but not in the Windows native run.

The Odin package already exposes the native-only `wgpu.DevicePoll` wrapper;
`InstanceProcessEvents` is also available. The SDL fixture calls both while
async work is pending, without busy waiting. Its opt-in destroy is deferred
until outside the map callback. On Windows D3D12, both a full readback scenario
and a zero-resource/zero-submission destroy scenario fail to deliver the
callback. In the minimal scenario the test was run with both
`AllowProcessEvents` and `AllowSpontaneous`; a blocking poll returned
`queue_empty=true`, and normal release completed without the callback. The
browser did deliver `Destroyed` for the same fixture.

This is now traced to the pinned wgpu-native C API source rather than an
unresolved Odin symbol: `wgpuAdapterRequestDevice` stores the C callback in its
error sink but does not register a wgpu-core lost closure, while
`wgpuDeviceDestroy` only calls `context.device_destroy`. Core poll-time destroy
notification is driven through that separate closure. See the pinned
[native device request](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1.1/src/lib.rs#L767-L827),
[native destroy function](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1/src/lib.rs#L2399-L2406),
and [core closure/poll path](https://github.com/gfx-rs/wgpu/blob/v29.0.1/wgpu-core/src/device/global.rs#L1847-L1879).
This source finding explains why polling, callback mode, and an empty queue
didn't fix the CAPI case. A direct C caller remains useful to confirm the
published binary matches the tagged source. The smallest reproducible case and
the targeted callback-ownership fix are recorded in
`docs/webgpu-migration.md`; no upstream report has been filed.

Do not claim native loss notification or recovery until a fixed native library
passes the probe. Pending-callback shutdown safety, resource retirement, and
actual recovery remain unproven on both hosts.

The JS wrapper reports `InstanceProcessEvents` as unimplemented, while browser
async completion uses promises/event-loop callbacks; the browser destruction
callback did arrive in the test. Pending-callback shutdown safety, resource
retirement, and actual recovery remain unproven on both hosts.

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
