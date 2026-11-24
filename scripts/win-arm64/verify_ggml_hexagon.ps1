[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$Summary.Add('GGML Hexagon | zh-plain-1 | target on HTP0, audio and optional Q4 draft on Adreno')
& (Join-Path $PSScriptRoot 'verify_replay_assets.ps1') -InstallDirectory $InstallDirectory
$failed = @()
$cases = @('adreno-target', 'adreno-draft')
try {
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly -Hexagon | Out-Host
    $product = Join-Path $BuildDirectory 'hexagon'
    $Summary.Add('GGML Hexagon native Windows build: PASS')
    $cases += 'hexagon-target', 'hexagon-draft'
} catch {
    $failed += 'Hexagon build'
    $Summary.Add("GGML Hexagon build blocked | $($_.Exception.Message)")
    $Summary.Add('Running both Adreno measurements with the local OpenCL build.')
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly | Out-Host
    $product = $BuildDirectory
}
$baseline = $null
foreach ($name in $cases) {
    $path = Join-Path $LogDirectory "$name.txt"
    $backend = if ($name -like 'adreno-*') { 'opencl' } else { 'hexagon' }
    $draft = $name -like '*-draft'
    try {
        & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $InstallDirectory -NativeBuildDirectory $product `
            -ReportPath $path -MetricsPath "$path.metrics.json" -Backend $backend -Transcribe -Draft:$draft | Out-Host
        $lines = Get-Content -Encoding UTF8 -LiteralPath $path
        if (!($lines -match '^Transcription probe: PASS$') -or !($lines -match '^Exit code: 0 \(0x00000000\)$')) {
            $last = @($lines -match 'Startup probe error|Transcription probe: FAIL|No ready event|failed|error:|Exit code:' |
                Select-Object -First 4)
            throw "Transcription incomplete. $($last -join ' | ')"
        }
        $m = Get-Content -Raw -Encoding UTF8 -LiteralPath "$path.metrics.json" | ConvertFrom-Json
        if (!$m.ids.Count -or $m.tokens -le 0 -or $m.wall_ms -le 0 -or $m.finish -ne 'stop') {
            throw 'Missing generated token trace, request timing, or normal end of generation.'
        }
        $events = 0
        $inRequest = $false
        foreach ($line in $lines) {
            if ($line -match 'voxt: GGML Hexagon audio request started') { $inRequest = $true }
            if ($inRequest -and $line -match 'ggml-hex: HTP0 profile-op (?!OPBATCH).*\|usec [0-9]+ cycles [1-9][0-9]*') {
                $events++
            }
        }
        $Summary.Add(('{0} | {1} tokens / {2:F0} ms = {3:F2} request tok/s | DSP profile events {4}' -f
            $name, $m.tokens, $m.wall_ms, ($m.tokens * 1000 / $m.wall_ms), $events))
        if ($backend -eq 'hexagon' -and !$events) { throw 'No timed HTP0 operation in GGML profiler.' }
        if ($draft -and ($m.rounds -le 0 -or $m.proposed -le 0)) { throw 'Missing speculative verification rounds.' }
        if ($name -eq 'adreno-target') { $baseline = $m }
        elseif (!$baseline -or $m.text -cne $baseline.text -or ($m.ids -join ',') -ne ($baseline.ids -join ',')) {
            throw 'Adreno baseline missing or generated text/token sequence differs. Inspect the metrics JSON files.'
        }
        $Summary.Add("${name}: PASS | $($m.text)")
    } catch {
        $failed += $name
        $Summary.Add("${name}: FAIL | $($_.Exception.Message)")
    }
}
if ($failed.Count) { throw "Incomplete steps: $($failed -join ', '). See the details above." }
