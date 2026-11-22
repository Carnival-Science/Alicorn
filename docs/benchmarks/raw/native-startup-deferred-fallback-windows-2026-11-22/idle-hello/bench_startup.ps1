<#
.SYNOPSIS
  Fresh-process startup attribution for the native SDL_GPU host.

.DESCRIPTION
  Launches each configured application repeatedly and records, per launch:
    * every SDL application PASS marker (startup phases, window shown,
      first application submit, first input-ready pump, first diagnostics),
    * the host's alicorn_startup_attribution line (declared eager resources
      and runtime requested bytes),
    * sampled working set / private bytes / CPU time,
    * GPU Process Memory dedicated and shared usage.

  Every launch is a fresh process. Launches are labelled:
    session-first        first process of this script session, no warm pass
    file-cache-warmup    one unmeasured launch after session-first
    warm-order           measured launches; the executable file is in cache

  No reboot, cache purge or page-file control is performed. These are
  warm-order numbers, never cold-start claims.

  The process's PASS line is detected while the process is still alive so
  "settle" memory is sampled before the shutdown work (GPU idle wait,
  device/window destruction) that follows the marker line.

.EXAMPLE
  .\tools\bench_startup.ps1 -App all -Runs 12 `
      -ScratchpadExe "$env:TEMP\startup-attribution-172\scratchpad\out\alicorn\scratchpad.exe" `
      -PunksExe "$env:TEMP\startup-attribution-172\punks\target\windows-x86_64\release\punks.exe" `
      -PunksFolder "$env:TEMP\startup-attribution-172\punks\crates\punks-audio\tests\fixtures"

  Build prerequisites (not performed by this runner):
    Hello:      odin build examples\01_hello -collection:alicorn=<repo> ... -o:speed
    Scratchpad: go run ./cmd/alicorn-dev build --alicorn-root <repo> \
                  --allow-alicorn-revision --release --renderer=sdl-gpu
    Punks:      cargo build -p punks-caliber --release, then odin build
                  punks-standalone/odin -collection:alicorn=<repo> \
                  -collection:alikit=<punks>/vendor/alicorn-kit -o:speed
#>
param(
    [ValidateSet('hello', 'scratchpad', 'punks', 'all')]
    [string]$App = 'all',

    [int]$Runs = 12,

    [int]$TimeoutSeconds = 90,

    [string]$ResultsDirectory,

    [string]$HelloExe,
    [string]$ScratchpadExe,
    [string]$PunksExe,

    [string]$ScratchpadWorkspace,
    [string]$PunksFolder,

    [switch]$SessionFirst,

    # Paired A/B mode: every measured round launches the primary arm and the
    # compare arm back to back, alternating which arm goes first. Both arms use
    # the same executable; only the extra arguments differ.
    [switch]$Paired,
    [string]$PrimaryArmLabel = 'prototype',
    [string]$CompareArmLabel = 'baseline',
    [string[]]$PrimaryArmArguments = @(),
    [string[]]$CompareArmArguments = @()
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $RepoRoot 'docs\benchmarks\raw\native-startup-attribution-windows-2026-11-21'
}
$ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
$LogRoot = Join-Path $ResultsDirectory 'logs'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$Utf8 = [System.Text.UTF8Encoding]::new($false)
$Script:CounterReliability = New-Object System.Collections.Generic.List[string]

function Get-KeyValues {
    param([string]$Line, [int]$Start = 1)
    $values = @{}
    $tokens = $Line -split '\s+'
    for ($i = $Start; $i + 1 -lt $tokens.Length; $i += 2) {
        $values[$tokens[$i]] = $tokens[$i + 1]
    }
    return $values
}

function Get-Percentile {
    param([double[]]$Values, [double]$Fraction)
    if ($null -eq $Values -or $Values.Length -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    if ($ordered.Length -eq 1) { return $ordered[0] }
    $position = $Fraction * ($ordered.Length - 1)
    $lower = [int][Math]::Floor($position)
    $upper = [int][Math]::Ceiling($position)
    if ($lower -eq $upper) { return $ordered[$lower] }
    $weight = $position - $lower
    return $ordered[$lower] * (1.0 - $weight) + $ordered[$upper] * $weight
}

function Get-MetricSummary {
    param([object[]]$Samples, [string]$Name)
    $values = @()
    foreach ($sample in $Samples) {
        if ($null -eq $sample) { continue }
        $property = $sample.PSObject.Properties[$Name]
        if ($null -eq $property) { continue }
        $value = $property.Value
        if ($null -eq $value) { continue }
        $values += [double]$value
    }
    if ($values.Length -eq 0) { return $null }
    return [pscustomobject]@{
        n = $values.Length
        min = ($values | Measure-Object -Minimum).Minimum
        p50 = Get-Percentile $values 0.50
        p95 = Get-Percentile $values 0.95
        max = ($values | Measure-Object -Maximum).Maximum
    }
}

function Get-GpuProcessMemory {
    param([int]$ProcessId)
    $dedicated = [int64]0
    $shared = [int64]0
    $matched = 0
    $ok = $false
    try {
        $counterPaths = @(
            ("\GPU Process Memory(pid_{0}*)\Dedicated Usage" -f $ProcessId),
            ("\GPU Process Memory(pid_{0}*)\Shared Usage" -f $ProcessId)
        )
        $sample = Get-Counter -Counter $counterPaths -MaxSamples 1 -ErrorAction Stop
        foreach ($entry in $sample.CounterSamples) {
            if ($entry.Path -like '*dedicated usage*') {
                $dedicated += [int64]$entry.CookedValue
                $matched += 1
            } elseif ($entry.Path -like '*shared usage*') {
                $shared += [int64]$entry.CookedValue
                $matched += 1
            }
        }
        $ok = $matched -gt 0
    } catch {
        if ($Script:CounterReliability.Count -eq 0 -or $Script:CounterReliability[-1] -notlike 'GPU Process Memory*') {
            $Script:CounterReliability.Add("GPU Process Memory counter sample failed: $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{ ok = $ok; dedicated = $dedicated; shared = $shared }
}

function Get-ExecutableFacts {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ path = $Path; exists = $false; size_bytes = $null; sha256 = $null }
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $full
    return [pscustomobject]@{
        path = $full
        exists = $true
        size_bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Invoke-StartupLaunch {
    param(
        [string]$Label,
        [string]$Phase,
        [int]$Index,
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [string]$Arm = ''
    )

    $runName = '{0}-{1:D2}' -f $Phase, $Index
    if (-not [string]::IsNullOrWhiteSpace($Arm)) {
        $runName = '{0}-{1}-{2:D2}' -f $Phase, $Arm, $Index
    }
    $runLog = Join-Path $LogRoot ('{0}-{1}.log' -f $Label, $runName)
    $stdoutLog = Join-Path $LogRoot ('{0}-{1}.stdout.log' -f $Label, $runName)
    $stderrLog = Join-Path $LogRoot ('{0}-{1}.stderr.log' -f $Label, $runName)
    if (Test-Path $stdoutLog) { Remove-Item -LiteralPath $stdoutLog -Force }
    if (Test-Path $stderrLog) { Remove-Item -LiteralPath $stderrLog -Force }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = ($Arguments -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) { $startInfo.Environment[$key] = [string]$Environment[$key] }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw "Could not start $Label $runName" }
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    $stdoutRead = $process.StandardOutput.ReadLineAsync()
    $stderrRead = $process.StandardError.ReadLineAsync()

    $samples = New-Object System.Collections.Generic.List[object]
    $peakWorkingSet = [int64]0
    $peakPrivate = [int64]0
    $peakGpuDedicated = [int64]0
    $peakGpuShared = [int64]0
    $lastWorkingSet = [int64]0
    $lastPrivate = [int64]0
    $lastGpuDedicated = [int64]0
    $lastGpuShared = [int64]0
    $passSeen = $false
    $passElapsedMs = $null
    $settleWorkingSet = $null
    $settlePrivate = $null
    $settleGpuDedicated = $null
    $settleGpuShared = $null
    $settleCpuSeconds = $null
    $lastGpuSampleMs = -1000.0
    $timedOut = $false

    while (-not $process.HasExited) {
        $process.Refresh()
        try {
            $lastWorkingSet = [int64]$process.WorkingSet64
            $lastPrivate = [int64]$process.PrivateMemorySize64
            if ($lastWorkingSet -gt $peakWorkingSet) { $peakWorkingSet = $lastWorkingSet }
            if ($lastPrivate -gt $peakPrivate) { $peakPrivate = $lastPrivate }
        } catch { }

        $elapsedMs = $watch.Elapsed.TotalMilliseconds
        if (($elapsedMs - $lastGpuSampleMs) -ge 500.0) {
            $lastGpuSampleMs = $elapsedMs
            $gpu = Get-GpuProcessMemory -ProcessId $process.Id
            if ($gpu.ok) {
                $lastGpuDedicated = $gpu.dedicated
                $lastGpuShared = $gpu.shared
                if ($lastGpuDedicated -gt $peakGpuDedicated) { $peakGpuDedicated = $lastGpuDedicated }
                if ($lastGpuShared -gt $peakGpuShared) { $peakGpuShared = $lastGpuShared }
            }
        }

        if ($null -ne $stdoutRead -and $stdoutRead.IsCompleted) {
            if ($stdoutRead.IsFaulted) {
                $stdoutRead = $null
            } elseif ($stdoutRead.Result -eq $null) {
                $stdoutRead = $null
            } else {
                $line = $stdoutRead.Result
                $stdoutLines.Add($line)
                if (-not $passSeen -and $line.StartsWith('SDL application PASS ')) {
                    $passSeen = $true
                    # Recompute: a slow GPU counter query earlier in this
                    # iteration can otherwise leave the timestamp stale by ~1 s.
                    $passElapsedMs = $watch.Elapsed.TotalMilliseconds
                    $settleWorkingSet = $lastWorkingSet
                    $settlePrivate = $lastPrivate
                    $settleGpuDedicated = $lastGpuDedicated
                    $settleGpuShared = $lastGpuShared
                    try { $settleCpuSeconds = $process.TotalProcessorTime.TotalSeconds } catch { }
                }
                $stdoutRead = $process.StandardOutput.ReadLineAsync()
            }
        }
        if ($null -ne $stderrRead -and $stderrRead.IsCompleted) {
            if ($stderrRead.IsFaulted) {
                $stderrRead = $null
            } elseif ($stderrRead.Result -eq $null) {
                $stderrRead = $null
            } else {
                $stderrLines.Add($stderrRead.Result)
                $stderrRead = $process.StandardError.ReadLineAsync()
            }
        }

        if ($elapsedMs -ge ($TimeoutSeconds * 1000.0)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            break
        }
        Start-Sleep -Milliseconds 10
    }
    $process.WaitForExit()
    $watch.Stop()
    # Drain complete lines that arrived after the last asynchronous read. Do not
    # call ReadToEnd here: it would contend with the pending ReadLineAsync.
    $drainDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ($null -ne $stdoutRead -and [DateTime]::UtcNow -lt $drainDeadline) {
        if (-not $stdoutRead.Wait(50)) { break }
        if ($stdoutRead.Result -eq $null) { $stdoutRead = $null; break }
        $stdoutLines.Add($stdoutRead.Result)
        $stdoutRead = $process.StandardOutput.ReadLineAsync()
    }
    while ($null -ne $stderrRead -and [DateTime]::UtcNow -lt $drainDeadline) {
        if (-not $stderrRead.Wait(50)) { break }
        if ($stderrRead.Result -eq $null) { $stderrRead = $null; break }
        $stderrLines.Add($stderrRead.Result)
        $stderrRead = $process.StandardError.ReadLineAsync()
    }
    $stdout = ($stdoutLines.ToArray()) -join [Environment]::NewLine
    $stderr = ($stderrLines.ToArray()) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($stdoutLog, $stdout, $Utf8)
    [System.IO.File]::WriteAllText($stderrLog, $stderr, $Utf8)
    $log = $stdout + $stderr
    [System.IO.File]::WriteAllText($runLog, $log, $Utf8)

    $passLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('SDL application PASS ') } | Select-Object -Last 1)
    $attributionLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('alicorn_startup_attribution ') } | Select-Object -Last 1)
    if ($passLine.Count -eq 0) {
        throw "$Label $runName omitted the SDL application PASS line (exit $($process.ExitCode), timed out $timedOut). See $runLog"
    }

    $markers = Get-KeyValues $passLine[0] 3
    $attribution = @{}
    if ($attributionLine.Count -gt 0) { $attribution = Get-KeyValues $attributionLine[0] 1 }

    $originNs = [int64]$markers['startup_origin_unix_ns']
    $originUtc = if ($originNs -gt 0) {
        [DateTimeOffset]::FromUnixTimeMilliseconds([int64]($originNs / 1000000)).UtcDateTime
    } else { $null }
    $preOriginMs = $null
    if ($null -ne $originUtc) {
        try { $preOriginMs = ($originUtc - $process.StartTime.ToUniversalTime()).TotalMilliseconds } catch { }
    }
    $cpuSeconds = $null
    try { $cpuSeconds = $process.TotalProcessorTime.TotalSeconds } catch { }
    $processStartUtc = $null
    try { $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch { }
    $shutdownAfterPassMs = $null
    if ($null -ne $passElapsedMs) {
        $shutdownAfterPassMs = $watch.Elapsed.TotalMilliseconds - $passElapsedMs
    }
    $cpuTotalMs = $null
    if ($null -ne $cpuSeconds) { $cpuTotalMs = $cpuSeconds * 1000.0 }
    $settleCpuMs = $null
    if ($null -ne $settleCpuSeconds) { $settleCpuMs = $settleCpuSeconds * 1000.0 }

    $result = [pscustomobject]@{
        app = $Label
        phase = $Phase
        arm = $Arm
        run = $runName
        exit_code = $process.ExitCode
        timed_out = $timedOut
        process_start_utc = $processStartUtc
        pass_detected_elapsed_ms = $passElapsedMs
        shutdown_after_pass_ms = $shutdownAfterPassMs
        pre_origin_ms = $preOriginMs
        process_wall_ms = $watch.Elapsed.TotalMilliseconds
        cpu_total_ms = $cpuTotalMs
        peak_working_set_bytes = $peakWorkingSet
        peak_private_bytes = $peakPrivate
        settle_working_set_bytes = $settleWorkingSet
        settle_private_bytes = $settlePrivate
        settle_cpu_ms = $settleCpuMs
        peak_gpu_dedicated_bytes = $peakGpuDedicated
        peak_gpu_shared_bytes = $peakGpuShared
        settle_gpu_dedicated_bytes = $settleGpuDedicated
        settle_gpu_shared_bytes = $settleGpuShared
        log = $runLog
    }
    foreach ($key in $markers.Keys) {
        if ($key -eq 'SDL' -or $key -eq 'application' -or $key -eq 'PASS') { continue }
        $result | Add-Member -NotePropertyName $key -NotePropertyValue $markers[$key] -Force
    }
    foreach ($key in $attribution.Keys) {
        $result | Add-Member -NotePropertyName ("attr_" + $key) -NotePropertyValue $attribution[$key] -Force
    }
    return $result
}

function Get-AppConfig {
    param([string]$Name)
    $exe = switch ($Name) {
        'hello' { $HelloExe }
        'scratchpad' { $ScratchpadExe }
        'punks' { $PunksExe }
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $exe = switch ($Name) {
            'hello' { Join-Path $RepoRoot 'out\hello.exe' }
            'scratchpad' { '' }
            'punks' { '' }
        }
    }
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        return $null
    }
    $exe = (Resolve-Path -LiteralPath $exe).Path
    $arguments = @()
    $environment = @{}
    $workingDirectory = Split-Path -Parent $exe
    switch ($Name) {
        'hello' {
            $arguments = @('--idle-validation-seconds=3')
        }
        'scratchpad' {
            $arguments = @('--idle-validation-seconds=3')
            if (-not [string]::IsNullOrWhiteSpace($ScratchpadWorkspace)) {
                $environment['SCRATCHPAD_ALICORN_WORKSPACE'] = $ScratchpadWorkspace
            }
            $environment.Remove('SCRATCHPAD_ALICORN_SMOKE')
        }
        'punks' {
            $arguments = @('--smoke')
            if (-not [string]::IsNullOrWhiteSpace($PunksFolder)) {
                $arguments += @('--folder', $PunksFolder)
            }
        }
    }
    return [pscustomobject]@{
        name = $Name
        executable = $exe
        arguments = $arguments
        working_directory = $workingDirectory
        environment = $environment
    }
}

function New-LaunchEnvironment {
    param([string]$Name, [string]$Phase, [int]$Index, [hashtable]$Base)
    $environment = @{}
    if ($null -ne $Base) {
        foreach ($key in $Base.Keys) { $environment[$key] = $Base[$key] }
    }
    if ($Name -eq 'scratchpad') {
        # Fresh application data per launch so a previous process's restored
        # session cannot change the measured startup path.
        $profile = Join-Path $ResultsDirectory ('profile\scratchpad-{0}-{1:D2}-{2}' -f $Phase, $Index, [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $profile | Out-Null
        $environment['APPDATA'] = $profile
        $environment['LOCALAPPDATA'] = $profile
    }
    return $environment
}

function Invoke-AppSuite {
    param([string]$Name, [int]$RunCount)

    $config = Get-AppConfig $Name
    if ($null -eq $config) {
        Write-Output "skip $Name (executable not configured or missing)"
        return $null
    }
    Write-Output "app ${Name}: $($config.executable)"
    $all = New-Object System.Collections.Generic.List[object]
    if ($Paired) {
        $arms = @(
            [pscustomobject]@{ label = $PrimaryArmLabel; arguments = $PrimaryArmArguments },
            [pscustomobject]@{ label = $CompareArmLabel; arguments = $CompareArmArguments }
        )
        # One unmeasured warmup per arm so both arms start from the same
        # executable-in-cache state.
        foreach ($arm in $arms) {
            $environment = New-LaunchEnvironment -Name $Name -Phase 'file-cache-warmup' -Index 1 -Base $config.environment
            $arguments = @($config.arguments) + @($arm.arguments)
            $warm = Invoke-StartupLaunch -Label $Name -Phase 'file-cache-warmup' -Index 1 -Executable $config.executable -Arguments $arguments -WorkingDirectory $config.working_directory -Environment $environment -Arm $arm.label
            $all.Add($warm)
            Write-Output ('  warmup {0} exit {1}, submit {2} ms' -f $arm.label, $warm.exit_code, ([double]$warm.first_application_submit_ns / 1e6))
        }
        for ($round = 1; $round -le $RunCount; $round++) {
            # Alternate order every round so a monotonic drift (thermals,
            # background load) cannot favour one arm.
            $order = if ($round % 2 -eq 1) { $arms } else { @($arms[1], $arms[0]) }
            foreach ($arm in $order) {
                $environment = New-LaunchEnvironment -Name $Name -Phase 'warm-order' -Index $round -Base $config.environment
                $arguments = @($config.arguments) + @($arm.arguments)
                $sample = Invoke-StartupLaunch -Label $Name -Phase 'warm-order' -Index $round -Executable $config.executable -Arguments $arguments -WorkingDirectory $config.working_directory -Environment $environment -Arm $arm.label
                $all.Add($sample)
                Write-Output ('  run {0:D2} {9} exit {1}, shown {2:N1} ms, submit {3:N1} ms, input {4:N1} ms, fonts {10:N1} ms, WS {5:N1} MiB, private {6:N1} MiB, GPU {7:N1}/{8:N1} MiB' -f `
                    $round, $sample.exit_code,
                    ([double]$sample.window_shown_ns / 1e6),
                    ([double]$sample.first_application_submit_ns / 1e6),
                    ([double]$sample.first_input_ready_ns / 1e6),
                    ([double]$sample.settle_working_set_bytes / 1MB),
                    ([double]$sample.settle_private_bytes / 1MB),
                    ([double]$sample.settle_gpu_dedicated_bytes / 1MB),
                    ([double]$sample.settle_gpu_shared_bytes / 1MB),
                    $arm.label,
                    ([double]$sample.fonts_ns / 1e6))
            }
        }
        return [pscustomobject]@{ config = $config; samples = $all }
    }
    if ($SessionFirst) {
        $environment = New-LaunchEnvironment -Name $Name -Phase 'session-first' -Index 1 -Base $config.environment
        $sample = Invoke-StartupLaunch -Label $Name -Phase 'session-first' -Index 1 -Executable $config.executable -Arguments $config.arguments -WorkingDirectory $config.working_directory -Environment $environment
        $all.Add($sample)
        Write-Output ('  session-first exit {0}, submit {1} ms, WS {2:N1} MiB' -f $sample.exit_code, ([double]$sample.first_application_submit_ns / 1e6), ([double]$sample.settle_working_set_bytes / 1MB))
    }
    $environment = New-LaunchEnvironment -Name $Name -Phase 'file-cache-warmup' -Index 1 -Base $config.environment
    $warm = Invoke-StartupLaunch -Label $Name -Phase 'file-cache-warmup' -Index 1 -Executable $config.executable -Arguments $config.arguments -WorkingDirectory $config.working_directory -Environment $environment
    $all.Add($warm)
    Write-Output ('  warmup exit {0}, submit {1} ms' -f $warm.exit_code, ([double]$warm.first_application_submit_ns / 1e6))
    for ($round = 1; $round -le $RunCount; $round++) {
        $environment = New-LaunchEnvironment -Name $Name -Phase 'warm-order' -Index $round -Base $config.environment
        $sample = Invoke-StartupLaunch -Label $Name -Phase 'warm-order' -Index $round -Executable $config.executable -Arguments $config.arguments -WorkingDirectory $config.working_directory -Environment $environment
        $all.Add($sample)
        Write-Output ('  run {0:D2} exit {1}, shown {2:N1} ms, submit {3:N1} ms, input {4:N1} ms, WS {5:N1} MiB, private {6:N1} MiB, GPU {7:N1}/{8:N1} MiB' -f `
            $round, $sample.exit_code,
            ([double]$sample.window_shown_ns / 1e6),
            ([double]$sample.first_application_submit_ns / 1e6),
            ([double]$sample.first_input_ready_ns / 1e6),
            ([double]$sample.settle_working_set_bytes / 1MB),
            ([double]$sample.settle_private_bytes / 1MB),
            ([double]$sample.settle_gpu_dedicated_bytes / 1MB),
            ([double]$sample.settle_gpu_shared_bytes / 1MB))
    }
    # One extra launch records the historical post-submit diagnostics marker.
    # It is excluded from the measured percentiles because capture perturbs the
    # run (bundle write plus screenshot readback).
    $captureDir = Join-Path $ResultsDirectory ('diagnostics\' + $Name)
    New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
    $diagArgs = @($config.arguments) + @('--diagnostics', '--capture-after=0', ('--capture-dir=' + $captureDir))
    $environment = New-LaunchEnvironment -Name $Name -Phase 'diagnostics-probe' -Index 1 -Base $config.environment
    $diagSample = Invoke-StartupLaunch -Label $Name -Phase 'diagnostics-probe' -Index 1 -Executable $config.executable -Arguments $diagArgs -WorkingDirectory $config.working_directory -Environment $environment
    $all.Add($diagSample)
    Write-Output ('  diagnostics probe exit {0}, diagnostics {1} ms' -f $diagSample.exit_code, ([double]$diagSample.first_diagnostics_ns / 1e6))
    return [pscustomobject]@{ config = $config; samples = $all }
}

$loadAtStart = $null
try { $loadAtStart = (Get-CimInstance Win32_Processor | Select-Object -First 1).LoadPercentage } catch { }

$apps = if ($App -eq 'all') { @('hello', 'scratchpad', 'punks') } else { @($App) }
$suites = @{}
$allSamples = New-Object System.Collections.Generic.List[object]
foreach ($name in $apps) {
    $suite = Invoke-AppSuite -Name $name -RunCount $Runs
    if ($null -ne $suite) {
        $suites[$name] = $suite
        foreach ($sample in $suite.samples) { $allSamples.Add($sample) }
    }
}

$metricNames = @(
    'process_wall_ms', 'pass_detected_elapsed_ms', 'pre_origin_ms', 'shutdown_after_pass_ms',
    'cpu_total_ms', 'settle_cpu_ms',
    'peak_working_set_bytes', 'settle_working_set_bytes',
    'peak_private_bytes', 'settle_private_bytes',
    'peak_gpu_dedicated_bytes', 'settle_gpu_dedicated_bytes',
    'peak_gpu_shared_bytes', 'settle_gpu_shared_bytes',
    'sdl_init_ns', 'window_create_ns', 'gpu_device_create_ns',
    'gpu_claim_window_ns', 'runtime_init_ns', 'host_loop_setup_ns',
    'app_init_ns', 'app_init_requested_bytes',
    'fonts_ns', 'fonts_requested_bytes',
    'renderers_make_ns', 'text_renderer_make_ns', 'chrome_text_make_ns',
    'surface_renderer_make_ns', 'solid_renderer_make_ns', 'build_initial_ns',
    'window_shown_ns', 'first_application_submit_ns', 'first_input_ready_ns',
    'first_diagnostics_ns'
)

function Get-ArmSummary {
    param([object[]]$Samples)
    $summary = @{}
    foreach ($metric in $metricNames) {
        $value = Get-MetricSummary -Samples $Samples -Name $metric
        if ($null -ne $value) { $summary[$metric] = $value }
    }
    $markerNames = @($Samples[0].PSObject.Properties.Name | Where-Object {
        $_ -notin $metricNames -and
        $_ -notin @('app','phase','arm','run','exit_code','timed_out','process_start_utc','pass_detected_elapsed_ms','log') -and
        $_ -notlike 'attr_*'
    })
    foreach ($marker in $markerNames) {
        if ($marker -in @('submissions','primary_gpu_submissions','retired','max_frames_in_flight','logical_resize_events','pixel_resize_events','scale_events','text_input_events','composition_events')) { continue }
        $value = Get-MetricSummary -Samples $Samples -Name $marker
        if ($null -ne $value) { $summary[$marker] = $value }
    }
    $attribution = [ordered]@{}
    foreach ($property in $Samples[0].PSObject.Properties) {
        if ($property.Name -like 'attr_*') {
            $attribution[$property.Name.Substring(5)] = $property.Value
        }
    }
    return [pscustomobject]@{
        measured_sample_count = $Samples.Count
        summary = $summary
        attribution = $attribution
    }
}

$summaries = @{}
foreach ($name in $suites.Keys) {
    $suite = $suites[$name]
    $measured = @($suite.samples | Where-Object { $_.phase -eq 'warm-order' })
    $diagProbe = @($suite.samples | Where-Object { $_.phase -eq 'diagnostics-probe' } | Select-Object -First 1)
    $diagnosticsProbe = $null
    if ($diagProbe.Count -gt 0) {
        $diagnosticsProbe = [pscustomobject]@{
            first_diagnostics_ns = $diagProbe[0].first_diagnostics_ns
            first_application_submit_ns = $diagProbe[0].first_application_submit_ns
            settle_working_set_bytes = $diagProbe[0].settle_working_set_bytes
            settle_private_bytes = $diagProbe[0].settle_private_bytes
            exit_code = $diagProbe[0].exit_code
        }
    }
    $entry = [pscustomobject]@{
        executable = $suite.config.executable
        arguments = $suite.config.arguments
        working_directory = $suite.config.working_directory
        environment = $suite.config.environment
        executable_facts = Get-ExecutableFacts $suite.config.executable
        samples = $suite.samples
        paired = [bool]$Paired
        primary_arm_arguments = @($PrimaryArmArguments)
        compare_arm_arguments = @($CompareArmArguments)
        diagnostics_probe = $diagnosticsProbe
    }
    if ($Paired) {
        $arms = [ordered]@{}
        foreach ($label in @($PrimaryArmLabel, $CompareArmLabel)) {
            $armSamples = @($measured | Where-Object { $_.arm -eq $label })
            if ($armSamples.Count -eq 0) { continue }
            $arms[$label] = Get-ArmSummary -Samples $armSamples
        }
        $entry | Add-Member -NotePropertyName arms -NotePropertyValue $arms
        $entry | Add-Member -NotePropertyName measured_sample_count -NotePropertyValue $measured.Count
    } else {
        $armSummary = Get-ArmSummary -Samples $measured
        $entry | Add-Member -NotePropertyName measured_sample_count -NotePropertyValue $armSummary.measured_sample_count
        $entry | Add-Member -NotePropertyName summary -NotePropertyValue $armSummary.summary
        $entry | Add-Member -NotePropertyName attribution -NotePropertyValue $armSummary.attribution
    }
    $summaries[$name] = $entry
    $csvPath = Join-Path $ResultsDirectory ('samples-{0}.csv' -f $name)
    $suite.samples | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
}

$loadAtEnd = $null
try { $loadAtEnd = (Get-CimInstance Win32_Processor | Select-Object -First 1).LoadPercentage } catch { }
$hostFacts = [pscustomobject]@{
    os = [System.Environment]::OSVersion.VersionString
    computer = $env:COMPUTERNAME
    processor = $env:PROCESSOR_IDENTIFIER
    logical_processors = [Environment]::ProcessorCount
    cpu_load_percent_at_start = $loadAtStart
    cpu_load_percent_at_end = $loadAtEnd
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
    $hostFacts = [pscustomobject]@{
        os = $os.Caption
        build = $os.BuildNumber
        computer = $env:COMPUTERNAME
        processor = $cpu.Name
        logical_processors = $cpu.NumberOfLogicalProcessors
        gpu = $gpu.Name
        gpu_driver_version = $gpu.DriverVersion
        memory_bytes = [int64]$os.TotalVisibleMemorySize * 1024
        cpu_load_percent_at_start = $loadAtStart
        cpu_load_percent_at_end = $loadAtEnd
    }
} catch { }

$odinVersion = $null
try { $odinVersion = (& C:\odin\odin.exe version | Out-String).Trim() } catch { }
$alicornCommit = $null
try { $alicornCommit = (& git -C $RepoRoot rev-parse HEAD | Out-String).Trim() } catch { }

$binaryFacts = [ordered]@{}
foreach ($name in $suites.Keys) {
    $exe = $suites[$name].config.executable
    $dir = Split-Path -Parent $exe
    $sdl = Join-Path $dir 'SDL3.dll'
    $binaryFacts[$name] = [pscustomobject]@{
        executable = Get-ExecutableFacts $exe
        sdl3_dll = Get-ExecutableFacts $sdl
        directory = $dir
    }
}
$fontFacts = @()
$fontRoot = Join-Path $RepoRoot 'assets\fonts'
if (Test-Path $fontRoot) {
    foreach ($file in Get-ChildItem -LiteralPath $fontRoot -Filter *.ttf) {
        $fontFacts += [pscustomobject]@{ name = $file.Name; size_bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

$report = [pscustomobject]@{
    schema = 1
    scenario = if ($Paired) { 'native SDL_GPU paired A/B (issue #172 phase 2)' } else { 'native SDL_GPU startup attribution (issue #172 phase 1)' }
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    warm_state = 'warm-order; one session-first launch and one file-cache warmup per app; no reboot or cache purge'
    runs_per_app = $Runs
    session_first_enabled = [bool]$SessionFirst
    paired = [bool]$Paired
    arms = if ($Paired) {
        [pscustomobject]@{
            primary_label = $PrimaryArmLabel
            primary_arguments = @($PrimaryArmArguments)
            compare_label = $CompareArmLabel
            compare_arguments = @($CompareArmArguments)
            order = 'round 1 primary then compare; round 2 compare then primary; alternate each round'
        }
    } else { $null }
    host = $hostFacts
    toolchain = [pscustomobject]@{ odin_version = $odinVersion; odin_path = 'C:\odin\odin.exe'; alicorn_commit = $alicornCommit }
    counters = [pscustomobject]@{
        process = @('Process.WorkingSet64', 'Process.PrivateMemorySize64', 'Process.TotalProcessorTime', 'Process.StartTime')
        gpu = @('\GPU Process Memory(pid_<pid>*)\Dedicated Usage', '\GPU Process Memory(pid_<pid>*)\Shared Usage')
        units = 'bytes; perf counters sampled every 500 ms during the run; settle value is the sample when the PASS line was observed'
        reliability = $Script:CounterReliability
    }
    binaries = $binaryFacts
    embedded_fonts = $fontFacts
    apps = $summaries
    limitations = @(
        'Warm-order only: no reboot, cache purge or page-file control; not a cold-start measurement.',
        'first_application_submit_ns is a GPU submission, not time to first visible pixel or scan-out.',
        'first_input_ready_ns is the first completed primary event pump, not an input-to-display latency.',
        'The timing origin is the host entry point; OS loader and Odin process-entry time are reported separately as pre_origin_ms.',
        'GPU Process Memory is driver-managed residency sampled at the PASS marker; it excludes driver heaps, shader caches and OS reservations.',
        'Process.PrivateMemorySize64 is the PROCESS_MEMORY_COUNTERS_EX private committed page view; it is not allocator-requested bytes.',
        'Punks was built against this Alicorn master with its own pinned Caliber/Alicorn-Kit dependencies; see the manifest for revisions.'
    )
}
$summaryPath = Join-Path $ResultsDirectory 'summary.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$csv = Join-Path $ResultsDirectory 'samples.csv'
if ($allSamples.Count -gt 0) {
    $allSamples | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
}

Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $ResultsDirectory 'bench_startup.ps1') -Force
Write-Output "summary: $summaryPath"
Write-Output "samples: $csv"
