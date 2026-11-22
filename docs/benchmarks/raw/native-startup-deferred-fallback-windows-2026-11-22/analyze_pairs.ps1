# Paired A/B analysis for the issue #172 phase-2 deferred-fallback prototype.
# Reads the paired bench_startup.ps1 outputs (hello/, scratchpad/, punks/,
# probe-*/ and idle-*/) and writes paired-summary.json next to this script.
#
# For each app and metric it reports:
#   arms.<arm>.p50/p95      raw per-arm percentiles (what a naive A/B reports)
#   paired.<metric>.median  median of the per-round (prototype - baseline)
#   paired.<metric>.wins    rounds where the prototype arm was lower
# The median of per-round deltas is the primary statistic: each round ran both
# arms back to back in alternating order, so a monotonic drift cancels.

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

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

function Get-Median {
    param([double[]]$Values)
    return Get-Percentile -Values $Values -Fraction 0.5
}

$Metrics = @(
    'window_shown_ns', 'first_application_submit_ns', 'first_input_ready_ns',
    'fonts_ns', 'fonts_requested_bytes', 'gpu_device_create_ns', 'build_initial_ns',
    'settle_working_set_bytes', 'peak_working_set_bytes',
    'settle_private_bytes', 'peak_private_bytes',
    'settle_gpu_dedicated_bytes', 'settle_gpu_shared_bytes',
    'peak_gpu_dedicated_bytes',
    'runtime_persistent_requested_live_bytes', 'runtime_persistent_requested_peak_bytes',
    'cpu_total_ms',
    'deferred_system_font_faces', 'deferred_system_font_ns', 'deferred_system_font_at_ns',
    'fallback_probe_build_ns', 'fallback_probe_at_ns', 'fallback_probe_fallback_glyphs',
    'fallback_probe_unresolved'
)

function Read-PairedSuite {
    param([string]$Directory, [string]$App)
    $summaryPath = Join-Path $Directory 'summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { return $null }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $samples = @($summary.apps.$App.samples | Where-Object { $_.phase -eq 'warm-order' })
    $arms = [ordered]@{}
    foreach ($label in @($summary.arms.primary_label, $summary.arms.compare_label)) {
        $armSamples = @($samples | Where-Object { $_.arm -eq $label })
        if ($armSamples.Count -eq 0) { continue }
        $arm = [ordered]@{ n = $armSamples.Count; arguments = @(); metrics = [ordered]@{} }
        $arm.arguments = if ($label -eq $summary.arms.primary_label) {
            @($summary.arms.primary_arguments)
        } else {
            @($summary.arms.compare_arguments)
        }
        foreach ($metric in $Metrics) {
            $values = @()
            foreach ($sample in $armSamples) {
                $property = $sample.PSObject.Properties[$metric]
                if ($null -ne $property -and $null -ne $property.Value) { $values += [double]$property.Value }
            }
            if ($values.Length -eq 0) { continue }
            $arm.metrics[$metric] = [ordered]@{
                p50 = Get-Percentile -Values $values -Fraction 0.50
                p95 = Get-Percentile -Values $values -Fraction 0.95
                min = ($values | Measure-Object -Minimum).Minimum
                max = ($values | Measure-Object -Maximum).Maximum
            }
        }
        $arms[$label] = $arm
    }
    # Pair by the numeric round suffix of the run id.
    $byRound = @{}
    foreach ($sample in $samples) {
        if ($sample.run -notmatch '(\d+)$') { continue }
        $round = [int]$Matches[1]
        if (-not $byRound.ContainsKey($round)) { $byRound[$round] = @{} }
        $byRound[$round][$sample.arm] = $sample
    }
    $paired = [ordered]@{}
    foreach ($metric in $Metrics) {
        $deltas = @()
        $wins = 0
        foreach ($round in ($byRound.Keys | Sort-Object)) {
            $pair = $byRound[$round]
            if (-not $pair.ContainsKey($summary.arms.primary_label) -or -not $pair.ContainsKey($summary.arms.compare_label)) { continue }
            $p = $pair[$summary.arms.primary_label]
            $b = $pair[$summary.arms.compare_label]
            $pp = $p.PSObject.Properties[$metric]
            $bp = $b.PSObject.Properties[$metric]
            if ($null -eq $pp -or $null -eq $bp -or $null -eq $pp.Value -or $null -eq $bp.Value) { continue }
            $delta = [double]$pp.Value - [double]$bp.Value
            $deltas += $delta
            if ($delta -lt 0) { $wins += 1 }
        }
        if ($deltas.Length -eq 0) { continue }
        $paired[$metric] = [ordered]@{
            n = $deltas.Length
            median = Get-Median -Values $deltas
            min = ($deltas | Measure-Object -Minimum).Minimum
            max = ($deltas | Measure-Object -Maximum).Maximum
            wins = $wins
        }
    }
    return [ordered]@{
        scenario = $summary.scenario
        runs_per_app = $summary.runs_per_app
        arms = $arms
        paired = $paired
    }
}

$result = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    delta_definition = 'prototype - baseline; negative means the prototype arm was lower (faster or smaller)'
    suites = [ordered]@{}
}

$suites = [ordered]@{
    'main-hello' = @{ dir = 'hello'; app = 'hello' }
    'main-scratchpad' = @{ dir = 'scratchpad'; app = 'scratchpad' }
    'main-punks' = @{ dir = 'punks'; app = 'punks' }
    'probe-hello' = @{ dir = 'probe-hello'; app = 'hello' }
    'probe-scratchpad' = @{ dir = 'probe-scratchpad'; app = 'scratchpad' }
    'probe-punks' = @{ dir = 'probe-punks'; app = 'punks' }
    'idle-hello-20s' = @{ dir = 'idle-hello'; app = 'hello' }
    'idle-scratchpad-20s' = @{ dir = 'idle-scratchpad'; app = 'scratchpad' }
}

foreach ($name in $suites.Keys) {
    $entry = $suites[$name]
    $suite = Read-PairedSuite -Directory (Join-Path $Root $entry.dir) -App $entry.app
    if ($null -eq $suite) {
        Write-Output "missing suite $name"
        continue
    }
    $result.suites[$name] = $suite
}

$outPath = Join-Path $Root 'paired-summary.json'
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output "paired summary: $outPath"
