param([string]$Odin='C:\odin\odin.exe')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if (-not (Test-Path -LiteralPath $Odin -PathType Leaf)) { throw "Odin not found: $Odin" }
New-Item -ItemType Directory -Force -Path (Join-Path $root 'out'),(Join-Path $root 'web') | Out-Null
Push-Location $root
try {
	& $Odin build . -out:out\webgpu_feasibility.exe
	if ($LASTEXITCODE -ne 0) { throw "Native fixture build failed: $LASTEXITCODE" }
	$odinRoot=Split-Path -Parent $Odin
	Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $root 'out\SDL3.dll') -Force
	$wgpuDll=Join-Path $odinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll'
	if (Test-Path -LiteralPath $wgpuDll) { Copy-Item $wgpuDll (Join-Path $root 'out\wgpu_native.dll') -Force }
	& $Odin build . -target:js_wasm32 -o:size -out:web\feasibility.wasm -extra-linker-flags:--export-table
	if ($LASTEXITCODE -ne 0) { throw "Browser fixture build failed: $LASTEXITCODE" }
	$odinRoot=& $Odin root
	Copy-Item (Join-Path $odinRoot 'core\sys\wasm\js\odin.js') (Join-Path $root 'web\odin.js') -Force
	Copy-Item (Join-Path $odinRoot 'vendor\wgpu\wgpu.js') (Join-Path $root 'web\wgpu.js') -Force
	Write-Host "Native: $root\out\webgpu_feasibility.exe"
	Write-Host "Browser: serve $root\web on localhost and open /index.html"
} finally { Pop-Location }
