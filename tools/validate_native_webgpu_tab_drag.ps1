param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('d3d12', 'vulkan', 'sdl-gpu')][string]$Backend = 'd3d12',
    [string]$OutputDir = 'out\tab-drag-capture',
    [int]$HoldMs = 5000
)

# Captures a mid-drag frame of the titlebar tab reorder fixture on either the
# hosted WebGPU host or the SDL_GPU reference host. The fixture scripts the drag
# itself (--tab-drag-hold-ms keeps it open and nudges the pointer one pixel per
# frame) so the pointer path is deterministic; this script only focuses the
# window and presses F12 while the lift is alive. The resulting bundle's
# inspector.txt records the drag session and every preview paint command, so the
# two backends can be compared command for command.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TabDragCapture {
    private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion data; }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    struct InputUnion {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const ushort VK_F12 = 0x7B;
    const uint WM_CLOSE = 0x0010;

    public static string ClassOf(IntPtr hwnd) {
        var sb = new StringBuilder(256); GetClassName(hwnd, sb, 256); return sb.ToString();
    }

    public static IntPtr FirstSdlWindow(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid != processId || ClassOf(hwnd) != "SDL_app" || !IsWindowVisible(hwnd)) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Focus(IntPtr hwnd) {
        ShowWindow(hwnd, 9);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        return GetForegroundWindow() == hwnd;
    }

    static bool SendKey(ushort key, bool up) {
        var input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.data.ki.wVk = key;
        input.data.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        return SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool PressF12() {
        if (!SendKey(VK_F12, false)) return false;
        System.Threading.Thread.Sleep(40);
        return SendKey(VK_F12, true);
    }

    public static void CloseWindow(IntPtr hwnd) { PostMessage(hwnd, WM_CLOSE, UIntPtr.Zero, IntPtr.Zero); }
}
'@

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$captureDir = Join-Path $OutputDir "$Backend-captures"
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
$logPath = Join-Path $OutputDir "$Backend-tab-drag.log"

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $executablePath
$startInfo.Arguments = "--tab-drag-hold-ms=$HoldMs --backend=$Backend --diagnostics --capture-after=1 --capture-dir=$captureDir"
$startInfo.WorkingDirectory = Split-Path -Parent $executablePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$window = [IntPtr]::Zero
$outputTask = $null
$errorTask = $null

function Wait-Until([scriptblock]$predicate, [int]$timeoutMs = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        if (& $predicate) { return $true }
        Start-Sleep -Milliseconds 30
    } while ([DateTime]::UtcNow -lt $deadline)
    return (& $predicate)
}

$captured = $false
try {
    if (-not $process.Start()) { throw 'process did not start' }
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    Write-Output "backend=$Backend executable=$executablePath pid=$($process.Id)"
    $found = Wait-Until { [TabDragCapture]::FirstSdlWindow($process.Id) -ne [IntPtr]::Zero } 20000
    if (-not $found) { throw 'main SDL window did not appear' }
    $window = [TabDragCapture]::FirstSdlWindow($process.Id)
    $focused = Wait-Until { [void][TabDragCapture]::Focus($window); [TabDragCapture]::GetForegroundWindow() -eq $window } 8000
    Write-Output "window=$window focused=$focused"
    # The scripted lift starts within the first few presented frames and stays
    # alive for HoldMs. --capture-after=1 writes the mid-drag bundle; F12 adds a
    # second one when this session owns the foreground window.
    Start-Sleep -Milliseconds 900
    $captured = [TabDragCapture]::PressF12()
    $exited = $process.WaitForExit(20000)
    if (-not $exited) { $process.Kill(); $process.WaitForExit(5000) }
} finally {
    if ($window -ne [IntPtr]::Zero -and [TabDragCapture]::IsWindow($window)) {
        [TabDragCapture]::CloseWindow($window)
        Start-Sleep -Milliseconds 300
    }
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) }
    $stdout = if ($outputTask) { $outputTask.GetAwaiter().GetResult() } else { '' }
    $stderr = if ($errorTask) { $errorTask.GetAwaiter().GetResult() } else { '' }
    Set-Content -LiteralPath $logPath -Value ($stdout + $stderr)
}

$smokeLine = Select-String -Path $logPath -Pattern 'tab_drag_smoke' | Select-Object -First 1
if ($smokeLine) { Write-Output $smokeLine.Line } else { Write-Output 'tab_drag_smoke line missing' }

$bundles = @(Get-ChildItem -LiteralPath $captureDir -Directory | Sort-Object Name)
Write-Output "capture_f12=$captured bundles=$($bundles.Count) dir=$captureDir"
$dragBundles = @($bundles | Where-Object {
    $inspector = Join-Path $_.FullName 'inspector.txt'
    (Test-Path -LiteralPath $inspector) -and
        (Select-String -Path $inspector -Pattern 'drag: phase=Dragging' -Quiet)
})
if ($dragBundles.Count -eq 0) {
    Write-Output 'tab_drag_capture FAIL no bundle contains an active drag frame'
    exit 1
}
$bundle = $dragBundles[$dragBundles.Count - 1]
Write-Output "drag_bundle=$($bundle.FullName)"
$inspector = Join-Path $bundle.FullName 'inspector.txt'
$dragLines = Select-String -Path $inspector -Pattern '^drag: |^  preview\[' | ForEach-Object { $_.Line }
$dragLines | Set-Content -LiteralPath (Join-Path $OutputDir "$Backend-drag-preview.txt")
$previewCount = @($dragLines | Where-Object { $_ -match '^  preview\[' }).Count
if ($previewCount -eq 0) {
    Write-Output 'tab_drag_capture FAIL the drag frame has no preview paint commands'
    exit 1
}
Write-Output "tab_drag_capture PASS preview_commands=$previewCount"
exit 0
