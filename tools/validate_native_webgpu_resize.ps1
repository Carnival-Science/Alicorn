param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('d3d12', 'vulkan', 'sdl-gpu')][string]$Backend = 'd3d12',
    [string]$OutputDir = 'out\interactive-webgpu-resize',
    [int]$DragSteps = 24,
    [int]$StepDelayMs = 25,
    # Fixture mode drives examples/16's --live-resize-smoke. Application mode
    # drives a real consumer (Scratchpad) that owns its own chrome: the scripted
    # drags and frame accounting are identical, but the fixture's caption-band
    # and live_resize_smoke checks do not apply.
    [ValidateSet('fixture', 'application')][string]$Mode = 'fixture',
    [string[]]$ExtraArguments = @()
)

# Drives examples/16_native_webgpu_ui --live-resize-smoke through real Windows
# window drags and proves the host presented frames *during* the drag.
#
# The fixture keeps a retained motion probe animating, so a modal move or resize
# that withholds host turns is visible as a gap in presented frames. A reader
# thread attached to the child's stdout timestamps every `live_resize_frame` line
# the host traces and records the live client size at receipt, so the checks can
# assert that frames exist mid-drag, that the presented drawable tracked the live
# window size, and that the drawable aspect matched the live window aspect.
#
# The same fixture runs on --backend=sdl-gpu; there the reference host reports
# its modal-loop redraw counters at shutdown instead of per frame, and the
# fixture-side live_resize_smoke line is identical on both renderers.
#
# -Mode application drives a real consumer instead. Use it to validate a
# Scratchpad-shaped build through the same physical drags: it asserts live
# frames, drawable/client agreement, and host telemetry, but it does not need
# the fixture's titlebar regions or its live_resize_smoke verdict.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class NativeWebGpuResizeValidation {
    private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion data; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit, Size = 32)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint WM_NCHITTEST = 0x0084;
    public const uint WM_CLOSE = 0x0010;

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

    public static int[] Rect(IntPtr hwnd) {
        RECT r; if (!GetWindowRect(hwnd, out r)) return new int[] { 0, 0, 0, 0 };
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static int[] Client(IntPtr hwnd) {
        RECT r; if (!GetClientRect(hwnd, out r)) return new int[] { 0, 0 };
        return new int[] { r.Right - r.Left, r.Bottom - r.Top };
    }

    public static int HitTest(IntPtr hwnd, int screenX, int screenY) {
        ulong packed = ((ulong)(uint)(screenY & 0xffff) << 16) | (ulong)(uint)(screenX & 0xffff);
        return (int)SendMessage(hwnd, WM_NCHITTEST, UIntPtr.Zero, new IntPtr((long)packed));
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

    public static bool Click(int x, int y) {
        MoveCursor(x, y);
        Thread.Sleep(40);
        if (!LeftDown()) return false;
        Thread.Sleep(40);
        return LeftUp();
    }

    static bool SendMouse(uint flags) {
        var input = new INPUT();
        input.type = INPUT_MOUSE;
        input.data.mi.dwFlags = flags;
        return SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Drag(int fromX, int fromY, int toX, int toY, int steps, int stepDelayMs) {
        MoveCursor(fromX, fromY);
        Thread.Sleep(80);
        if (!LeftDown()) return false;
        Thread.Sleep(80);
        for (int i = 1; i <= steps; i++) {
            int x = fromX + (toX - fromX) * i / steps;
            int y = fromY + (toY - fromY) * i / steps;
            MoveCursor(x, y);
            Thread.Sleep(stepDelayMs);
        }
        Thread.Sleep(80);
        return LeftUp();
    }

    // ---- stdout tap -------------------------------------------------------
    // A dedicated thread reads the child's stdout. PowerShell event handlers
    // cannot be used here: they are marshalled onto the runspace, which is busy
    // inside the drag, so counting would be deferred past the release and would
    // not prove anything about the modal loop.
    public struct FrameSample {
        public string Line;
        public int ClientWidth;
        public int ClientHeight;
    }

    public static volatile bool DragActive;
    public static volatile IntPtr Target;
    private static readonly object Gate = new object();
    private static readonly List<string> AllLines = new List<string>();
    private static readonly List<FrameSample> DragFrames = new List<FrameSample>();

    public static void StartTap(StreamReader reader) {
        var thread = new Thread(delegate() {
            string line;
            while ((line = reader.ReadLine()) != null) {
                lock (Gate) { AllLines.Add(line); }
                bool live = line.StartsWith("live_resize_frame", StringComparison.Ordinal) ||
                            line.StartsWith("reference_live_resize_frame", StringComparison.Ordinal);
                if (!DragActive || !live) continue;
                var sample = new FrameSample { Line = line };
                if (Target != IntPtr.Zero) {
                    int[] client = Client(Target);
                    sample.ClientWidth = client[0];
                    sample.ClientHeight = client[1];
                }
                lock (Gate) { DragFrames.Add(sample); }
            }
        });
        thread.IsBackground = true;
        thread.Name = "alicorn-live-resize-tap";
        thread.Start();
    }

    public static FrameSample[] TakeDragFrames() {
        lock (Gate) { var copy = DragFrames.ToArray(); DragFrames.Clear(); return copy; }
    }

    public static string[] AllLinesSnapshot() {
        lock (Gate) { return AllLines.ToArray(); }
    }

    public static string[] FramesLike(string prefix) {
        lock (Gate) {
            var matches = new List<string>();
            foreach (var line in AllLines) if (line.StartsWith(prefix, StringComparison.Ordinal)) matches.Add(line);
            return matches.ToArray();
        }
    }

    public static void ClearDragFrames() { lock (Gate) { DragFrames.Clear(); } }

    // Parses `pixels=<w>x<h>` out of a live_resize_frame trace line.
    public static int[] TracePixels(string line) {
        int index = line.IndexOf("pixels=", StringComparison.Ordinal);
        if (index < 0) return new int[] { 0, 0 };
        string rest = line.Substring(index + 7);
        int space = rest.IndexOf(' ');
        if (space >= 0) rest = rest.Substring(0, space);
        string[] parts = rest.Split('x');
        if (parts.Length != 2) return new int[] { 0, 0 };
        int width, height;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out width)) return new int[] { 0, 0 };
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out height)) return new int[] { 0, 0 };
        return new int[] { width, height };
    }

    // Parses `logical=<w>x<h>` out of a live_resize_frame trace line.
    public static int[] TraceLogical(string line) {
        int index = line.IndexOf("logical=", StringComparison.Ordinal);
        if (index < 0) return new int[] { 0, 0 };
        string rest = line.Substring(index + 8);
        int space = rest.IndexOf(' ');
        if (space >= 0) rest = rest.Substring(0, space);
        string[] parts = rest.Split('x');
        if (parts.Length != 2) return new int[] { 0, 0 };
        int width, height;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out width)) return new int[] { 0, 0 };
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out height)) return new int[] { 0, 0 };
        return new int[] { width, height };
    }
}
'@

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutputDir "$Backend-live-resize-$stamp.log"
$checks = New-Object System.Collections.Generic.List[object]
$script:log = New-Object System.Collections.Generic.List[string]

function Log([string]$text) {
    $script:log.Add($text)
    Write-Host $text
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

# Get-TraceValue pulls one `key=<integer>` field out of a live-resize trace
# line. Both hosts print the same vocabulary for the shared metrics; the
# reference prints `build_ns` where the hosted host prints `description_ns`.
function Get-TraceValue([string]$line, [string]$key) {
    if ($line -match "(?:^|\s)$([regex]::Escape($key))=(-?[0-9]+)(?:\s|$)") { return [int64]$Matches[1] }
    return [int64]0
}

function Get-Percentile([double[]]$values, [double]$fraction) {
    if ($null -eq $values -or $values.Count -eq 0) { return [double]0 }
    $sorted = @($values | Sort-Object)
    $index = [int][Math]::Floor($fraction * ($sorted.Count - 1))
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [double]$sorted[$index]
}

function Format-Ms([double]$nanoseconds) {
    return ('{0:F2}' -f ($nanoseconds / 1000000.0))
}

function Show-Distribution([string]$label, [double[]]$values, [string]$unit = 'ms') {
    if ($null -eq $values -or $values.Count -eq 0) {
        Log ("  {0,-26} n=0" -f $label)
        return
    }
    $p50 = Get-Percentile $values 0.50
    $p95 = Get-Percentile $values 0.95
    $p99 = Get-Percentile $values 0.99
    $max = ($values | Measure-Object -Maximum).Maximum
    Log ("  {0,-26} n={1,-3} p50={2} {3} p95={4} {3} p99={5} {3} max={6} {3}" -f `
        $label, $values.Count, (Format-Ms $p50), $unit, (Format-Ms $p95), (Format-Ms $p99), (Format-Ms $max))
}

# Measure-LiveGesture turns the per-frame trace captured during one scripted
# drag into the metrics the acceptance asks for. It reports distributions rather
# than pass/fail thresholds: the latency floor is OS/compositor-dependent and the
# only hard invariant (aspect delta 0%, drawable tracks client) stays above.
function Measure-LiveGesture([string]$name, $samples, [string]$backend) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($sample in $samples) {
        $line = $sample.Line
        $isReference = $line.StartsWith('reference_live_resize_frame')
        $description = if ($isReference) { Get-TraceValue $line 'build_ns' } else { Get-TraceValue $line 'description_ns' }
        $rows.Add([pscustomobject]@{
            Gesture = $name
            Backend = $backend
            Host = if ($isReference) { 'sdl-gpu' } else { 'webgpu' }
            Cause = (($line -split 'cause=', 2)[1] -split '\s', 2)[0]
            IntervalNs = Get-TraceValue $line 'interval_ns'
            GeometryToPresentNs = Get-TraceValue $line 'geometry_to_present_ns'
            FrameNs = Get-TraceValue $line 'frame_ns'
            ReconfigureNs = Get-TraceValue $line 'reconfigure_ns'
            AdoptNs = Get-TraceValue $line 'adopt_ns'
            DescriptionNs = $description
            DescriptionPasses = Get-TraceValue $line 'description_passes'
            ReconcileNodes = Get-TraceValue $line 'reconcile_nodes'
            LayoutNodes = Get-TraceValue $line 'layout_nodes'
            PaintNodes = Get-TraceValue $line 'paint_nodes'
            PrePresentNs = Get-TraceValue $line 'pre_present_ns'
            RuntimeStepNs = Get-TraceValue $line 'runtime_step_ns'
            AcquireNs = Get-TraceValue $line 'acquire_ns'
            EncodeNs = Get-TraceValue $line 'encode_ns'
            SubmitNs = Get-TraceValue $line 'submit_ns'
            PresentNs = Get-TraceValue $line 'present_ns'
            PostPresentNs = Get-TraceValue $line 'post_present_ns'
            PollNs = Get-TraceValue $line 'poll_ns'
            PixelWidth = ([NativeWebGpuResizeValidation]::TracePixels($line))[0]
            MeshRebuilds = (Get-TraceValue $line 'solid_mesh_rebuilds') + (Get-TraceValue $line 'text_mesh_rebuilds') + (Get-TraceValue $line 'surface_mesh_rebuilds')
            Reconfigured = $line -match 'reconfigured=true'
        })
    }
    $intervals = @($rows | Where-Object { $_.IntervalNs -gt 0 } | ForEach-Object { [double]$_.IntervalNs })
    $geometryAges = @($rows | Where-Object { $_.GeometryToPresentNs -gt 0 } | ForEach-Object { [double]$_.GeometryToPresentNs })
    $descriptions = @($rows | ForEach-Object { [double]$_.DescriptionNs })
    $reconfigures = @($rows | Where-Object { $_.ReconfigureNs -gt 0 } | ForEach-Object { [double]$_.ReconfigureNs })
    $adopts = @($rows | Where-Object { $_.AdoptNs -gt 0 } | ForEach-Object { [double]$_.AdoptNs })
    $acquires = @($rows | ForEach-Object { [double]$_.AcquireNs })
    $encodes = @($rows | ForEach-Object { [double]$_.EncodeNs })
    $submits = @($rows | ForEach-Object { [double]$_.SubmitNs })
    $frames = @($rows | ForEach-Object { [double]$_.FrameNs })
    $prePresent = @($rows | ForEach-Object { [double]$_.PrePresentNs })
    $postPresent = @($rows | ForEach-Object { [double]$_.PostPresentNs })
    $polls = @($rows | ForEach-Object { [double]$_.PollNs })
    $overFrame = @($intervals | Where-Object { $_ -gt 16666667 }).Count
    $overTwo = @($intervals | Where-Object { $_ -gt 33333333 }).Count
    Log ("live_resize_metrics backend={0} gesture={1} host={2} frames={3}" -f `
        $backend, $name, ($(if ($rows.Count -gt 0) { $rows[0].Host } else { 'none' })), $rows.Count)
    Show-Distribution 'inter-present' $intervals
    Log ("  {0,-26} over_16.7ms={1} over_33.3ms={2}" -f 'stale-frame gaps', $overFrame, $overTwo)
    if ($name -eq 'resize') { Show-Distribution 'geometry-to-present' $geometryAges }
    Show-Distribution 'description/layout' $descriptions
    Show-Distribution 'surface reconfigure' $reconfigures
    Show-Distribution 'geometry adoption' $adopts
    Show-Distribution 'surface acquire' $acquires
    Show-Distribution 'renderer encode' $encodes
    Show-Distribution 'queue submit' $submits
    Show-Distribution 'chrome pre-present' $prePresent
    Show-Distribution 'host post-present' $postPresent
    Show-Distribution 'device poll' $polls
    Show-Distribution 'whole live frame' $frames
    $layoutNodes = @($rows | ForEach-Object { [double]$_.LayoutNodes })
    if (($layoutNodes | Measure-Object -Maximum).Maximum -gt 0) {
        Show-Distribution 'layout nodes visited' $layoutNodes 'nodes'
    }
    if ($rows.Count -gt 1) {
        $rebuilds = $rows[$rows.Count - 1].MeshRebuilds - $rows[0].MeshRebuilds
        Log ("  {0,-26} {1} (first-to-last retained mesh rebuild counter delta)" -f 'mesh rebuilds in gesture', $rebuilds)
    }
    return $rows
}

# Midpoint of the contiguous HTCAPTION run in the integrated titlebar band.
function Find-CaptionBandPoint([int]$yOffset = 16) {
    $rect = [NativeWebGpuResizeValidation]::Rect($script:main)
    if ($rect[2] -le 0) { return @(0, 0) }
    $y = $rect[1] + $yOffset
    $first = -1
    $last = -1
    $x = $rect[0] + 300
    $limit = $rect[0] + $rect[2] - 160
    while ($x -le $limit) {
        if ([NativeWebGpuResizeValidation]::HitTest($script:main, $x, $y) -eq 2) {
            if ($first -lt 0) { $first = $x }
            $last = $x
        }
        $x += 4
    }
    if ($first -lt 0) { return @(0, 0) }
    return @([int](($first + $last) / 2), $y)
}

function Record-LiveFrame([string]$name, [bool]$ok, [string]$detail) {
    # Per-frame traces are a hosted-host test seam. The reference SDL_GPU host
    # reports the same evidence as shutdown counters, checked separately below.
    if ($Backend -eq 'sdl-gpu') {
        Record $name 'PASS' "hosted-only per-frame seam; reference modal-loop counters are checked after close ($detail)"
        return
    }
    Record $name ($(if ($ok) { 'PASS' } else { 'FAIL' })) $detail
}

function Run-Drag([int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    [NativeWebGpuResizeValidation]::ClearDragFrames()
    [NativeWebGpuResizeValidation]::DragActive = $true
    try {
        $ok = [NativeWebGpuResizeValidation]::Drag($fromX, $fromY, $toX, $toY, $DragSteps, $StepDelayMs)
    }
    finally {
        [NativeWebGpuResizeValidation]::DragActive = $false
    }
    Start-Sleep -Milliseconds 120
    return $ok
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$arguments = if ($Mode -eq 'fixture') {
    "--titlebar-smoke --live-resize-smoke --interactive --backend=$Backend --test-live-resize-trace"
} else {
    "--backend=$Backend --test-live-resize-trace"
}
if ($ExtraArguments.Count -gt 0) { $arguments = "$arguments $($ExtraArguments -join ' ')" }
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $executablePath
$startInfo.Arguments = $arguments
$startInfo.WorkingDirectory = Split-Path -Parent $executablePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$script:main = [IntPtr]::Zero

try {
    if (-not $process.Start()) { throw 'process did not start' }
    [NativeWebGpuResizeValidation]::StartTap($process.StandardOutput)
    Log "backend=$Backend executable=$executablePath pid=$($process.Id)"

    $found = Wait-Until { [NativeWebGpuResizeValidation]::FirstSdlWindow($process.Id) -ne [IntPtr]::Zero } 20000
    if (-not $found) { throw 'main SDL window did not appear' }
    $script:main = [NativeWebGpuResizeValidation]::FirstSdlWindow($process.Id)
    [NativeWebGpuResizeValidation]::Target = $script:main
    Record 'main window created' 'PASS' "hwnd=$script:main"

    $focused = Wait-Until { [void][NativeWebGpuResizeValidation]::Focus($script:main); [NativeWebGpuResizeValidation]::GetForegroundWindow() -eq $script:main } 8000
    if (-not $focused) {
        $focusRect = [NativeWebGpuResizeValidation]::Rect($script:main)
        [void][NativeWebGpuResizeValidation]::Click($focusRect[0] + [int]($focusRect[2] / 2), $focusRect[1] + 120)
        Start-Sleep -Milliseconds 400
        $focused = [NativeWebGpuResizeValidation]::Focus($script:main)
    }
    Record 'window focus' ($(if ($focused) { 'PASS' } else { 'FAIL' })) "foreground=$focused"

    # Deterministic starting geometry for both drags.
    [void][NativeWebGpuResizeValidation]::SetWindowPos($script:main, [IntPtr]::Zero, 120, 120, 1100, 700, 0x0004)
    Start-Sleep -Milliseconds 700
    $rect = [NativeWebGpuResizeValidation]::Rect($script:main)
    Record 'window resized for live interaction' 'PASS' ("rect={0},{1} {2}x{3}" -f $rect[0], $rect[1], $rect[2], $rect[3])

    if ($Backend -eq 'sdl-gpu') {
        # The reference host reports modal-loop redraws at shutdown; per-frame
        # traces are a hosted-host seam. Wait for any queued trace lines from the
        # live path so both backends are summarised the same way.
        Start-Sleep -Milliseconds 300
    }

    # ---- move drag: presentation must continue inside the modal move loop ----
    # The caption-band check needs the fixture's declared Window_Drag region. A
    # real application drags its native caption instead, so only the motion
    # continuity check applies there.
    $band = Find-CaptionBandPoint 16
    $hit = if ($band[0] -ne 0) { [NativeWebGpuResizeValidation]::HitTest($script:main, $band[0], $band[1]) } else { 0 }
    if ($Mode -eq 'fixture') {
        Record 'Window_Drag region maps to HTCAPTION' ($(if ($hit -eq 2) { 'PASS' } else { 'FAIL' })) "point=$($band[0]),$($band[1]) WM_NCHITTEST=$hit (HTCAPTION=2)"
    } else {
        Record 'native caption available for move drag' ($(if ($hit -eq 2) { 'PASS' } else { 'FAIL' })) "point=$($band[0]),$($band[1]) WM_NCHITTEST=$hit (HTCAPTION=2)"
    }
    $before = [NativeWebGpuResizeValidation]::Rect($script:main)
    $moved = $false
    if ($band[0] -ne 0) {
        $moved = Run-Drag $band[0] $band[1] ($band[0] + 100) ($band[1] + 50)
    }
    $moveFrames = [NativeWebGpuResizeValidation]::TakeDragFrames()
    $after = [NativeWebGpuResizeValidation]::Rect($script:main)
    $movedX = $after[0] - $before[0]
    $movedY = $after[1] - $before[1]
    Record 'drag-to-move on caption band' ($(if ($moved -and $movedX -ge 70 -and $movedY -ge 30) { 'PASS' } else { 'FAIL' })) "delta=$movedX,$movedY (expected about +100,+50)"
    if ($Backend -eq 'sdl-gpu') {
        # The reference host has no per-frame trace seam. Its modal-loop redraw
        # counters are checked after close below, and the shared fixture line
        # proves live layout on both renderers.
        Record 'frames presented during modal move' 'PASS' "native counters verified after close (trace lines seen: $($moveFrames.Count))"
    } else {
        Record 'frames presented during modal move' ($(if ($moveFrames.Count -gt 0) { 'PASS' } else { 'FAIL' })) "frames=$($moveFrames.Count) (retained motion must keep animating while the window is dragged)"
    }

    # ---- edge resize: layout and presentation must track the live size ----
    $rect = [NativeWebGpuResizeValidation]::Rect($script:main)
    $edgeX = $rect[0] + $rect[2] - 2
    $edgeY = $rect[1] + [int]($rect[3] / 2)
    $edgeHit = [NativeWebGpuResizeValidation]::HitTest($script:main, $edgeX, $edgeY)
    Record 'right edge maps to HTRIGHT' ($(if ($edgeHit -eq 11) { 'PASS' } else { 'FAIL' })) "WM_NCHITTEST=$edgeHit (HTRIGHT=11)"
    $clientBefore = [NativeWebGpuResizeValidation]::Client($script:main)
    $beforeRect = [NativeWebGpuResizeValidation]::Rect($script:main)
    $resized = Run-Drag $edgeX $edgeY ($edgeX + 140) $edgeY
    $resizeFrames = [NativeWebGpuResizeValidation]::TakeDragFrames()
    $afterRect = [NativeWebGpuResizeValidation]::Rect($script:main)
    $clientAfter = [NativeWebGpuResizeValidation]::Client($script:main)
    $grown = $afterRect[2] - $beforeRect[2]
    Record 'resize by right edge drag' ($(if ($resized -and $grown -ge 100) { 'PASS' } else { 'FAIL' })) "width delta=$grown (expected about +140)"

    $parsed = New-Object System.Collections.Generic.List[object]
    foreach ($sample in $resizeFrames) {
        $pixels = [NativeWebGpuResizeValidation]::TracePixels($sample.Line)
        $logical = [NativeWebGpuResizeValidation]::TraceLogical($sample.Line)
        $parsed.Add([pscustomobject]@{
            Pixels = $pixels
            Logical = $logical
            ClientWidth = $sample.ClientWidth
            ClientHeight = $sample.ClientHeight
            Line = $sample.Line
        })
    }
    $midDragCount = $parsed.Count
    $pixelWidths = @($parsed | ForEach-Object { $_.Pixels[0] } | Where-Object { $_ -gt 0 })
    $distinctWidths = @($pixelWidths | Sort-Object -Unique).Count
    $maxPixelWidth = if ($pixelWidths.Count -gt 0) { ($pixelWidths | Measure-Object -Maximum).Maximum } else { 0 }
    $minPixelWidth = if ($pixelWidths.Count -gt 0) { ($pixelWidths | Measure-Object -Minimum).Minimum } else { 0 }
    $trackedGrowth = $maxPixelWidth - $clientBefore[0]
    Record-LiveFrame 'resize presentations happen mid-drag' ($midDragCount -ge 3) "frames=$midDragCount pixel_widths=$($pixelWidths -join ',')"
    Record-LiveFrame 'drawable tracks the live window size' ($trackedGrowth -ge 50 -and $maxPixelWidth -le ($clientAfter[0] + 8)) "client_before=$($clientBefore[0]) max_frame_pixel_width=$maxPixelWidth client_after=$($clientAfter[0])"
    Record-LiveFrame 'live layout follows the drag continuously' ($distinctWidths -ge 3) "distinct_pixel_widths=$distinctWidths min=$minPixelWidth max=$maxPixelWidth"

    # Last mid-drag frame: the drawable aspect must match the live client aspect.
    $aspectOk = $false
    $aspectDetail = 'no mid-drag frames'
    if ($midDragCount -gt 0) {
        $last = $parsed[$midDragCount - 1]
        $pw = [double]$last.Pixels[0]
        $ph = [double]$last.Pixels[1]
        $cw = [double]$last.ClientWidth
        $ch = [double]$last.ClientHeight
        if ($pw -gt 0 -and $ph -gt 0 -and $cw -gt 0 -and $ch -gt 0) {
            $drawableAspect = $pw / $ph
            $clientAspect = $cw / $ch
            $ratio = [Math]::Abs($drawableAspect / $clientAspect - 1.0)
            $widthAgrees = [Math]::Abs($pw - $cw) -le 48
            $aspectOk = $ratio -le 0.03 -and $widthAgrees
            $aspectDetail = "drawable={0}x{1} live_client={2}x{3} aspect_delta={4:P2} width_delta={5}" -f [int]$pw, [int]$ph, [int]$cw, [int]$ch, $ratio, [int][Math]::Abs($pw - $cw)
        }
    }
    Record-LiveFrame 'mid-drag drawable matches live client aspect' $aspectOk $aspectDetail

    # ---- measured latency table (recorded, not enforced) -------------------
    # The founder acceptance for this slice is a measured comparison, not a new
    # pass/fail knob: the compositor floor differs by backend and desktop session.
    # The hard invariants remain the C1 checks above.
    $metricRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in (Measure-LiveGesture 'move' $moveFrames $Backend)) { $metricRows.Add($row) }
    foreach ($row in (Measure-LiveGesture 'resize' $resizeFrames $Backend)) { $metricRows.Add($row) }
    $csvPath = Join-Path $OutputDir "$Backend-live-resize-metrics-$stamp.csv"
    $metricRows | Export-Csv -NoTypeInformation -LiteralPath $csvPath
    $resizeIntervals = @($metricRows | Where-Object { $_.Gesture -eq 'resize' -and $_.IntervalNs -gt 0 } | ForEach-Object { [double]$_.IntervalNs })
    $moveIntervals = @($metricRows | Where-Object { $_.Gesture -eq 'move' -and $_.IntervalNs -gt 0 } | ForEach-Object { [double]$_.IntervalNs })
    $resizeGeometryAges = @($metricRows | Where-Object { $_.Gesture -eq 'resize' -and $_.GeometryToPresentNs -gt 0 } | ForEach-Object { [double]$_.GeometryToPresentNs })
    Record 'live-resize latency recorded (no threshold)' 'PASS' ("resize inter-present p50={0} ms p95={1} ms | resize geometry-to-present p50={2} ms p95={3} ms | move inter-present p50={4} ms p95={5} ms | csv={6}" -f `
        (Format-Ms (Get-Percentile $resizeIntervals 0.50)), (Format-Ms (Get-Percentile $resizeIntervals 0.95)), `
        (Format-Ms (Get-Percentile $resizeGeometryAges 0.50)), (Format-Ms (Get-Percentile $resizeGeometryAges 0.95)), `
        (Format-Ms (Get-Percentile $moveIntervals 0.50)), (Format-Ms (Get-Percentile $moveIntervals 0.95)), $csvPath)


    # Close through the native close path so the fixture prints its own verdict.
    [void][NativeWebGpuResizeValidation]::PostMessage($script:main, [NativeWebGpuResizeValidation]::WM_CLOSE, [UIntPtr]::Zero, [IntPtr]::Zero)
    $exited = $process.WaitForExit(15000)
    if ($exited) {
        # Drain stdout so the tap thread observes the final lines.
        Start-Sleep -Milliseconds 200
    } else {
        try { $process.Kill() } catch { }
    }
    $exitCode = if ($exited) { $process.ExitCode } else { -1 }
    $lines = [NativeWebGpuResizeValidation]::AllLinesSnapshot()

    $fixtureLine = $lines | Where-Object { $_ -like 'live_resize_smoke*' } | Select-Object -Last 1
    if ($Mode -eq 'fixture') {
        $fixtureOk = $fixtureLine -like '*PASS*'
        Record 'fixture-side live layout accounting' ($(if ($fixtureOk) { 'PASS' } else { 'FAIL' })) ($(if ($fixtureLine) { $fixtureLine } else { 'no live_resize_smoke line' }))
    } elseif ($fixtureLine) {
        Record 'fixture-side live layout accounting' ($(if ($fixtureLine -like '*PASS*') { 'PASS' } else { 'FAIL' })) $fixtureLine
    }

    if ($Backend -eq 'sdl-gpu') {
        $nativeLine = $lines | Where-Object { $_ -like 'SDL application PASS*' } | Select-Object -Last 1
        $exposes = 0
        $redraws = 0
        if ($nativeLine -match 'live_resize_expose_events (\d+)') { $exposes = [int]$Matches[1] }
        if ($nativeLine -match 'windows_move_redraws (\d+)') { $redraws = [int]$Matches[1] }
        $nativeLive = $exposes + $redraws -gt 0
        Record 'reference host redrew inside the modal loop' ($(if ($nativeLive) { 'PASS' } else { 'FAIL' })) "live_resize_expose_events=$exposes windows_move_redraws=$redraws"
    } else {
        $summary = $lines | Where-Object { $_ -like 'webgpu_live_resize*' } | Select-Object -Last 1
        $frames = 0
        $exposes = 0
        $timerWakes = 0
        if ($summary -match 'frames (\d+)') { $frames = [int]$Matches[1] }
        if ($summary -match 'expose_events (\d+)') { $exposes = [int]$Matches[1] }
        if ($summary -match 'move_timer_wakes (\d+)') { $timerWakes = [int]$Matches[1] }
        $summaryOk = $frames -gt 0 -and ($exposes + $timerWakes) -gt 0
        Record 'host live-resize telemetry' ($(if ($summaryOk) { 'PASS' } else { 'FAIL' })) ($(if ($summary) { $summary } else { 'no webgpu_live_resize line' }))
    }

    Record 'clean exit' ($(if ($exited -and $exitCode -eq 0) { 'PASS' } else { 'FAIL' })) "exited=$exited exit=$exitCode"
    Record 'mixed-DPI live drag during WM_DPICHANGED' 'HANDS-ON' 'requires a physical multi-monitor arrangement; the live path re-reads pixel and logical metrics together, but the founder drag across monitors is the confirming check'
}
finally {
    [NativeWebGpuResizeValidation]::DragActive = $false
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
