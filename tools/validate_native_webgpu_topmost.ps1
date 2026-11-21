param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('d3d12', 'vulkan', 'sdl-gpu')][string]$Backend = 'd3d12',
    [string]$OutputDir = 'out\topmost-reentry',
    [int]$Entries = 4,
    [switch]$KeepOpen
)

# Physical half of the #211 floating-window regression, recorded by bae58e9 and
# ported to the hosted chrome in host/sdl3/window_frame.
#
# examples/16_native_webgpu_ui --topmost-child-smoke keeps an ALWAYS_ON_TOP
# child window with integrated chrome open. SDL promotes that window on every
# mouse entry with a standard-frame-adjusted position; on a custom full-client
# WM_NCCALCSIZE contract the adjustment subtracts the caption/border inset and
# moves the window up and to the left. This script hovers the real cursor over
# the child repeatedly and asserts the Win32 rectangle never changes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TopmostReentryValidation {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const uint WM_CLOSE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    public static List<IntPtr> Find(uint processId, string fragment) {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows((hwnd, data) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != processId || !IsWindowVisible(hwnd)) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowTextW(hwnd, title, title.Capacity);
            if (title.ToString().IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0) found.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IsTopmost(IntPtr hwnd) {
        return (GetWindowLong(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    }
}
'@

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$ExecutablePath = (Resolve-Path -LiteralPath $Executable).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath = Join-Path $OutputDir "$Backend-topmost-reentry-$Stamp.log"
$Log = [System.Collections.Generic.List[string]]::new()
function Write-Log([string]$Line) {
    $Log.Add($Line) | Out-Null
    Write-Host $Line
}

$Checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $Checks.Add([pscustomobject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail }) | Out-Null
}

$Arguments = "--topmost-child-smoke --backend=$Backend"
$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $ExecutablePath
$StartInfo.WorkingDirectory = Split-Path -Parent $ExecutablePath
$StartInfo.Arguments = $Arguments
$StartInfo.UseShellExecute = $false
$StartInfo.RedirectStandardOutput = $true
$StartInfo.RedirectStandardError = $true
$Process = [System.Diagnostics.Process]::Start($StartInfo)
$StdOut = $Process.StandardOutput.ReadToEndAsync()
$StdErr = $Process.StandardError.ReadToEndAsync()

$Child = [IntPtr]::Zero
$Primary = [IntPtr]::Zero
$OriginalCursor = New-Object TopmostReentryValidation+POINT
$null = [TopmostReentryValidation]::GetCursorPos([ref]$OriginalCursor)

try {
    Write-Log "backend=$Backend executable=$ExecutablePath pid=$($Process.Id)"
    $Deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $Deadline) {
        $children = [TopmostReentryValidation]::Find([uint32]$Process.Id, 'Alicorn topmost child probe')
        $primaries = [TopmostReentryValidation]::Find([uint32]$Process.Id, 'Native Renderer Probe')
        if ($children.Count -gt 0 -and $primaries.Count -gt 0) {
            $Child = $children[0]
            $Primary = $primaries[0]
            break
        }
        if ($Process.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    Add-Check 'child-window-open' ($Child -ne [IntPtr]::Zero) "child=$Child primary=$Primary"
    Add-Check 'primary-window-open' ($Primary -ne [IntPtr]::Zero) "primary=$Primary"
    if ($Child -eq [IntPtr]::Zero) { throw 'the topmost child window never appeared' }
    Add-Check 'child-is-topmost' ([TopmostReentryValidation]::IsTopmost($Child)) 'WS_EX_TOPMOST must be set'
    $null = [TopmostReentryValidation]::SetForegroundWindow($Primary)
    Start-Sleep -Milliseconds 300

    $Baseline = New-Object TopmostReentryValidation+RECT
    $null = [TopmostReentryValidation]::GetWindowRect($Child, [ref]$Baseline)
    Write-Log ("baseline rect={0},{1},{2},{3}" -f $Baseline.Left, $Baseline.Top, $Baseline.Right, $Baseline.Bottom)
    $OffsetX = [int](($Baseline.Right - $Baseline.Left) / 2)
    $OffsetY = [int](($Baseline.Bottom - $Baseline.Top) / 2)

    # Hover outside both windows, then re-enter the child. SDL promotes the
    # always-on-top window on the first WM_MOUSEMOVE of the entry.
    for ($i = 0; $i -lt $Entries; $i++) {
        $null = [TopmostReentryValidation]::SetCursorPos(8, 8)
        Start-Sleep -Milliseconds 200
        $null = [TopmostReentryValidation]::SetCursorPos($Baseline.Left + $OffsetX, $Baseline.Top + $OffsetY)
        Start-Sleep -Milliseconds 350
        $After = New-Object TopmostReentryValidation+RECT
        $null = [TopmostReentryValidation]::GetWindowRect($Child, [ref]$After)
        $Moved = ($After.Left -ne $Baseline.Left) -or ($After.Top -ne $Baseline.Top) -or
                 ($After.Right -ne $Baseline.Right) -or ($After.Bottom -ne $Baseline.Bottom)
        Write-Log ("entry {0} rect={1},{2},{3},{4} delta=({5},{6})" -f $i,
            $After.Left, $After.Top, $After.Right, $After.Bottom,
            ($After.Left - $Baseline.Left), ($After.Top - $Baseline.Top))
        Add-Check "entry-$i-position-preserved" (-not $Moved) "expected $($Baseline.Left),$($Baseline.Top)"
        if ($Moved) { break }
    }
    if (-not $KeepOpen) {
        $null = [TopmostReentryValidation]::SendMessage($Child, [TopmostReentryValidation]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
        $null = [TopmostReentryValidation]::SendMessage($Child, [TopmostReentryValidation]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 300
        $null = [TopmostReentryValidation]::SendMessage($Primary, [TopmostReentryValidation]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        if (-not $Process.WaitForExit(15000)) { throw 'the application did not exit after WM_CLOSE' }
        Add-Check 'clean-exit' ($Process.ExitCode -eq 0) "exit=$($Process.ExitCode)"
    }
}
catch {
    Add-Check 'harness' $false $_.Exception.Message
}
finally {
    $null = [TopmostReentryValidation]::SetCursorPos($OriginalCursor.X, $OriginalCursor.Y)
    if (-not $Process.HasExited) { $Process.Kill() }
    $StdOut.Wait(2000) | Out-Null
    $StdErr.Wait(2000) | Out-Null
    $Log.Add('--- stdout ---') | Out-Null
    $Log.Add($StdOut.Result) | Out-Null
    $Log.Add('--- stderr ---') | Out-Null
    $Log.Add($StdErr.Result) | Out-Null
    Set-Content -LiteralPath $LogPath -Value $Log -Encoding UTF8
}

$Failures = @($Checks | Where-Object { $_.Status -eq 'FAIL' }).Count
$Passes = @($Checks | Where-Object { $_.Status -eq 'PASS' }).Count
foreach ($check in $Checks) {
    Write-Host ("{0} {1} {2}" -f $check.Status, $check.Name, $check.Detail)
}
$Summary = "backend=$Backend failures=$Failures pass=$Passes log=$LogPath"
if ($Failures -gt 0) {
    Write-Host "topmost_reentry FAIL $Summary"
    exit 1
}
Write-Host "topmost_reentry PASS $Summary"
exit 0
