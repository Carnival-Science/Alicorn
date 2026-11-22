param(
    [string]$Odin = 'C:\odin\odin.exe',
    [string]$PatchedWgpuDirectory = 'out\wgpu-native-v29.0.1.1\target\release',
    [string]$OutputDir = 'out\webgpu-phase0\backend-removal',
    [ValidateSet('d3d12')][string]$Backend = 'd3d12',
    [int]$RemovalRepetitions = 3
)

# Induced backend device removal (device-loss ladder rung 3).
#
# Builds examples/16_native_webgpu_ui with the validation-only
# ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE hook, links the patched wgpu-native
# shared library, then removes the live D3D12 device with
# ID3D12Device5::RemoveDevice through the test-only
# wgpuDeviceRemoveD3D12ForTesting export. The probe asserts that:
#   - the removal is issued,
#   - wgpu's DeviceLost callback fires with reason Unknown,
#   - the host's normal recovery path recreates adapter/device/presenters,
#   - a frame presents after recovery, and the process exits 0.
#
# This is harness-induced backend removal, not an OS- or driver-initiated loss.
# Vulkan is not applicable to this rung. The patched library is built with
# --no-default-features --features wgsl,dx12; do not use it for Vulkan runs.
#
# Build the patched library first:
#   dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch
#   docs/validation/webgpu-native-backend-removal-windows-2026-11-19.md
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$Odin = Resolve-AlicornOdin -Requested $Odin
$AccessKit = Get-AlicornAccessKit

$patchedDirectory = if ([System.IO.Path]::IsPathRooted($PatchedWgpuDirectory)) {
    $PatchedWgpuDirectory
} else {
    Join-Path $root $PatchedWgpuDirectory
}
$wgpuDll = Join-Path $patchedDirectory 'wgpu_native.dll'
if (-not (Test-Path -LiteralPath $wgpuDll)) {
    throw "Patched wgpu_native.dll not found at '$wgpuDll'. Build it from the pinned source with the device-loss patches."
}
& findstr /C:"wgpuDeviceRemoveD3D12ForTesting" $wgpuDll > $null
if ($LASTEXITCODE -ne 0) {
    throw "The wgpu_native.dll at '$wgpuDll' lacks wgpuDeviceRemoveD3D12ForTesting; apply dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch and rebuild."
}

$outputPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $root $OutputDir }
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$executable = Join-Path $outputPath 'backend_removal_probe.exe'

Push-Location $root
try {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build examples\16_native_webgpu_ui "-collection:alicorn=$root" @($AccessKit.CompilerArguments) `
        -define:WGPU_SHARED=true -define:ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE=true `
        -out:$executable 2>&1 | ForEach-Object { Write-Host $_ }
    $ErrorActionPreference = $previousErrorAction
    if ($LASTEXITCODE -ne 0) { throw "Probe build failed: $LASTEXITCODE" }

    Copy-Item $wgpuDll (Join-Path $outputPath 'wgpu_native.dll') -Force
    $odinRoot = (& $Odin root | Out-String).Trim()
    Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $outputPath 'SDL3.dll') -Force
    $env:PATH = $outputPath + ';' + $env:PATH

    $cases = @(
        @{ Name = 'ordinary-smoke'; Arguments = @('--smoke', "--backend=$Backend"); ExpectRecovery = $false },
        @{ Name = 'synthetic-callback'; Arguments = @('--smoke', '--test-simulate-unexpected-device-loss', "--backend=$Backend"); ExpectRecovery = $true },
        @{ Name = 'primary-removal'; Arguments = @('--smoke', '--test-remove-d3d12-device', "--backend=$Backend"); ExpectRecovery = $true },
        @{ Name = 'removal-during-motion'; Arguments = @('--removal-motion-probe', '--test-remove-d3d12-device', "--backend=$Backend"); ExpectRecovery = $true; ExpectMotion = $true }
    )
    for ($i = 1; $i -le $RemovalRepetitions; $i += 1) {
        $cases += @{
            Name = "primary-removal-run$i"
            Arguments = @('--smoke', '--test-remove-d3d12-device', "--backend=$Backend")
            ExpectRecovery = $true
        }
    }
    $cases += @{
        Name = 'primary-plus-child-removal'
        Arguments = @('--child-smoke', '--test-remove-d3d12-device', "--backend=$Backend")
        ExpectRecovery = $true
    }

    $failures = 0
    foreach ($case in $cases) {
        $logPath = Join-Path $outputPath ($case.Name + '.log')
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $executable @($case.Arguments) 2>&1 | Out-File -Encoding utf8 $logPath
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction
        $lines = Get-Content -LiteralPath $logPath
        $removalIssued = [bool]($lines | Select-String -SimpleMatch 'ID3D12Device5::RemoveDevice issued=true' | Select-Object -First 1)
        $callbackFired = [bool]($lines | Select-String -SimpleMatch 'device-lost callback fired reason=Unknown' | Select-Object -First 1)
        $recovered = [bool]($lines | Select-String -SimpleMatch 'WebGPU device recovered' | Select-Object -First 1)
        $postFrame = [bool]($lines | Select-String -SimpleMatch 'post-recovery frame presented' | Select-Object -First 1)
        $motionAtLoss = $false
        $motionAfterRecovery = $false
        $motionSmokePass = $false
        $motionAfterPostFrame = $false
        if ($case.ExpectMotion) {
            $motionAtLoss = [bool]($lines | Select-String -Pattern 'motion before-removal active_owners=[1-9]' | Select-Object -First 1)
            $motionAfterRecovery = [bool]($lines | Select-String -Pattern 'motion after-recovery-reattach active_owners=[1-9]' | Select-Object -First 1)
            $motionSmokePass = [bool]($lines | Select-String -SimpleMatch 'motion_removal_smoke PASS' | Select-Object -First 1)
            $postFrameIndex = -1
            $lastMotionActiveIndex = -1
            for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex += 1) {
                if ($lines[$lineIndex] -match 'post-recovery frame presented') { $postFrameIndex = $lineIndex }
                if ($lines[$lineIndex] -match 'motion_probe tick \d+ active_owners [1-9]') { $lastMotionActiveIndex = $lineIndex }
            }
            $motionAfterPostFrame = $postFrameIndex -ge 0 -and $lastMotionActiveIndex -gt $postFrameIndex
        }

        $ok = $exitCode -eq 0
        if ($case.Name -like '*removal*') {
            $ok = $ok -and $removalIssued -and $callbackFired -and $recovered -and $postFrame
        }
        if ($case.ExpectRecovery) { $ok = $ok -and $recovered }
        if ($case.ExpectMotion) {
            $ok = $ok -and $motionAtLoss -and $motionAfterRecovery -and $motionSmokePass -and $motionAfterPostFrame
        }
        if (-not $ok) { $failures += 1 }
        Write-Host ("{0}: {1} (exit={2} removal={3} callback={4} recovered={5} post_frame={6} motion_at_loss={7} motion_after_recovery={8} motion_after_post_frame={9} motion_smoke={10})" -f
            $case.Name, $(if ($ok) { 'PASS' } else { 'FAIL' }), $exitCode,
            $removalIssued, $callbackFired, $recovered, $postFrame,
            $motionAtLoss, $motionAfterRecovery, $motionAfterPostFrame, $motionSmokePass)
    }

    if ($failures -ne 0) { throw "$failures induced-device-removal case(s) failed; see $outputPath" }
    Write-Host "Induced D3D12 device removal: all $($cases.Count) cases passed. Logs: $outputPath"
} finally {
    Pop-Location
}
