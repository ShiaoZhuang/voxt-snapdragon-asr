[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$Summary.Add('QNN live | GPU prefill and draft | HTP eight-position Target verification')
& (Join-Path $PSScriptRoot 'verify_replay_assets.ps1') -InstallDirectory $InstallDirectory
$python = @('qnn-probe-venv', 'qnn-probe-venv-arm64') | ForEach-Object {
    Join-Path (Get-Location).Path ".local/$_/Scripts/python.exe"
} | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$python) { throw 'QNN Python environment from the device replay is required.' }

Write-Host '[voxt] Building the native backend for QNN live.'
& (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly | Out-Host
$probe = Join-Path $PSScriptRoot 'probe_opencl_startup.ps1'
$probeArgs = @{InstallDirectory=$InstallDirectory; NativeBuildDirectory=$BuildDirectory; Transcribe=$true; Draft=$true}
$capture = Join-Path $LogDirectory 'live-calibration'
$calibrationLog = Join-Path $LogDirectory 'live-calibration.txt'
Write-Host '[voxt] Capturing the eight-position calibration batch.'
& $probe @probeArgs -CaptureDirectory $capture -CaptureAllLayers -ReportPath $calibrationLog | Out-Host
if (!(Test-Path -LiteralPath (Join-Path $capture 'target_logits.f32') -PathType Leaf)) {
    throw "No complete capture for QNN calibration. See $calibrationLog"
}

function Invoke-LiveClip([string]$Name, [string]$Directory) {
    $path = Join-Path $LogDirectory "$Name.txt"
    & $probe @probeArgs -LiveVerifyDirectory $Directory -ReportPath $path -MetricsPath "$path.metrics.json" | Out-Host
    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $path)
    if (!($lines -match '^Transcription probe: PASS$') -or !($lines -match '^Exit code: 0 \(0x00000000\)$')) {
        $detail = @($lines -match 'live Target verification failed|Transcription probe: FAIL|Startup probe error|No ready event' |
            Select-Object -First 2) -join ' | '
        if ($Directory -and (Test-Path -LiteralPath (Join-Path $Directory 'error.json'))) {
            $detail += ' | ' + (Get-Content -Raw -LiteralPath (Join-Path $Directory 'error.json') | ConvertFrom-Json).error
        }
        throw "$Name transcription failed. $detail"
    }
    $m = Get-Content -Raw -Encoding UTF8 -LiteralPath "$path.metrics.json" | ConvertFrom-Json
    if ($m.finish -ne 'stop' -or $m.tokens -lt 1 -or !$m.ids.Count -or $m.wall_ms -le 0 -or !$m.rounds) {
        throw "$Name produced no complete DFlash token trace."
    }
    return @{
        Metrics = $m
        Rate = $m.tokens * 1000 / $m.wall_ms
        LiveRounds = [int]$m.live_rounds
    }
}

Write-Host '[voxt] Measuring all-GPU DFlash.'
$baseline = Invoke-LiveClip 'live-gpu-dflash' ''
$Summary.Add(('All-GPU DFlash | {0} tokens | {1:F0} ms | {2:F2} request tok/s' -f
    $baseline.Metrics.tokens, $baseline.Metrics.wall_ms, $baseline.Rate))
Write-Host "[voxt] $($Summary[$Summary.Count - 1])"
$workerDirectory = (New-Item -ItemType Directory -Path (Join-Path $LogDirectory 'live-qnn-worker')).FullName
$workerError = Join-Path $workerDirectory 'error.json'
$workerOut = Join-Path $workerDirectory 'stdout.log'
$workerScript = Join-Path $PSScriptRoot '../../tools/qnn-probe/live_verify.py'
$models = Join-Path $InstallDirectory 'models'
$arguments = @('-X', 'utf8', $workerScript, '--target', (Join-Path $models 'target.gguf'),
    '--draft', (Join-Path $models 'draft-4.gguf'), '--capture', $capture, '--directory', $workerDirectory)
$quoted = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
$processArgs = @{
    FilePath=$python; ArgumentList=$quoted; NoNewWindow=$true; PassThru=$true
    RedirectStandardOutput=$workerOut; RedirectStandardError=(Join-Path $workerDirectory 'stderr.log')
}
Write-Host '[voxt] Calibrating and initializing the QNN verifier (up to 12 minutes).'
$worker = Start-Process @processArgs
try {
    $deadline = (Get-Date).AddMinutes(12)
    while (!(Test-Path -LiteralPath (Join-Path $workerDirectory 'ready.json') -PathType Leaf)) {
        if ($worker.HasExited -or (Get-Date) -ge $deadline) {
            $detail = if (Test-Path -LiteralPath $workerError) {
                (Get-Content -Raw -LiteralPath $workerError | ConvertFrom-Json).error
            } else { @(Get-Content -LiteralPath $workerOut -Tail 2) -join ' | ' }
            throw "QNN worker did not become ready. $detail"
        }
        Start-Sleep -Milliseconds 250
    }
    $ready = Get-Content -Raw -LiteralPath (Join-Path $workerDirectory 'ready.json') | ConvertFrom-Json
    $Summary.Add("QNN verifier ready | history capacity $($ready.history_capacity) tokens")
    Write-Host '[voxt] Measuring GPU + HTP DFlash.'
    $hybrid = Invoke-LiveClip 'live-qnn-dflash' $workerDirectory
} finally {
    if (!$worker.HasExited) {
        New-Item -ItemType File -Path (Join-Path $workerDirectory 'stop') -Force | Out-Null
        if (!$worker.WaitForExit(30000)) { $worker.Kill(); $worker.WaitForExit() }
    }
    $worker.Dispose()
    foreach ($name in @('target-verify.onnx', 'target-verify.onnx.data')) {
        Remove-Item -LiteralPath (Join-Path $workerDirectory $name) -Force -ErrorAction SilentlyContinue
    }
}
$profile = Get-Content -Raw -LiteralPath (Join-Path $workerDirectory 'worker_report.json') | ConvertFrom-Json
$Summary.Add(('GPU + HTP DFlash | {0} tokens | {1:F0} ms | {2:F2} request tok/s | {3}/{4} HTP rounds | {5} DSP executes' -f
    $hybrid.Metrics.tokens, $hybrid.Metrics.wall_ms, $hybrid.Rate, $hybrid.LiveRounds, $hybrid.Metrics.rounds, $profile.qaairt_execute_events))
if ($hybrid.LiveRounds -lt 1 -or $hybrid.LiveRounds -gt $hybrid.Metrics.rounds -or $profile.rounds -ne $hybrid.LiveRounds -or $profile.qaairt_execute_events -lt $profile.rounds) {
    throw 'Missing device execution evidence for live Target verification.'
}
if ($hybrid.Metrics.text -cne $baseline.Metrics.text -or ($hybrid.Metrics.ids -join ',') -ne ($baseline.Metrics.ids -join ',')) {
    throw 'Live QNN transcript or generated token sequence differs from all-GPU DFlash.'
}
$Summary.Add(('Live QNN | token sequence matched | hybrid / all-GPU request throughput {0:F2}x' -f ($hybrid.Rate / $baseline.Rate)))
