param([string]$Odin='C:\odin\odin.exe')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root '..\..\tools\common.ps1')
$Odin = Resolve-AlicornOdin -Requested $Odin
$odinRoot = (& $Odin root | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $odinRoot -or -not (Test-Path -LiteralPath $odinRoot -PathType Container)) {
	throw "Could not resolve Odin SDK root from '$Odin'."
}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'out'),(Join-Path $root 'web') | Out-Null
Push-Location $root
try {
	& $Odin build . -out:out\webgpu_feasibility.exe
	if ($LASTEXITCODE -ne 0) { throw "Native fixture build failed: $LASTEXITCODE" }
	& $Odin build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -out:out\webgpu_feasibility_smoke.exe
	if ($LASTEXITCODE -ne 0) { throw "Native smoke fixture build failed: $LASTEXITCODE" }
	& $Odin build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_COMPOSITOR_RECREATION=true -out:out\webgpu_feasibility_recreate_smoke.exe
	if ($LASTEXITCODE -ne 0) { throw "Native compositor-recreation smoke fixture build failed: $LASTEXITCODE" }
	& $Odin build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_WEBGPU_PRESENTER=true -out:out\webgpu_feasibility_presenter_smoke.exe
	if ($LASTEXITCODE -ne 0) { throw "Native host-owned presenter smoke fixture build failed: $LASTEXITCODE" }
	& $Odin build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_SURFACE_PRESENTER=true -out:out\webgpu_feasibility_surface_presenter.exe
	if ($LASTEXITCODE -ne 0) { throw "Native SDL surface presenter fixture build failed: $LASTEXITCODE" }
	& $Odin build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_RESIZE=true -out:out\webgpu_feasibility_resize_smoke.exe
	if ($LASTEXITCODE -ne 0) { throw "Native resize smoke fixture build failed: $LASTEXITCODE" }
	Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $root 'out\SDL3.dll') -Force
	$wgpuDll=Join-Path $odinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll'
	if (Test-Path -LiteralPath $wgpuDll) { Copy-Item $wgpuDll (Join-Path $root 'out\wgpu_native.dll') -Force }
	& $Odin build . -collection:alicorn=../.. -target:js_wasm32 -o:size -define:FEASIBILITY_TEST_WEB_CANVAS_PRESENTER=true -out:web\feasibility.wasm -extra-linker-flags:--export-table
	if ($LASTEXITCODE -ne 0) { throw "Browser fixture build failed: $LASTEXITCODE" }
	$odinRoot=& $Odin root
	Copy-Item (Join-Path $odinRoot 'core\sys\wasm\js\odin.js') (Join-Path $root 'web\odin.js') -Force
	Copy-Item (Join-Path $odinRoot 'vendor\wgpu\wgpu.js') (Join-Path $root 'web\wgpu.js') -Force
	Copy-Item (Join-Path $root '..\..\host\web\demand_scheduler.js') (Join-Path $root 'web\alicorn_demand_scheduler.js') -Force
	Write-Host "Native interactive: $root\out\webgpu_feasibility.exe"
	Write-Host "Native readback smoke: $root\out\webgpu_feasibility_smoke.exe"
	Write-Host "Native compositor recreation smoke: $root\out\webgpu_feasibility_recreate_smoke.exe"
	Write-Host "Native host-owned presenter smoke: $root\out\webgpu_feasibility_presenter_smoke.exe"
	Write-Host "Native SDL surface presenter smoke: $root\out\webgpu_feasibility_surface_presenter.exe"
	Write-Host "Native resize smoke: $root\out\webgpu_feasibility_resize_smoke.exe"
	Write-Host "Browser shared-renderer fixture: serve $root\web on localhost and open /index.html"
} finally { Pop-Location }
