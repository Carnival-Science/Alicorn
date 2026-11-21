# Builds and runs the wxWidgets reference capture used by the issue #200 and
# #201 validation records. Requires an MSYS2 UCRT64 installation with
# mingw-w64-ucrt-x86_64-wxwidgets3.2:
#
#   pacman -S mingw-w64-ucrt-x86_64-wxwidgets3.2
#
# The tool consumes `.scene` files written by the Alicorn validation
# executables and writes `.rgb`/`.meta` reference captures next to them.
param(
    [Parameter(Mandatory = $true)][string]$Scenes,
    [string]$OutDir = '',
    [string]$Msys2Root = 'C:\msys64',
    [int]$Repeat = 64,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$Bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
$WxConfig = Join-Path $Msys2Root 'ucrt64\bin\wx-config'
if (-not (Test-Path -LiteralPath $Bash -PathType Leaf)) { throw "MSYS2 bash not found at '$Bash'." }
if (-not (Test-Path -LiteralPath $WxConfig -PathType Leaf)) {
    throw "wx-config not found at '$WxConfig'. Install mingw-w64-ucrt-x86_64-wxwidgets3.2 in $Msys2Root."
}
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'out\wx-reference' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The MSYS2 tools address the same tree as POSIX paths.
function ConvertTo-MsysPath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Msys2Root)
    if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return '/c' + ($resolved.Substring(2) -replace '\\', '/')
    }
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    return "/$drive" + ($resolved.Substring(2) -replace '\\', '/')
}

$Source = ConvertTo-MsysPath (Join-Path $PSScriptRoot 'wx_reference\main.cpp')
$Output = ConvertTo-MsysPath (Join-Path $OutDir 'wx_reference.exe')
$Script = "export PATH=/ucrt64/bin:`$PATH; cd / && g++ -O2 -std=c++17 '$Source' `$(wx-config --cxxflags --libs) -static-libgcc -static-libstdc++ -o '$Output'"
& $Bash -lc $Script
if ($LASTEXITCODE -ne 0) { throw 'wx_reference build failed.' }
Write-Output "wx-reference: built $(Join-Path $OutDir 'wx_reference.exe')"

if ($BuildOnly) { exit 0 }
if (-not (Test-Path -LiteralPath $Scenes -PathType Container)) { throw "Scene directory not found: '$Scenes'" }

$SceneFiles = Get-ChildItem -LiteralPath $Scenes -Filter '*.scene' | Sort-Object Name
if (-not $SceneFiles) { throw "No .scene files in '$Scenes'." }
$CostLog = Join-Path $OutDir 'wx-cost.txt'
if (Test-Path -LiteralPath $CostLog) { Remove-Item -LiteralPath $CostLog }
$Failures = 0
foreach ($Scene in $SceneFiles) {
    $prefix = Join-Path $OutDir $Scene.BaseName
    $args = "--scene='$(ConvertTo-MsysPath $Scene.FullName)' --out='$(ConvertTo-MsysPath $prefix)' --repeat=$Repeat"
    $lines = & $Bash -lc "export PATH=/ucrt64/bin:`$PATH; cd / && '$(ConvertTo-MsysPath (Join-Path $OutDir 'wx_reference.exe'))' $args"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "wx-reference failed for $($Scene.Name)"
        $Failures += 1
        continue
    }
    $lines | Where-Object { $_ -match '^wx_reference_cost ' } | Add-Content -LiteralPath $CostLog
}
Write-Output "wx-reference: $($SceneFiles.Count - $Failures)/$($SceneFiles.Count) scenes captured in $OutDir"
if ($Failures -ne 0) { exit 1 }
