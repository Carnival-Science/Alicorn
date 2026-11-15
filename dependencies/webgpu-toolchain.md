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
- WASM linker: Odin invokes `wasm-ld`; the macOS official SDK archive omits it.
  Install Homebrew `lld` and put `$(brew --prefix lld)/bin` on `PATH` before
  building the browser target. The macOS foundation workflow does this
  explicitly and logs the linker version.
- Native platform integration: Odin `vendor:sdl3` plus
  `vendor:wgpu/sdl3glue`. SDL3 remains the window/input host.
- Linux x64 CI compiler: the official `dev-2026-11` archive, SHA-256
  `65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618`,
  installed by `tools/setup_linux_odin.sh` and checked for version
  `dev-2026-11-nightly:9a69916`.

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

The Windows compiler installed locally is x64. The Odin release page also
publishes Linux builds; the macOS and Linux CI jobs use separate official
archives with recorded version/hash checks. No macOS/Linux native SDK is
installed in this Windows environment. Package formats, code-signing and
redistribution still require platform-specific verification before support is
claimed.

The pinned release contains native archives for the current Odin binding's
desktop architecture selectors. The [official asset manifest](https://github.com/gfx-rs/wgpu-native/releases/expanded_assets/v29.0.1.1)
publishes these SHA-256 values for download verification. Non-Windows archives
have not been downloaded or verified locally; availability does not establish
successful linking or runtime behavior on the corresponding machines. Alicorn's
supported OS/architecture matrix is not yet explicitly declared, so this table
records binding/package coverage rather than a project support commitment.

The macOS arm64 foundation workflow downloads the exact release archive and
checks its SHA-256 with `tools/setup_macos_wgpu_native.sh` before installing it
under Odin's `vendor/wgpu/lib` tree. The hosted native build, Metal readback and
resize, and patched explicit-destroy callback probes have passed. This is
hosted macOS arm64 evidence; it does not replace a maintainer-run Metal session.
The Linux x64 WebGPU workflow similarly verifies the official wgpu-native
archive and exercises the native X11 surface through Xvfb with Mesa lavapipe.
That is software Vulkan evidence, not physical-GPU or Wayland validation.

| Desktop target | Odin binding selection | Official release asset | SHA-256 | Observed validation |
| --- | --- | --- | --- | --- |
| Windows x64 MSVC | `.Windows` + `.amd64` → `x86_64-msvc` | `wgpu-windows-x86_64-msvc-release.zip` | `7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132` | Installed Odin package; patched static build and D3D12 probes passed |
| macOS arm64 | `.Darwin` + `.arm64` → `aarch64` | `wgpu-macos-aarch64-release.zip` | `a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e` | Hosted arm64 CI hash-verified the archive; native/JS, Metal readback/resize, and patched explicit-destroy callbacks passed on [`cde2f08`](https://github.com/samanshaiza004/alicorn/actions/runs/43756274305); no maintainer-local Mac validation |
| macOS x64 | `.Darwin` + `.amd64` → `x86_64` | `wgpu-macos-x86_64-release.zip` | `8e2f7378548ddd0e2cf21e7d864dda46e953f0af724855a33778b85ead206d41` | Not installed or run here |
| Linux arm64 | `.Linux` + `.arm64` → `aarch64` | `wgpu-linux-aarch64-release.zip` | `015fcdf1dbae82e614a783cc38017e5399ae0927a889fe9b69c9b664bc61b47a` | Not installed or run here |
| Linux x64 | `.Linux` + `.amd64` → `x86_64` | `wgpu-linux-x86_64-release.zip` | `95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a` | New Xvfb/lavapipe CI smoke configured; first run pending; no physical GPU or Wayland claim |

The release also publishes Windows ARM64 and i686 archives, but the current
Odin `vendor:wgpu` Windows selector only names `x86_64` for `.amd64` and
`.i386`, and rejects other architectures. Windows ARM64 is therefore not a
supported build target through this binding as currently shipped; the `.i386`
mapping appears inconsistent with the x86_64 archive and is not treated as
32-bit support. If either target becomes part of Alicorn's support matrix, the
binding/package selection needs a separate verified correction.

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
`QueueOnSubmittedWorkDone`, surface configuration/acquisition, queue
uploads/submission, and WGPU JS callbacks. The shared feasibility fixture has
verified asynchronous offscreen readback, nonzero-offset partial vertex-buffer
updates, WGSL uniform-buffer layout/binding, and queue-completion callbacks on
Windows native and browser WebGPU. Browser pixel-probe results are exposed in
the page's accessible live status as well as the developer console. Its opt-in
`DeviceDestroy` test
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

A related, separate wgpu-core issue is [#9579](https://github.com/gfx-rs/wgpu/issues/9579),
which remains open as of 2026-11-15. In the pinned v29.0.1 source, explicit
destroy marks the device invalid at the start, while the device-lost closure
and GPU-resource release are queued until maintenance observes an empty queue;
the v30.0.2 source retains the same queue-empty condition. The WebGPU spec
change in [gpuweb PR #4903](https://github.com/gpuweb/gpuweb/pull/4903) removed
the intermediate `destroy started` state and described waiting for outstanding
work before loss as unobservable. The local C-wrapper patch only registers and
dispatches the existing core closure; it does not change this queue-drain
policy. Our no-pending-work probes do not resolve #9579, emulate driver loss,
or prove recovery.

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

## Browser adapter metadata bridge (2026-11-15)

The browser feasibility fixture was executed in a real browser WebGPU session,
and its shared asynchronous offscreen readback passed all thirteen pixel
probes, including partial buffer upload, uniform-buffer binding, and a padded
256-byte row layout for a 63-pixel RGBA8 texture.
That proves the browser runtime path works; the adapter classification probe
below adds evidence about the browser's fallback flag, but is not by itself a
physical-GPU or hardware-acceleration benchmark.

Source inspection of the Odin JS bridge at
`C:\odin\vendor\wgpu\wgpu.js` has a concrete defect: its
`genericGetAdapterInfo(infoPtr, info)` reads `info.vendor`, `info.architecture`,
and related fields, while `wgpuAdapterGetInfo(adapterIdx, infoPtr)` calls it
with only `infoPtr`. The feasibility page now overrides only that imported
function, obtains the exact selected adapter from Odin's JS object manager,
passes its `adapter.info` into the existing marshaller, and logs the standard
`isFallbackAdapter` property separately. It also maps WebGPU's lowercase
`subgroupMinSize`/`subgroupMaxSize` to the spelling expected by the pinned
Odin wrapper. Native adapter queries remain unchanged. No installed Odin files
were modified; the upstream binding defect remains to be reported or fixed in
the pinned toolchain.

The local browser session reported `fallback=false`, vendor `nvidia`, and
architecture `turing`; device and description were redacted. Odin's returned
`AdapterInfo` then reported backend `WebGPU`, type `Unknown`, and the same
vendor/architecture. The actual browser runtime readback passed all thirteen
pixel probes and settled without scheduling another frame. Per the WebGPU spec,
the flag says whether the selected adapter is a fallback adapter; a false value
is not a general proof of physical-GPU acceleration. Metadata may be redacted,
and other browser implementations may not expose the flag through this binding.
The JS wrapper's `AdapterInfoFreeMembers` is a no-op; this fixture queries the
metadata once at startup, so the four allocated adapter strings are bounded
to one call for the lifetime of this page.
