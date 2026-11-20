param(
    [string]$Odin,
    [ValidateSet('direct3d12', 'vulkan')][string]$Driver = 'direct3d12'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $RepoRoot
try {
    New-Item -ItemType Directory -Force out/point-markers | Out-Null
    $AccessKit = Get-AlicornAccessKit
    $SDL3 = Join-Path (Split-Path -Parent $Odin) 'vendor\sdl3\SDL3.dll'
    if (-not (Test-Path -LiteralPath $SDL3 -PathType Leaf) -or (Get-Item -LiteralPath $SDL3).Length -lt 100000) {
        throw "Valid SDL3.dll not found at '$SDL3'."
    }
    Copy-Item -LiteralPath $SDL3 -Destination out\SDL3.dll -Force
    # native/sdl_gpu now imports alicorn:host/sdl3; the collection is required
    # even though this fixture has no WebGPU dependency.
    & $Odin build native\point_marker_validation_entry "-collection:alicorn=$RepoRoot" @($AccessKit.CompilerArguments) `
        -o:speed -out:out\alicorn_point_marker_validation.exe
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & .\out\alicorn_point_marker_validation.exe "--driver=$Driver"
    exit $LASTEXITCODE
}
finally { Pop-Location }
