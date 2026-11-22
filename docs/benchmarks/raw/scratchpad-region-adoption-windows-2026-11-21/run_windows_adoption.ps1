param(
    [Parameter(Mandatory = $true)][ValidateSet('sequence', 'typing', 'quickopen')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$PlainExe,
    [Parameter(Mandatory = $true)][string]$AdoptedExe,
    [Parameter(Mandatory = $true)][string]$QuickOpenExe,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    [int]$Runs = 7,
    [int]$Warmups = 1,
    [int]$TimeoutSeconds = 90,
    [int]$MaxAttempts = 3,
    [string]$PlainRevision = '',
    [string]$AdoptedRevision = '',
    [string]$QuickOpenRevision = '',
    [string]$ScratchpadRevision = '',
    [string]$CaliberRevision = '',
    [string]$HarnessPatchSha256 = '',
    [string]$AdoptionPatchSha256 = '',
    [string]$QuickOpenPatchSha256 = ''
)

$ErrorActionPreference = 'Stop'
$ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
$PlainExe = [System.IO.Path]::GetFullPath($PlainExe)
$AdoptedExe = [System.IO.Path]::GetFullPath($AdoptedExe)
$QuickOpenExe = [System.IO.Path]::GetFullPath($QuickOpenExe)
if ($Runs -lt 1 -or $Warmups -lt 0 -or $TimeoutSeconds -lt 1 -or $MaxAttempts -lt 1) { throw 'Invalid run, warmup, timeout, or attempt count.' }
New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
$logDirectory = Join-Path $ResultsDirectory 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)

# ---- Fixture -----------------------------------------------------------------
# Identical to the 2026-11-04 / 2026-11-21 captures: 8 directories, 192 small
# files, a README, and a 5,002-line application/sample_00.go (193 files).
$workspace = Join-Path $ResultsDirectory 'workspace'
if (-not (Test-Path -LiteralPath (Join-Path $workspace 'application\sample_00.go'))) {
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $workspace 'README.md'), "# Scratchpad Windows A/B fixture`n`nGenerated disposable benchmark workspace.`n", $utf8)
    $folders = @('application', 'editor', 'document', 'runtime', 'tests', 'docs', 'themes', 'tools')
    $extensions = @('.go', '.odin', '.md', '.json', '.txt', '.ts')
    foreach ($folderIndex in 0..($folders.Length - 1)) {
        $folder = $folders[$folderIndex]
        $directory = Join-Path $workspace $folder
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        foreach ($fileIndex in 0..23) {
            $extension = $extensions[($folderIndex + $fileIndex) % $extensions.Length]
            $name = 'sample_{0:D2}{1}' -f $fileIndex, $extension
            $path = Join-Path $directory $name
            if ($folder -eq 'application' -and $fileIndex -eq 0) {
                $builder = [System.Text.StringBuilder]::new()
                [void]$builder.AppendLine('package sample')
                [void]$builder.AppendLine()
                foreach ($lineIndex in 0..4999) {
                    $lineText = 'func GeneratedRow{0:D5}() int {{ return {1} }}' -f $lineIndex, $lineIndex
                    [void]$builder.Append($lineText)
                    [void]$builder.AppendLine()
                }
                [System.IO.File]::WriteAllText($path, $builder.ToString(), $utf8)
            } else {
                $builder = [System.Text.StringBuilder]::new()
                foreach ($lineIndex in 0..31) {
                    $lineText = '// fixture {0}/{1} row {2:D2}' -f $folder, $name, $lineIndex
                    [void]$builder.AppendLine($lineText)
                }
                [System.IO.File]::WriteAllText($path, $builder.ToString(), $utf8)
            }
        }
    }
}

function Get-KeyValues([string]$line, [int]$start) {
    $tokens = $line -split '\s+'
    $values = @{}
    for ($i = $start; $i + 1 -lt $tokens.Length; $i += 2) { $values[$tokens[$i]] = $tokens[$i + 1] }
    return $values
}

$scenarioEnv = @{
    sequence  = 'SCRATCHPAD_ALICORN_PERF_SEQUENCE'
    typing    = 'SCRATCHPAD_ALICORN_PERF_TYPING'
    quickopen = 'SCRATCHPAD_ALICORN_PERF_QUICKOPEN'
}
$stepMarker = @{
    sequence  = 'alicorn-performance-sequence-step'
    typing    = 'alicorn-performance-typing-step'
    quickopen = 'alicorn-performance-quickopen-step'
}
$counterMarker = @{
    sequence  = 'alicorn-performance-sequence-counters'
    typing    = 'alicorn-performance-typing-counters'
    quickopen = 'alicorn-performance-quickopen-counters'
}
$summaryMarker = @{
    sequence  = 'alicorn-performance-sequence '
    typing    = 'alicorn-performance-typing '
    quickopen = 'alicorn-performance-quickopen '
}
$expectedSteps = @{ sequence = 9; typing = 24; quickopen = 19 }

function Invoke-SampleOnce([string]$Label, [string]$Executable, [string]$RunName) {
    $binDirectory = Split-Path -Parent $Executable
    $profile = Join-Path $ResultsDirectory ('profile-{0}-{1}' -f $Label, $RunName)
    if (Test-Path -LiteralPath $profile) { Remove-Item -Recurse -Force $profile }
    New-Item -ItemType Directory -Force -Path $profile | Out-Null
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $binDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['SCRATCHPAD_ALICORN_SMOKE'] = '1'
    $startInfo.Environment[$scenarioEnv[$Scenario]] = '1'
    $startInfo.Environment['SCRATCHPAD_ALICORN_WORKSPACE'] = $workspace
    $startInfo.Environment['APPDATA'] = $profile
    $startInfo.Environment['LOCALAPPDATA'] = $profile
    $startInfo.Environment['PATH'] = $binDirectory + ';' + $env:PATH
    # The measured path is the SDL_GPU reference host. No renderer override.
    $startInfo.Environment.Remove('SCRATCHPAD_RENDERER')
    $startInfo.Environment.Remove('SCRATCHPAD_BACKEND_LIBRARY')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw "Could not start $Label $RunName." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peakWorkingSet = [int64]0
    $timedOut = $false
    while (-not $process.HasExited) {
        $process.Refresh()
        try { $peakWorkingSet = [Math]::Max($peakWorkingSet, [int64]$process.PeakWorkingSet64) } catch { }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            $process.Kill($true)
            break
        }
        Start-Sleep -Milliseconds 10
    }
    $process.WaitForExit()
    $watch.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $log = $stdout + $stderr
    $logPath = Join-Path $logDirectory ('{0}-{1}.log' -f $Label, $RunName)
    [System.IO.File]::WriteAllText($logPath, $log, $utf8)
    $attempt = [pscustomobject]@{
        ok = $false; timedOut = $timedOut; exitCode = $process.ExitCode; logPath = $logPath
        log = $log; elapsedNs = [int64]($watch.Elapsed.TotalMilliseconds * 1000000)
        cpuTotalNs = [int64]($process.TotalProcessorTime.TotalMilliseconds * 1000000)
        peakWorkingSetBytes = $peakWorkingSet
        sample = $null; steps = @(); counters = @()
    }
    if ($timedOut) { return $attempt }
    if ($process.ExitCode -ne 0) { return $attempt }

    $hostLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('SDL application PASS ') } | Select-Object -Last 1)
    $smokeLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('alicorn-smoke ') } | Select-Object -Last 1)
    $summaryLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith($summaryMarker[$Scenario]) } | Select-Object -Last 1)
    if ($hostLine.Count -eq 0 -or $smokeLine.Count -eq 0 -or $summaryLine.Count -eq 0) { return $attempt }
    $hostFields = Get-KeyValues $hostLine[0] 3
    $smoke = Get-KeyValues $smokeLine[0] 1
    $scenarioSummary = Get-KeyValues $summaryLine[0] 1
    if ($smoke.publication_rendered -ne 'true' -or $smoke.wake_observed -ne 'true' -or $smoke.ordered_shutdown -ne 'true') { return $attempt }
    if ($scenarioSummary.steps -ne "$($expectedSteps[$Scenario])" -or $scenarioSummary.complete -ne 'true' -or $scenarioSummary.passed -ne 'true') { return $attempt }
    foreach ($required in @('wall_ns', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'primary_gpu_submissions')) {
        if (-not $hostFields.ContainsKey($required)) { return $attempt }
    }
    if ([int64]$hostFields.application_build_max_ns -le 0 -or [int64]$hostFields.primary_gpu_submissions -le 0) { return $attempt }

    $stepLines = @($log -split "`r?`n" | Where-Object { $_.StartsWith($stepMarker[$Scenario]) })
    if ($stepLines.Count -ne $expectedSteps[$Scenario]) { return $attempt }
    $stepRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($stepLine in $stepLines) {
        $stepFields = Get-KeyValues $stepLine 1
        [void]$stepRecords.Add([pscustomobject]@{
            candidate = $Label
            run = $RunName
            step = [int]$stepFields.step
            action_ns = [int64]$stepFields.action_ns
            build_ns = [int64]$stepFields.build_ns
            builds = [int64]$stepFields.builds
            query_len = if ($stepFields.ContainsKey('query_len')) { [int]$stepFields.query_len } else { 0 }
        })
    }
    for ($stepIndex = 0; $stepIndex -lt $expectedSteps[$Scenario]; $stepIndex++) {
        $stepMatches = @($stepRecords | Where-Object { $_.step -eq $stepIndex })
        if ($stepMatches.Count -ne 1) { return $attempt }
    }

    $counterRecords = [System.Collections.Generic.List[object]]::new()
    $counterLines = @($log -split "`r?`n" | Where-Object { $_.StartsWith($counterMarker[$Scenario]) })
    foreach ($counterLine in $counterLines) {
        $fields = Get-KeyValues $counterLine 1
        $record = [ordered]@{ candidate = $Label; run = $RunName; step = [int]$fields.step }
        foreach ($key in @('emitted', 'reused', 'regions_skipped', 'retained_reused', 'reconcile_nodes', 'layout_nodes', 'paint_nodes', 'composition_nodes', 'text_shapes', 'stage_description_ns', 'stage_reconcile_ns', 'query_len', 'selected', 'results')) {
            if ($fields.ContainsKey($key)) { $record[$key] = [int64]$fields[$key] }
        }
        [void]$counterRecords.Add([pscustomobject]$record)
    }

    $process.Refresh()
    $peakWorkingSet = [Math]::Max($peakWorkingSet, [int64]$process.PeakWorkingSet64)
    $setupLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith("alicorn-performance-$($Scenario)-setup ") } | Select-Object -Last 1)
    $tailLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith("alicorn-performance-$($Scenario)-tail ") } | Select-Object -Last 1)
    $setup = if ($setupLine.Count -gt 0) { Get-KeyValues $setupLine[0] 1 } else { @{} }
    $tail = if ($tailLine.Count -gt 0) { Get-KeyValues $tailLine[0] 1 } else { @{} }
    $attempt.ok = $true
    $attempt.sample = [pscustomobject]@{
        candidate = $Label
        run = $RunName
        exit_code = $process.ExitCode
        elapsed_ns = [int64]($watch.Elapsed.TotalMilliseconds * 1000000)
        cpu_total_ns = [int64]($process.TotalProcessorTime.TotalMilliseconds * 1000000)
        peak_working_set_bytes = $peakWorkingSet
        application_build_ns = [int64]$hostFields.application_build_ns
        application_build_max_ns = [int64]$hostFields.application_build_max_ns
        first_application_submit_ns = [int64]$hostFields.first_application_submit_ns
        host_wall_ns = [int64]$hostFields.wall_ns
        gpu_submissions = [int64]$hostFields.primary_gpu_submissions
        scenario_build_ns = [int64]$scenarioSummary.build_ns
        setup_build_ns = if ($setup.ContainsKey('build_ns')) { [int64]$setup.build_ns } else { [int64]0 }
        setup_builds = if ($setup.ContainsKey('builds')) { [int64]$setup.builds } else { [int64]0 }
        tail_build_ns = if ($tail.ContainsKey('build_ns')) { [int64]$tail.build_ns } else { [int64]0 }
        tail_builds = if ($tail.ContainsKey('builds')) { [int64]$tail.builds } else { [int64]0 }
        attempts = 1
        log = $logPath
    }
    $attempt.steps = $stepRecords.ToArray()
    $attempt.counters = $counterRecords.ToArray()
    return $attempt
}

function Invoke-Sample([string]$Label, [string]$Executable, [string]$RunName) {
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-SampleOnce $Label $Executable $RunName
        if ($result.ok) {
            $result.sample.attempts = $attempt
            return $result
        }
        $failedPath = Join-Path $logDirectory ('{0}-{1}-attempt-{2}-failed.log' -f $Label, $RunName, $attempt)
        if (Test-Path -LiteralPath $result.logPath) { Move-Item -Force -LiteralPath $result.logPath -Destination $failedPath }
        Write-Output ('retry {0} {1}: attempt {2} did not pass acceptance (exit {3}, timeout {4}); see {5}' -f $Label, $RunName, $attempt, $result.exitCode, $result.timedOut, $failedPath)
    }
    throw "$Label $RunName failed acceptance after $MaxAttempts attempts; see $logDirectory"
}

$arms = @(
    [pscustomobject]@{ label = 'plain'; exe = $PlainExe },
    [pscustomobject]@{ label = 'adopted'; exe = $AdoptedExe },
    [pscustomobject]@{ label = 'quickopen'; exe = $QuickOpenExe }
)
# Balanced order: every arm occupies each position twice across six rounds.
$orders = @(
    @('plain', 'adopted', 'quickopen'),
    @('quickopen', 'adopted', 'plain'),
    @('adopted', 'quickopen', 'plain'),
    @('plain', 'quickopen', 'adopted'),
    @('quickopen', 'plain', 'adopted'),
    @('adopted', 'plain', 'quickopen')
)

$samples = [System.Collections.Generic.List[object]]::new()
$allSteps = [System.Collections.Generic.List[object]]::new()
$allCounters = [System.Collections.Generic.List[object]]::new()
for ($warmup = 1; $warmup -le $Warmups; $warmup++) {
    foreach ($arm in $arms) {
        $result = Invoke-Sample $arm.label $arm.exe ('warmup-{0:D2}' -f $warmup)
        Write-Output ('warmup {0} {1}: app build {2:N3} ms' -f $arm.label, $result.sample.run, ($result.sample.application_build_ns / 1e6))
    }
}
for ($round = 0; $round -lt $Runs; $round++) {
    $order = $orders[$round % $orders.Length]
    $runName = 'run-{0:D2}' -f ($round + 1)
    foreach ($label in $order) {
        $arm = $arms | Where-Object { $_.label -eq $label } | Select-Object -First 1
        $result = Invoke-Sample $arm.label $arm.exe $runName
        $samples.Add($result.sample)
        foreach ($step in $result.steps) { [void]$allSteps.Add($step) }
        foreach ($counter in $result.counters) { [void]$allCounters.Add($counter) }
        Write-Output ('completed {0} {1}: app build {2:N3} ms, scenario build {3:N3} ms, setup {4:N3} ms, tail {5:N3} ms, attempts {6}' -f $result.sample.candidate, $result.sample.run, ($result.sample.application_build_ns / 1e6), ($result.sample.scenario_build_ns / 1e6), ($result.sample.setup_build_ns / 1e6), ($result.sample.tail_build_ns / 1e6), $result.sample.attempts)
    }
}

function Get-Percentile([double[]]$sortedValues, [double]$percentile) {
    if ($sortedValues.Length -eq 0) { return 0 }
    $index = [int][Math]::Floor($percentile * ($sortedValues.Length - 1))
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sortedValues.Length) { $index = $sortedValues.Length - 1 }
    return $sortedValues[$index]
}

function Get-SeriesSummary([System.Collections.Generic.List[double]]$values) {
    if ($values.Count -eq 0) { return [pscustomobject]@{ count = 0; min = 0; p50 = 0; p95 = 0; max = 0 } }
    $ordered = $values.ToArray()
    [Array]::Sort($ordered)
    return [pscustomobject]@{
        count = $ordered.Length
        min = $ordered[0]
        p50 = (Get-Percentile $ordered 0.50)
        p95 = (Get-Percentile $ordered 0.95)
        max = $ordered[-1]
    }
}

$metrics = @('elapsed_ns', 'cpu_total_ns', 'peak_working_set_bytes', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'host_wall_ns', 'gpu_submissions', 'scenario_build_ns', 'setup_build_ns', 'tail_build_ns')
$summaries = @{}
foreach ($arm in $arms) {
    $summary = @{}
    foreach ($metric in $metrics) {
        $values = [System.Collections.Generic.List[double]]::new()
        foreach ($sample in $samples) {
            if ($sample.candidate -eq $arm.label) { [void]$values.Add([double]($sample.$metric)) }
        }
        $summary[$metric] = Get-SeriesSummary $values
    }
    $summaries[$arm.label] = $summary
}

function Get-Paired([string]$FromLabel, [string]$ToLabel) {
    $result = @{}
    foreach ($metric in $metrics) {
        $changes = [System.Collections.Generic.List[double]]::new()
        foreach ($round in 1..$Runs) {
            $runName = 'run-{0:D2}' -f $round
            $beforeSample = $null
            $afterSample = $null
            foreach ($sample in $samples) {
                if ($sample.run -eq $runName -and $sample.candidate -eq $FromLabel) { $beforeSample = $sample }
                if ($sample.run -eq $runName -and $sample.candidate -eq $ToLabel) { $afterSample = $sample }
            }
            if ($null -eq $beforeSample -or $null -eq $afterSample) { throw "Missing paired sample for $runName ($FromLabel -> $ToLabel, $metric)" }
            $before = [double]($beforeSample.$metric)
            $after = [double]($afterSample.$metric)
            if ($before -ne 0) { [void]$changes.Add(($after - $before) * 100.0 / $before) }
        }
        $result[$metric] = [pscustomobject]@{ median_percent_change = (Get-SeriesSummary $changes).p50; changes = $changes.ToArray() }
    }
    return $result
}
$paired = [pscustomobject]@{
    plain_to_adopted = Get-Paired 'plain' 'adopted'
    adopted_to_quickopen = Get-Paired 'adopted' 'quickopen'
    plain_to_quickopen = Get-Paired 'plain' 'quickopen'
}

$stepSummaries = @{}
$stepPaired = @{}
for ($stepIndex = 0; $stepIndex -lt $expectedSteps[$Scenario]; $stepIndex++) {
    $stepKey = "step_$stepIndex"
    $stepSummaries[$stepKey] = @{}
    foreach ($arm in $arms) {
        $stepSummaries[$stepKey][$arm.label] = @{}
        foreach ($field in @('action_ns', 'build_ns', 'builds')) {
            $values = [System.Collections.Generic.List[double]]::new()
            foreach ($step in $allSteps) {
                if ($step.candidate -eq $arm.label -and $step.step -eq $stepIndex -and $step.run -notlike 'warmup-*') {
                    [void]$values.Add([double]($step.$field))
                }
            }
            $stepSummaries[$stepKey][$arm.label][$field] = Get-SeriesSummary $values
        }
    }
    $stepPaired[$stepKey] = @{}
    foreach ($field in @('action_ns', 'build_ns')) {
        foreach ($comparison in @(@('plain', 'adopted'), @('adopted', 'quickopen'), @('plain', 'quickopen'))) {
            $changes = [System.Collections.Generic.List[double]]::new()
            foreach ($round in 1..$Runs) {
                $runName = 'run-{0:D2}' -f $round
                $before = $null
                $after = $null
                foreach ($step in $allSteps) {
                    if ($step.run -ne $runName -or $step.step -ne $stepIndex) { continue }
                    if ($step.candidate -eq $comparison[0]) { $before = $step }
                    if ($step.candidate -eq $comparison[1]) { $after = $step }
                }
                if ($null -eq $before -or $null -eq $after) { throw "Missing paired step sample for $runName step $stepIndex ($($comparison -join ' -> '), $field)" }
                if ([double]$before.$field -ne 0) { [void]$changes.Add(([double]$after.$field - [double]$before.$field) * 100.0 / [double]$before.$field) }
            }
            $stepPaired[$stepKey]["$($comparison[0])_to_$($comparison[1])_$field"] = [pscustomobject]@{ median_percent_change = (Get-SeriesSummary $changes).p50; changes = $changes.ToArray() }
        }
    }
}

# Counter medians per character (typing/quickopen): per-run median over the
# measured characters 1..N-1, then the arm median across runs.
$counterSummaries = @{}
$counterSteps = $expectedSteps[$Scenario]
if ($Scenario -ne 'sequence') {
    foreach ($arm in $arms) {
        $counterSummaries[$arm.label] = @{}
        foreach ($field in @('emitted', 'reused', 'regions_skipped', 'retained_reused', 'reconcile_nodes', 'layout_nodes', 'paint_nodes', 'composition_nodes', 'text_shapes', 'stage_description_ns', 'stage_reconcile_ns')) {
            $perRun = [System.Collections.Generic.List[double]]::new()
            foreach ($round in 1..$Runs) {
                $runName = 'run-{0:D2}' -f $round
                $values = [System.Collections.Generic.List[double]]::new()
                foreach ($counter in $allCounters) {
                    if ($counter.candidate -eq $arm.label -and $counter.run -eq $runName -and $counter.step -ge 1 -and $counter.step -lt $counterSteps) {
                        if ($counter.PSObject.Properties.Name -contains $field) { [void]$values.Add([double]$counter.$field) }
                    }
                }
                if ($values.Count -gt 0) { [void]$perRun.Add((Get-SeriesSummary $values).p50) }
            }
            $counterSummaries[$arm.label][$field] = Get-SeriesSummary $perRun
        }
    }
}

$hostFacts = [pscustomobject]@{ os = 'Windows 10 Home 22H2'; build = '19045'; computer = $env:COMPUTERNAME; processor = 'AMD Ryzen 5 7600X (12 logical processors)'; memory_gib = 16; gpu = 'NVIDIA GeForce RTX 2080 SUPER' }
try {
    $osFacts = Get-CimInstance Win32_OperatingSystem
    $cpuFacts = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpuFacts = Get-CimInstance Win32_VideoController | Select-Object -First 1
    $hostFacts = [pscustomobject]@{
        os = "$($osFacts.Caption), build $($osFacts.BuildNumber)"
        computer = $env:COMPUTERNAME
        processor = $cpuFacts.Name
        memory_gib = [Math]::Round($osFacts.TotalVisibleMemorySize / 1MB, 0)
        gpu = $gpuFacts.Name
        gpu_driver = $gpuFacts.DriverVersion
    }
} catch { }
$odin = 'C:\odin\odin.exe'
$odinVersion = (& $odin version | Out-String).Trim()
$goVersion = (& go version | Out-String).Trim()

$report = [pscustomobject]@{
    schema = 2
    recorded_local_date = '2026-11-21'
    scenario = $Scenario
    host = $hostFacts
    display = [pscustomobject]@{ scale = 1.0; note = 'Logical window size equals pixel size in this capture; no DPI transition was exercised.' }
    theme = 'Scratchpad default Warm theme; no appearance fixture or preference was set.'
    scratchpad_revision = $ScratchpadRevision
    caliber_revision = $CaliberRevision
    odin_path = $odin
    odin_version = $odinVersion
    go_version = $goVersion
    workspace = [pscustomobject]@{
        directories = 8
        small_files = 192
        readme_files = 1
        total_files = 193
        large_document = 'application/sample_00.go'
        large_document_lines = 5002
    }
    runs_per_candidate = $Runs
    warmups_per_candidate = $Warmups
    max_attempts = $MaxAttempts
    order = $orders[0..([Math]::Min($Runs, $orders.Length) - 1)]
    candidate_revisions = [pscustomobject]@{ plain = $PlainRevision; adopted = $AdoptedRevision; quickopen = $QuickOpenRevision }
    build_profile = 'Release, Odin -o:speed; Go driver build'
    renderer = 'SDL_GPU reference host (build carries both renderers; no SCRATCHPAD_RENDERER override was set)'
    sequence = switch ($Scenario) {
        'sequence' { @('open README.md', 'open application/sample_00.go', 'switch back to README.md', 'open Quick Open', 'close Quick Open after index ready', 'open Settings', 'close Settings', 'close README.md', 'close the remaining Go document') }
        'typing' { @('open application/sample_00.go (setup, unmeasured)', '24 committed character insertions at the editor caret, one per step') }
        'quickopen' { @('open Quick Open and wait for the path index and query focus (setup, unmeasured)', '19 committed query characters through the runtime text-field commit path, one per step', 'close Quick Open (tail)') }
    }
    smoke_window = 'The reference host exits smoke at its fixed 3 s window after startup; every accepted process completed its measured scenario inside it.'
    artifacts = [pscustomobject]@{
        plain = [pscustomobject]@{ binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PlainExe).Hash; path = $PlainExe }
        adopted = [pscustomobject]@{ binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $AdoptedExe).Hash; path = $AdoptedExe }
        quickopen = [pscustomobject]@{ binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $QuickOpenExe).Hash; path = $QuickOpenExe }
        harness_patch_sha256 = $HarnessPatchSha256
        adoption_patch_sha256 = $AdoptionPatchSha256
        quickopen_patch_sha256 = $QuickOpenPatchSha256
    }
    summaries = $summaries
    paired_comparison = $paired
    step_summaries = $stepSummaries
    step_paired_comparison = $stepPaired
    counter_summaries = $counterSummaries
    samples = $samples
}
$jsonPath = Join-Path $ResultsDirectory 'summary.json'
$report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$csvPath = Join-Path $ResultsDirectory 'samples.csv'
$csvColumns = @('candidate', 'run', 'exit_code', 'attempts', 'elapsed_ns', 'cpu_total_ns', 'peak_working_set_bytes', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'host_wall_ns', 'gpu_submissions', 'scenario_build_ns', 'setup_build_ns', 'setup_builds', 'tail_build_ns', 'tail_builds', 'log_file')
$csvRows = [System.Collections.Generic.List[string]]::new()
[void]$csvRows.Add((($csvColumns | ForEach-Object { '"' + $_ + '"' }) -join ','))
foreach ($sample in $samples) {
    $values = @($sample.candidate, $sample.run, $sample.exit_code, $sample.attempts, $sample.elapsed_ns, $sample.cpu_total_ns, $sample.peak_working_set_bytes, $sample.application_build_ns, $sample.application_build_max_ns, $sample.first_application_submit_ns, $sample.host_wall_ns, $sample.gpu_submissions, $sample.scenario_build_ns, $sample.setup_build_ns, $sample.setup_builds, $sample.tail_build_ns, $sample.tail_builds, [System.IO.Path]::GetFileName($sample.log))
    $cells = @()
    foreach ($value in $values) { $cells += '"' + ([string]$value).Replace('"', '""') + '"' }
    [void]$csvRows.Add(($cells -join ','))
}
[System.IO.File]::WriteAllLines($csvPath, $csvRows, [System.Text.UTF8Encoding]::new($false))

$stepsPath = Join-Path $ResultsDirectory 'steps.csv'
$stepRows = [System.Collections.Generic.List[string]]::new()
[void]$stepRows.Add('"candidate","run","step","action_ns","build_ns","builds","query_len"')
foreach ($step in $allSteps) {
    [void]$stepRows.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}"' -f $step.candidate, $step.run, $step.step, $step.action_ns, $step.build_ns, $step.builds, $step.query_len))
}
[System.IO.File]::WriteAllLines($stepsPath, $stepRows, [System.Text.UTF8Encoding]::new($false))

$countersPath = Join-Path $ResultsDirectory 'counters.csv'
$counterColumns = @('candidate', 'run', 'step', 'emitted', 'reused', 'regions_skipped', 'retained_reused', 'reconcile_nodes', 'layout_nodes', 'paint_nodes', 'composition_nodes', 'text_shapes', 'stage_description_ns', 'stage_reconcile_ns', 'query_len', 'selected', 'results')
$counterRows = [System.Collections.Generic.List[string]]::new()
[void]$counterRows.Add((($counterColumns | ForEach-Object { '"' + $_ + '"' }) -join ','))
foreach ($counter in $allCounters) {
    $cells = @()
    foreach ($column in $counterColumns) {
        $value = ''
        if ($counter.PSObject.Properties.Name -contains $column) { $value = [string]$counter.$column }
        $cells += '"' + $value + '"'
    }
    [void]$counterRows.Add(($cells -join ','))
}
[System.IO.File]::WriteAllLines($countersPath, $counterRows, [System.Text.UTF8Encoding]::new($false))
Write-Output "summary: $jsonPath"
