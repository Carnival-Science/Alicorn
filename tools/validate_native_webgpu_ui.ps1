param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('d3d12', 'vulkan')][string]$Backend = 'd3d12',
    [string]$OutputDir = 'out\interactive-webgpu-ui',
    [switch]$NoScreenshots
)

# Drives examples/16_native_webgpu_ui through its real SDL3 window with
# Windows UI Automation and physical-style SendInput/SendKeys events. Evidence
# is written as a log plus UIA tree dumps; screenshots are best effort.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class NativeWebGpuUiValidation {
    private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion data; }

    // The native INPUT union is sized for MOUSEINPUT (32 bytes on x64), not
    // just KEYBDINPUT; SendInput rejects a smaller cbSize.
    [StructLayout(LayoutKind.Explicit, Size = 32)]
    struct InputUnion {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;

    public static uint SendUnicode(string text) {
        var inputs = new List<INPUT>();
        foreach (char ch in text) {
            inputs.Add(KeyInput(ch, KEYEVENTF_UNICODE));
            inputs.Add(KeyInput(ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
        }
        var array = inputs.ToArray();
        return SendInput((uint)array.Length, array, Marshal.SizeOf(typeof(INPUT)));
    }

    static INPUT KeyInput(char ch, uint flags) {
        var input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.data.ki.wScan = ch;
        input.data.ki.dwFlags = flags;
        return input;
    }

    public static string ClassOf(IntPtr hwnd) {
        var sb = new StringBuilder(256); GetClassName(hwnd, sb, 256); return sb.ToString();
    }

    public static string TitleOf(IntPtr hwnd) {
        var sb = new StringBuilder(512); GetWindowText(hwnd, sb, 512); return sb.ToString();
    }

    public static IntPtr[] WindowsForProcess(int processId) {
        var result = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid == processId) result.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    public static IntPtr FirstSdlWindow(int processId, IntPtr exclude) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid != processId || hwnd == exclude) return true;
            if (ClassOf(hwnd) != "SDL_app" || !IsWindowVisible(hwnd)) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static int[] Rect(IntPtr hwnd) {
        RECT r; if (!GetWindowRect(hwnd, out r)) return new int[] { 0, 0, 0, 0 };
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
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

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutputDir "$Backend-$stamp.log"
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
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    return (& $predicate)
}

function Dump-UiaTree($root, [string]$path) {
    $lines = New-Object System.Collections.Generic.List[string]
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($root, 0))
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $element = $entry[0]
        $depth = $entry[1]
        try { $current = $element.Current } catch { continue }
        $patterns = New-Object System.Collections.Generic.List[string]
        foreach ($p in @(
            [System.Windows.Automation.ValuePattern]::Pattern,
            [System.Windows.Automation.TextPattern]::Pattern,
            [System.Windows.Automation.InvokePattern]::Pattern,
            [System.Windows.Automation.SelectionItemPattern]::Pattern,
            [System.Windows.Automation.ScrollPattern]::Pattern
        )) {
            $obj = $null
            if ($element.TryGetCurrentPattern($p, [ref]$obj)) {
                $patterns.Add($p.ProgrammaticName.Replace('PatternIdentifiers.Pattern', ''))
            }
        }
        $lines.Add(('  ' * $depth) + ("{0} name='{1}' class='{2}' id='{3}' enabled={4} keyboardFocusable={5} offscreen={6} patterns=[{7}]" -f `
            $current.ControlType.ProgrammaticName, $current.Name, $current.ClassName, $current.AutomationId, `
            $current.IsEnabled, $current.IsKeyboardFocusable, $current.IsOffscreen, ($patterns -join ',')))
        $children = @()
        $child = $walker.GetFirstChild($element)
        while ($null -ne $child) { $children += $child; $child = $walker.GetNextSibling($child) }
        for ($i = $children.Count - 1; $i -ge 0; $i--) { $stack.Push(@($children[$i], $depth + 1)) }
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    return $lines.Count
}

function Find-ElementByName($root, [string]$name, $controlType = $null) {
    $typeCondition = $null
    if ($null -ne $controlType) {
        $typeCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $controlType)
    }
    $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    if ($null -ne $typeCondition) {
        $condition = New-Object System.Windows.Automation.AndCondition($typeCondition, $nameCondition)
    } else {
        $condition = $nameCondition
    }
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $executablePath
$startInfo.Arguments = "--backend=$Backend"
$startInfo.WorkingDirectory = Split-Path -Parent $executablePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
$main = [IntPtr]::Zero
$child = [IntPtr]::Zero
$mainRoot = $null

try {
    if (-not $process.Start()) { throw 'process did not start' }
    Log "backend=$Backend executable=$executablePath pid=$($process.Id)"

    $found = Wait-Until { [NativeWebGpuUiValidation]::FirstSdlWindow($process.Id, [IntPtr]::Zero) -ne [IntPtr]::Zero } 20000
    if (-not $found) { throw 'main SDL window did not appear' }
    $main = [NativeWebGpuUiValidation]::FirstSdlWindow($process.Id, [IntPtr]::Zero)
    Record 'main window created' 'PASS' "hwnd=$main title='$([NativeWebGpuUiValidation]::TitleOf($main))' class=$([NativeWebGpuUiValidation]::ClassOf($main))"

    $focused = Wait-Until { [void][NativeWebGpuUiValidation]::SetForegroundWindow($main); [NativeWebGpuUiValidation]::GetForegroundWindow() -eq $main } 5000
    Record 'window focus' ($(if ($focused) { 'PASS' } else { 'FAIL' })) "foreground=$focused"

    $mainRoot = [System.Windows.Automation.AutomationElement]::FromHandle($main)
    $treePath = Join-Path $OutputDir "$Backend-uia-initial.txt"
    $treeLines = Dump-UiaTree $mainRoot $treePath
    Record 'UIA tree dump' ($(if ($treeLines -gt 5) { 'PASS' } else { 'FAIL' })) "$treeLines elements -> $treePath"

    # AccessKit's UIA adapter derives IsKeyboardFocusable from the AccessKit
    # Focus action. Every button that Tab can reach must therefore report it,
    # or assistive technology is told the control cannot take focus.
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $buttons = $mainRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    $buttonNames = New-Object System.Collections.Generic.List[string]
    $notFocusable = New-Object System.Collections.Generic.List[string]
    foreach ($buttonElement in $buttons) {
        $buttonNames.Add($buttonElement.Current.Name)
        if (-not $buttonElement.Current.IsKeyboardFocusable) { $notFocusable.Add($buttonElement.Current.Name) }
    }
    $focusableOk = $buttons.Count -gt 0 -and $notFocusable.Count -eq 0
    Record 'buttons report IsKeyboardFocusable' ($(if ($focusableOk) { 'PASS' } else { 'FAIL' })) `
        ("buttons=[{0}] notFocusable=[{1}]" -f ($buttonNames -join ','), ($notFocusable -join ','))

    $edit = Find-ElementByName $mainRoot 'Try native text input' ([System.Windows.Automation.ControlType]::Edit)
    Record 'text field exposed' ($(if ($null -ne $edit) { 'PASS' } else { 'FAIL' })) "name='Try native text input'"

    if ($null -eq $edit) { throw 'text field missing' }
    $valuePattern = $null
    $hasValue = $edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)
    Record 'ValuePattern' ($(if ($hasValue) { 'PASS' } else { 'FAIL' })) "value='$(if ($hasValue) { $valuePattern.Current.Value } else { '<unavailable>' })'"
    $textPattern = $null
    $hasText = $edit.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)
    $textRun = '<unavailable>'
    if ($hasText) { $textRun = $textPattern.DocumentRange.GetText(-1) }
    Record 'TextPattern' ($(if ($hasText) { 'PASS' } else { 'UNTESTED' })) "text='$textRun'"

    $initial = $valuePattern.Current.Value
    $edit.SetFocus()
    $focusOk = Wait-Until { [System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -eq 'Try native text input' } 3000
    Record 'UIA SetFocus on text field' ($(if ($focusOk) { 'PASS' } else { 'FAIL' })) "focused=$focusOk"

    # Clear through a physical Ctrl+A/Backspace, then type plain ASCII.
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')
    Wait-Until { $valuePattern.Current.Value -eq '' } 3000 | Out-Null
    $cleared = $valuePattern.Current.Value -eq ''
    Record 'physical clear (Ctrl+A, Backspace)' ($(if ($cleared) { 'PASS' } else { 'FAIL' })) "value='$($valuePattern.Current.Value)'"

    [System.Windows.Forms.SendKeys]::SendWait('Native input ok')
    $typed = Wait-Until { $valuePattern.Current.Value -eq 'Native input ok' } 3000
    if (-not $typed) {
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('Native input ok')
        $typed = Wait-Until { $valuePattern.Current.Value -eq 'Native input ok' } 3000
    }
    Record 'physical keyboard text input' ($(if ($typed) { 'PASS' } else { 'FAIL' })) "value='$($valuePattern.Current.Value)'"

    if (Wait-Until { $valuePattern.Current.Value -eq 'Native input ok' } 500) {
        Dump-UiaTree $mainRoot (Join-Path $OutputDir "$Backend-uia-after-text.txt") | Out-Null
    }

    # Unicode codepoint delivery through SendInput KEYEVENTF_UNICODE. This is
    # WM_CHAR text input, not an IME composition session.
    $unicode = [char]0x00E9
    $sent = [NativeWebGpuUiValidation]::SendUnicode([string]$unicode)
    $unicodeOk = Wait-Until { $valuePattern.Current.Value.EndsWith([string]$unicode) } 3000
    $unicodeDetail = "sent=$sent/2 value='$($valuePattern.Current.Value)' appended='$unicode'"
    if (-not $unicodeOk) {
        Start-Sleep -Milliseconds 300
        $sent = [NativeWebGpuUiValidation]::SendUnicode([string]$unicode)
        $unicodeOk = Wait-Until { $valuePattern.Current.Value.EndsWith([string]$unicode) } 3000
        $unicodeDetail = "retried sent=$sent/2 value='$($valuePattern.Current.Value)' appended='$unicode'"
    }
    Record 'unicode codepoint input (SendInput, not IME composition)' ($(if ($unicodeOk) { 'PASS' } else { 'FAIL' })) $unicodeDetail

    # Remove the unicode character so later assertions remain stable.
    [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')
    Wait-Until { $valuePattern.Current.Value -eq 'Native input ok' } 2000 | Out-Null

    # Tab traversal from the text field.
    $edit.SetFocus()
    Start-Sleep -Milliseconds 150
    $sequence = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 8; $i++) {
        [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
        Start-Sleep -Milliseconds 150
        $current = [System.Windows.Automation.AutomationElement]::FocusedElement
        $sequence.Add("$($current.Current.ControlType.ProgrammaticName):$($current.Current.Name)")
    }
    $distinct = ($sequence | Select-Object -Unique)
    Record 'Tab keyboard navigation' ($(if ($distinct.Count -ge 2) { 'PASS' } else { 'FAIL' })) ("order=" + ($sequence -join ' -> '))

    [System.Windows.Forms.SendKeys]::SendWait('+{TAB}')
    Start-Sleep -Milliseconds 150
    $shiftTab = [System.Windows.Automation.AutomationElement]::FocusedElement
    Record 'Shift+Tab reverse navigation' ($(if ($shiftTab.Current.Name -ne '') { 'PASS' } else { 'FAIL' })) "focused='$($shiftTab.Current.Name)'"

    # UIA activation of the increment button updates the retained status text.
    $increment = Find-ElementByName $mainRoot 'Increment' ([System.Windows.Automation.ControlType]::Button)
    $invoked = $false
    if ($null -ne $increment) {
        $invoke = $increment.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
        $invoked = Wait-Until { $null -ne (Find-ElementByName $mainRoot 'Button activations: 1') } 5000
    }
    Record 'UIA Invoke (Increment) updates status' ($(if ($invoked) { 'PASS' } else { 'FAIL' })) 'expected Button activations: 1'

    # Wake button exercises the application wake callback on the owner thread.
    $wakeButton = Find-ElementByName $mainRoot 'Queue application wake' ([System.Windows.Automation.ControlType]::Button)
    $woke = $false
    if ($null -ne $wakeButton) {
        $wakeInvoke = $wakeButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $wakeInvoke.Invoke()
        $woke = Wait-Until { $null -ne (Find-ElementByName $mainRoot 'Application wake callbacks: 1') } 5000
    }
    Record 'UIA Invoke (wake) delivers wake callback' ($(if ($woke) { 'PASS' } else { 'FAIL' })) 'expected Application wake callbacks: 1'

    # Open the auxiliary window. Prefer real keyboard activation from Tab focus.
    $openButton = Find-ElementByName $mainRoot 'Open auxiliary window' ([System.Windows.Automation.ControlType]::Button)
    $openedByKeyboard = $false
    $reachedOpen = $false
    if ($null -ne $openButton) {
        $edit.SetFocus()
        Start-Sleep -Milliseconds 150
        for ($i = 0; $i -lt 6; $i++) {
            [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
            Start-Sleep -Milliseconds 150
            if ([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -eq 'Open auxiliary window') {
                $reachedOpen = $true
                break
            }
        }
        if ($reachedOpen) {
            [System.Windows.Forms.SendKeys]::SendWait(' ')
            $openedByKeyboard = Wait-Until { [NativeWebGpuUiValidation]::FirstSdlWindow($process.Id, $main) -ne [IntPtr]::Zero } 5000
        }
    }
    $openPath = "keyboard Space after Tab (reachedOpen=$reachedOpen)"
    if (-not $openedByKeyboard -and $null -ne $openButton) {
        $openInvoke = $openButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $openInvoke.Invoke()
        $openPath = 'UIA Invoke fallback after keyboard Space did not open'
        $openedByKeyboard = Wait-Until { [NativeWebGpuUiValidation]::FirstSdlWindow($process.Id, $main) -ne [IntPtr]::Zero } 8000
    }
    Record 'auxiliary window open' ($(if ($openedByKeyboard) { 'PASS' } else { 'FAIL' })) $openPath

    if ($openedByKeyboard) {
        $child = [NativeWebGpuUiValidation]::FirstSdlWindow($process.Id, $main)
        $childTitle = [NativeWebGpuUiValidation]::TitleOf($child)
        Record 'auxiliary window title' ($(if ($childTitle -like '*auxiliary*') { 'PASS' } else { 'FAIL' })) "title='$childTitle'"
        $childRoot = [System.Windows.Automation.AutomationElement]::FromHandle($child)
        $childTreePath = Join-Path $OutputDir "$Backend-uia-auxiliary.txt"
        $childLines = Dump-UiaTree $childRoot $childTreePath
        Record 'auxiliary UIA tree dump' ($(if ($childLines -ge 4) { 'PASS' } else { 'FAIL' })) "$childLines elements -> $childTreePath"

        $childClose = Find-ElementByName $childRoot 'Close auxiliary window' ([System.Windows.Automation.ControlType]::Button)
        Record 'auxiliary close control exposed' ($(if ($null -ne $childClose) { 'PASS' } else { 'FAIL' })) "name='Close auxiliary window'"

        $before = [NativeWebGpuUiValidation]::Rect($child)
        [void][NativeWebGpuUiValidation]::SetWindowPos($child, [IntPtr]::Zero, $before[0], $before[1], 760, 420, 0x0006)
        $resized = Wait-Until {
            $r = [NativeWebGpuUiValidation]::Rect($child)
            [Math]::Abs($r[2] - 760) -le 20 -and [Math]::Abs($r[3] - 420) -le 40
        } 5000
        $after = [NativeWebGpuUiValidation]::Rect($child)
        Record 'auxiliary window resize' ($(if ($resized) { 'PASS' } else { 'FAIL' })) "before=$($before[2])x$($before[3]) after=$($after[2])x$($after[3])"
        Start-Sleep -Milliseconds 700

        if (-not $NoScreenshots) {
            $shot = Join-Path $OutputDir "$Backend-auxiliary.png"
            $saved = [NativeWebGpuUiValidation]::SavePng($child, $shot)
            Record 'auxiliary screenshot' ($(if ($saved) { 'PASS' } else { 'UNTESTED' })) $(if ($saved) { $shot } else { 'PrintWindow capture unavailable' })
        }

        if ($null -ne $childClose) {
            $closeInvoke = $childClose.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $closeInvoke.Invoke()
            $closed = Wait-Until { -not [NativeWebGpuUiValidation]::IsWindow($child) } 5000
            Record 'auxiliary window close' ($(if ($closed) { 'PASS' } else { 'FAIL' })) "hwnd=$child destroyed=$closed"
        }
    }

    if (-not $NoScreenshots) {
        $shot = Join-Path $OutputDir "$Backend-main.png"
        $saved = [NativeWebGpuUiValidation]::SavePng($main, $shot)
        Record 'main window screenshot' ($(if ($saved) { 'PASS' } else { 'UNTESTED' })) $(if ($saved) { $shot } else { 'PrintWindow capture unavailable' })
    }

    # Application text must survive the auxiliary-window lifecycle.
    $textSurvived = $valuePattern.Current.Value -eq 'Native input ok'
    Record 'primary state preserved after auxiliary lifecycle' ($(if ($textSurvived) { 'PASS' } else { 'FAIL' })) "value='$($valuePattern.Current.Value)'"

    $mainRoot = [System.Windows.Automation.AutomationElement]::FromHandle($main)
    $finalTree = Join-Path $OutputDir "$Backend-uia-final.txt"
    $finalLines = Dump-UiaTree $mainRoot $finalTree
    Record 'final UIA tree dump' ($(if ($finalLines -gt 5) { 'PASS' } else { 'FAIL' })) "$finalLines elements -> $finalTree"

    # Clipboard: this fixture has no clipboard control and the native text
    # field does not implement Ctrl+C/Ctrl+V (host/clipboard is only wired to
    # the browser example). Record explicitly rather than claiming a check.
    Record 'clipboard shortcuts' 'UNTESTED' 'no clipboard control in examples/16; native text editing has no clipboard path'

    Record 'IME composition' 'UNTESTED' 'Unicode WM_CHAR delivery tested; no IME composition session was driven'

    [void][NativeWebGpuUiValidation]::PostMessage($main, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    $exited = $process.WaitForExit(8000)
    Record 'window close and process exit' ($(if ($exited -and $process.ExitCode -eq 0) { 'PASS' } else { 'FAIL' })) "exited=$exited code=$(if ($exited) { $process.ExitCode } else { '<running>' })"
} catch {
    Record 'automation exception' 'FAIL' $_.Exception.Message
    Log $_.ScriptStackTrace
} finally {
    if ($child -ne [IntPtr]::Zero -and [NativeWebGpuUiValidation]::IsWindow($child)) {
        [void][NativeWebGpuUiValidation]::PostMessage($child, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    }
    if ($main -ne [IntPtr]::Zero -and [NativeWebGpuUiValidation]::IsWindow($main)) {
        [void][NativeWebGpuUiValidation]::PostMessage($main, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    }
    if (-not $process.HasExited -and -not $process.WaitForExit(3000)) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()

    Log ''
    Log 'SUMMARY'
    $checks | ForEach-Object { Log ("{0,-8} {1} -- {2}" -f $_.Status, $_.Name, $_.Detail) }
    $failures = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    Log "failures=$failures"
    Set-Content -LiteralPath $logPath -Value $script:log -Encoding UTF8
    Log "log=$logPath"
    exit $(if ($failures -gt 0) { 1 } else { 0 })
}
