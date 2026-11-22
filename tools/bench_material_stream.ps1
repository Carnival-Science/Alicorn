param(
    [string]$Odin,
    [int]$Runs = 5,
    [int]$Passes = 24,
    [int]$IdleHoldMs = 1200,
    [string[]]$Treatments = @(
        'rect-flat-h0', 'rect-flat-h05', 'rect-relief-h0', 'rect-relief-h05',
        'rounded-flat-h0', 'rounded-flat-h05', 'rounded-relief-h0', 'rounded-relief-h05'
    ),
    [string[]]$Conditions = @('cold', 'warm', 'resize', 'theme', 'hover', 'scroll', 'idle'),
    [string[]]$ScratchpadInteractions = @('typing', 'scroll'),
    [string]$OutputDir = 'out\issue-104-material-stream',
    [switch]$SkipBuild,
    [switch]$SkipWindow,
    [switch]$SkipWebGPU,
    [switch]$SkipScratchpad,
    [switch]$SkipOffscreen,
    [switch]$Quick
)

# Issue #104 phase A harness. It builds one executable that:
#   * describes the same 500 card + 28 scrolling-row stream through ui.run,
#   * describes it through the hosted WebGPU presenter,
#   * renders the same resolved command stream offscreen at 1x/1.25x/1.5x/2x.
# Every number is host CPU wall time or a renderer counter. The offscreen
# fence wait is a GPU completion round trip, not presented-frame latency.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$AccessKit = Get-AlicornAccessKit
$OutputDir = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $OutputDir)).Path
$Executable = Join-Path $OutputDir 'material_stream.exe'

function Copy-RuntimeDlls([string]$directory) {
    $odinRoot = Split-Path -Parent $Odin
    Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $directory 'SDL3.dll') -Force
    Copy-Item (Join-Path $odinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll') `
        (Join-Path $directory 'wgpu_native.dll') -Force
}

function Invoke-Logged([string[]]$arguments, [string]$log, [int]$timeoutMs = 60000) {
    $errorLog = "$log.stderr"
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    if (Test-Path -LiteralPath $errorLog) { Remove-Item -LiteralPath $errorLog -Force }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMs)) {
        try { $process.Kill() } catch {}
        throw "material stream run timed out after ${timeoutMs}ms: $log"
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    Set-Content -LiteralPath $log -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath $errorLog -Value $stderr -Encoding UTF8
    if ($process.ExitCode -ne 0) {
        throw "material stream run exited with $($process.ExitCode): $log`n$stderr"
    }
}

# Read-Tokens merges every 'key=value' and "key value" token from the log into
# one dictionary. Later lines win, which is what the exit summary wants.
function Read-Tokens([string]$path) {
    $tokens = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $tokens }
    foreach ($line in Get-Content -LiteralPath $path) {
        $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $token = $parts[$i]
            if ($token -match '^([A-Za-z0-9_]+)=([-0-9]+(?:\.[0-9]+)?)$') {
                $tokens[$Matches[1]] = [double]$Matches[2]
            } elseif ($token -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $i + 1 -lt $parts.Count -and
                      $parts[$i + 1] -match '^-?[0-9]+(?:\.[0-9]+)?$') {
                $tokens[$token] = [double]$parts[$i + 1]
            }
        }
    }
    return $tokens
}

function Token($tokens, [string]$key) {
    if ($tokens -and $tokens.ContainsKey($key)) { return $tokens[$key] }
    return $null
}

function Median([object[]]$values) {
    $present = @($values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($present.Count -eq 0) { return $null }
    $sorted = @($present | Sort-Object)
    if ($sorted.Count % 2 -eq 1) { return $sorted[[int]($sorted.Count / 2)] }
    return ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2
}

if (-not $SkipBuild) {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build (Join-Path $RepoRoot 'benchmarks\material_stream') `
        "-collection:alicorn=$RepoRoot" -define:WGPU_SHARED=true -o:speed `
        "-out:$Executable" @($AccessKit.CompilerArguments) 2>&1 | ForEach-Object { Write-Output $_ }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($buildExit -ne 0) { exit $buildExit }
}
Copy-RuntimeDlls $OutputDir

# ---- dogfood trace --------------------------------------------------------
$dogfoodLog = Join-Path $OutputDir 'dogfood.txt'
Invoke-Logged @('--mode=dogfood') $dogfoodLog 60000
$dogfoodLines = @(Get-Content -LiteralPath $dogfoodLog | Where-Object { $_ -match '^\[alicorn-material-dogfood\]' })
foreach ($line in $dogfoodLines) { Write-Output $line }

# ---- offscreen scale sweep ------------------------------------------------
$offRows = New-Object System.Collections.Generic.List[object]
if (-not $SkipOffscreen) {
    $offscreenDir = Join-Path $OutputDir 'offscreen'
    New-Item -ItemType Directory -Force -Path $offscreenDir | Out-Null
    $offRuns = if ($Quick) { 1 } else { $Runs }
    for ($run = 1; $run -le $offRuns; $run++) {
        $log = Join-Path $offscreenDir ("offscreen-run{0}.txt" -f $run)
        Invoke-Logged @('--mode=offscreen') $log 900000
        foreach ($line in Get-Content -LiteralPath $log) {
            if ($line -notmatch '^\[alicorn-material-offscreen\]') { continue }
            $tokens = @{}
            foreach ($token in ($line -split '\s+')) {
                if ($token -match '^([A-Za-z0-9_]+)=([-0-9]+(?:\.[0-9]+)?)$') {
                    $tokens[$Matches[1]] = [double]$Matches[2]
                }
            }
            $offRows.Add([pscustomobject]@{
                run = $run
                backend = 'offscreen-d3d12'
                treatment = ($line -replace '^.*treatment=([^\s]+).*$', '$1')
                condition = ($line -replace '^.*condition=([^\s]+).*$', '$1')
                scale = Token $tokens 'scale'
                surfaces = Token $tokens 'surfaces'
                passes = Token $tokens 'passes'
                vertices_per_pass = Token $tokens 'vertices_per_pass'
                draw_calls_per_pass = Token $tokens 'draw_calls_per_pass'
                upload_bytes_per_pass = Token $tokens 'upload_bytes_per_pass'
                peak_vertex_capacity = Token $tokens 'peak_vertex_capacity'
                growth_events = Token $tokens 'growth_events'
                growth_ms = Token $tokens 'growth_ms'
                idle_waits = Token $tokens 'idle_waits'
                idle_ms = Token $tokens 'idle_ms'
                build_p50_ns = Token $tokens 'build_p50_ns'
                build_p95_ns = Token $tokens 'build_p95_ns'
                build_p99_ns = Token $tokens 'build_p99_ns'
                pack_p50_ns = Token $tokens 'pack_p50_ns'
                pack_p95_ns = Token $tokens 'pack_p95_ns'
                pack_p99_ns = Token $tokens 'pack_p99_ns'
                submit_p50_ns = Token $tokens 'submit_p50_ns'
                submit_p95_ns = Token $tokens 'submit_p95_ns'
                submit_p99_ns = Token $tokens 'submit_p99_ns'
                gpu_wait_p50_ns = Token $tokens 'wait_p50_ns'
                gpu_wait_p95_ns = Token $tokens 'wait_p95_ns'
                gpu_wait_p99_ns = Token $tokens 'wait_p99_ns'
                wall_p50_ns = Token $tokens 'wall_p50_ns'
                wall_p95_ns = Token $tokens 'wall_p95_ns'
                wall_p99_ns = Token $tokens 'wall_p99_ns'
            })
        }
        Write-Output "offscreen run $run complete"
    }
    $offRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputDir 'offscreen-runs.csv') -Encoding UTF8
}

# ---- window / hosted matrix ----------------------------------------------
$windowRows = New-Object System.Collections.Generic.List[object]
function Invoke-WindowMatrix([string]$backend, [string[]]$extraArguments, [string]$tag) {
    $matrixDir = Join-Path $OutputDir $tag
    New-Item -ItemType Directory -Force -Path $matrixDir | Out-Null
    for ($run = 1; $run -le $Runs; $run++) {
        foreach ($treatment in $Treatments) {
            foreach ($condition in $Conditions) {
                $log = Join-Path $matrixDir ("{0}-{1}-run{2}.txt" -f $treatment, $condition, $run)
                $arguments = @(
                    "--backend=$backend", "--treatment=$treatment", "--condition=$condition",
                    "--passes=$Passes", "--smoke", "--smoke-hold-ms=$IdleHoldMs"
                ) + $extraArguments
                Invoke-Logged $arguments $log 60000
                $tokens = Read-Tokens $log
                $submissions = if ($null -ne (Token $tokens 'primary_gpu_submissions')) { Token $tokens 'primary_gpu_submissions' } else { Token $tokens 'frames_presented' }
                $drawCalls = Token $tokens 'solid_draw_calls'
                $uploadBytes = Token $tokens 'solid_vertex_upload_bytes'
                $drawCallsPerPass = if ($null -ne $drawCalls -and $null -ne $submissions -and $submissions -gt 0) { $drawCalls / $submissions } else { $null }
                $uploadBytesPerPass = if ($null -ne $uploadBytes -and $null -ne $submissions -and $submissions -gt 0) { $uploadBytes / $submissions } else { $null }
                $windowRows.Add([pscustomobject]@{
                    run = $run
                    backend = $tag
                    treatment = $treatment
                    condition = $condition
                    passes = Token $tokens 'passes'
                    submissions = $submissions
                    wake_deliveries = Token $tokens 'wake_deliveries'
                    commands = Token $tokens 'commands'
                    realized_rows = Token $tokens 'realized_rows'
                    description_p50_ns = Token $tokens 'description_p50_ns'
                    description_p95_ns = Token $tokens 'description_p95_ns'
                    description_p99_ns = Token $tokens 'description_p99_ns'
                    build_p50_ns = if ($null -ne (Token $tokens 'application_build_p50_ns')) { Token $tokens 'application_build_p50_ns' } else { Token $tokens 'runtime_step_ns_p50' }
                    build_p95_ns = if ($null -ne (Token $tokens 'application_build_p95_ns')) { Token $tokens 'application_build_p95_ns' } else { Token $tokens 'runtime_step_ns_p95' }
                    build_p99_ns = if ($null -ne (Token $tokens 'application_build_p99_ns')) { Token $tokens 'application_build_p99_ns' } else { Token $tokens 'runtime_step_ns_p99' }
                    solid_build_p50_ns = Token $tokens 'solid_build_p50_ns'
                    solid_build_p95_ns = Token $tokens 'solid_build_p95_ns'
                    solid_build_p99_ns = Token $tokens 'solid_build_p99_ns'
                    encode_p50_ns = if ($null -ne (Token $tokens 'renderer_encode_ns_p50')) { Token $tokens 'renderer_encode_ns_p50' } else { Token $tokens 'renderer_encode_ns_p50' }
                    encode_p95_ns = Token $tokens 'renderer_encode_ns_p95'
                    encode_p99_ns = Token $tokens 'renderer_encode_ns_p99'
                    submit_p50_ns = if ($null -ne (Token $tokens 'queue_submit_ns_p50')) { Token $tokens 'queue_submit_ns_p50' } else { Token $tokens 'queue_submit_ns_p50' }
                    submit_p95_ns = Token $tokens 'queue_submit_ns_p95'
                    submit_p99_ns = Token $tokens 'queue_submit_ns_p99'
                    step_to_present_p50_ns = Token $tokens 'step_to_present_ns_p50'
                    frame_p95_ns = Token $tokens 'frame_p95_ns'
                    draw_calls = Token $tokens 'solid_draw_calls'
                    draw_calls_per_pass = $drawCallsPerPass
                    upload_bytes = Token $tokens 'solid_vertex_upload_bytes'
                    upload_bytes_per_pass = $uploadBytesPerPass
                    vertex_capacity_peak = Token $tokens 'solid_vertex_capacity_peak'
                    growth_events = Token $tokens 'solid_vertex_growth_events'
                    growth_ns = Token $tokens 'solid_vertex_growth_ns'
                    idle_waits = Token $tokens 'solid_device_idle_waits'
                    idle_ns = Token $tokens 'solid_device_idle_ns'
                    solid_batches = Token $tokens 'solid_batches'
                    solid_mesh_rebuilds = Token $tokens 'solid_mesh_rebuilds'
                    solid_vertex_uploads = Token $tokens 'solid_vertex_uploads'
                    solid_transform_uploads = Token $tokens 'solid_transform_uploads'
                    solid_transform_upload_bytes = Token $tokens 'solid_transform_upload_bytes'
                    idle_after_last_submit_ns = if ($null -ne (Token $tokens 'idle_after_last_submit_ns')) { Token $tokens 'idle_after_last_submit_ns' } else { Token $tokens 'idle_after_last_present_ns' }
                })
            }
        }
        Write-Output "$tag run $run complete"
    }
}

if (-not $SkipWindow) {
    Invoke-WindowMatrix 'sdl-gpu' @() 'sdl-gpu'
}
if (-not $SkipWebGPU) {
    Invoke-WindowMatrix 'd3d12' @('--timings') 'webgpu-d3d12'
}

# ---- Scratchpad-representative variant -----------------------------------
$scratchRows = New-Object System.Collections.Generic.List[object]
if (-not $SkipScratchpad) {
    $scratchDir = Join-Path $OutputDir 'scratchpad'
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    foreach ($backend in @('sdl-gpu', 'd3d12')) {
        $tag = if ($backend -eq 'sdl-gpu') { 'sdl-gpu-scratchpad' } else { 'webgpu-d3d12-scratchpad' }
        $extra = if ($backend -eq 'd3d12') { @('--timings') } else { @() }
        for ($run = 1; $run -le $Runs; $run++) {
            foreach ($interaction in $ScratchpadInteractions) {
                $log = Join-Path $scratchDir ("{0}-{1}-run{2}.txt" -f $tag, $interaction, $run)
                $arguments = @(
                    "--backend=$backend", '--scene=scratchpad', "--interaction=$interaction",
                    "--passes=$Passes", '--smoke', "--smoke-hold-ms=$IdleHoldMs"
                ) + $extra
                Invoke-Logged $arguments $log 60000
                $tokens = Read-Tokens $log
                $submissions = if ($null -ne (Token $tokens 'primary_gpu_submissions')) { Token $tokens 'primary_gpu_submissions' } else { Token $tokens 'frames_presented' }
                $solidUpload = Token $tokens 'solid_vertex_upload_bytes'
                $solidDraws = Token $tokens 'solid_draw_calls'
                $scratchRows.Add([pscustomobject]@{
                    run = $run
                    backend = $tag
                    interaction = $interaction
                    submissions = $submissions
                    display_commands = Token $tokens 'display_commands'
                    description_p50_ns = Token $tokens 'description_p50_ns'
                    build_p50_ns = if ($null -ne (Token $tokens 'application_build_p50_ns')) { Token $tokens 'application_build_p50_ns' } else { Token $tokens 'runtime_step_ns_p50' }
                    build_p95_ns = if ($null -ne (Token $tokens 'application_build_p95_ns')) { Token $tokens 'application_build_p95_ns' } else { Token $tokens 'runtime_step_ns_p95' }
                    build_p99_ns = if ($null -ne (Token $tokens 'application_build_p99_ns')) { Token $tokens 'application_build_p99_ns' } else { Token $tokens 'runtime_step_ns_p99' }
                    solid_build_p50_ns = Token $tokens 'solid_build_p50_ns'
                    solid_build_p95_ns = Token $tokens 'solid_build_p95_ns'
                    solid_build_p99_ns = Token $tokens 'solid_build_p99_ns'
                    encode_p50_ns = Token $tokens 'renderer_encode_ns_p50'
                    encode_p95_ns = Token $tokens 'renderer_encode_ns_p95'
                    submit_p50_ns = Token $tokens 'queue_submit_ns_p50'
                    solid_draw_calls = $solidDraws
                    draw_calls_per_pass = if ($null -ne $solidDraws -and $null -ne $submissions -and $submissions -gt 0) { $solidDraws / $submissions } else { $null }
                    solid_upload_bytes = $solidUpload
                    solid_vertex_uploads = Token $tokens 'solid_vertex_uploads'
                    solid_mesh_rebuilds = Token $tokens 'solid_mesh_rebuilds'
                    solid_transform_uploads = Token $tokens 'solid_transform_uploads'
                })
            }
        }
    }
    $scratchRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputDir 'scratchpad-runs.csv') -Encoding UTF8
}
$windowRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputDir 'window-runs.csv') -Encoding UTF8

# ---- summary --------------------------------------------------------------
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('# Issue #104 phase A material-stream matrix')
$summary.Add('')
$summary.Add("Runs: $Runs; passes per condition: $Passes; idle hold: $IdleHoldMs ms.")
$summary.Add('All values are host CPU wall time or renderer counters. `gpu_wait` is a fence completion round trip on an offscreen target, not presented-frame latency or scan-out.')
$summary.Add('')

function Add-MedianTable($rows, [string]$title, [string]$groupField, [string]$backend) {
    $filtered = @($rows | Where-Object { $_.backend -eq $backend })
    if ($filtered.Count -eq 0) { return }
    $summary.Add("## $title")
    $summary.Add('')
    $summary.Add('| Treatment | Condition | Scale | Build p50/p95 us | Pack p50/p95 us | Submit p50 us | GPU wait p50/p95 us | Wall p50/p95 us | Draws | Upload B/pass | Peak verts | Growth | Idle ms |')
    $summary.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    $groups = $filtered | Group-Object { "$($_.treatment)|$($_.condition)|$($_.scale)" } | Sort-Object Name
    foreach ($group in $groups) {
        $items = @($group.Group)
        $first = $items[0]
        $fmtUs = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N2}' -f ([double]$v / 1000) } }
        $fmt = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N0}' -f [double]$v } }
        $summary.Add(("| {0} | {1} | {2} | {3}/{4} | {5}/{6} | {7} | {8}/{9} | {10}/{11} | {12} | {13} | {14} | {15} | {16} |" -f `
            $first.treatment, $first.condition, $first.scale,
            (& $fmtUs (Median @($items | ForEach-Object { $_.build_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.build_p95_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.pack_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.pack_p95_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.submit_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.gpu_wait_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.gpu_wait_p95_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.wall_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.wall_p95_ns }))),
            (& $fmt (Median @($items | ForEach-Object { $_.draw_calls_per_pass }))),
            (& $fmt (Median @($items | ForEach-Object { $_.upload_bytes_per_pass }))),
            (& $fmt (Median @($items | ForEach-Object { $_.peak_vertex_capacity }))),
            (& $fmt (Median @($items | ForEach-Object { $_.growth_events }))),
            (& $fmt (Median @($items | ForEach-Object { $_.idle_ms })))))
    }
    $summary.Add('')
}

Add-MedianTable $offRows 'Offscreen GPU sweep (D3D12)' 'treatment' 'offscreen-d3d12'

foreach ($backend in @('sdl-gpu', 'webgpu-d3d12')) {
    $filtered = @($windowRows | Where-Object { $_.backend -eq $backend })
    if ($filtered.Count -eq 0) { continue }
    $summary.Add("## Window matrix: $backend")
    $summary.Add('')
    $summary.Add('| Treatment | Condition | Submits | Solid build p50/p95/p99 us | Encode p50/p95/p99 us | Submit p50 us | Description p50 us | Draws/pass | Upload B/pass | Peak verts | Growth | Idle stalls | Mesh rebuilds |')
    $summary.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    $groups = $filtered | Group-Object { "$($_.treatment)|$($_.condition)" } | Sort-Object Name
    foreach ($group in $groups) {
        $items = @($group.Group)
        $first = $items[0]
        $fmtUs = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N2}' -f ([double]$v / 1000) } }
        $fmt = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N0}' -f [double]$v } }
        $summary.Add(("| {0} | {1} | {2} | {3}/{4}/{5} | {6}/{7}/{8} | {9} | {10} | {11} | {12} | {13} | {14} | {15} | {16} |" -f `
            $first.treatment, $first.condition,
            (& $fmt (Median @($items | ForEach-Object { $_.submissions }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.solid_build_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.solid_build_p95_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.solid_build_p99_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.encode_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.encode_p95_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.encode_p99_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.submit_p50_ns }))),
            (& $fmtUs (Median @($items | ForEach-Object { $_.description_p50_ns }))),
            (& $fmt (Median @($items | ForEach-Object { $_.draw_calls_per_pass }))),
            (& $fmt (Median @($items | ForEach-Object { $_.upload_bytes_per_pass }))),
            (& $fmt (Median @($items | ForEach-Object { $_.vertex_capacity_peak }))),
            (& $fmt (Median @($items | ForEach-Object { $_.growth_events }))),
            (& $fmt (Median @($items | ForEach-Object { $_.idle_waits }))),
            (& $fmt (Median @($items | ForEach-Object { $_.solid_mesh_rebuilds })))))
    }
    $summary.Add('')
}

$summary.Add('## Dogfood trace')
$summary.Add('')
foreach ($line in $dogfoodLines) { $summary.Add("- ``$line``") }
$summary.Add('')

if (Test-Path (Join-Path $OutputDir 'scratchpad-runs.csv')) {
    $scratch = Import-Csv (Join-Path $OutputDir 'scratchpad-runs.csv')
    if ($scratch.Count -gt 0) {
        $summary.Add('## Scratchpad-representative variant')
        $summary.Add('')
        $summary.Add('| Backend | Interaction | Submits | Display commands | Description p50 us | Build p50/p95/p99 us | Encode p50/p95 us | Solid build p50/p95 us | Draws/pass | Solid upload B | Mesh rebuilds | Transform uploads |')
        $summary.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
        $groups = $scratch | Group-Object { "$($_.backend)|$($_.interaction)" } | Sort-Object Name
        foreach ($group in $groups) {
            $items = @($group.Group)
            $first = $items[0]
            $fmtUs = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N2}' -f ([double]$v / 1000) } }
            $fmt = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N0}' -f [double]$v } }
            $summary.Add(("| {0} | {1} | {2} | {3} | {4} | {5}/{6}/{7} | {8}/{9} | {10}/{11} | {12} | {13} | {14} | {15} |" -f `
                $first.backend, $first.interaction,
                (& $fmt (Median @($items | ForEach-Object { $_.submissions }))),
                (& $fmt (Median @($items | ForEach-Object { $_.display_commands }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.description_p50_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.build_p50_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.build_p95_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.build_p99_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.encode_p50_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.encode_p95_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.solid_build_p50_ns }))),
                (& $fmtUs (Median @($items | ForEach-Object { $_.solid_build_p95_ns }))),
                (& $fmt (Median @($items | ForEach-Object { $_.draw_calls_per_pass }))),
                (& $fmt (Median @($items | ForEach-Object { $_.solid_upload_bytes }))),
                (& $fmt (Median @($items | ForEach-Object { $_.solid_mesh_rebuilds }))),
                (& $fmt (Median @($items | ForEach-Object { $_.solid_transform_uploads })))))
        }
        $summary.Add('')
    }
}

$summaryPath = Join-Path $OutputDir 'material-stream-summary.md'
$summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Output "summary=$summaryPath"
Write-Output "window_csv=$(Join-Path $OutputDir 'window-runs.csv')"
Write-Output "offscreen_csv=$(Join-Path $OutputDir 'offscreen-runs.csv')"
