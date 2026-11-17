param([string]$Odin)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$ExampleRoot = Join-Path $RepoRoot 'examples'
$OutputRoot = Join-Path $RepoRoot 'out\examples'
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$AccessKit = Get-AlicornAccessKit

Push-Location $RepoRoot
try {
	$Examples = Get-ChildItem -LiteralPath $ExampleRoot -Directory |
		Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'main.odin') } |
		Sort-Object -Property Name
	foreach ($Example in $Examples) {
		$Output = Join-Path $OutputRoot ($Example.Name + '.exe')
		Write-Host "Building example $($Example.Name)"
		$ExampleArguments = @()
		if ($Example.Name -eq '16_native_webgpu_ui') {
			# AccessKit's Rust static library and Odin's static wgpu-native both
			# define rust_eh_personality. Use Odin's bundled shared WGPU library.
			$ExampleArguments += '-define:WGPU_SHARED=true'
		}
		& $Odin build (Join-Path 'examples' $Example.Name) "-collection:alicorn=$RepoRoot" @($AccessKit.CompilerArguments) @ExampleArguments "-out:$Output"
		if ($LASTEXITCODE -ne 0) { throw "Example build failed: $($Example.Name) (exit $LASTEXITCODE)" }
		if ($Example.Name -eq '16_native_webgpu_ui') {
			$OdinRoot = Split-Path -Parent $Odin
			$SDL3Dll = Join-Path $OdinRoot 'vendor\sdl3\SDL3.dll'
			$WgpuDll = Join-Path $OdinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll'
			if (-not (Test-Path -LiteralPath $SDL3Dll -PathType Leaf) -or (Get-Item -LiteralPath $SDL3Dll).Length -lt 100000) {
				throw "Valid SDL3.dll not found at '$SDL3Dll'."
			}
			if (-not (Test-Path -LiteralPath $WgpuDll -PathType Leaf) -or (Get-Item -LiteralPath $WgpuDll).Length -lt 100000) {
				throw "Shared wgpu-native DLL not found at '$WgpuDll'."
			}
			Copy-Item -LiteralPath $SDL3Dll -Destination $OutputRoot -Force
			Copy-Item -LiteralPath $WgpuDll -Destination $OutputRoot -Force
		}
	}
}
finally {
	Pop-Location
}
