param(
    [string]$Odin,
    [ValidateSet('direct3d12', 'vulkan')][string]$Driver = 'direct3d12',
    [string]$EmitScenes = '',
    [string]$WxReference = ''
)

# The build emits compiler warnings on stderr. Windows PowerShell 5.1 turns
# native stderr into an ErrorRecord, which a Stop preference would treat as a
# failure, so the exit code is checked explicitly instead.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $RepoRoot
try {
    New-Item -ItemType Directory -Force out/rectangles | Out-Null
    $AccessKit = Get-AlicornAccessKit
    $SDL3 = Join-Path (Split-Path -Parent $Odin) 'vendor\sdl3\SDL3.dll'
    if (-not (Test-Path -LiteralPath $SDL3 -PathType Leaf) -or (Get-Item -LiteralPath $SDL3).Length -lt 100000) {
        throw "Valid SDL3.dll not found at '$SDL3'."
    }
    Copy-Item -LiteralPath $SDL3 -Destination out\SDL3.dll -Force
    & $Odin build native\rectangle_validation_entry "-collection:alicorn=$RepoRoot" @($AccessKit.CompilerArguments) `
        -o:speed -out:out\alicorn_rectangle_validation.exe
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $arguments = @("--driver=$Driver")
    if ($EmitScenes) { $arguments += "--emit-wx-scenes=$EmitScenes" }
    if ($WxReference) { $arguments += "--wx-reference=$WxReference" }
    & .\out\alicorn_rectangle_validation.exe @arguments
    exit $LASTEXITCODE
}
finally { Pop-Location }
