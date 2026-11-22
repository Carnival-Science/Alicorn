param(
    [string]$Odin,
    [ValidateSet('d3d12', 'vulkan', 'd3d11')]
    [string]$Backend = 'd3d12',
    [string]$Screenshot,
    [int]$HoldMs = 0,
    [string]$Log
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$OutDir = Join-Path $RepoRoot 'out'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Fixture = Join-Path $OutDir 'plugin_host_fixture.exe'
if (-not $Log) { $Log = Join-Path $OutDir "plugin_host_self_test_$Backend.log" }
if ($Screenshot -and -not [IO.Path]::IsPathRooted($Screenshot)) {
    $Screenshot = Join-Path $RepoRoot $Screenshot
}
if ($Screenshot) {
    $screenshotDirectory = Split-Path -Parent $Screenshot
    if ($screenshotDirectory) { New-Item -ItemType Directory -Force -Path $screenshotDirectory | Out-Null }
}

& $Odin build (Join-Path $RepoRoot 'tests\fixtures\plugin_host') "-collection:alicorn=$RepoRoot" "-out:$Fixture"
if ($LASTEXITCODE -ne 0) { throw 'plugin_host fixture build failed' }

$arguments = @('--self-test', "--backend=$Backend")
if ($HoldMs -gt 0) { $arguments += "--hold-ms=$HoldMs" }

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $Fixture
$startInfo.Arguments = ($arguments -join ' ')
$startInfo.RedirectStandardOutput = $true
$startInfo.UseShellExecute = $false
$process = [System.Diagnostics.Process]::Start($startInfo)
$lines = New-Object System.Collections.Generic.List[string]
$captured = $false
$captureError = $null
if ($Screenshot) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AlicornPluginHostRect {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
"@
}
while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
    $lines.Add($line)
    Write-Host $line
    if ($Screenshot -and -not $captured -and $line -like 'SCREENSHOT_READY*') {
        if ($line -match 'client_left=(-?\d+) client_top=(-?\d+) client_right=(-?\d+) client_bottom=(-?\d+)') {
            $left = [int]$matches[1]
            $top = [int]$matches[2]
            $right = [int]$matches[3]
            $bottom = [int]$matches[4]
            $width = $right - $left
            $height = $bottom - $top
            Start-Sleep -Milliseconds 450
            try {
                $bitmap = New-Object System.Drawing.Bitmap($width, $height)
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                $graphics.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
                $bitmap.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
                $graphics.Dispose()
                $bitmap.Dispose()
                $captured = $true
                Write-Host "screenshot=$Screenshot"
            } catch {
                $captureError = $_.Exception.Message
            }
        }
    }
}
$process.WaitForExit()
$lines | Set-Content -LiteralPath $Log
if ($captureError) { throw "screenshot capture failed: $captureError" }
if ($Screenshot -and -not $captured) { throw 'fixture did not emit a SCREENSHOT_READY marker' }
if ($process.ExitCode -ne 0) { throw "plugin_host fixture failed with exit $($process.ExitCode); see $Log" }
Write-Host "plugin_host fixture passed; log=$Log"
