param(
    [string]$Odin
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
New-Item -ItemType Directory -Force -Path 'out' | Out-Null
$AccessKit = Get-AlicornAccessKit
& $Odin build benchmarks/native_material @($AccessKit.CompilerArguments) -o:speed -out:out\alicorn_material_benchmark.exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# CPU renderer helpers are backend-neutral; no SDL host or native renderer is
# needed by this geometry-only benchmark.
& .\out\alicorn_material_benchmark.exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $Odin build benchmarks/native_material_budget @($AccessKit.CompilerArguments) -o:speed -out:out\alicorn_material_budget.exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& .\out\alicorn_material_budget.exe
exit $LASTEXITCODE
