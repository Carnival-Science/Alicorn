# Native WebGPU UI validation — Windows

Validated against Alicorn commit `d04f72faccc5bc10fbcc94c8eae2bdf4b66dd9d2`
on Windows x64 with Odin `dev-2026-11-nightly:08539cd`, the Odin-pinned
wgpu-native `v29.0.1.1`, and an NVIDIA GeForce RTX 2080 SUPER using D3D12.

## Native `ui.run_webgpu` smoke

The example was built optimized using the repository's pinned AccessKit
compiler/linker arguments supplied by `tools/common.ps1`:

```powershell
. .\tools\common.ps1
$accessKit = Get-AlicornAccessKit
$buildArgs = @(
  'build', 'examples/16_native_webgpu_ui', '-o:speed',
  "-collection:alicorn=$((Get-Location).Path)"
) + @($accessKit.CompilerArguments) + @('-out:out/native_webgpu_ui_exact.exe')
& C:\odin\odin.exe @buildArgs
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\SDL3.dll -Force
```

Two consecutive runs of
`out\native_webgpu_ui_exact.exe --backend=d3d12 --smoke` exited with code 0.
Both logged `adapter backend=D3D12`, `type=DiscreteGPU`, and
`device=NVIDIA GeForce RTX 2080 SUPER`. This smoke returns successfully only
after the application presents a frame and drains its in-flight frame work.

## Hosted_Runtime interaction and resize smoke

The feasibility consumer was rebuilt from the same checkout with the native
Hosted_Runtime presenter and bounded interaction smoke enabled:

```powershell
C:\odin\odin.exe build examples/15_webgpu_feasibility -o:speed `
  -collection:alicorn=. `
  -define:FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER=true `
  -define:FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE=true `
  -out:examples/15_webgpu_feasibility/out/native_hosted_feasibility_exact.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll `
  examples/15_webgpu_feasibility/out/SDL3.dll -Force
Copy-Item C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll `
  examples/15_webgpu_feasibility/out/wgpu_native.dll -Force
```

`native_hosted_feasibility_exact.exe --backend=d3d12` exited with code 0. The
fixture reported successful D3D12 adapter and device callbacks, retained
presentation, pointer routing, application text-key routing, synthetic UTF-8
IME preedit/cancel/focus/commit handling, an 800×450 resize and resized
presentation, and completed teardown.

## Limits

Earlier default-mode D3D12 UI smoke attempts stalled before emitting adapter
details; the cause was not established. The successful UI retest used the
optimized build and does not validate debug-mode startup. The feasibility
input/IME events are synthetic and do not replace physical keyboard, IME, or
accessibility checks. No genuine driver/OS device loss was induced, so this is
not recovery evidence. macOS/Linux native recovery and secondary-window
recovery remain unvalidated.
