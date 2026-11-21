param(
    [Parameter(Mandatory = $true)][string]$ScratchpadRoot,
    [Parameter(Mandatory = $true)][string]$BaselineExe,
    [Parameter(Mandatory = $true)][string]$CandidateExe,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    [int]$Runs = 7,
    [int]$Warmups = 1,
    [int]$TimeoutSeconds = 45,
    [string]$BaselineRevision = '',
    [string]$CandidateRevision = '',
    [string]$ScratchpadRevision = '',
    [string]$CaliberRevision = '',
    [string]$HookPatchSha256 = ''
)

$ErrorActionPreference = 'Stop'
$ScratchpadRoot = [System.IO.Path]::GetFullPath($ScratchpadRoot)
$ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
$BaselineExe = [System.IO.Path]::GetFullPath($BaselineExe)
$CandidateExe = [System.IO.Path]::GetFullPath($CandidateExe)
if ($Runs -lt 1 -or $Warmups -lt 0 -or $TimeoutSeconds -lt 1) { throw 'Invalid run, warmup, or timeout count.' }
New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
$logDirectory = Join-Path $ResultsDirectory 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

# ---- Fixture -----------------------------------------------------------------
# Identical to the 2026-11-04 matched Scratchpad A/B fixture: 8 directories,
# 192 small files, a README, and a 5,002-line application/sample_00.go.
$workspace = Join-Path $ResultsDirectory 'workspace'
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

function Get-KeyValues([string]$line, [int]$start) {
    $tokens = $line -split '\s+'
    $values = @{}
    for ($i = $start; $i + 1 -lt $tokens.Length; $i += 2) { $values[$tokens[$i]] = $tokens[$i + 1] }
    return $values
}

function Invoke-BenchmarkSample([string]$Label, [string]$Executable, [string]$RunName) {
    $binDirectory = Split-Path -Parent $Executable
    $profile = Join-Path $ResultsDirectory ('profile-{0}-{1}' -f $Label, $RunName)
    New-Item -ItemType Directory -Force -Path $profile | Out-Null
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $binDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['SCRATCHPAD_ALICORN_SMOKE'] = '1'
    $startInfo.Environment['SCRATCHPAD_ALICORN_PERF_SEQUENCE'] = '1'
    $startInfo.Environment['SCRATCHPAD_ALICORN_WORKSPACE'] = $workspace
    $startInfo.Environment['APPDATA'] = $profile
    $startInfo.Environment['LOCALAPPDATA'] = $profile
    $startInfo.Environment['PATH'] = $binDirectory + ';' + $env:PATH
    # The build carries both renderers. The measured path is the SDL_GPU
    # reference host, whose exit summary publishes the application build and
    # submission counters. No renderer env or argument is set.
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
    if ($timedOut) { throw "$Label $RunName timed out; see $logPath`n$($log.Substring([Math]::Max(0, $log.Length - 3000)))" }
    if ($process.ExitCode -ne 0) { throw "$Label $RunName exited $($process.ExitCode); see $logPath`n$($log.Substring([Math]::Max(0, $log.Length - 3000)))" }

    $hostLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('SDL application PASS ') } | Select-Object -Last 1)
    $smokeLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('alicorn-smoke ') } | Select-Object -Last 1)
    $sequenceLine = @($log -split "`r?`n" | Where-Object { $_.StartsWith('alicorn-performance-sequence ') } | Select-Object -Last 1)
    $stepLines = @($log -split "`r?`n" | Where-Object { $_.StartsWith('alicorn-performance-sequence-step ') })
    if ($hostLine.Count -eq 0 -or $smokeLine.Count -eq 0 -or $sequenceLine.Count -eq 0) { throw "$Label $RunName omitted host or sequence acceptance output; see $logPath" }
    $hostFields = Get-KeyValues $hostLine[0] 3
    $smoke = Get-KeyValues $smokeLine[0] 1
    $sequence = Get-KeyValues $sequenceLine[0] 1
    if ($smoke.publication_rendered -ne 'true' -or $smoke.wake_observed -ne 'true' -or $smoke.ordered_shutdown -ne 'true') { throw "$Label $RunName failed smoke acceptance; see $logPath" }
    if ($sequence.steps -ne '9' -or $sequence.complete -ne 'true' -or $sequence.passed -ne 'true') { throw "$Label $RunName failed interaction sequence: $($sequence | ConvertTo-Json -Compress); see $logPath" }
    if ($stepLines.Count -ne 9) { throw "$Label $RunName reported $($stepLines.Count) step lines, expected 9; see $logPath" }
    foreach ($required in @('wall_ns', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'primary_gpu_submissions')) {
        if (-not $hostFields.ContainsKey($required)) { throw "$Label $RunName missing host metric $required; see $logPath" }
    }
    if ([int64]$hostFields.first_application_submit_ns -le 0 -or [int64]$hostFields.application_build_max_ns -le 0) { throw "$Label $RunName has zero first-submit or build timing; see $logPath" }
    if ([int64]$hostFields.primary_gpu_submissions -le 0) { throw "$Label $RunName made no primary GPU submission; see $logPath" }

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
        })
    }
    # Steps must be reported in order 0..8 exactly once.
    for ($stepIndex = 0; $stepIndex -lt 9; $stepIndex++) {
        $stepMatches = @($stepRecords | Where-Object { $_.step -eq $stepIndex })
        if ($stepMatches.Count -ne 1) { throw "$Label $RunName step $stepIndex reported $($stepMatches.Count) times; see $logPath" }
    }

    $process.Refresh()
    $peakWorkingSet = [Math]::Max($peakWorkingSet, [int64]$process.PeakWorkingSet64)
    $sample = [pscustomobject]@{
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
        sequence_build_ns = [int64]$sequence.build_ns
        log = $logPath
    }
    return [pscustomobject]@{ sample = $sample; steps = $stepRecords.ToArray() }
}

$candidates = @(
    [pscustomobject]@{ label = 'baseline'; exe = $BaselineExe },
    [pscustomobject]@{ label = 'candidate'; exe = $CandidateExe }
)
$samples = [System.Collections.Generic.List[object]]::new()
$allSteps = [System.Collections.Generic.List[object]]::new()
for ($warmup = 1; $warmup -le $Warmups; $warmup++) {
    foreach ($candidate in $candidates) {
        $result = Invoke-BenchmarkSample $candidate.label $candidate.exe ('warmup-{0:D2}' -f $warmup)
        foreach ($step in $result.steps) { [void]$allSteps.Add($step) }
    }
}
foreach ($round in 0..($Runs - 1)) {
    $order = if (($round % 2) -eq 0) { $candidates } else { @($candidates[1], $candidates[0]) }
    foreach ($candidate in $order) {
        $result = Invoke-BenchmarkSample $candidate.label $candidate.exe ('run-{0:D2}' -f ($round + 1))
        $samples.Add($result.sample)
        foreach ($step in $result.steps) { [void]$allSteps.Add($step) }
        Write-Output ('completed {0} {1}: wall {2:N0} ms, app build {3:N3} ms, sequence build {4:N3} ms' -f $result.sample.candidate, $result.sample.run, ($result.sample.elapsed_ns / 1e6), ($result.sample.application_build_ns / 1e6), ($result.sample.sequence_build_ns / 1e6))
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

$metrics = @('elapsed_ns', 'cpu_total_ns', 'peak_working_set_bytes', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'host_wall_ns', 'gpu_submissions', 'sequence_build_ns')
$summaries = @{}
foreach ($candidate in $candidates) {
    $summary = @{}
    foreach ($metric in $metrics) {
        $values = [System.Collections.Generic.List[double]]::new()
        foreach ($sample in $samples) {
            if ($sample.candidate -eq $candidate.label) { [void]$values.Add([double]($sample.$metric)) }
        }
        $summary[$metric] = Get-SeriesSummary $values
    }
    $summaries[$candidate.label] = $summary
}
$paired = @{}
foreach ($metric in $metrics) {
    $changes = [System.Collections.Generic.List[double]]::new()
    foreach ($round in 1..$Runs) {
        $runName = 'run-{0:D2}' -f $round
        $beforeSample = $null
        $afterSample = $null
        foreach ($sample in $samples) {
            if ($sample.run -eq $runName -and $sample.candidate -eq 'baseline') { $beforeSample = $sample }
            if ($sample.run -eq $runName -and $sample.candidate -eq 'candidate') { $afterSample = $sample }
        }
        if ($null -eq $beforeSample -or $null -eq $afterSample) { throw "Missing paired sample for $runName ($metric)" }
        $before = [double]($beforeSample.$metric)
        $after = [double]($afterSample.$metric)
        if ($before -ne 0) { [void]$changes.Add(($after - $before) * 100.0 / $before) }
    }
    $paired[$metric] = [pscustomobject]@{ median_percent_change = (Get-SeriesSummary $changes).p50; changes = $changes.ToArray() }
}

$stepSummaries = @{}
$stepPaired = @{}
for ($stepIndex = 0; $stepIndex -lt 9; $stepIndex++) {
    $stepKey = "step_$stepIndex"
    $stepSummaries[$stepKey] = @{}
    foreach ($candidate in $candidates) {
        $stepSummaries[$stepKey][$candidate.label] = @{}
        foreach ($field in @('action_ns', 'build_ns', 'builds')) {
            $values = [System.Collections.Generic.List[double]]::new()
            foreach ($step in $allSteps) {
                if ($step.candidate -eq $candidate.label -and $step.step -eq $stepIndex -and $step.run -notlike 'warmup-*') {
                    [void]$values.Add([double]($step.$field))
                }
            }
            $stepSummaries[$stepKey][$candidate.label][$field] = Get-SeriesSummary $values
        }
    }
    $stepPaired[$stepKey] = @{}
    foreach ($field in @('action_ns', 'build_ns')) {
        $changes = [System.Collections.Generic.List[double]]::new()
        foreach ($round in 1..$Runs) {
            $runName = 'run-{0:D2}' -f $round
            $before = $null
            $after = $null
            foreach ($step in $allSteps) {
                if ($step.run -ne $runName -or $step.step -ne $stepIndex) { continue }
                if ($step.candidate -eq 'baseline') { $before = $step }
                if ($step.candidate -eq 'candidate') { $after = $step }
            }
            if ($null -eq $before -or $null -eq $after) { throw "Missing paired step sample for $runName step $stepIndex ($field)" }
            if ([double]$before.$field -ne 0) { [void]$changes.Add(([double]$after.$field - [double]$before.$field) * 100.0 / [double]$before.$field) }
        }
        $stepPaired[$stepKey][$field] = [pscustomobject]@{ median_percent_change = (Get-SeriesSummary $changes).p50; changes = $changes.ToArray() }
    }
}

# ---- Host and toolchain pins -------------------------------------------------
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
    schema = 1
    recorded_local_date = '2026-11-21'
    scenario = 'nine-action large-document interaction'
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
    sequence = @(
        'open README.md',
        'open application/sample_00.go',
        'switch back to README.md',
        'open Quick Open',
        'close Quick Open after index ready',
        'open Settings',
        'close Settings',
        'close README.md',
        'close the remaining Go document'
    )
    sequence_driver = 'Benchmark-only scheduled hook invokes Scratchpad application/backend command paths. It does not synthesize native keyboard or pointer input.'
    sequence_cadence = 'First step 500 ms after start; later steps advance after the previous step description was built, with a 30 ms floor. The last step waits for its closing description before completion is declared.'
    candidate_revisions = [pscustomobject]@{ baseline = $BaselineRevision; candidate = $CandidateRevision }
    build_profile = 'Release, Odin -o:speed; Go driver build'
    renderer = 'SDL_GPU reference host (build carries both renderers; no SCRATCHPAD_RENDERER override was set)'
    smoke_window = 'The reference host exits smoke at its fixed 3 s window; all 16 processes completed the nine-step sequence inside it.'
    artifacts = [pscustomobject]@{
        baseline = [pscustomobject]@{ binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $BaselineExe).Hash; path = $BaselineExe }
        candidate = [pscustomobject]@{ binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $CandidateExe).Hash; path = $CandidateExe }
        scratchpad_perf_sequence_hook_sha256 = $HookPatchSha256
    }
    summaries = $summaries
    paired_comparison = $paired
    step_summaries = $stepSummaries
    step_paired_comparison = $stepPaired
    samples = $samples
}
$jsonPath = Join-Path $ResultsDirectory 'summary.json'
$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$csvPath = Join-Path $ResultsDirectory 'samples.csv'
$csvColumns = @('candidate', 'run', 'exit_code', 'elapsed_ns', 'cpu_total_ns', 'peak_working_set_bytes', 'application_build_ns', 'application_build_max_ns', 'first_application_submit_ns', 'host_wall_ns', 'gpu_submissions', 'sequence_build_ns', 'log_file')
$csvRows = [System.Collections.Generic.List[string]]::new()
[void]$csvRows.Add((($csvColumns | ForEach-Object { '"' + $_ + '"' }) -join ','))
foreach ($sample in $samples) {
    $values = @($sample.candidate, $sample.run, $sample.exit_code, $sample.elapsed_ns, $sample.cpu_total_ns, $sample.peak_working_set_bytes, $sample.application_build_ns, $sample.application_build_max_ns, $sample.first_application_submit_ns, $sample.host_wall_ns, $sample.gpu_submissions, $sample.sequence_build_ns, [System.IO.Path]::GetFileName($sample.log))
    $cells = @()
    foreach ($value in $values) { $cells += '"' + ([string]$value).Replace('"', '""') + '"' }
    [void]$csvRows.Add(($cells -join ','))
}
[System.IO.File]::WriteAllLines($csvPath, $csvRows, [System.Text.UTF8Encoding]::new($false))

$stepsPath = Join-Path $ResultsDirectory 'steps.csv'
$stepRows = [System.Collections.Generic.List[string]]::new()
[void]$stepRows.Add('"candidate","run","step","action_ns","build_ns","builds"')
foreach ($step in $allSteps) {
    [void]$stepRows.Add(('"{0}","{1}","{2}","{3}","{4}","{5}"' -f $step.candidate, $step.run, $step.step, $step.action_ns, $step.build_ns, $step.builds))
}
[System.IO.File]::WriteAllLines($stepsPath, $stepRows, [System.Text.UTF8Encoding]::new($false))
Write-Output "summary: $jsonPath"
