param(
    [string]$Odin,
    [int]$Runs = 5,
    [int]$Frames = 24,
    [int]$IdleHoldMs = 1200,
    [int]$SmokeHoldMs = 800,
    [string]$OutputDir = 'out\scratchpad-perf',
    # Optional scenario filter for focused re-measurement, e.g.
    # -Only typing,churn. Empty runs the full matrix.
    [string[]]$Only = @(),
    # 1 builds the issue #229 phase 2 exact description-reuse path (default);
    # 0 builds the same source with the pre-phase-2 copy-everything path so a
    # paired before/after measurement needs no source revert.
    [int]$DescriptionReuse = 1,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$Executable = Join-Path $OutputDir 'workload_matrix.exe'

function Copy-RuntimeDlls([string]$directory) {
    $odinRoot = Split-Path -Parent $Odin
    Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $directory 'SDL3.dll') -Force
    Copy-Item (Join-Path $odinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll') `
        (Join-Path $directory 'wgpu_native.dll') -Force
}

if (-not $SkipBuild) {
    # Native compiler diagnostics are warnings on stderr; keep PowerShell 5.1
    # from promoting them to a terminating error before we read the exit code.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build (Join-Path $RepoRoot 'benchmarks\workload_matrix') `
        "-collection:alicorn=$RepoRoot" -define:WGPU_SHARED=true `
        "-define:ALICORN_DESCRIPTION_REUSE=$DescriptionReuse" -o:speed `
        "-out:$Executable" @($AccessKit.CompilerArguments) 2>&1 | ForEach-Object { Write-Output $_ }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($buildExit -ne 0) { exit $buildExit }
}
Copy-RuntimeDlls $OutputDir

# Every scenario is one process. The driver posts one wake per planned
# description, and the host holds the final frame long enough for WebGPU smoke
# mode to accept the wake sequence instead of exiting after the first present.
$Scenarios = @(
    [pscustomobject]@{ Name = 'typing';    Interaction = 'typing';    Frames = $Frames; Hold = $SmokeHoldMs },
    [pscustomobject]@{ Name = 'scroll';    Interaction = 'scroll';    Frames = $Frames; Hold = $SmokeHoldMs },
    [pscustomobject]@{ Name = 'selection'; Interaction = 'selection'; Frames = $Frames; Hold = $SmokeHoldMs },
    [pscustomobject]@{ Name = 'resize';    Interaction = 'resize';    Frames = $Frames; Hold = $SmokeHoldMs },
    [pscustomobject]@{ Name = 'tabs';      Interaction = 'tabs';      Frames = $Frames; Hold = $SmokeHoldMs },
    # Churn mutates every realized row's text in place each step: the retained
    # string keeps its address and length but reports new bytes. No description
    # may be reused, so this arm proves the fast path never taxes a changed
    # node and that the exact comparison fails fast.
    [pscustomobject]@{ Name = 'churn';     Interaction = 'churn';     Frames = $Frames; Hold = $SmokeHoldMs },
    [pscustomobject]@{ Name = 'idle';      Interaction = 'idle';      Frames = 1;       Hold = $IdleHoldMs }
)

$Renderers = @(
    [pscustomobject]@{ Name = 'sdl-gpu'; Arguments = @('--backend=sdl-gpu') },
    [pscustomobject]@{ Name = 'd3d12';   Arguments = @('--backend=d3d12') },
    [pscustomobject]@{ Name = 'vulkan';  Arguments = @('--backend=vulkan') }
)

if ($Only.Count -gt 0) {
    $wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Scenarios = @($Scenarios | Where-Object { $wanted -contains $_.Name })
    if ($Scenarios.Count -eq 0) { throw "-Only '$($Only -join ',')' matched no scenario" }
}

function Convert-Line-Metrics([string]$line) {
    $result = @{}
    $tokens = @($line -split '\s+' | Where-Object { $_ -ne '' })
    foreach ($token in $tokens) {
        if ($token -match '^([A-Za-z0-9_]+)=(.+)$') {
            $result[$Matches[1]] = $Matches[2]
        }
    }
    return $result
}

function Invoke-Scenario([string]$scenarioName, [string]$rendererName, [string[]]$rendererArguments,
    [string]$interaction, [int]$frames, [int]$hold, [int]$run, [string]$logPath) {
    $arguments = @('--smoke', "--smoke-hold-ms=$hold", "--workload=scratchpad",
        "--interaction=$interaction", "--frames=$frames") + $rendererArguments
    $stderrPath = "$logPath.stderr"
    # A hosted WebGPU process can occasionally miss the smoke-exit window while
    # the machine is busier than the calibration run. Retry such a run once
    # instead of discarding the whole paired measurement; the retry is recorded
    # only as a normal run so the medians stay honest.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
        $process = Start-Process -FilePath $Executable -ArgumentList $arguments `
            -RedirectStandardOutput $logPath -RedirectStandardError $stderrPath -PassThru -NoNewWindow
        $finished = $process.WaitForExit(60000)
        if (-not $finished) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Refresh()
        $producedSummary = $false
        if (Test-Path -LiteralPath $logPath) {
            $producedSummary = [bool](Select-String -LiteralPath $logPath -Pattern '^\[alicorn-scratchpad\] role=primary' -Quiet)
        }
        if ($finished -and $producedSummary) { return }
        Write-Output ("scratchpad {0}/{1} run {2} attempt {3} produced no summary; retrying" -f
            $scenarioName, $rendererName, $run, $attempt)
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    throw "scratchpad workload did not report a summary: $logPath`n$stderr"
}

$runRows = New-Object System.Collections.Generic.List[object]
$counterRows = New-Object System.Collections.Generic.List[object]
$workloadRows = New-Object System.Collections.Generic.List[object]

foreach ($scenario in $Scenarios) {
    foreach ($renderer in $Renderers) {
        for ($run = 1; $run -le $Runs; $run++) {
            $log = Join-Path $OutputDir ("{0}-{1}-run{2}.txt" -f $scenario.Name, $renderer.Name, $run)
            Invoke-Scenario $scenario.Name $renderer.Name $renderer.Arguments $scenario.Interaction `
                $scenario.Frames $scenario.Hold $run $log
            foreach ($line in Get-Content -LiteralPath $log) {
                if ($line -match '^\[alicorn-scratchpad-stage\]') {
                    $m = Convert-Line-Metrics $line
                    $runRows.Add([pscustomobject]@{
                        scenario = $scenario.Name
                        renderer = $renderer.Name
                        run = $run
                        stage = $m['stage']
                        samples = $m['samples']
                        p50_ns = [double]$m['p50_ns']
                        p95_ns = [double]$m['p95_ns']
                        p99_ns = [double]$m['p99_ns']
                        max_ns = [double]$m['max_ns']
                    })
                } elseif ($line -match '^\[alicorn-scratchpad-counters\]') {
                    $m = Convert-Line-Metrics $line
                    $counterRows.Add([pscustomobject]@{
                        scenario = $scenario.Name
                        renderer = $renderer.Name
                        run = $run
                        samples = [int]$m['samples']
                        descriptions_emitted = [double]$m['descriptions_emitted']
                        descriptions_reused = [double]$m['descriptions_reused']
                        descriptions_retained_match = [double]$m['descriptions_retained_match']
                        structure_sequence_matches = [double]$m['structure_sequence_matches']
                        reconcile_visits = [double]$m['reconcile_visits']
                        measure_requests = [double]$m['measure_requests']
                        measure_hits = [double]$m['measure_hits']
                        measure_misses = [double]$m['measure_misses']
                        layout_visits = [double]$m['layout_visits']
                        paint_visits = [double]$m['paint_visits']
                        composition_visits = [double]$m['composition_visits']
                        text_shape_requests = [double]$m['text_shape_requests']
                        semantic_entities = [double]$m['semantic_entities']
                        semantic_structure_changes = [double]$m['semantic_structure_changes']
                        semantic_property_changes = [double]$m['semantic_property_changes']
                        nodes_created = [double]$m['nodes_created']
                        nodes_retired = [double]$m['nodes_retired']
                        display_finalization_full_passes = [double]$m['display_finalization_full_passes']
                        global_fallbacks = [double]$m['global_fallbacks']
                        persistent_alloc_calls = [double]$m['persistent_alloc_calls']
                        scratch_alloc_calls = [double]$m['scratch_alloc_calls']
                    })
                } elseif ($line -match '^\[alicorn-workload-runtime\]') {
                    $m = Convert-Line-Metrics $line
                    $workloadRows.Add([pscustomobject]@{
                        scenario = $scenario.Name
                        renderer = $renderer.Name
                        run = $run
                        frames_built = [double]$m['frames_built']
                        idle_frames = [double]$m['idle_frames']
                        descriptions_emitted = [double]$m['descriptions_emitted']
                        descriptions_reused = [double]$m['descriptions_reused']
                        layout_nodes_visited = [double]$m['layout_nodes_visited']
                        paint_nodes_visited = [double]$m['paint_nodes_visited']
                        display_commands_finalized = [double]$m['display_commands_finalized']
                        text_shape_requests = [double]$m['text_shape_requests']
                    })
                }
            }
            Write-Output ("scratchpad {0}/{1} run {2} complete" -f $scenario.Name, $renderer.Name, $run)
        }
    }
}

function Get-Median([double[]]$values) {
    $items = @($values | Sort-Object)
    if ($items.Count -eq 0) { return 0 }
    $middle = [int][Math]::Floor($items.Count / 2)
    if ($items.Count % 2 -eq 1) { return $items[$middle] }
    return ($items[$middle - 1] + $items[$middle]) / 2
}

$runRows | Export-Csv -LiteralPath (Join-Path $OutputDir 'scratchpad-runs.csv') -NoTypeInformation
$counterRows | Export-Csv -LiteralPath (Join-Path $OutputDir 'scratchpad-counters-runs.csv') -NoTypeInformation
$workloadRows | Export-Csv -LiteralPath (Join-Path $OutputDir 'scratchpad-workload-runs.csv') -NoTypeInformation

$summaryRows = New-Object System.Collections.Generic.List[object]
foreach ($scenario in $Scenarios) {
    foreach ($renderer in $Renderers) {
        $stageGroups = $runRows | Where-Object { $_.scenario -eq $scenario.Name -and $_.renderer -eq $renderer.Name } |
            Group-Object stage
        foreach ($group in $stageGroups) {
            $summaryRows.Add([pscustomobject]@{
                scenario = $scenario.Name
                renderer = $renderer.Name
                stage = $group.Name
                runs = $group.Count
                p50_ns = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.p50_ns }))
                p95_ns = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.p95_ns }))
                p99_ns = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.p99_ns }))
            })
        }
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDir 'scratchpad-summary.csv') -NoTypeInformation

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Scratchpad-shaped workload summary')
$lines.Add('')
$lines.Add(("Runs per scenario and renderer: {0}. Frames: {1}. CPU wall time only; no GPU execution or scanout." -f $Runs, $Frames))
$lines.Add('')
$lines.Add('`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.')
$lines.Add('')
$stageOrder = @('description', 'reconcile', 'reconcile_hash', 'reconcile_copy', 'structure_diff',
    'measure', 'measure_text', 'layout', 'semantic_sync', 'paint', 'composition', 'finalize',
    'application_build', 'reconcile_other')
foreach ($scenario in $Scenarios) {
    $lines.Add(("## {0}" -f $scenario.Name))
    $lines.Add('')
    $lines.Add('| Stage (median of per-run p95) | ' + (($Renderers | ForEach-Object { $_.Name }) -join ' | ') + ' |')
    $lines.Add('|---|' + (($Renderers | ForEach-Object { '---:' }) -join '|') + '|')
    foreach ($stage in $stageOrder) {
        $values = foreach ($renderer in $Renderers) {
            $row = $summaryRows | Where-Object {
                $_.scenario -eq $scenario.Name -and $_.renderer -eq $renderer.Name -and $_.stage -eq $stage
            } | Select-Object -First 1
            if ($null -eq $row) { 'n/a' } else { ('{0:N3}' -f ($row.p95_ns / 1000000.0)) }
        }
        $lines.Add(('| {0} | {1} |' -f $stage, ($values -join ' | ')))
    }
    $lines.Add('')
}
$lines.Add('## Description percentiles (median across runs)')
$lines.Add('')
$lines.Add('| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |')
$lines.Add('|---|---|---:|---:|---:|')
foreach ($scenario in $Scenarios) {
    foreach ($renderer in $Renderers) {
        $row = $summaryRows | Where-Object {
            $_.scenario -eq $scenario.Name -and $_.renderer -eq $renderer.Name -and $_.stage -eq 'description'
        } | Select-Object -First 1
        if ($null -eq $row) { continue }
        $lines.Add(('| {0} | {1} | {2:N3} | {3:N3} | {4:N3} |' -f
            $scenario.Name, $renderer.Name,
            ($row.p50_ns / 1000000.0), ($row.p95_ns / 1000000.0), ($row.p99_ns / 1000000.0)))
    }
}
$lines.Add('')
$lines.Add('## Retained-work counters (median across runs)')
$lines.Add('')
$lines.Add('| Scenario | Renderer | descriptions emitted | reused | exact-match reuses | structure-sequence matches | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |')
$lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($scenario in $Scenarios) {
    foreach ($renderer in $Renderers) {
        $rows = @($counterRows | Where-Object { $_.scenario -eq $scenario.Name -and $_.renderer -eq $renderer.Name })
        if ($rows.Count -eq 0) { continue }
        $lines.Add(('| {0} | {1} | {2:N0} | {3:N0} | {4:N0} | {5:N0} | {6:N0} | {7:N0} | {8:N0} | {9:N0} | {10:N0} | {11:N0} | {12:N0} | {13:N0} | {14:N0} | {15:N0} |' -f
            $scenario.Name, $renderer.Name,
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.descriptions_emitted }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.descriptions_reused }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.descriptions_retained_match }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.structure_sequence_matches }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.reconcile_visits }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.measure_requests }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.text_shape_requests }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.layout_visits }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.paint_visits }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.composition_visits }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.display_finalization_full_passes }))),
            ((Get-Median ([double[]]@($rows | ForEach-Object { $_.semantic_structure_changes }))) +
             (Get-Median ([double[]]@($rows | ForEach-Object { $_.semantic_property_changes })))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.persistent_alloc_calls }))),
            (Get-Median ([double[]]@($rows | ForEach-Object { $_.scratch_alloc_calls }))))
        )
    }
}
$lines.Add('')
Set-Content -LiteralPath (Join-Path $OutputDir 'scratchpad-summary.md') -Value $lines -Encoding UTF8
Write-Output ("scratchpad workload summary: {0}" -f (Join-Path $OutputDir 'scratchpad-summary.md'))
