param(
    [string]$Odin,
    [int]$Runs = 5,
    [string]$OutputDir = 'out\webgpu-phase0\perf-2026-11-19'
)

# Builds examples/16_native_webgpu_ui once, then runs the same retained-control
# scene through SDL_GPU, WebGPU/D3D12 and WebGPU/Vulkan. Both fixture paths are
# compiled into one executable and share the same Odin render callback and
# window size. Timing values are host CPU wall time from each backend's existing
# diagnostics; they are not GPU execution, scanout or photon latency.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$Executable = Join-Path $OutputDir 'native_webgpu_ui_perf.exe'
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Odin build (Join-Path $RepoRoot 'examples\16_native_webgpu_ui') `
    "-collection:alicorn=$RepoRoot" -define:WGPU_SHARED=true -o:speed `
    "-out:$Executable" @($AccessKit.CompilerArguments) 2>&1 | ForEach-Object { Write-Output $_ }
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($buildExit -ne 0) { exit $buildExit }

$OdinRoot = Split-Path -Parent $Odin
Copy-Item (Join-Path $OdinRoot 'vendor\sdl3\SDL3.dll') (Join-Path $OutputDir 'SDL3.dll') -Force
Copy-Item (Join-Path $OdinRoot 'vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll') `
    (Join-Path $OutputDir 'wgpu_native.dll') -Force

$configs = @(
    [pscustomobject]@{ Name = 'cold-sdl-gpu';        Args = @('--smoke', '--backend=sdl-gpu') },
    [pscustomobject]@{ Name = 'cold-webgpu-d3d12';   Args = @('--smoke', '--timings', '--backend=d3d12') },
    [pscustomobject]@{ Name = 'cold-webgpu-vulkan';  Args = @('--smoke', '--timings', '--backend=vulkan') },
    [pscustomobject]@{ Name = 'motion-sdl-gpu';      Args = @('--smoke', '--timing-motion', '--backend=sdl-gpu') },
    [pscustomobject]@{ Name = 'motion-webgpu-d3d12'; Args = @('--smoke', '--timings', '--timing-motion', '--backend=d3d12') },
    [pscustomobject]@{ Name = 'motion-webgpu-vulkan'; Args = @('--smoke', '--timings', '--timing-motion', '--backend=vulkan') }
)

function Read-Metrics([string]$path) {
    $metrics = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\[alicorn-webgpu-timing\] samples=(\d+)') {
            $metrics['samples'] = [double]$Matches[1]
        }
        $tokens = @($line -split '\s+' | Where-Object { $_ -ne '' })
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $token = $tokens[$i]
            if ($token -match '^([A-Za-z0-9_]+)=([0-9]+(?:\.[0-9]+)?)$') {
                $metrics[$Matches[1]] = [double]$Matches[2]
            } elseif ($token -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $i + 1 -lt $tokens.Count -and
                      $tokens[$i + 1] -match '^[0-9]+(?:\.[0-9]+)?$') {
                # The SDL_GPU diagnostics print unquoted "key value" pairs.
                $metrics[$token] = [double]$tokens[$i + 1]
            }
        }
    }
    return $metrics
}

function Median([double[]]$values) {
    if ($values.Count -eq 0) { return $null }
    $sorted = $values | Sort-Object
    if ($sorted.Count % 2 -eq 1) { return $sorted[[int]($sorted.Count / 2)] }
    return ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2
}

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
        $m = Read-Metrics $log
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
