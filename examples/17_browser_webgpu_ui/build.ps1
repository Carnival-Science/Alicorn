param([string]$Odin='C:\odin\odin.exe')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root '..\..\tools\common.ps1')
$Odin=Resolve-AlicornOdin -Requested $Odin
$odinRoot=(& $Odin root | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $odinRoot -or -not (Test-Path -LiteralPath $odinRoot -PathType Container)) {
	throw "Could not resolve Odin SDK root from '$Odin'."
}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'out\web') | Out-Null
Push-Location $root
try {
	& $Odin build . -collection:alicorn=../.. -target:js_wasm32 -o:size -out:out\web\app.wasm -extra-linker-flags:--export-table
	if ($LASTEXITCODE -ne 0) { throw "Browser WebGPU UI build failed: $LASTEXITCODE" }
	Copy-Item web\index.html out\web\index.html -Force
	Copy-Item (Join-Path $odinRoot 'core\sys\wasm\js\odin.js') out\web\odin.js -Force
	Copy-Item (Join-Path $odinRoot 'vendor\wgpu\wgpu.js') out\web\wgpu.js -Force
	Copy-Item (Join-Path $root '..\..\host\web\demand_scheduler.js') out\web\alicorn_demand_scheduler.js -Force
	Copy-Item (Join-Path $root '..\..\host\web\accessibility_dom.js') out\web\alicorn_accessibility_dom.js -Force
	Copy-Item (Join-Path $root '..\..\host\web\webgpu_ui_host.js') out\web\alicorn_webgpu_host.js -Force
	Write-Host "Build complete: $root\out\web\app.wasm"
	Write-Host "Serve $root\out\web and open index.html in a WebGPU-capable browser."
} finally { Pop-Location }
