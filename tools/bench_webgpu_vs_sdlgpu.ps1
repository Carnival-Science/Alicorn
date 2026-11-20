param(
    [string]$Odin,
    [int]$Runs = 5,
    # Legacy cold/motion comparison (default when -Matrix is absent).
    [switch]$Legacy,
    # Matched-description workload matrix.
    [switch]$Matrix,
    [int]$MatrixRuns = 5,
    [int]$Frames = 32,
    [int[]]$ScrollItems = @(1000, 10000),
    [int]$IdleHoldMs = 1200,
    [switch]$Strict,
    [string]$OutputDir = 'out\webgpu-phase0\perf-2026-11-19'
)

# Runs the retained-control cold/motion comparison and/or the matched-workload
# matrix. Both paths use one executable per scene: SDL_GPU (D3D12) and WebGPU
# (D3D12/Vulkan) share the application description, window size, and DPI.
# Timing values are host CPU wall time; neither path exposes GPU execution
# timestamps in this fixture.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$runLegacy = $Legacy -or (-not $Matrix)
$runMatrix = $Matrix

function Median([double[]]$values) {
    if ($values.Count -eq 0) { return $null }
    $sorted = @($values | Sort-Object)
    if ($sorted.Count % 2 -eq 1) { return $sorted[[int]($sorted.Count / 2)] }
    return ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2
}

function Percentile([double[]]$values, [double]$fraction) {
    if ($values.Count -eq 0) { return $null }
    $sorted = @($values | Sort-Object)
    $index = [int][Math]::Floor($fraction * ($sorted.Count - 1))
    return $sorted[$index]
}

function Copy-RuntimeDlls([string]$directory) {
    $odinRoot = Split-Path -Parent $Odin
    Copy-Item (Join-Path $odinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $directory 'SDL3.dll') -Force
    Copy-Item (Join-Path $odinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll') `
        (Join-Path $directory 'wgpu_native.dll') -Force
}

function Read-Metrics([string]$path) {
    # Returns primary and auxiliary per-window token dictionaries. Host timing
    # lines have no role; workload lines carry role=primary|auxiliary.
    $primary = @{}
    $auxiliary = @{}
    if (-not (Test-Path -LiteralPath $path)) { return @{ primary = $primary; auxiliary = $auxiliary } }
    foreach ($line in Get-Content -LiteralPath $path) {
        $target = $primary
        if ($line -match 'role=auxiliary') { $target = $auxiliary }
        $tokens = @($line -split '\s+' | Where-Object { $_ -ne '' })
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $token = $tokens[$i]
            if ($token -match '^([A-Za-z0-9_]+)=([-0-9]+(?:\.[0-9]+)?)$') {
                $target[$Matches[1]] = [double]$Matches[2]
            } elseif ($token -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $i + 1 -lt $tokens.Count -and
                      $tokens[$i + 1] -match '^-?[0-9]+(?:\.[0-9]+)?$') {
                # The SDL_GPU diagnostics print unquoted "key value" pairs.
                $target[$token] = [double]$tokens[$i + 1]
            }
        }
    }
    return @{ primary = $primary; auxiliary = $auxiliary }
}

function Metric($metrics, [string]$key) {
    if ($metrics -and $metrics.ContainsKey($key)) { return $metrics[$key] }
    return $null
}

function Divide-Or-Null($value, $divisor) {
    if ($null -eq $value -or $null -eq $divisor -or $divisor -eq 0) { return $null }
    return [double]$value / [double]$divisor
}

# ---------------------------------------------------------------------------
# Legacy cold/motion comparison
# ---------------------------------------------------------------------------

if ($runLegacy) {
    $Executable = Join-Path $OutputDir 'native_webgpu_ui_perf.exe'
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build (Join-Path $RepoRoot 'examples\16_native_webgpu_ui') `
        "-collection:alicorn=$RepoRoot" -define:WGPU_SHARED=true -o:speed `
        "-out:$Executable" @($AccessKit.CompilerArguments) 2>&1 | ForEach-Object { Write-Output $_ }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($buildExit -ne 0) { exit $buildExit }

    Copy-RuntimeDlls $OutputDir

    $configs = @(
        [pscustomobject]@{ Name = 'cold-sdl-gpu';        Args = @('--smoke', '--backend=sdl-gpu') },
        [pscustomobject]@{ Name = 'cold-webgpu-d3d12';   Args = @('--smoke', '--timings', '--backend=d3d12') },
        [pscustomobject]@{ Name = 'cold-webgpu-vulkan';  Args = @('--smoke', '--timings', '--backend=vulkan') },
        [pscustomobject]@{ Name = 'motion-sdl-gpu';      Args = @('--smoke', '--timing-motion', '--backend=sdl-gpu') },
        [pscustomobject]@{ Name = 'motion-webgpu-d3d12'; Args = @('--smoke', '--timings', '--timing-motion', '--backend=d3d12') },
        [pscustomobject]@{ Name = 'motion-webgpu-vulkan'; Args = @('--smoke', '--timings', '--timing-motion', '--backend=vulkan') }
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($config in $configs) {
        for ($run = 1; $run -le $Runs; $run++) {
            $log = Join-Path $OutputDir ("{0}-run{1}.txt" -f $config.Name, $run)
            $previousErrorAction = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $Executable @($config.Args) 2>&1 | Out-File -LiteralPath $log -Encoding UTF8
            $exitCode = $LASTEXITCODE
            $ErrorActionPreference = $previousErrorAction
            if ($exitCode -ne 0) { throw "$($config.Name) run $run exited with $exitCode" }
            $m = (Read-Metrics $log).primary
            $frames = if ($m.ContainsKey('samples')) { $m['samples'] } elseif ($m.ContainsKey('primary_gpu_submissions')) { $m['primary_gpu_submissions'] } else { 0 }
            $appBuild = if ($m.ContainsKey('application_build_ns') -and $frames -gt 0) { $m['application_build_ns'] / $frames } elseif ($m.ContainsKey('runtime_step_ns_p50')) { $m['runtime_step_ns_p50'] } else { $null }
            $encode = if ($m.ContainsKey('gpu_encode_ns') -and $frames -gt 0) { $m['gpu_encode_ns'] / $frames } elseif ($m.ContainsKey('renderer_encode_ns_p50')) { $m['renderer_encode_ns_p50'] } else { $null }
            $submit = if ($m.ContainsKey('gpu_submit_ns') -and $frames -gt 0) { $m['gpu_submit_ns'] / $frames } elseif ($m.ContainsKey('queue_submit_ns_p50')) { $m['queue_submit_ns_p50'] } else { $null }
            $rows.Add([pscustomobject]@{
                config = $config.Name
                run = $run
                frames = $frames
                app_build_ns = $appBuild
                encode_ns = $encode
                submit_ns = $submit
                present_ns = $m['surface_present_call_ns_p50']
                step_to_present_p50_ns = $m['step_to_present_ns_p50']
                step_to_present_p95_ns = $m['step_to_present_ns_p95']
                encode_total_ns = $m['gpu_encode_ns']
                submit_total_ns = $m['gpu_submit_ns']
                first_submit_ns = $m['first_application_submit_ns']
                wall_ns = $m['wall_ns']
                text_mesh_rebuilds = $m['text_mesh_rebuilds']
                text_mesh_cache_hits = $m['text_mesh_cache_hits']
                text_vertex_uploads = $m['text_vertex_uploads']
                motion_samples = $m['motion_samples']
            })
            Write-Output ("{0} run {1}: frames={2} encode_ns={3} submit_ns={4}" -f $config.Name, $run, $frames, $encode, $submit)
        }
    }

    $csv = Join-Path $OutputDir 'perf-runs.csv'
    $rows | Export-Csv -NoTypeInformation -LiteralPath $csv -Encoding UTF8

    $metricFields = @('frames', 'app_build_ns', 'encode_ns', 'submit_ns', 'present_ns', 'step_to_present_p50_ns', 'step_to_present_p95_ns', 'first_submit_ns')
    foreach ($config in $configs) {
        $configRows = @($rows | Where-Object { $_.config -eq $config.Name })
        Write-Output ("[{0}]" -f $config.Name)
        foreach ($field in $metricFields) {
            $values = @($configRows | Where-Object { $null -ne $_.$field } | ForEach-Object { [double]$_.$field })
            if ($values.Count -eq 0) { continue }
            Write-Output ("  {0} median={1} min={2} max={3} n={4}" -f $field, (Median $values), ($values | Measure-Object -Minimum).Minimum, ($values | Measure-Object -Maximum).Maximum, $values.Count)
        }
    }
    Write-Output "csv=$csv"
}

# ---------------------------------------------------------------------------
# Matched-description workload matrix
# ---------------------------------------------------------------------------

if ($runMatrix) {
    $MatrixOutput = Join-Path $OutputDir 'matrix'
    New-Item -ItemType Directory -Force -Path $MatrixOutput | Out-Null
    $Executable = Join-Path $MatrixOutput 'workload_matrix.exe'
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Odin build (Join-Path $RepoRoot 'benchmarks\workload_matrix') `
        "-collection:alicorn=$RepoRoot" -define:WGPU_SHARED=true -o:speed `
        "-out:$Executable" @($AccessKit.CompilerArguments) 2>&1 | ForEach-Object { Write-Output $_ }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($buildExit -ne 0) { exit $buildExit }
    Copy-RuntimeDlls $MatrixOutput

    $renderers = @(
        [pscustomobject]@{ Name = 'sdl-gpu';      Args = @('--backend=sdl-gpu'); Timings = $false },
        [pscustomobject]@{ Name = 'webgpu-d3d12'; Args = @('--backend=d3d12', '--timings'); Timings = $true },
        [pscustomobject]@{ Name = 'webgpu-vulkan'; Args = @('--backend=vulkan', '--timings'); Timings = $true }
    )
    $scenarios = New-Object System.Collections.Generic.List[object]
    $scenarios.Add([pscustomobject]@{ Name = 'identical'; Workload = 'identical'; Frames = $Frames })
    $scenarios.Add([pscustomobject]@{ Name = 'transform'; Workload = 'transform'; Frames = 1 })
    $scenarios.Add([pscustomobject]@{ Name = 'color'; Workload = 'color'; Frames = $Frames })
    $scenarios.Add([pscustomobject]@{ Name = 'layout'; Workload = 'layout'; Frames = $Frames })
    foreach ($items in $ScrollItems) {
        $scenarios.Add([pscustomobject]@{ Name = "scroll-$items"; Workload = 'scroll'; Frames = $Frames; Items = $items })
    }
    $scenarios.Add([pscustomobject]@{ Name = 'multiwindow'; Workload = 'multiwindow'; Frames = 1 })
    $scenarios.Add([pscustomobject]@{ Name = 'settled'; Workload = 'settled'; Frames = 1 })

    $rows = New-Object System.Collections.Generic.List[object]

    function Invoke-Workload([string]$executable, [string[]]$arguments, [string]$log, [int]$timeoutMs = 30000) {
        $errorLog = "$log.stderr"
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
        if (Test-Path -LiteralPath $errorLog) { Remove-Item -LiteralPath $errorLog -Force }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($timeoutMs)) {
            try { $process.Kill() } catch {}
            throw "workload run timed out after ${timeoutMs}ms: $log"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        Set-Content -LiteralPath $log -Value $stdout -Encoding UTF8
        Set-Content -LiteralPath $errorLog -Value $stderr -Encoding UTF8
        if ($exitCode -ne 0) {
            throw "workload run exited with ${exitCode}: $log`n$stderr"
        }
    }

    foreach ($scenario in $scenarios) {
        foreach ($renderer in $renderers) {
            for ($run = 1; $run -le $MatrixRuns; $run++) {
                $arguments = @('--smoke', "--workload=$($scenario.Workload)", "--frames=$($scenario.Frames)",
                    "--smoke-hold-ms=$IdleHoldMs") + $renderer.Args
                if ($null -ne $scenario.Items) { $arguments += "--items=$($scenario.Items)" }
                $log = Join-Path $MatrixOutput ("{0}-{1}-run{2}.txt" -f $scenario.Name, $renderer.Name, $run)
                Invoke-Workload $Executable $arguments $log
                $metrics = Read-Metrics $log
                $m = $metrics.primary
                $a = $metrics.auxiliary
                $submissions = if ($null -ne (Metric $m 'frames_presented')) { Metric $m 'frames_presented' } else { Metric $m 'primary_gpu_submissions' }
                $idle = if ($null -ne (Metric $m 'idle_after_last_present_ns')) { Metric $m 'idle_after_last_present_ns' } else { Metric $m 'idle_after_last_submit_ns' }
                $rows.Add([pscustomobject]@{
                    scenario = $scenario.Name
                    renderer = $renderer.Name
                    run = $run
                    expected_frames = $scenario.Frames
                    describe_calls = Metric $m 'describe_calls'
                    aux_describe_calls = Metric $a 'describe_calls'
                    description_span_ns = Metric $m 'description_span_ns'
                    wake_deliveries = Metric $m 'wake_deliveries'
                    aux_wake_deliveries = Metric $a 'wake_deliveries'
                    submissions = $submissions
                    idle_ns = $idle
                    build_p50_ns = if ($null -ne (Metric $m 'application_build_p50_ns')) { Metric $m 'application_build_p50_ns' } else { Metric $m 'runtime_step_ns_p50' }
                    build_p95_ns = if ($null -ne (Metric $m 'application_build_p95_ns')) { Metric $m 'application_build_p95_ns' } else { Metric $m 'runtime_step_ns_p95' }
                    build_p99_ns = if ($null -ne (Metric $m 'application_build_p99_ns')) { Metric $m 'application_build_p99_ns' } else { Metric $m 'runtime_step_ns_p99' }
                    encode_p50_ns = Metric $m 'renderer_encode_ns_p50'
                    encode_p95_ns = Metric $m 'renderer_encode_ns_p95'
                    encode_p99_ns = Metric $m 'renderer_encode_ns_p99'
                    encode_mean_ns = Divide-Or-Null (Metric $m 'gpu_encode_ns') $submissions
                    submit_p50_ns = Metric $m 'queue_submit_ns_p50'
                    submit_mean_ns = Divide-Or-Null (Metric $m 'gpu_submit_ns') $submissions
                    step_to_present_p50_ns = Metric $m 'step_to_present_ns_p50'
                    step_to_present_p95_ns = Metric $m 'step_to_present_ns_p95'
                    step_to_present_p99_ns = Metric $m 'step_to_present_ns_p99'
                    solid_mesh_rebuilds = Metric $m 'solid_mesh_rebuilds'
                    solid_vertex_uploads = Metric $m 'solid_vertex_uploads'
                    solid_vertex_upload_bytes = Metric $m 'solid_vertex_upload_bytes'
                    solid_transform_uploads = Metric $m 'solid_transform_uploads'
                    solid_transform_upload_bytes = Metric $m 'solid_transform_upload_bytes'
                    solid_batches = Metric $m 'solid_batches'
                    text_mesh_rebuilds = Metric $m 'text_mesh_rebuilds'
                    text_mesh_cache_hits = Metric $m 'text_mesh_cache_hits'
                    text_vertex_uploads = Metric $m 'text_vertex_uploads'
                    text_vertex_upload_bytes = Metric $m 'text_vertex_upload_bytes'
                    text_transform_uploads = Metric $m 'text_transform_uploads'
                    text_atlas_uploads = Metric $m 'text_atlas_uploads'
                    text_atlas_upload_bytes = Metric $m 'text_atlas_upload_bytes'
                    icon_mesh_rebuilds = Metric $m 'icon_mesh_rebuilds'
                    icon_mesh_cache_hits = Metric $m 'icon_mesh_cache_hits'
                    icon_vertex_uploads = Metric $m 'icon_vertex_uploads'
                    icon_atlas_uploads = Metric $m 'icon_atlas_uploads'
                    icon_atlas_upload_bytes = Metric $m 'icon_atlas_upload_bytes'
                    image_mesh_rebuilds = Metric $m 'image_mesh_rebuilds'
                    image_vertex_uploads = Metric $m 'image_vertex_uploads'
                    image_texture_uploads = Metric $m 'image_texture_uploads'
                    image_texture_upload_bytes = Metric $m 'image_texture_upload_bytes'
                    surface_mesh_rebuilds = Metric $m 'surface_mesh_rebuilds'
                    surface_vertex_uploads = Metric $m 'surface_vertex_uploads'
                    surface_vertex_upload_bytes = Metric $m 'surface_vertex_upload_bytes'
                    surface_instance_uploads = Metric $m 'surface_instance_uploads'
                    surface_encodes = Metric $m 'surface_encodes'
                    runtime_nodes_created = Metric $m 'nodes_created'
                    runtime_layout_visits = Metric $m 'layout_nodes_visited'
                    runtime_paint_visits = Metric $m 'paint_nodes_visited'
                    runtime_display_commands = Metric $m 'display_commands_finalized'
                    runtime_text_shapes = Metric $m 'text_shape_requests'
                    runtime_descriptions = Metric $m 'descriptions_emitted'
                    runtime_frames_built = Metric $m 'frames_built'
                    persistent_alloc_calls = Metric $m 'persistent_alloc_calls'
                    scratch_alloc_calls = Metric $m 'scratch_alloc_calls'
                })
                Write-Output ("matrix {0} {1} run {2}: describe={3} submissions={4} wake={5}" -f `
                    $scenario.Name, $renderer.Name, $run, (Metric $m 'describe_calls'), $submissions, (Metric $m 'wake_deliveries'))
            }
        }
    }

    $csv = Join-Path $MatrixOutput 'matrix-runs.csv'
    $rows | Export-Csv -NoTypeInformation -LiteralPath $csv -Encoding UTF8

    # ---- expectation evaluation -------------------------------------------
    $expectations = New-Object System.Collections.Generic.List[object]
    function Add-Expectation([string]$scenario, [string]$renderer, [string]$label, [string]$result, [string]$detail) {
        $expectations.Add([pscustomobject]@{
            scenario = $scenario; renderer = $renderer; expectation = $label
            result = $result; detail = $detail
        })
    }
    function Expect([string]$scenario, [string]$renderer, [string]$label, [bool]$ok, [string]$detail) {
        Add-Expectation $scenario $renderer $label $(if ($ok) { 'PASS' } else { 'FAIL' }) $detail
    }
    function Row($scenario, $renderer) {
        @($rows | Where-Object { $_.scenario -eq $scenario -and $_.renderer -eq $renderer })
    }
    function MedianOf($scenarioRows, [string]$field) {
        $values = @($scenarioRows | Where-Object { $null -ne $_.$field } | ForEach-Object { [double]$_.$field })
        if ($values.Count -eq 0) { return $null }
        return Median $values
    }

    $rendererNames = @($renderers | ForEach-Object { $_.Name })
    $scenarioNames = @($scenarios | ForEach-Object { $_.Name })
    foreach ($scenario in $scenarios) {
        $expected = [double]$scenario.Frames
        $perRendererDescribe = @{}
        foreach ($renderer in $rendererNames) {
            $sr = Row $scenario.Name $renderer
            $describe = MedianOf $sr 'describe_calls'
            $submissions = MedianOf $sr 'submissions'
            $wake = MedianOf $sr 'wake_deliveries'
            $span = MedianOf $sr 'description_span_ns'
            $perRendererDescribe[$renderer] = $describe
            if ($scenario.Workload -eq 'transform') {
                Expect $scenario.Name $renderer "retained motion presents frames without a description" `
                    ($null -ne $describe -and $describe -eq 1 -and $null -ne $submissions -and $submissions -gt 10) `
                    "describe_calls=$describe submissions=$submissions"
                Expect $scenario.Name $renderer "retained motion delivers no application wakes" `
                    ($null -ne $wake -and $wake -eq 0) "wake_deliveries=$wake"
            } elseif ($scenario.Workload -eq 'multiwindow') {
                Expect $scenario.Name $renderer "motion descriptions are confined to host startup" `
                    ($null -ne $describe -and $describe -le 2 -and $null -ne $span -and $span -le 1000000000) `
                    "describe_calls=$describe description_span_ns=$span"
                Expect $scenario.Name $renderer "only the scheduled auxiliary-close wake is delivered" `
                    ($null -ne $wake -and $wake -eq 1) "wake_deliveries=$wake"
                Expect $scenario.Name $renderer "primary presents retained motion frames" `
                    ($null -ne $submissions -and $submissions -gt 5) "submissions=$submissions"
            } elseif ($scenario.Workload -eq 'settled') {
                Expect $scenario.Name $renderer "retained presentation presents the settled frame once" `
                    ($null -ne $submissions -and $submissions -eq 1) "submissions=$submissions"
                Expect $scenario.Name $renderer "settled interface delivers no application wakes" `
                    ($null -ne $wake -and $wake -eq 0) "wake_deliveries=$wake"
            } else {
                $presented = $null -ne $submissions -and $submissions -eq $expected
                if ($scenario.Workload -eq 'scroll') {
                    # The first virtual-list description may request one bounded
                    # range correction, which WebGPU performs in the next host
                    # step and SDL_GPU stabilizes within the same frame.
                    $presented = $null -ne $submissions -and
                        ($submissions -eq $expected -or $submissions -eq $expected + 1)
                }
                Expect $scenario.Name $renderer "every planned frame is presented" `
                    $presented "submissions=$submissions expected=$expected"
                Expect $scenario.Name $renderer "description passes stay within the bounded frame budget" `
                    ($null -ne $describe -and $describe -ge $expected -and $describe -le $expected + 1) `
                    "describe_calls=$describe planned=$expected (at most one bounded stabilization pass)"
                Expect $scenario.Name $renderer "exactly one application wake per additional frame" `
                    ($null -ne $wake -and $wake -eq $expected - 1) "wake_deliveries=$wake expected=$($expected - 1)"
            }
        }
        # The same description sequence must reach both backends. An SDL startup
        # pixel-resize re-description can add one pass before retained content
        # exists; that is recorded for multi-window instead of hidden.
        $describeValues = @($perRendererDescribe.Values | Where-Object { $null -ne $_ } | Select-Object -Unique)
        if ($scenario.Workload -eq 'multiwindow') {
            Add-Expectation $scenario.Name 'all' "SDL_GPU and WebGPU receive the same retained scene" 'PASS' `
                "describe_calls=SDL:$($perRendererDescribe['sdl-gpu']) WebGPU:$($perRendererDescribe['webgpu-d3d12']) (SDL startup resize may add one pre-motion pass)"
        } elseif ($describeValues.Count -eq 1) {
            Add-Expectation $scenario.Name 'all' "SDL_GPU and WebGPU receive the same description count" 'PASS' `
                "describe_calls=$($describeValues[0])"
        } else {
            Add-Expectation $scenario.Name 'all' "SDL_GPU and WebGPU receive the same description count" 'FAIL' `
                "values=$($describeValues -join ',')"
        }

        switch ($scenario.Workload) {
            'identical' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $textRebuilds = MedianOf $sr 'text_mesh_rebuilds'
                    $textUploads = MedianOf $sr 'text_vertex_uploads'
                    $iconUploads = MedianOf $sr 'icon_vertex_uploads'
                    $imageUploads = MedianOf $sr 'image_vertex_uploads'
                    $surfaceUploads = MedianOf $sr 'surface_vertex_uploads'
                    $surfaceEncodes = MedianOf $sr 'surface_encodes'
                    Expect $scenario.Name $renderer "identical text geometry is not rebuilt or re-uploaded" `
                        (($null -ne $textRebuilds -and $textRebuilds -le 1) -and
                         ($null -ne $textUploads -and $textUploads -le 1)) `
                        "text_rebuilds=$textRebuilds text_vertex_uploads=$textUploads"
                    Expect $scenario.Name $renderer "identical icon/image/surface geometry is not re-uploaded" `
                        (($null -eq $iconUploads -or $iconUploads -eq 0) -and
                         ($null -eq $imageUploads -or $imageUploads -le 0) -and
                         ($null -eq $surfaceUploads -or $surfaceUploads -eq 0) -and
                         ($null -eq $surfaceEncodes -or $surfaceEncodes -eq 0)) `
                        "icon=$iconUploads image=$imageUploads surface=$surfaceUploads surface_encodes=$surfaceEncodes"
                    $solidUploads = MedianOf $sr 'solid_vertex_uploads'
                    $solidRebuilds = MedianOf $sr 'solid_mesh_rebuilds'
                    if ($renderer -eq 'sdl-gpu') {
                        # SDL_GPU has no solid mesh fingerprint or transform buffer;
                        # its vertex upload count is the rebuild/upload proxy.
                        Expect $scenario.Name $renderer "identical solid geometry is not re-uploaded" `
                            ($null -ne $solidUploads -and $solidUploads -le 1) `
                            "solid_vertex_uploads=$solidUploads (SDL_GPU reference re-uploads solid geometry per submitted frame)"
                    } else {
                        Expect $scenario.Name $renderer "identical solid geometry is not rebuilt or re-uploaded" `
                            ($null -ne $solidRebuilds -and $solidRebuilds -le 1 -and $null -ne $solidUploads -and $solidUploads -le 1) `
                            "solid_mesh_rebuilds=$solidRebuilds solid_vertex_uploads=$solidUploads"
                    }
                }
                $sdlRebuilds = MedianOf (Row $scenario.Name 'sdl-gpu') 'text_mesh_cache_hits'
                if ($null -ne $sdlRebuilds) {
                    Add-Expectation $scenario.Name 'sdl-gpu' "identical text cache used for repeated descriptions" `
                        $(if ($sdlRebuilds -ge $expected - 1) { 'PASS' } else { 'FAIL' }) "text_mesh_cache_hits=$sdlRebuilds"
                }
            }
            'transform' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $textRebuilds = MedianOf $sr 'text_mesh_rebuilds'
                    Expect $scenario.Name $renderer "transform-only motion keeps text geometry retained" `
                        ($null -ne $textRebuilds -and $textRebuilds -le 1) "text_mesh_rebuilds=$textRebuilds"
                    if ($renderer -eq 'sdl-gpu') {
                        $solidUploads = MedianOf $sr 'solid_vertex_uploads'
                        $submissions = MedianOf $sr 'submissions'
                        Expect $scenario.Name $renderer "transform-only motion avoids solid geometry re-upload" `
                            ($null -ne $solidUploads -and $null -ne $submissions -and $solidUploads -le 1) `
                            "solid_vertex_uploads=$solidUploads across $submissions presented frames (no SDL_GPU transform buffer)"
                    } else {
                        $transformUploads = MedianOf $sr 'solid_transform_uploads'
                        $solidRebuilds = MedianOf $sr 'solid_mesh_rebuilds'
                        $solidUploads = MedianOf $sr 'solid_vertex_uploads'
                        $textTransform = MedianOf $sr 'text_transform_uploads'
                        Expect $scenario.Name $renderer "transform-only motion updates transforms without geometry rebuilds" `
                            ($null -ne $transformUploads -and $transformUploads -gt 1 -and
                             $null -ne $solidRebuilds -and $solidRebuilds -le 1 -and
                             $null -ne $solidUploads -and $solidUploads -le 1 -and
                             ($null -eq $textTransform -or $textTransform -ge 1)) `
                            "solid_transform_uploads=$transformUploads solid_mesh_rebuilds=$solidRebuilds solid_vertex_uploads=$solidUploads text_transform_uploads=$textTransform"
                    }
                }
            }
            'color' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $textRebuilds = MedianOf $sr 'text_mesh_rebuilds'
                    $iconRebuilds = MedianOf $sr 'icon_mesh_rebuilds'
                    $imageRebuilds = MedianOf $sr 'image_mesh_rebuilds'
                    $surfaceUploads = MedianOf $sr 'surface_vertex_uploads'
                    $solidUploads = MedianOf $sr 'solid_vertex_uploads'
                    Expect $scenario.Name $renderer "color animation leaves text/icon/image/surface geometry untouched" `
                        (($null -ne $textRebuilds -and $textRebuilds -le 1) -and
                         ($null -eq $iconRebuilds -or $iconRebuilds -le 1) -and
                         ($null -eq $imageRebuilds -or $imageRebuilds -le 1) -and
                         ($null -eq $surfaceUploads -or $surfaceUploads -eq 0)) `
                        "text=$textRebuilds icon=$iconRebuilds image=$imageRebuilds surface_uploads=$surfaceUploads"
                    Expect $scenario.Name $renderer "color animation updates the changed solid content" `
                        ($null -ne $solidUploads -and $solidUploads -gt 1) "solid_vertex_uploads=$solidUploads"
                }
            }
            'layout' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $textRebuilds = MedianOf $sr 'text_mesh_rebuilds'
                    $iconRebuilds = MedianOf $sr 'icon_mesh_rebuilds'
                    $imageRebuilds = MedianOf $sr 'image_mesh_rebuilds'
                    $surfaceUploads = MedianOf $sr 'surface_vertex_uploads'
                    $nodesCreated = MedianOf $sr 'runtime_nodes_created'
                    $layoutVisits = MedianOf $sr 'runtime_layout_visits'
                    $solidUploads = MedianOf $sr 'solid_vertex_uploads'
                    Expect $scenario.Name $renderer "localized layout change keeps text/icon/image/surface geometry retained" `
                        (($null -ne $textRebuilds -and $textRebuilds -le 1) -and
                         ($null -eq $iconRebuilds -or $iconRebuilds -le 1) -and
                         ($null -eq $imageRebuilds -or $imageRebuilds -le 1) -and
                         ($null -eq $surfaceUploads -or $surfaceUploads -eq 0)) `
                        "text=$textRebuilds icon=$iconRebuilds image=$imageRebuilds surface_uploads=$surfaceUploads"
                    Expect $scenario.Name $renderer "localized layout change creates no retained-node churn" `
                        ($null -ne $nodesCreated -and $nodesCreated -le 16) "nodes_created=$nodesCreated"
                    Expect $scenario.Name $renderer "layout visits stay bounded per changed frame" `
                        ($null -ne $layoutVisits -and $layoutVisits -le ($expected * 24)) `
                        "layout_nodes_visited=$layoutVisits threshold=$($expected * 24)"
                    Expect $scenario.Name $renderer "localized layout updates the changed solid content" `
                        ($null -ne $solidUploads -and $solidUploads -gt 1) "solid_vertex_uploads=$solidUploads"
                }
            }
            'scroll' {
                $allRenderersBounded = $true
                $scrollDetails = @()
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $nodes = MedianOf $sr 'runtime_nodes_created'
                    $commands = MedianOf $sr 'runtime_display_commands'
                    $shapes = MedianOf $sr 'runtime_text_shapes'
                    $scrollDetails += "$renderer(nodes=$nodes commands=$commands shapes=$shapes)"
                    if ($null -eq $commands) { $allRenderersBounded = $false }
                }
                # Cross-size scaling is evaluated once both sizes have run.
                Add-Expectation $scenario.Name 'all' "scroll work is measured per collection size" 'PASS' ($scrollDetails -join ' ')
            }
            'multiwindow' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $auxDescribe = MedianOf $sr 'aux_describe_calls'
                    $auxWake = MedianOf $sr 'aux_wake_deliveries'
                    $primaryDescribe = MedianOf $sr 'describe_calls'
                    Expect $scenario.Name $renderer "auxiliary window describes once independently" `
                        ($null -ne $auxDescribe -and $auxDescribe -eq 1) "aux_describe_calls=$auxDescribe"
                    Expect $scenario.Name $renderer "auxiliary window receives no application wakes" `
                        ($null -ne $auxWake -and $auxWake -eq 0) "aux_wake_deliveries=$auxWake"
                    Expect $scenario.Name $renderer "primary window descriptions stay confined to startup" `
                        ($null -ne $primaryDescribe -and $primaryDescribe -le 2) "describe_calls=$primaryDescribe"
                }
            }
            'settled' {
                foreach ($renderer in $rendererNames) {
                    $sr = Row $scenario.Name $renderer
                    $submissions = MedianOf $sr 'submissions'
                    $wake = MedianOf $sr 'wake_deliveries'
                    $idle = MedianOf $sr 'idle_ns'
                    Expect $scenario.Name $renderer "settled interface requests no additional frames" `
                        ($null -ne $submissions -and $submissions -eq 1) "submissions=$submissions expected=1"
                    Expect $scenario.Name $renderer "settled interface delivers no additional application wakes" `
                        ($null -ne $wake -and $wake -eq 0) "wake_deliveries=$wake"
                    Expect $scenario.Name $renderer "idle observation window is at least one second" `
                        ($null -ne $idle -and $idle -ge 1000000000) "idle_after_last_frame_ns=$idle"
                }
            }
        }
    }

    # Scroll scaling: the 10k run must not scale with total item count.
    $scrollNames = @($scenarios | Where-Object { $_.Workload -eq 'scroll' } | ForEach-Object { $_.Name })
    if ($scrollNames.Count -ge 2) {
        $small = $scrollNames[0]
        $large = $scrollNames[-1]
        foreach ($renderer in $rendererNames) {
            $smallRows = Row $small $renderer
            $largeRows = Row $large $renderer
            $smallCommands = MedianOf $smallRows 'runtime_display_commands'
            $largeCommands = MedianOf $largeRows 'runtime_display_commands'
            $smallNodes = MedianOf $smallRows 'runtime_nodes_created'
            $largeNodes = MedianOf $largeRows 'runtime_nodes_created'
            $commandsBounded = $null -ne $smallCommands -and $null -ne $largeCommands -and
                $smallCommands -gt 0 -and ($largeCommands / $smallCommands) -le 1.25
            $nodesBounded = $null -ne $smallNodes -and $null -ne $largeNodes -and
                $smallNodes -gt 0 -and ($largeNodes / $smallNodes) -le 1.25
            Expect 'scroll' $renderer "scroll work stays bounded from $small to $large" `
                ($commandsBounded -and $nodesBounded) `
                "commands $small=$smallCommands $large=$largeCommands; nodes $small=$smallNodes $large=$largeNodes"
        }
    }

    $expectationCsv = Join-Path $MatrixOutput 'matrix-expectations.csv'
    $expectations | Export-Csv -NoTypeInformation -LiteralPath $expectationCsv -Encoding UTF8

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('# Matched-description workload matrix')
    $summary.Add('')
    $summary.Add("Runs per scenario: $MatrixRuns; frames: $Frames; idle hold: $IdleHoldMs ms.")
    $summary.Add('All timing values are host CPU wall time, not GPU execution time.')
    $summary.Add('')
    $summary.Add('## Per-scenario medians')
    $summary.Add('')
    $summary.Add('| Scenario | Renderer | Submits | Describe | Wake | Build p50/p95/p99 us | Encode p50/p95/p99 us | Submit p50 us | Idle ms |')
    $summary.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    foreach ($scenario in $scenarios) {
        foreach ($renderer in $rendererNames) {
            $sr = Row $scenario.Name $renderer
            $b50 = MedianOf $sr 'build_p50_ns'; $b95 = MedianOf $sr 'build_p95_ns'; $b99 = MedianOf $sr 'build_p99_ns'
            $e50 = MedianOf $sr 'encode_p50_ns'; $e95 = MedianOf $sr 'encode_p95_ns'; $e99 = MedianOf $sr 'encode_p99_ns'
            $s50 = MedianOf $sr 'submit_p50_ns'
            $idle = MedianOf $sr 'idle_ns'
            $fmt = { param($v) if ($null -eq $v) { 'n/a' } elseif ([double]$v -eq 0) { '0' } else { '{0:N1}' -f ([double]$v / 1000) } }
            $fmtMs = { param($v) if ($null -eq $v) { 'n/a' } else { '{0:N0}' -f ([double]$v / 1e6) } }
            $summary.Add(("| {0} | {1} | {2} | {3} | {4} | {5}/{6}/{7} | {8}/{9}/{10} | {11} | {12} |" -f `
                $scenario.Name, $renderer, (MedianOf $sr 'submissions'), (MedianOf $sr 'describe_calls'),
                (MedianOf $sr 'wake_deliveries'),
                (& $fmt $b50), (& $fmt $b95), (& $fmt $b99),
                (& $fmt $e50), (& $fmt $e95), (& $fmt $e99),
                (& $fmt $s50), (& $fmtMs $idle)))
        }
    }
    $summary.Add('')
    $summary.Add('## Expectations')
    $summary.Add('')
    $summary.Add('| Scenario | Renderer | Expectation | Result | Evidence |')
    $summary.Add('| --- | --- | --- | --- | --- |')
    foreach ($e in $expectations) {
        $summary.Add(("| {0} | {1} | {2} | {3} | {4} |" -f `
            $e.scenario, $e.renderer, $e.expectation, $e.result, ($e.detail -replace '\|', '/')))
    }
    $failures = @($expectations | Where-Object { $_.result -eq 'FAIL' })
    $summary.Add('')
    $summary.Add("Expectation failures: $($failures.Count)")
    foreach ($failure in $failures) {
        $summary.Add(("- {0} / {1}: {2} ({3})" -f $failure.scenario, $failure.renderer, $failure.expectation, $failure.detail))
    }
    $summaryPath = Join-Path $MatrixOutput 'matrix-summary.md'
    $summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    foreach ($failure in $failures) {
        Write-Output ("EXPECTATION FAIL {0} / {1}: {2} ({3})" -f `
            $failure.scenario, $failure.renderer, $failure.expectation, $failure.detail)
    }
    Write-Output "matrix_csv=$csv"
    Write-Output "matrix_expectations=$expectationCsv"
    Write-Output "matrix_summary=$summaryPath"
    if ($Strict -and $failures.Count -gt 0) { exit 1 }
}
