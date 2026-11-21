param(
    [string]$Odin,
    [int]$Samples = 24,
    [string]$Output = ""
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\tools\common.ps1"

$Odin = Resolve-AlicornOdin -Requested $Odin
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $RepoRoot
try {
    New-Item -ItemType Directory -Force -Path 'out' | Out-Null
    if ([string]::IsNullOrWhiteSpace($Output)) {
        $Output = Join-Path $RepoRoot 'docs\benchmarks\raw\issue-190-sparse-updates-windows-2026-11-21.txt'
    }
    $Output = [IO.Path]::GetFullPath($Output)

    $Executable = Join-Path $RepoRoot 'out\issue190_sparse_updates.exe'
    & $Odin build benchmarks\diagnostics\issue190_sparse_updates.odin -file -o:speed `
        -collection:alicorn=. "-out:$Executable"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $Sha = (& git rev-parse HEAD).Trim()
    $Branch = (& git branch --show-current).Trim()
    $Cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim()
    $OdinVersion = (& $Odin version).Trim()

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Alicorn issue #190 sparse application updates and authoring cost - raw capture')
    $Lines.Add("captured_utc=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    $Lines.Add("source_sha=$Sha")
    $Lines.Add("branch=$Branch")
    $Lines.Add("odin=$OdinVersion")
    $Lines.Add("compiler=$Odin")
    $Lines.Add("build=-o:speed -collection:alicorn=.")
    $Lines.Add("host_os=$([System.Environment]::OSVersion.VersionString)")
    $Lines.Add("cpu=$Cpu")
    $Lines.Add('viewport=1280x900')
    $Lines.Add('theme=issue190-painted (registered accent/surface/text/selection colors; paint-only replacement)')
    $Lines.Add("samples=$Samples")
    $Lines.Add('measurement=headless CPU; no GPU presentation; timings are machine-specific')
    $Lines.Add('')

    $RunLines = & $Executable "--samples=$Samples" 2>&1
    $Code = $LASTEXITCODE
    foreach ($Line in $RunLines) { $Lines.Add([string]$Line) }
    [IO.File]::WriteAllLines($Output, $Lines, [Text.UTF8Encoding]::new($false))
    Write-Output "raw_capture=$Output"
    Write-Output "benchmark_exit=$Code"
    exit $Code
}
finally {
    Pop-Location
}
