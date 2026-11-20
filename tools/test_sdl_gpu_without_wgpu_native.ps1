param(
    [string]$Odin,
    [switch]$BuildOnly
)

# Prove that an SDL_GPU-only Alicorn consumer builds (and can smoke) when the
# pinned wgpu-native library is genuinely unreachable. This guards the
# build-time half of the renderer opt-in: alicorn:ui and native/sdl_gpu must not
# import the WebGPU host. The check temporarily moves Odin's vendor/wgpu/lib
# aside, runs a negative control against a WebGPU consumer, builds SDL_GPU
# consumers, and restores the library in finally.
#
# CI can adopt this unchanged; see
# docs/validation/webgpu-build-time-opt-in-windows-2026-11-19.md.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$OdinRoot = Split-Path -Parent $Odin
$WgpuLib = Join-Path $OdinRoot 'vendor\wgpu\lib'
$HiddenWgpuLib = Join-Path $OdinRoot 'vendor\wgpu\lib.alicorn-disabled'
$OutputRoot = Join-Path $RepoRoot 'out\without-wgpu'

if (-not (Test-Path -LiteralPath (Join-Path $OdinRoot 'vendor\wgpu\wgpu.odin') -PathType Leaf)) {
    throw "Odin vendor:wgpu package was not found under '$OdinRoot'."
}
if (Test-Path -LiteralPath $HiddenWgpuLib) {
    if (Test-Path -LiteralPath $WgpuLib) {
        throw "Both '$WgpuLib' and '$HiddenWgpuLib' exist; refusing to guess which is the real library."
    }
    Move-Item -LiteralPath $HiddenWgpuLib -Destination $WgpuLib
    Write-Host "Restored a wgpu-native library left hidden by an earlier interrupted run."
}

$AccessKit = Get-AlicornAccessKit
$CheckArguments = @($AccessKit.CompilerArguments | Where-Object { $_ -notlike '-extra-linker-flags*' })
$BuildArguments = @($AccessKit.CompilerArguments)

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

# Odin writes compiler warnings to stderr, which Windows PowerShell 5.1 turns
# into a terminating error under ErrorActionPreference=Stop. Run native tools
# under Continue and decide success from their exit code instead.
function Invoke-OdinChecked {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Odin @Arguments
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($code -ne 0) { throw "$Description failed (exit $code)." }
}

$HidLibrary = $false
Push-Location $RepoRoot
try {
    if (Test-Path -LiteralPath $WgpuLib) {
        Move-Item -LiteralPath $WgpuLib -Destination $HiddenWgpuLib
        $HidLibrary = $true
        Write-Host "Temporarily hid wgpu-native: $WgpuLib -> $HiddenWgpuLib"
    } else {
        Write-Host "wgpu-native is already absent from '$WgpuLib'; using the pristine environment."
    }

    # Negative control: a WebGPU consumer must fail here. Otherwise the proof
    # would not demonstrate that wgpu-native was actually unavailable. Odin
    # writes the compile error to stderr, which Windows PowerShell 5.1 turns
    # into a terminating error under ErrorActionPreference=Stop.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $control = & $Odin check examples\16_native_webgpu_ui "-collection:alicorn=$RepoRoot" @CheckArguments 2>&1 | Out-String
        $controlExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($controlExit -eq 0) {
        throw 'Negative control failed: a WebGPU consumer compiled without wgpu-native, so this environment does not prove SDL_GPU isolation.'
    }
    if ($control -notmatch 'WGPU Native library|wgpu_native') {
        throw "Negative control failed for an unexpected reason:`n$control"
    }
    Write-Host 'Negative control passed: the WebGPU consumer cannot find wgpu-native.'

    $HelloOutput = Join-Path $OutputRoot '01_hello.exe'
    Write-Host 'Building the SDL_GPU ui.run starter without wgpu-native'
    $HelloArguments = @(
        'build', 'examples\01_hello', "-collection:alicorn=$RepoRoot", "-out:$HelloOutput"
    ) + $BuildArguments
    Invoke-OdinChecked 'examples/01_hello build without wgpu-native' $HelloArguments
    Write-Host "Built $HelloOutput"

    $SmokeOutput = Join-Path $OutputRoot '03_async_list.exe'
    Write-Host 'Building the SDL_GPU async-list example without wgpu-native'
    $SmokeArguments = @(
        'build', 'examples\03_async_list', "-collection:alicorn=$RepoRoot", "-out:$SmokeOutput"
    ) + $BuildArguments
    Invoke-OdinChecked 'examples/03_async_list build without wgpu-native' $SmokeArguments

    $SDL3 = Join-Path $OdinRoot 'vendor\sdl3\SDL3.dll'
    if (-not (Test-Path -LiteralPath $SDL3 -PathType Leaf)) {
        throw "SDL3.dll not found at '$SDL3'. Use an Odin distribution that includes vendor/sdl3."
    }
    Copy-Item -LiteralPath $SDL3 -Destination (Join-Path $OutputRoot 'SDL3.dll') -Force

    if (-not $BuildOnly) {
        Write-Host 'Running the SDL_GPU async-list --smoke lifecycle without wgpu-native'
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $SmokeOutput '--smoke'
            $smokeExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($smokeExit -ne 0) { throw "examples/03_async_list --smoke failed without wgpu-native (exit $smokeExit)." }
    }

    Write-Host 'PASS: SDL_GPU consumers build and smoke without wgpu-native; WebGPU consumers still require it.'
} finally {
    Pop-Location
    if ($HidLibrary) {
        Move-Item -LiteralPath $HiddenWgpuLib -Destination $WgpuLib
        Write-Host "Restored wgpu-native: $WgpuLib"
    }
}
