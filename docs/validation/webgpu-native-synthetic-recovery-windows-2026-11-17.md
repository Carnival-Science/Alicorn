# Native WebGPU recovery callback smoke — Windows

Validated 2026-11-17 from the `codex/webgpu-phase0-feasibility` worktree. This
records a test-injected recovery callback on the native SDL3 host. It is not a
driver-loss or operating-system-loss test.

## Environment

- Windows x64, NVIDIA GeForce RTX 2080 SUPER.
- Odin `dev-2026-11-nightly:08539cd` at `C:\odin\odin.exe`.
- Shared wgpu-native DLL and repository-pinned AccessKit compiler arguments.
- Both D3D12 and Vulkan adapters selected successfully.

## Reproduce

From the Alicorn repository root in PowerShell:

```powershell
. .\tools\common.ps1
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force out\webgpu-phase0 | Out-Null
& C:\odin\odin.exe build examples\16_native_webgpu_ui `
  "-collection:alicorn=$PWD" @($AccessKit.CompilerArguments) `
  -define:WGPU_SHARED=true -out:out\webgpu-phase0\native_webgpu_ui.exe
if ($LASTEXITCODE -ne 0) { throw 'WebGPU fixture build failed' }
$env:PATH = (Join-Path $PWD 'out\webgpu-phase0') + ';' + $env:PATH

& .\out\webgpu-phase0\native_webgpu_ui.exe --smoke --backend=d3d12
& .\out\webgpu-phase0\native_webgpu_ui.exe `
  --smoke --test-simulate-unexpected-device-loss --backend=d3d12
& .\out\webgpu-phase0\native_webgpu_ui.exe `
  --child-smoke --test-simulate-unexpected-device-loss --backend=d3d12
& .\out\webgpu-phase0\native_webgpu_ui.exe `
  --smoke --test-simulate-unexpected-device-loss --backend=vulkan
& .\out\webgpu-phase0\native_webgpu_ui.exe `
  --child-smoke --test-simulate-unexpected-device-loss --backend=vulkan
```

## Results

- The ordinary D3D12 smoke presented and exited successfully.
- Synthetic primary-window recovery passed on D3D12 and Vulkan.
- Synthetic primary-plus-secondary-window recovery passed on D3D12 and
  Vulkan. The fixture recreated both SDL WebGPU surfaces, then presented on
  the replacement device while preserving each Hosted_Runtime.
- Renderer/WebGPU tests: 6 passed. Presentation-host tests: 5 passed. SDL3
  host tests: 10 passed. `odin check host/web -no-entry-point
  -target:js_wasm32` passed.

The recovery callback is invoked with `.Unknown` after the fixture's first
successful frame. It exercises the host recovery state machine, lost-presenter
detachment, CPU-side renderer cleanup, surface recreation, adapter/device
replacement, and primary/secondary reattachment. It does not cause a physical
GPU reset or verify a real driver's callback timing, so genuine device-loss
recovery remains open.

## Fix exercised

Lost presenters now abandon their WebGPU handles instead of calling ordinary
resource-release APIs against a lost parent device. Alicorn still frees its
CPU-side caches. The host releases the old device-owned resources through
device teardown and recreates each SDL surface before attaching the replacement
device. Reusing the old surface returned a texture tied to the lost device on
the next presentation, which caused `wgpuTextureRelease` to panic in
wgpu-native; replacing the surface fixed that failure in both tested backends.

