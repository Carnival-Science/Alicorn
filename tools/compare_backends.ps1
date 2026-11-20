<#
.SYNOPSIS
    Run one application scene on several renderer/backend hosts and produce a
    matched full-frame and per-region capture comparison.

.DESCRIPTION
    This is the standard evidence harness for renderer-parity slices: it launches
    the same executable with the same restored state, capture arguments, window
    size and DPI for every backend, presses F12 through the host's capture
    shortcut, proves the scene settled (two consecutive captures byte-identical),
    and diffs each candidate against the reference frame.

    The application and its state are caller-supplied so the harness stays
    usable for any Alicorn consumer:

      * -Backends supplies the name, environment and extra arguments for each
        leg. The leg named by -Reference is the baseline.
      * -StateFiles supplies application state to install for the run
        (@{ Path = <live path>; Source = <fixture path> }). Every installed file
        is backed up and restored byte-for-byte in a finally block; a failed
        restore throws.
      * -Env supplies environment common to every leg (for example a workspace).
      * -RegionsFile supplies named rectangles for supplementary statistics.

    Captures land in <OutputDir>/<backend>/capture and the comparison report in
    <OutputDir>/report.md plus report.json.

.PARAMETER Backends
    Array of hashtables: @{ Name = 'webgpu-d3d12'; Env = @{ SCRATCHPAD_RENDERER = 'webgpu' }; Args = @('--backend=d3d12') }.

.PARAMETER StateFiles
    Array of hashtables: @{ Path = "$env:APPDATA\Scratchpad\session.json"; Source = 'C:\fixtures\session-go.json' }.
    A state file whose Source is empty is removed for the run and restored after.

.PARAMETER SettleSeconds
    Seconds between process start and the first F12. The default leaves time for
    a restored session, theme compilation and font initialization.

.PARAMETER Captures
    Consecutive F12 captures used to prove the frame settled. Requires at least 2
    for the settled-frame assertion.

.EXAMPLE
    .\tools\compare_backends.ps1 `
        -Executable C:\work\scratchpad\out\c4\scratchpad-alicorn.exe `
        -Scene go-editor -Theme cool-light `
        -Backends @(
            @{ Name = 'sdl-gpu'; Env = @{ SCRATCHPAD_RENDERER = 'sdl-gpu' } },
            @{ Name = 'webgpu-d3d12'; Env = @{ SCRATCHPAD_RENDERER = 'webgpu' }; Args = @('--backend=d3d12') }
        ) `
        -Reference sdl-gpu `
        -StateFiles @(@{ Path = "$env:APPDATA\Scratchpad\session.json"; Source = 'fixtures\session-go.json' }) `
        -RegionsFile .\tools\compare_regions.scratchpad-1216x799.json `
        -OutputDir out\compare\go-cool-light
#>
param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][object[]]$Backends,
    [string]$Reference = 'sdl-gpu',
    [hashtable]$Env = @{},
    [object[]]$StateFiles = @(),
    [string]$Scene = 'scene',
    [string]$Theme = '',
    [string]$OutputDir,
    [int]$SettleSeconds = 10,
    [int]$Captures = 2,
    [int]$CaptureGapMs = 1200,
    [int]$WindowTimeoutSeconds = 30,
    [int]$CaptureTimeoutSeconds = 20,
    [string]$RegionsFile,
    [hashtable]$Metadata = @{},
    [switch]$AllowMismatch,
    [switch]$KeepProcessLogs
)

$ErrorActionPreference = 'Stop'
# PowerShell can keep its location and the process working directory apart, so
# make relative -OutputDir/-RegionsFile/state paths resolve the way the caller
# typed them and give child processes the same working directory.
[IO.Directory]::SetCurrentDirectory((Get-Location).Path)
Add-Type -AssemblyName System.Windows.Forms

if ($Captures -lt 2) { throw 'compare_backends: -Captures must be at least 2 to prove the frame settled.' }
if (-not $OutputDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeScene = ($Scene -replace '[^A-Za-z0-9._-]', '-')
    $safeTheme = ($Theme -replace '[^A-Za-z0-9._-]', '-')
    $suffix = if ($safeTheme) { "$safeScene-$safeTheme" } else { $safeScene }
    $OutputDir = Join-Path 'out\backend-compare' "$suffix-$stamp"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$Executable = [IO.Path]::GetFullPath($Executable)
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "compare_backends: executable not found: $Executable" }
if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Executable }
$WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)

$Python = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $Python) { throw 'compare_backends: python is required for tools/ppm_diff.py.' }
$DiffTool = Join-Path $PSScriptRoot 'ppm_diff.py'

function Get-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-JsonFile([string]$Path, $Value) {
    $text = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

# ---- install state fixtures -------------------------------------------------

$stateManifest = @()
$stateBackupDir = Join-Path $OutputDir 'state-backup'
if ($StateFiles.Count -gt 0) { New-Item -ItemType Directory -Force -Path $stateBackupDir | Out-Null }
foreach ($entry in $StateFiles) {
    if (-not $entry.Path) { throw 'compare_backends: each -StateFiles entry needs Path.' }
    $path = [IO.Path]::GetFullPath([string]$entry.Path)
    $source = if ($entry.Source) { [IO.Path]::GetFullPath([string]$entry.Source) } else { '' }
    $backup = Join-Path $stateBackupDir (Split-Path -Leaf $path)
    $record = [pscustomobject]@{
        Path   = $path
        Backup = $backup
        Source = $source
        Existed = Test-Path -LiteralPath $path -PathType Leaf
        Hash   = Get-Hash $path
    }
    if ($record.Existed) { Copy-Item -LiteralPath $path -Destination $backup -Force }
    $stateManifest += $record
    if ($source) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "compare_backends: state fixture not found: $source" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Copy-Item -LiteralPath $source -Destination $path -Force
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}
if ($stateManifest.Count -gt 0) {
    Write-JsonFile (Join-Path $OutputDir 'state-manifest.json') @(
        $stateManifest | ForEach-Object { [pscustomobject]@{ path = $_.Path; fixture = $_.Source; existed = $_.Existed; original_sha256 = $_.Hash } }
    )
}

function Restore-State {
    foreach ($record in $stateManifest) {
        if ($record.Existed) {
            Copy-Item -LiteralPath $record.Backup -Destination $record.Path -Force
        } elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) {
            Remove-Item -LiteralPath $record.Path -Force
        }
        $restored = Get-Hash $record.Path
        if ($restored -ne $record.Hash) {
            throw "compare_backends: failed to restore $($record.Path) (expected $($record.Hash), got $restored)"
        }
    }
}

function Get-WindowHandle([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return [IntPtr]::Zero }
    $process.Refresh()
    return $process.MainWindowHandle
}

function Focus-Window([int]$ProcessId) {
    $shell = New-Object -ComObject WScript.Shell
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ($shell.AppActivate($ProcessId)) {
            Start-Sleep -Milliseconds 500
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-CaptureFrames([string]$CaptureDir) {
    if (-not (Test-Path -LiteralPath $CaptureDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $CaptureDir -Directory |
        ForEach-Object {
            $ppm = Join-Path $_.FullName 'screenshot.ppm'
            if (Test-Path -LiteralPath $ppm -PathType Leaf) { Get-Item -LiteralPath $ppm }
        } |
        Sort-Object LastWriteTimeUtc)
}

function Invoke-Leg($leg) {
    $name = [string]$leg.Name
    $legDir = Join-Path $OutputDir $name
    $captureDir = Join-Path $legDir 'capture'
    New-Item -ItemType Directory -Force -Path $captureDir | Out-Null

    $savedEnvironment = @{}
    foreach ($key in $Env.Keys) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    if ($leg.Env) {
        foreach ($key in $leg.Env.Keys) {
            if (-not $savedEnvironment.ContainsKey($key)) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
        }
    }

    $arguments = @('--diagnostics', "--capture-dir=$captureDir", '--capture-after=600')
    if ($leg.Args) { $arguments += $leg.Args }
    if ($leg.Arguments) { $arguments += $leg.Arguments }

    $logOut = Join-Path $legDir 'stdout.txt'
    $logErr = Join-Path $legDir 'stderr.txt'
    $process = $null
    try {
        foreach ($key in $Env.Keys) { [Environment]::SetEnvironmentVariable($key, [string]$Env[$key], 'Process') }
        if ($leg.Env) {
            foreach ($key in $leg.Env.Keys) { [Environment]::SetEnvironmentVariable($key, [string]$leg.Env[$key], 'Process') }
        }
        $process = Start-Process -FilePath $Executable -ArgumentList $arguments `
            -WorkingDirectory $WorkingDirectory -PassThru `
            -RedirectStandardOutput $logOut -RedirectStandardError $logErr
        Write-Host ("compare_backends: [$name] pid {0} {1}" -f $process.Id, ($arguments -join ' '))

        $deadline = (Get-Date).AddSeconds($WindowTimeoutSeconds)
        $handle = [IntPtr]::Zero
        while ((Get-Date) -lt $deadline) {
            if ($process.HasExited) { throw "compare_backends: [$name] exited during startup ($($process.ExitCode)). See $logErr" }
            $handle = Get-WindowHandle $process.Id
            if ($handle -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 300
        }
        if ($handle -eq [IntPtr]::Zero) { throw "compare_backends: [$name] did not create a window within $WindowTimeoutSeconds s." }

        Start-Sleep -Seconds $SettleSeconds
        if (-not (Focus-Window $process.Id)) { throw "compare_backends: [$name] could not be focused for the F12 capture." }

        $frames = @()
        for ($capture = 0; $capture -lt $Captures; $capture++) {
            $before = @(Get-CaptureFrames $captureDir | ForEach-Object { $_.FullName })
            [System.Windows.Forms.SendKeys]::SendWait('{F12}')
            $captureDeadline = (Get-Date).AddSeconds($CaptureTimeoutSeconds)
            $newFrame = $null
            while ((Get-Date) -lt $captureDeadline) {
                $candidates = @(Get-CaptureFrames $captureDir | Where-Object { $before -notcontains $_.FullName })
                if ($candidates.Count -gt 0) {
                    $newFrame = $candidates[-1]
                    $size = $newFrame.Length
                    Start-Sleep -Milliseconds 250
                    if ($newFrame.Length -eq $size -and $size -gt 1024) { break }
                }
                Start-Sleep -Milliseconds 200
            }
            if (-not $newFrame) { throw "compare_backends: [$name] F12 capture $($capture + 1) did not produce screenshot.ppm." }
            $frames += $newFrame
            if ($capture + 1 -lt $Captures) { Start-Sleep -Milliseconds $CaptureGapMs }
        }

        $hashes = @($frames | ForEach-Object { Get-Hash $_.FullName })
        $settled = $true
        for ($index = 1; $index -lt $hashes.Count; $index++) {
            if ($hashes[$index] -ne $hashes[0]) { $settled = $false }
        }
        if (-not $settled) { throw "compare_backends: [$name] frames did not settle across $Captures captures: $($hashes -join ', ')" }

        $final = $frames[-1]
        $bundle = Split-Path -Parent $final.FullName
        $windowsJson = Join-Path $bundle 'windows.json'
        $windowInfo = $null
        if (Test-Path -LiteralPath $windowsJson -PathType Leaf) {
            $windowInfo = Get-Content -LiteralPath $windowsJson -Raw | ConvertFrom-Json
        }
        return [pscustomobject]@{
            Name = $name
            Pid = $process.Id
            Arguments = $arguments
            Frame = $final.FullName
            FrameSha256 = $hashes[-1]
            Settled = $settled
            Captures = $frames.Count
            Bundle = $bundle
            Window = $windowInfo
        }
    } finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            try { $process.WaitForExit(5000) | Out-Null } catch { }
        }
        foreach ($key in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
        }
    }
}

# ---- run every leg ----------------------------------------------------------

$results = @()
$reportRows = @()
try {
    foreach ($leg in $Backends) {
        if (-not $leg.Name) { throw 'compare_backends: each -Backends entry needs Name.' }
        $results += Invoke-Leg $leg
    }

    $referenceResult = $results | Where-Object { $_.Name -eq $Reference } | Select-Object -First 1
    if (-not $referenceResult) { throw "compare_backends: -Reference '$Reference' did not produce a capture." }

    $sizes = @($results | ForEach-Object { if ($_.Window) { "{0}x{1}" -f $_.Window.primary.pixel_width, $_.Window.primary.pixel_height } else { '' } } | Select-Object -Unique)
    if ($sizes.Count -gt 1) { throw "compare_backends: backends captured different window sizes: $($sizes -join ', ')" }

    $comparisons = @()
    foreach ($result in $results) {
        if ($result.Name -eq $Reference) { continue }
        $jsonOut = Join-Path $OutputDir ("diff-$($result.Name)-vs-$Reference.json")
        $mdOut = Join-Path $OutputDir ("diff-$($result.Name)-vs-$Reference.md")
        $diffArguments = @($DiffTool, '--a', $referenceResult.Frame, '--b', $result.Frame,
            '--label-a', $result.Name, '--label-b', $Reference,
            '--json-out', $jsonOut, '--md-out', $mdOut, '--quiet')
        if ($RegionsFile) { $diffArguments += @('--regions', ([IO.Path]::GetFullPath($RegionsFile))) }
        & $Python.Source @diffArguments
        if ($LASTEXITCODE -ne 0) { throw "compare_backends: ppm_diff failed for $($result.Name) (exit $LASTEXITCODE)." }
        $diff = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json
        $comparisons += [pscustomobject]@{
            backend = $result.Name
            reference = $Reference
            frame = $result.Frame
            frame_sha256 = $result.FrameSha256
            settled = $result.Settled
            size = $diff.size
            diff = $diff
            markdown = $mdOut
        }
    }

    $meta = [ordered]@{
        harness = 'tools/compare_backends.ps1'
        executable = $Executable
        executable_sha256 = Get-Hash $Executable
        scene = $Scene
        theme = $Theme
        reference = $Reference
        regions = if ($RegionsFile) { [IO.Path]::GetFullPath($RegionsFile) } else { $null }
        settle_seconds = $SettleSeconds
        captures = $Captures
        window_sizes = $sizes
        started = (Get-Date).ToString('o')
    }
    foreach ($key in $Metadata.Keys) { $meta[$key] = $Metadata[$key] }

    $report = [ordered]@{
        metadata = $meta
        legs = @($results | ForEach-Object {
            $window = $null
            if ($_.Window) {
                $window = [ordered]@{
                    logical = "$($_.Window.primary.logical_width)x$($_.Window.primary.logical_height)"
                    pixel = "$($_.Window.primary.pixel_width)x$($_.Window.primary.pixel_height)"
                    density = $_.Window.primary.pixel_density
                    display_scale = $_.Window.primary.display_scale
                }
            }
            [ordered]@{
                name = $_.Name
                frame = $_.Frame
                frame_sha256 = $_.FrameSha256
                settled = $_.Settled
                capture_count = $_.Captures
                arguments = $_.Arguments
                window = $window
            }
        })
        comparisons = $comparisons
    }
    Write-JsonFile (Join-Path $OutputDir 'report.json') $report

    $lines = @()
    $lines += "# Matched backend comparison: $Scene$(if ($Theme) { " / $Theme" })"
    $lines += ''
    $lines += "Harness: ``tools/compare_backends.ps1``  "
    $lines += "Executable: ``$Executable`` ($(Get-Hash $Executable))  "
    $lines += "Reference: $Reference  "
    $lines += "Window: $($sizes -join ', ')  "
    $lines += "Captures: $Captures per leg, settled frame required  "
    $lines += ''
    foreach ($key in $Metadata.Keys) { $lines += "- $($key): $($Metadata[$key])" }
    if ($Metadata.Keys.Count -gt 0) { $lines += '' }
    foreach ($comparison in $comparisons) {
        $lines += "## $($comparison.backend) vs $Reference"
        $lines += ''
        $lines += Get-Content -LiteralPath $comparison.markdown -Raw
    }
    [IO.File]::WriteAllText((Join-Path $OutputDir 'report.md'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host "compare_backends: report $OutputDir\report.md"
    $mismatches = @($comparisons | Where-Object { $_.diff.full.differing_channels -ne 0 })
    foreach ($comparison in $comparisons) {
        $full = $comparison.diff.full
        Write-Host ("compare_backends: {0} vs {1}: {2} / {3} channels differ (max {4})" -f `
            $comparison.backend, $Reference, $full.differing_channels, $full.channels, $full.max_delta)
    }
    if ($mismatches.Count -gt 0 -and -not $AllowMismatch) {
        throw "compare_backends: $($mismatches.Count) backend(s) differ from $Reference. Inspect $OutputDir\report.md."
    }
}
finally {
    Restore-State
    if (-not $KeepProcessLogs) {
        foreach ($file in Get-ChildItem -LiteralPath $OutputDir -Recurse -Filter '*.txt' -ErrorAction SilentlyContinue) {
            if ($file.Length -eq 0) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
}
