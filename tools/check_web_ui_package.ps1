param([string]$Odin)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$Output = Join-Path $RepoRoot 'out\web_ui_package.wasm'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null

& $Odin build (Join-Path $RepoRoot 'tests\fixtures\web_ui_package') `
	"-collection:alicorn=$RepoRoot" -target:js_wasm32 "-out:$Output"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "WASM package-boundary build passed: $Output"
