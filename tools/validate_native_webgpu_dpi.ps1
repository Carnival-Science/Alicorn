param(
    [string]$Odin,
    [ValidateSet('d3d12', 'vulkan', '')]
    [string]$Backend = ''
)

# Hosted WebGPU high-DPI transition acceptance.
#
# Builds tests/fixtures/dpi_transition and runs it on a real GPU. The fixture
# posts synthetic WM_DPICHANGED/WM_DISPLAYCHANGE messages to the hosted window
# and adopts the metric shape a per-monitor transition produces at scales
# 1.0/1.25/1.5/1.75, capturing PPMs to verify text re-rasterization, logical
# bounds, hit testing, and per-window scale independence.
#
# This covers everything short of physically dragging the window between two
# monitors with different Windows display scales; see
# docs/webgpu-migration.md Stage C slice 6 for the founder's hands-on checklist.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$OutDir = Join-Path $RepoRoot 'out'
$FixtureDir = Join-Path $OutDir 'fixtures'
$LogPath = Join-Path $OutDir 'dpi-transition.log'
New-Item -ItemType Directory -Force -Path $FixtureDir | Out-Null

$AccessKit = Get-AlicornAccessKit
$FixtureArguments = @('-define:WGPU_SHARED=true')
$Output = Join-Path $FixtureDir 'dpi_transition.exe'

Push-Location $RepoRoot
try {
    Write-Host 'Building the hosted DPI transition fixture'
    $BuildPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build 'tests/fixtures/dpi_transition' "-collection:alicorn=$RepoRoot" `
        @($AccessKit.CompilerArguments) @FixtureArguments "-out:$Output"
    $BuildExit = $LASTEXITCODE
    $ErrorActionPreference = $BuildPreference
    if ($BuildExit -ne 0) { throw "DPI fixture build failed (exit $BuildExit)" }

    $OdinRoot = Split-Path -Parent $Odin
    $SDL3Dll = Join-Path $OdinRoot 'vendor\sdl3\SDL3.dll'
    $WgpuDll = Join-Path $OdinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll'
    foreach ($Dll in @($SDL3Dll, $WgpuDll)) {
        if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) { throw "Missing runtime: $Dll" }
        if ((Get-Item -LiteralPath $Dll).Length -lt 100000) { throw "Invalid runtime (LFS pointer?): $Dll" }
    }
    Copy-Item -LiteralPath $SDL3Dll -Destination $FixtureDir -Force
    Copy-Item -LiteralPath $WgpuDll -Destination $FixtureDir -Force

    $Arguments = @()
    if ($Backend -ne '') { $Arguments += "--backend=$Backend" }
    Write-Host "Running $Output $($Arguments -join ' ')"
    $OutputLines = & $Output @Arguments 2>&1 | Tee-Object -FilePath $LogPath
    $ExitCode = $LASTEXITCODE
    $OutputLines | ForEach-Object { Write-Host $_ }
    if ($ExitCode -ne 0) { throw "DPI transition fixture failed (exit $ExitCode). Log: $LogPath" }
    $Verdict = $OutputLines | Where-Object { $_ -match 'dpi_transition (PASS|FAIL)' }
    if (-not ($Verdict -match 'PASS')) { throw "DPI transition fixture did not report PASS. Log: $LogPath" }

    $Captures = Get-ChildItem -LiteralPath $OutDir -Filter 'dpi-transition-*.ppm' |
        Sort-Object Name
    if ($Captures.Count -lt 5) { throw "Expected at least five scale captures in $OutDir" }
    foreach ($Capture in $Captures) {
        if ($Capture.Length -lt 4096) { throw "Capture looks empty: $($Capture.FullName)" }
    }
    Write-Host ("Captures: " + (($Captures | ForEach-Object { $_.Name }) -join ', '))
    Write-Host "DPI transition validation PASS"
}
finally {
    Pop-Location
}
