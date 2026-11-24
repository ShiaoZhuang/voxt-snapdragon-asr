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
Write-Host '[voxt] Checking the Hexagon SDK and building GGML Hexagon.'
& (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly -Hexagon -InstallHexagonSdk | Out-Host
$product = Join-Path $BuildDirectory 'hexagon'
$Summary.Add('GGML Hexagon native Windows build: PASS')
$manifest = Get-Content -LiteralPath (Join-Path $product 'verify_native_manifest.json') -Raw | ConvertFrom-Json
if ($manifest.htp_build_error) { throw "llama.cpp DSP build failed | $($manifest.htp_build_error)" }
if (!$manifest.htp_ops -or !$manifest.htp_ops_sha256) { throw 'The native build manifest has no v73 DSP library.' }
$Summary.Add("llama.cpp DSP build: PASS | v73 package: $($manifest.htp_ops)")

$ops = $manifest.htp_ops
if ($env:GGML_HEXAGON_LIBHTP_DIR) { $ops = $env:GGML_HEXAGON_LIBHTP_DIR }
$ops = (Resolve-Path -LiteralPath $ops).Path
$library = Join-Path $ops 'libggml-htp-v73.so'
if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $manifest.htp_ops_sha256) {
    throw 'The signed directory must contain the v73 DSP library produced by this llama.cpp build.'
}
if (!(Test-Path -LiteralPath (Join-Path $ops 'libggml-htp.cat') -PathType Leaf)) {
    Write-Host '[voxt] Checking the Windows certificate stores for a code-signing key.'
    $ops = & (Join-Path $PSScriptRoot 'sign_htp_catalog.ps1') -PackageDirectory $ops `
        -TrialDirectory (Join-Path $LogDirectory 'htp-v73-self-signed') `
        -ToolCacheDirectory (Join-Path $BuildDirectory 'sdk/windows-signing-tools') -Summary $Summary
}
$Summary.Add("HTP library directory: $ops")

$gpuMetricsPath = Join-Path $LogDirectory 'live-calibration.txt.metrics.json'
$gpuReference = if (Test-Path -LiteralPath $gpuMetricsPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $gpuMetricsPath | ConvertFrom-Json }
$target = $null
$failed = @()
foreach ($name in @('hexagon-target', 'hexagon-draft')) {
    Write-Host "[voxt] Running $name."
    $path = Join-Path $LogDirectory "$name.txt"
    $draft = $name -like '*-draft'
    try {
        & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $InstallDirectory -NativeBuildDirectory $product `
            -ReportPath $path -MetricsPath "$path.metrics.json" -Backend hexagon -Transcribe -Draft:$draft -HexagonOpsDirectory $ops | Out-Host
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
        $rate = $m.tokens * 1000 / $m.wall_ms
        $Summary.Add(('{0} | {1} tokens / {2:F0} ms = {3:F2} request tok/s | DSP profile events {4}' -f
            $name, $m.tokens, $m.wall_ms, $rate, $events))
        if (!$events) { throw 'No timed HTP0 operation in GGML profiler.' }
        if ($draft -and ($m.rounds -le 0 -or $m.proposed -le 0)) { throw 'Missing speculative verification rounds.' }
        if ($gpuReference -and ($m.text -cne $gpuReference.text -or ($m.ids -join ',') -ne ($gpuReference.ids -join ','))) {
            throw 'Generated text/token sequence differs from the GPU calibration transcription.'
        }
        if (!$draft) { $target = $m }
        elseif (!$target -or $m.text -cne $target.text -or ($m.ids -join ',') -ne ($target.ids -join ',')) {
            throw 'HTP Target-only reference missing or generated text/token sequence differs. Inspect the metrics JSON files.'
        }
        $Summary.Add("${name}: PASS | $($m.text)")
    } catch {
        $failed += $name
        $Summary.Add("${name}: FAIL | $($_.Exception.Message)")
    }
}
if ($failed.Count) { throw "Incomplete steps: $($failed -join ', '). See the details above." }
