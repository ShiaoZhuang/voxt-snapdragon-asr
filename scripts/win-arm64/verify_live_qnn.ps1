[CmdletBinding()]
param(
    [switch]$PlacementMatrix,
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
& $probe @probeArgs -CaptureDirectory $capture -CaptureAllLayers -ReportPath $calibrationLog -MetricsPath "$calibrationLog.metrics.json" | Out-Host
$captureLines = @(Get-Content -Encoding UTF8 -LiteralPath $calibrationLog)
if (!($captureLines -match '^Transcription probe: PASS$') -or !($captureLines -match '^Capture: PASS') -or
    !(Test-Path -LiteralPath (Join-Path $capture 'target_logits.f32') -PathType Leaf)) {
    throw "No complete capture for QNN calibration. See $calibrationLog"
}

function Invoke-LiveClip([string]$Name, [string]$Directory, [int]$WorkerId) {
    $path = Join-Path $LogDirectory "$Name.txt"
    & $probe @probeArgs -MeasurePlacement:$PlacementMatrix -WorkerId $WorkerId -LiveVerifyDirectory $Directory -ReportPath $path -MetricsPath "$path.metrics.json" | Out-Host
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
    if ($PlacementMatrix) {
        if ($m.peak_private_bytes -le 0 -or $m.peak_working_bytes -le 0) { throw 'Missing request memory samples.' }
        if ($Directory) {
            $sent = 0L
            $received = 0L
            $prepare = 0L
            $wait = 0L
            $apply = 0L
            $records = 0
            foreach ($line in $lines) {
                if ($line -match 'voxt: verify IPC bytes (\d+) (\d+) us prepare (\d+) wait (\d+) apply (\d+)') {
                    $sent += [long]$Matches[1]
                    $received += [long]$Matches[2]
                    $prepare += [long]$Matches[3]
                    $wait += [long]$Matches[4]
                    $apply += [long]$Matches[5]
                    $records++
                }
            }
            if (!$records -or $records -ne $m.live_rounds) { throw "IPC trace missing or differs from live verification rounds." }
            $Summary.Add(('{0} | IPC out/in {1:F2}/{2:F2} MiB | prepare/worker wait/apply {3:F1}/{4:F1}/{5:F1} ms' -f
                $Name,($sent/1MB),($received/1MB),($prepare/1000),($wait/1000),($apply/1000)))
        }
    }
    return @{
        Metrics = $m
        Rate = $m.tokens * 1000 / $m.wall_ms
        LiveRounds = [int]$m.live_rounds
    }
}

$workerDirectory = (New-Item -ItemType Directory -Path (Join-Path $LogDirectory 'live-qnn-worker')).FullName
$workerError = Join-Path $workerDirectory 'error.json'
$workerOut = Join-Path $workerDirectory 'stdout.log'
$workerStderr = Join-Path $workerDirectory 'stderr.log'
$workerScript = Join-Path $PSScriptRoot '../../tools/qnn-probe/live_verify.py'
$models = Join-Path $InstallDirectory 'models'
$arguments = @('-X', 'utf8', $workerScript, '--target', (Join-Path $models 'target.gguf'),
    '--draft', (Join-Path $models 'draft-4.gguf'), '--capture', $capture, '--directory', $workerDirectory)
$quoted = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
$processArgs = @{
    FilePath=$python; ArgumentList=$quoted; NoNewWindow=$true; PassThru=$true
    RedirectStandardOutput=$workerOut; RedirectStandardError=$workerStderr
}
Write-Host '[voxt] Calibrating and initializing the QNN verifier (up to 12 minutes).'
$worker = Start-Process @processArgs
try {
    $deadline = (Get-Date).AddMinutes(12)
    $lastProgress = $null
    $nextUpdate = Get-Date
    while (!(Test-Path -LiteralPath (Join-Path $workerDirectory 'ready.json') -PathType Leaf)) {
        if ($worker.HasExited -or (Get-Date) -ge $deadline) {
            $detail = if (Test-Path -LiteralPath $workerError) {
                (Get-Content -Raw -LiteralPath $workerError | ConvertFrom-Json).error
            } else { @(Get-Content -LiteralPath $workerOut,$workerStderr -Tail 2) -join ' | ' }
            $reason = if ($worker.HasExited) { "exited with code $($worker.ExitCode)" } else { 'reached the 12-minute initialization limit' }
            throw "QNN worker $reason. $detail"
        }
        if ((Get-Date) -ge $nextUpdate) {
            $progress = Get-Content -LiteralPath $workerOut -Tail 1 -ErrorAction SilentlyContinue
            if ($progress -and $lastProgress -ne $progress) { Write-Host "[voxt] QNN: $progress"; $lastProgress = $progress }
            $nextUpdate = (Get-Date).AddSeconds(5)
        }
        Start-Sleep -Milliseconds 250
    }
    $ready = Get-Content -Raw -LiteralPath (Join-Path $workerDirectory 'ready.json') | ConvertFrom-Json
    $Summary.Add("QNN verifier ready | history capacity $($ready.history_capacity) tokens | transport $($ready.transport)")
    Write-Host '[voxt] Measuring GPU + HTP DFlash.'
    $trials = if ($PlacementMatrix) { 3 } else { 1 }
    $hybrids = @(for ($trial = 1; $trial -le $trials; $trial++) {
        $name = if ($trial -eq 1) { 'live-qnn-dflash' } else { "live-qnn-dflash-$trial" }
        $run = Invoke-LiveClip $name $workerDirectory $worker.Id
        if ($run.LiveRounds -lt 1 -or $run.LiveRounds -gt $run.Metrics.rounds) { throw "$name missing full HTP verification rounds." }
        $run
    })
    $hybrid = @($hybrids | Sort-Object { $_.Rate })[[int][Math]::Floor($trials/2)]
    $totalRounds = ($hybrids | ForEach-Object { $_.LiveRounds } | Measure-Object -Sum).Sum
} finally {
    if (!$worker.HasExited) {
        New-Item -ItemType File -Path (Join-Path $workerDirectory 'stop') -Force | Out-Null
        if (!$worker.WaitForExit(30000)) { $worker.Kill(); $worker.WaitForExit() }
    }
    $worker.Dispose()
    Get-ChildItem -LiteralPath $workerDirectory -Filter 'target-verify-*.onnx*' -File |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
$profile = Get-Content -Raw -LiteralPath (Join-Path $workerDirectory 'worker_report.json') | ConvertFrom-Json
$Summary.Add(('GPU + HTP DFlash | {0} tokens | {1:F0} ms | {2:F2} request tok/s | {3}/{4} HTP rounds | {5} DSP executes across {6} trial(s)' -f
    $hybrid.Metrics.tokens, $hybrid.Metrics.wall_ms, $hybrid.Rate, $hybrid.LiveRounds, $hybrid.Metrics.rounds, $profile.qaairt_execute_events, $trials))
$groupEvents = @($profile.group_executes)
$Summary.Add("QNN DSP executes per seven-layer group: $($groupEvents -join ', ')")
if ($groupEvents.Count -ne 4 -or @($groupEvents | Where-Object { $_ -lt $totalRounds }).Count -or $hybrid.LiveRounds -lt 1 -or $hybrid.LiveRounds -gt $hybrid.Metrics.rounds -or $profile.rounds -ne $totalRounds -or $profile.qaairt_execute_events -lt $profile.rounds) {
    throw 'Missing device execution evidence for live Target verification.'
}
Write-Host '[voxt] Measuring the all-GPU DFlash reference.'
$baselines = @(for ($trial = 1; $trial -le $trials; $trial++) {
    $name = if ($trial -eq 1) { 'live-gpu-dflash' } else { "live-gpu-dflash-$trial" }
    $run = Invoke-LiveClip $name '' 0
    if ($run.LiveRounds -ne 0) { throw "$name unexpectedly used live verification." }
    $run
})
$baseline = @($baselines | Sort-Object { $_.Rate })[[int][Math]::Floor($trials/2)]
$Summary.Add(('All-GPU DFlash | {0} tokens | {1:F0} ms | {2:F2} request tok/s' -f
    $baseline.Metrics.tokens, $baseline.Metrics.wall_ms, $baseline.Rate))
if ($PlacementMatrix) {
    foreach ($run in @($baselines + $hybrids)) {
        if ($run.Metrics.text -cne $baseline.Metrics.text -or ($run.Metrics.ids -join ',') -ne ($baseline.Metrics.ids -join ',')) {
            throw 'GPU/QNN trials differ in transcript or token sequence.'
        }
    }
    foreach ($group in @(@{Name='GPU+GPU'; Runs=$baselines},@{Name='GPU+GPU, verify8=QNN'; Runs=$hybrids})) {
        $metrics = @($group.Runs | ForEach-Object { $_.Metrics })
        $priv = ($metrics | Measure-Object peak_private_bytes -Maximum).Maximum
        $ws = ($metrics | Measure-Object peak_working_bytes -Maximum).Maximum
        $Summary.Add(('{0} | 3 requests | max sampled private/working set {1:F0}/{2:F0} MiB (includes active worker)' -f $group.Name,($priv/1MB),($ws/1MB)))
    }
}
if ($hybrid.Metrics.text -cne $baseline.Metrics.text -or ($hybrid.Metrics.ids -join ',') -ne ($baseline.Metrics.ids -join ',')) {
    throw 'Live QNN transcript or generated token sequence differs from all-GPU DFlash.'
}
$Summary.Add(('Live QNN | token sequence matched | hybrid / all-GPU request throughput {0:F2}x' -f ($hybrid.Rate / $baseline.Rate)))
