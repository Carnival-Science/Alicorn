# wgpu-native post-destroy error routing — Windows

Validated 2026-11-17 on Windows x64 / D3D12 with the Alicorn WebGPU feasibility
fixture. This is targeted C API error-routing evidence for Phase 0; it does not
simulate driver loss or validate recovery after a real device loss.

## Source and build pins

- wgpu-native `v29.0.1.1`, commit
  `6aed50955d934ac36049ba8d002034841633ae02`.
- Odin `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`).
- Rust `1.93.1`; release checkout lockfile.
- Windows x64 build with `wgsl,dx12`, `--no-default-features`.
- Existing device-lost callback patch SHA-256:
  `AE569A401C4014B96567F7BF459DF938ECAE96174C2C39E94336D86AE9243D5E`.
- New error-routing patch SHA-256:
  `81AB7D4F69A17F02FA7D9333E928C735BA0D5887EAE9EB9ED68E161C86D474F5`.
- Built shared `wgpu_native.dll` SHA-256:
  `AF6B2E62718631E53C199A7CBA2E408A8A2E97DA7BE94113EE1B60B14C6EE31C`.
- Bindgen used LLVM 23.1.5 Windows x64, release archive SHA-256
  `b2be33385ddc86e83511417a060de927ae8b09d1f3017cc3cdce5c73cd5029d7`.

The routing patch is adapted to v29.0.1.1 from
[wgpu-native PR #641](https://github.com/gfx-rs/wgpu-native/pull/641). It
routes `wgpuQueueSubmit` and `wgpuSurfaceGetCurrentTexture` errors through the
device error sink instead of `handle_error_fatal`; surface acquisition returns
status `.Error` and a null texture after reporting the error.

## Reproduce

Build the pinned library after applying the callback patch and then the routing
patch. The commands below assume LLVM 23.1.5 is extracted at the indicated path
and the source checkout is `out\wgpu-native-v29.0.1.1`:

```powershell
$source = Join-Path $PWD 'out\wgpu-native-v29.0.1.1'
$env:WGPU_NATIVE_VERSION = '29.0.1.1'
$env:LIBCLANG_PATH = 'C:\path\to\llvm-23.1.5\bin'
cargo +1.93.1 build --manifest-path (Join-Path $source 'Cargo.toml') `
  --release --locked --no-default-features --features wgsl,dx12
```

The verified DLL was built from the source with both patches applied. It was
copied into an isolated Odin vendor overlay; the installed `C:\odin` package
was not changed. The fixture was built with `-define:WGPU_SHARED=true` and
AccessKit's pinned compiler/linker arguments, then run from the directory
containing that DLL. From the repository root, with the patched DLL already
copied into `out\odin-overlay\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll`:

```powershell
. .\tools\common.ps1
$accesskit = Get-AlicornAccessKit
$vendor = (Resolve-Path .\out\odin-overlay\vendor).Path
Push-Location .\examples\15_webgpu_feasibility
& C:\odin\odin.exe build . `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true `
  -define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true `
  -define:FEASIBILITY_TEST_WGPU_NATIVE_POST_DESTROY_ERRORS=true `
  -define:WGPU_SHARED=true `
  -collection:alicorn=../.. "-collection:vendor=$vendor" `
  @($accesskit.CompilerArguments) `
  -out:..\..\out\webgpu-patched\post_destroy_errors.exe
if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed' }
Pop-Location
Copy-Item C:\odin\vendor\sdl3\SDL3.dll .\out\webgpu-patched\SDL3.dll -Force
Copy-Item .\out\odin-overlay\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll `
  .\out\webgpu-patched\wgpu_native.dll -Force
Push-Location .\out\webgpu-patched
.\post_destroy_errors.exe --backend=d3d12
Pop-Location
```

The corresponding compile-time options are
`FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true`,
`FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true`, and
`FEASIBILITY_TEST_WGPU_NATIVE_POST_DESTROY_ERRORS=true`.

## Results

- D3D12 selected the NVIDIA GeForce RTX 2080 SUPER.
- The fixture configured the surface, created one empty command buffer, and
  explicitly destroyed the device before any presentation.
- `QueueSubmit` returned. Its validation error reached the registered
  uncaptured-error callback rather than panicking across the C ABI.
- `SurfaceGetCurrentTexture` returned `.Error` with no texture. Its validation
  error also reached the uncaptured-error callback.
- The fixture received exactly one device-lost callback with reason
  `Destroyed`, completed teardown, printed `post-destroy error routing PASS`,
  and exited with code 0.

## Additional feasibility fixture validation (2026-11-17)

After wiring the pinned AccessKit arguments into the native fixture build, the
Hosted_Runtime smoke exposed that AccessKit's Windows window adapter must be
created before its SDL window is first shown. The fixture now prepares the
platform before window creation, keeps Hosted_Runtime windows hidden through
adapter initialization, then shows them. This also keeps the two-window case
on the same lifecycle.

`./examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed,
including native and browser builds. On Windows x64, both
`native_hosted_feasibility.exe` and `native_multi_surface_feasibility.exe`
passed. The latter verified independent Runtime pointer/focus routing, two
surface presentation and resize, text-key and synthetic IME commit/cancel, and
secondary Runtime/presenter teardown after queue completion. The primary
WebGPU readback smoke also passed on the NVIDIA GeForce RTX 2080 SUPER (Vulkan
backend), including core/compositor/effects pixel checks and resource
retirement. These checks complement, but do not upgrade, the intentional
device-destroy result into genuine driver-loss or recovery evidence.

This probe exposed that wgpu-native's default uncaptured-error handler panics
when the C error sink has no application callback. The native SDL3 and browser
hosts now install a logging callback, leaving recovery decisions to the
separate device-lost callback. The probe installs its own callback and asserts
both routed errors are observed.

## Limits

Only queue submission and surface texture acquisition were changed and tested.
Other wgpu-native C API paths may still call the fatal handler. This test uses
intentional `DeviceDestroy`; it is not evidence of driver/OS-initiated loss,
callback behavior during genuine device failure, successful resource rebuild,
or in-flight resource retirement. The patch remains a local validation patch;
it is not yet integrated into Odin SDK packaging. The macOS script applies
both patches and now includes the same fixture mode, but its updated CI run has
not yet completed.
