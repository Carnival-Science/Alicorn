param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('d3d12', 'vulkan', 'sdl-gpu')][string]$Backend = 'd3d12',
    [string]$OutputDir = 'out\interactive-webgpu-chrome',
    [switch]$NoScreenshots
)

# Drives examples/16_native_webgpu_ui --titlebar-smoke --interactive through
# real Windows window interactions: physical drag-to-move on the Window_Drag
# band, double-click maximize/restore, edge resize, and native caption button
# clicks. The hit-test checks read the window's own WM_NCHITTEST result, so the
# chrome-region mapping is exercised, not assumed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class NativeWebGpuChromeValidation {
    private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out RECT value, uint size);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

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

    // The native INPUT union is sized for MOUSEINPUT (32 bytes on x64).
    [StructLayout(LayoutKind.Explicit, Size = 32)]
    struct InputUnion {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;

    // WM_NCHITTEST
    const uint WM_NCHITTEST = 0x0084;
    // WM_SETTINGCHANGE, WM_THEMECHANGED, WM_SYSCOLORCHANGE
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint WM_THEMECHANGED = 0x031D;
    public const uint WM_SYSCOLORCHANGE = 0x0015;
    // DWMWA_CAPTION_BUTTON_BOUNDS
    const uint DWMWA_CAPTION_BUTTON_BOUNDS = 5;

    public static string ClassOf(IntPtr hwnd) {
        var sb = new StringBuilder(256); GetClassName(hwnd, sb, 256); return sb.ToString();
    }

    public static string TitleOf(IntPtr hwnd) {
        var sb = new StringBuilder(512); GetWindowText(hwnd, sb, 512); return sb.ToString();
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

    public static int[] Rect(IntPtr hwnd) {
        RECT r; if (!GetWindowRect(hwnd, out r)) return new int[] { 0, 0, 0, 0 };
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static int HitTest(IntPtr hwnd, int screenX, int screenY) {
        ulong packed = ((ulong)(uint)(screenY & 0xffff) << 16) | (ulong)(uint)(screenX & 0xffff);
        return (int)SendMessage(hwnd, WM_NCHITTEST, UIntPtr.Zero, new IntPtr((long)packed));
    }

    public static void BringToFront(IntPtr hwnd) {
        SetForegroundWindow(hwnd);
    }

    public static bool Focus(IntPtr hwnd) {
        ShowWindow(hwnd, 9);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        return GetForegroundWindow() == hwnd;
    }

    public static void MoveCursor(int x, int y) { SetCursorPos(x, y); }

    public static bool LeftDown() { return SendMouse(MOUSEEVENTF_LEFTDOWN); }

    public static bool LeftUp() { return SendMouse(MOUSEEVENTF_LEFTUP); }

    static bool SendMouse(uint flags) {
        var input = new INPUT();
        input.type = INPUT_MOUSE;
        input.data.mi.dwFlags = flags;
        return SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Click(int x, int y) {
        MoveCursor(x, y);
        System.Threading.Thread.Sleep(30);
        if (!LeftDown()) return false;
        System.Threading.Thread.Sleep(30);
        return LeftUp();
    }

    public static bool DoubleClick(int x, int y) {
        if (!Click(x, y)) return false;
        System.Threading.Thread.Sleep(90);
        return Click(x, y);
    }

    public static bool Drag(int fromX, int fromY, int toX, int toY, int steps) {
        MoveCursor(fromX, fromY);
        System.Threading.Thread.Sleep(60);
        if (!LeftDown()) return false;
        System.Threading.Thread.Sleep(60);
        for (int i = 1; i <= steps; i++) {
            int x = fromX + (toX - fromX) * i / steps;
            int y = fromY + (toY - fromY) * i / steps;
            MoveCursor(x, y);
            System.Threading.Thread.Sleep(25);
        }
        System.Threading.Thread.Sleep(60);
        return LeftUp();
    }

    public static int[] CaptionButtonBounds(IntPtr hwnd) {
        RECT r;
        if (DwmGetWindowAttribute(hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, out r, (uint)Marshal.SizeOf(typeof(RECT))) < 0) {
            return new int[] { 0, 0, 0, 0 };
        }
        // DWMWA_CAPTION_BUTTON_BOUNDS is client-area relative; convert to screen
        // coordinates so the same values can drive physical clicks.
        var origin = new POINT();
        if (!ClientToScreen(hwnd, ref origin)) { return new int[] { 0, 0, 0, 0 }; }
        return new int[] { origin.X + r.Left, origin.Y + r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static bool SavePng(IntPtr hwnd, string path) {
        int[] r = Rect(hwnd);
        if (r[2] <= 0 || r[3] <= 0) return false;
        using (var bmp = new System.Drawing.Bitmap(r[2], r[3]))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            bool ok;
            try { ok = PrintWindow(hwnd, hdc, 2); }
            finally { g.ReleaseHdc(hdc); }
            if (!ok) return false;
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return true;
        }
    }
}
'@

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutputDir "$Backend-chrome-$stamp.log"
$checks = New-Object System.Collections.Generic.List[object]
$script:log = New-Object System.Collections.Generic.List[string]

function Log([string]$text) {
    $script:log.Add($text)
    Write-Output $text
}

function Record([string]$name, [string]$status, [string]$detail) {
    $checks.Add([pscustomobject]@{ Name = $name; Status = $status; Detail = $detail })
    Log ("[{0}] {1}: {2}" -f $status, $name, $detail)
}

function Wait-Until([scriptblock]$predicate, [int]$timeoutMs = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        if (& $predicate) { return $true }
        Start-Sleep -Milliseconds 40
    } while ([DateTime]::UtcNow -lt $deadline)
    return (& $predicate)
}

function Save-Capture([string]$name) {
    if ($NoScreenshots) { return }
    $path = Join-Path $OutputDir "$Backend-$name-$stamp.png"
    try { [void][NativeWebGpuChromeValidation]::SavePng($script:main, $path) } catch { }
}

# Find the midpoint of the contiguous HTCAPTION run in the integrated titlebar
# band. The application-authored drag region grows between the tab strip and the
# caption reservation, so its exact x depends on measured menu/caption metrics.
function Find-CaptionBandPoint([int]$yOffset = 16) {
    $rect = [NativeWebGpuChromeValidation]::Rect($script:main)
    if ($rect[2] -le 0) { return @(0, 0) }
    $y = $rect[1] + $yOffset
    $first = -1
    $last = -1
    $x = $rect[0] + 300
    $limit = $rect[0] + $rect[2] - 160
    while ($x -le $limit) {
        if ([NativeWebGpuChromeValidation]::HitTest($script:main, $x, $y) -eq 2) {
            if ($first -lt 0) { $first = $x }
            $last = $x
        }
        $x += 4
    }
    if ($first -lt 0) { return @(0, 0) }
    return @([int](($first + $last) / 2), $y)
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $executablePath
$startInfo.Arguments = "--titlebar-smoke --interactive --backend=$Backend"
$startInfo.WorkingDirectory = Split-Path -Parent $executablePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$script:main = [IntPtr]::Zero

try {
    if (-not $process.Start()) { throw 'process did not start' }
    Log "backend=$Backend executable=$executablePath pid=$($process.Id)"

    $found = Wait-Until { [NativeWebGpuChromeValidation]::FirstSdlWindow($process.Id) -ne [IntPtr]::Zero } 20000
    if (-not $found) { throw 'main SDL window did not appear' }
    $script:main = [NativeWebGpuChromeValidation]::FirstSdlWindow($process.Id)
    Record 'main window created' 'PASS' "hwnd=$script:main title='$([NativeWebGpuChromeValidation]::TitleOf($script:main))'"

    $focused = Wait-Until { [void][NativeWebGpuChromeValidation]::Focus($script:main); [NativeWebGpuChromeValidation]::GetForegroundWindow() -eq $script:main } 8000
    if (-not $focused) {
        $rect = [NativeWebGpuChromeValidation]::Rect($script:main)
        [void][NativeWebGpuChromeValidation]::Click($rect[0] + [int]($rect[2] / 2), $rect[1] + 120)
        Start-Sleep -Milliseconds 400
        $focused = [NativeWebGpuChromeValidation]::Focus($script:main)
    }
    Record 'window focus' ($(if ($focused) { 'PASS' } else { 'FAIL' })) "foreground=$focused"

    # Give the integrated titlebar enough room for a real drag region and make
    # the measured menu/caption exclusions deterministic for the checks below.
    [void][NativeWebGpuChromeValidation]::SetWindowPos($script:main, [IntPtr]::Zero, 120, 120, 1100, 700, 0x0004)
    Start-Sleep -Milliseconds 500
    $rect = [NativeWebGpuChromeValidation]::Rect($script:main)
    Record 'window resized for chrome interaction' 'PASS' ("rect={0},{1} {2}x{3}" -f $rect[0], $rect[1], $rect[2], $rect[3])
    Save-Capture 'initial'

    $band = Find-CaptionBandPoint 16
    $bandX = $band[0]
    $bandY = $band[1]
    $hit = if ($bandX -ne 0) { [NativeWebGpuChromeValidation]::HitTest($script:main, $bandX, $bandY) } else { 0 }
    Record 'Window_Drag region maps to HTCAPTION' ($(if ($hit -eq 2) { 'PASS' } else { 'FAIL' })) "point=$bandX,$bandY WM_NCHITTEST=$hit (HTCAPTION=2)"

    $before = [NativeWebGpuChromeValidation]::Rect($script:main)
    $dragged = $false
    if ($bandX -ne 0) {
        $dragged = [NativeWebGpuChromeValidation]::Drag($bandX, $bandY, $bandX + 100, $bandY + 50, 12)
    }
    Start-Sleep -Milliseconds 600
    $after = [NativeWebGpuChromeValidation]::Rect($script:main)
    $movedX = $after[0] - $before[0]
    $movedY = $after[1] - $before[1]
    $dragOk = $dragged -and $movedX -ge 70 -and $movedY -ge 30
    Record 'drag-to-move on caption band' ($(if ($dragOk) { 'PASS' } else { 'FAIL' })) "delta=$movedX,$movedY (expected about +100,+50)"
    Save-Capture 'after-drag'

    # Double-click the same band toggles maximize through the native caption path.
    $band = Find-CaptionBandPoint 16
    if ($band[0] -ne 0) {
        [void][NativeWebGpuChromeValidation]::DoubleClick($band[0], $band[1])
    }
    $maximized = Wait-Until { [NativeWebGpuChromeValidation]::IsZoomed($script:main) } 3000
    Record 'double-click caption maximizes' ($(if ($maximized) { 'PASS' } else { 'FAIL' })) "IsZoomed=$maximized"
    Save-Capture 'maximized'

    if ($maximized) {
        $band = Find-CaptionBandPoint 16
        if ($band[0] -ne 0) {
            [void][NativeWebGpuChromeValidation]::DoubleClick($band[0], $band[1])
        }
        $restored = Wait-Until { -not [NativeWebGpuChromeValidation]::IsZoomed($script:main) } 3000
        Record 'double-click caption restores' ($(if ($restored) { 'PASS' } else { 'FAIL' })) "IsZoomed=$(-not $restored)"
    }

    # Edge resize uses the same integrated-frame hit test path.
    $rect = [NativeWebGpuChromeValidation]::Rect($script:main)
    $edgeX = $rect[0] + $rect[2] - 2
    $edgeY = $rect[1] + [int]($rect[3] / 2)
    $edgeHit = [NativeWebGpuChromeValidation]::HitTest($script:main, $edgeX, $edgeY)
    Record 'right edge maps to HTRIGHT' ($(if ($edgeHit -eq 11) { 'PASS' } else { 'FAIL' })) "WM_NCHITTEST=$edgeHit (HTRIGHT=11)"
    $before = [NativeWebGpuChromeValidation]::Rect($script:main)
    $resized = [NativeWebGpuChromeValidation]::Drag($edgeX, $edgeY, $edgeX + 120, $edgeY, 10)
    Start-Sleep -Milliseconds 500
    $after = [NativeWebGpuChromeValidation]::Rect($script:main)
    $grown = $after[2] - $before[2]
    $resizeOk = $resized -and $grown -ge 90
    Record 'resize by right edge drag' ($(if ($resizeOk) { 'PASS' } else { 'FAIL' })) "width delta=$grown (expected about +120)"

    # Caption controls are painted masks, not UIA elements. Use the same DWM
    # button bounds the host uses to lay them out.
    $caption = [NativeWebGpuChromeValidation]::CaptionButtonBounds($script:main)
    if ($caption[2] -gt 0 -and $caption[3] -gt 0) {
        $third = [int]($caption[2] / 3)
        $minX = $caption[0] + [int]($third / 2)
        $maxX = $caption[0] + $third + [int]($third / 2)
        $closeX = $caption[0] + $caption[2] - [int]($third / 2)
        $captionY = $caption[1] + [int]($caption[3] / 2)

        [void][NativeWebGpuChromeValidation]::Click($minX, $captionY)
        $iconic = Wait-Until { [NativeWebGpuChromeValidation]::IsIconic($script:main) } 3000
        Record 'caption minimize click' ($(if ($iconic) { 'PASS' } else { 'FAIL' })) "IsIconic=$iconic"
        if ($iconic) {
            [void][NativeWebGpuChromeValidation]::ShowWindow($script:main, 9)
            $restored = Wait-Until { -not [NativeWebGpuChromeValidation]::IsIconic($script:main) -and [NativeWebGpuChromeValidation]::IsWindowVisible($script:main) } 3000
            Record 'restore after minimize' ($(if ($restored) { 'PASS' } else { 'FAIL' })) "visible=$restored"
            [void][NativeWebGpuChromeValidation]::BringToFront($script:main)
            Start-Sleep -Milliseconds 300
        }

        $caption = [NativeWebGpuChromeValidation]::CaptionButtonBounds($script:main)
        $third = [int]($caption[2] / 3)
        $maxX = $caption[0] + $third + [int]($third / 2)
        $captionY = $caption[1] + [int]($caption[3] / 2)
        [void][NativeWebGpuChromeValidation]::Click($maxX, $captionY)
        $maximized = Wait-Until { [NativeWebGpuChromeValidation]::IsZoomed($script:main) } 3000
        Record 'caption maximize click' ($(if ($maximized) { 'PASS' } else { 'FAIL' })) "IsZoomed=$maximized"
        if ($maximized) {
            $caption = [NativeWebGpuChromeValidation]::CaptionButtonBounds($script:main)
            $third = [int]($caption[2] / 3)
            $maxX = $caption[0] + $third + [int]($third / 2)
            $captionY = $caption[1] + [int]($caption[3] / 2)
            [void][NativeWebGpuChromeValidation]::Click($maxX, $captionY)
            $restored = Wait-Until { -not [NativeWebGpuChromeValidation]::IsZoomed($script:main) } 3000
            Record 'caption restore click' ($(if ($restored) { 'PASS' } else { 'FAIL' })) "IsZoomed=$(-not $restored)"
        }

        # Native theme/settings notifications must repaint the chrome without
        # terminating the host. This is message-path coverage, not a visual
        # contrast/theme comparison.
        [void][NativeWebGpuChromeValidation]::SendMessage($script:main, [NativeWebGpuChromeValidation]::WM_SETTINGCHANGE, [UIntPtr]::Zero, [IntPtr]::Zero)
        [void][NativeWebGpuChromeValidation]::SendMessage($script:main, [NativeWebGpuChromeValidation]::WM_THEMECHANGED, [UIntPtr]::Zero, [IntPtr]::Zero)
        [void][NativeWebGpuChromeValidation]::SendMessage($script:main, [NativeWebGpuChromeValidation]::WM_SYSCOLORCHANGE, [UIntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 400
        $alive = [NativeWebGpuChromeValidation]::IsWindow($script:main) -and -not $process.HasExited
        Record 'chrome survives theme/settings messages' ($(if ($alive) { 'PASS' } else { 'FAIL' })) "alive=$alive"
        Save-Capture 'after-theme-messages'

        $caption = [NativeWebGpuChromeValidation]::CaptionButtonBounds($script:main)
        $third = [int]($caption[2] / 3)
        $closeX = $caption[0] + $caption[2] - [int]($third / 2)
        $captionY = $caption[1] + [int]($caption[3] / 2)
        [void][NativeWebGpuChromeValidation]::Click($closeX, $captionY)
        $exited = $process.WaitForExit(10000)
        $exitCode = if ($exited) { $process.ExitCode } else { -1 }
        Record 'caption close click exits cleanly' ($(if ($exited -and $exitCode -eq 0) { 'PASS' } else { 'FAIL' })) "exited=$exited exit=$exitCode"
    } else {
        Record 'caption button bounds available' 'FAIL' 'DwmGetWindowAttribute(DWMWA_CAPTION_BUTTON_BOUNDS) returned no bounds'
    }

    Record 'Snap Layouts flyout (hover maximize button)' 'HANDS-ON' 'requires a human pointer over the caption maximize button; the flyout and snapped placement are OS-owned'
    Record 'theme/contrast visual switch' 'HANDS-ON' 'setting a live system theme or high-contrast theme changes the user desktop; message-path survival is covered above'
    Record 'mixed-DPI monitor move (150% to 200%)' 'HANDS-ON' 'user-owned physical monitor arrangement; WM_DPICHANGED handling is compile-tested but not scripted here'
    Record 'trackpad inertia / precision touchpad feel' 'HANDS-ON' 'requires physical precision-touchpad input; scripted wheel deltas do not exercise OS inertia'
}
finally {
    if (-not $process.HasExited) {
        try { $process.Kill() } catch { }
    }
    $checks | Format-Table -AutoSize | Out-String | Add-Content -LiteralPath $logPath
    $script:log | Add-Content -LiteralPath $logPath
    $summary = "backend=$Backend failures=$((@($checks | Where-Object { $_.Status -eq 'FAIL' })).Count) pass=$((@($checks | Where-Object { $_.Status -eq 'PASS' })).Count) hands_on=$((@($checks | Where-Object { $_.Status -eq 'HANDS-ON' })).Count)"
    Log $summary
    $summary | Add-Content -LiteralPath $logPath
    Log "log=$logPath"
}
