[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [switch]$FullReplay
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
if ($FullReplay) { $summary.Add('Test: 28-layer Target HTP replay | eight positions | DFlash aux and logits') }
else { $summary.Add('Test: final-layer FFN down | identical SwiGLU input | Adreno and HTP') }
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path

function Invoke-QnnStep([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds, [switch]$Probe) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.WorkingDirectory = $source
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.EnvironmentVariables['PYTHON_MANAGER_AUTOMATIC_INSTALL'] = 'false'
    if ($Name -in @('target-replay', 'ffn-down-probe')) {
        $start.EnvironmentVariables['OPENBLAS_NUM_THREADS'] = '4'
    }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    try { $child = [Diagnostics.Process]::Start($start) } catch {
        if (!$Probe) { throw }
        $message = $_.Exception.Message
        [IO.File]::WriteAllText((Join-Path $LogDirectory "$Name.stderr.log"), $message)
        return @{ Passed = $false; Output = ''; Status = $message; Errors = '' }
    }
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $finished = $child.WaitForExit(1000 * $TimeoutSeconds)
        if (!$finished) { $child.Kill(); $child.WaitForExit() }
        $output = $stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $LogDirectory "$Name.stdout.log"), $output)
        $errors = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $LogDirectory "$Name.stderr.log"), $errors)
        $status = $child.ExitCode
    } finally { $child.Dispose() }

    if ($Probe) {
        $detail = if ($finished) { "exit $status" } else { "timed out after ${TimeoutSeconds}s" }
        if ($finished -and $status -lt 0) { $detail += ' (0x{0:X8})' -f $status }
        return @{ Passed = $finished -and $status -eq 0; Output = $output.Trim(); Status = $detail; Errors = $errors }
    }
    if (!$finished -or $status -ne 0) {
        foreach ($line in @($errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
            $summary.Add($line.Trim())
        }
        if (!$finished) { throw "$Name timed out after $TimeoutSeconds seconds." }
        throw "$Name exited with code $status."
    }
}

function Get-InstalledPython {
    $commands = Get-Command python, python3, python3.14, python3.13, python3.12, python3.11 `
        -All -CommandType Application -ErrorAction SilentlyContinue
    # Top-level WindowsApps aliases can launch the Store instead of an installed runtime.
    $storeAliases = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps' }
    foreach ($command in $commands) {
        if ((Split-Path -Parent $command.Source) -ne $storeAliases) { $command.Source }
    }
    # Official installers register PEP 514 paths even when Python is absent from PATH.
    foreach ($path in @('HKCU:\Software\Python\*\*\InstallPath', 'HKLM:\Software\Python\*\*\InstallPath')) {
        foreach ($key in @(Get-Item -Path $path -ErrorAction SilentlyContinue)) {
            $exe = $key.GetValue('ExecutablePath')
            if ($exe) { $exe }
            elseif ($key.Name -like '*\PythonCore\*' -and $key.GetValue('')) {
                Join-Path ($key.GetValue('')) 'python.exe'
            }
        }
    }
    $launcher = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcher) {
        $listing = Invoke-QnnStep $launcher.Source @('-0p') 'qnn-python-launcher' 15 -Probe
        if (!$listing.Passed) { $summary.Add("Python launcher listing: $($listing.Status)") }
        foreach ($line in ($listing.Output -split '\r?\n')) {
            if ($line -match '((?:[a-z]:\\|\\\\)[^"\r\n]+?\.exe)"?\s*$') { $Matches[1] }
        }
    }
}

function Get-TargetJournal([string]$Directory) {
    $journal = Join-Path $Directory 'target-layers.jsonl'
    if (Test-Path -LiteralPath $journal -PathType Leaf) {
        Get-Content -LiteralPath $journal | ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
    }
}

function Invoke-ReplayCpu([string]$Python, [string[]]$Arguments, [string]$Name, [string]$Directory, [switch]$Fp32) {
    $label = if ($Fp32) { 'CPU (FP32 arithmetic)' } else { 'CPU' }
    $argsForCpu = $Arguments + @('--backend', 'cpu', '--output', $Directory, '--warmup', '0', '--runs', '1')
    if ($Fp32) { $argsForCpu += '--attention-cpu-fp32' }
    $step = Invoke-QnnStep $Python $argsForCpu $Name 180 -Probe
    $report = Join-Path $Directory 'projection_probe.json'
    if (!(Test-Path -LiteralPath $report -PathType Leaf)) {
        $summary.Add("$label vs independent reference: NO RESULT ($($step.Status)). See $Name.stderr.log.")
        foreach ($line in ($step.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 2)) {
            $summary.Add($line.Trim())
        }
        return $false
    }
    $result = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
    $passed = $step.Passed -and $result.accuracy_passed
    $verdict = if ($passed) { 'PASS' } else { 'FAIL' }
    $summary.Add(('{0} vs independent reference: {1} | L2 {2:P4} | max / reference peak {3:P4} | {4}' -f
        $label, $verdict, $result.relative_l2_error, $result.max_error_fraction_of_reference_peak, $step.Status))
    return $passed
}

$stage = 'Python runtime'
try {
    # The fixed launcher starts this workflow from the user's checkout.
    $venv = Join-Path (Get-Location).Path '.local/qnn-probe-venv'
    $armVenv = "$venv-arm64"
    $localPythons = @(Join-Path $venv 'Scripts/python.exe'; Join-Path $armVenv 'Scripts/python.exe')
    $platformCheck = @'
import sys, sysconfig
platform = sysconfig.get_platform()
threaded = bool(sysconfig.get_config_var('Py_GIL_DISABLED'))
print(f'{platform} | {sys.implementation.name} {sys.version.split()[0]}' + (' (free-threaded)' if threaded else ''))
sys.exit(0 if platform == 'win-arm64' and sys.implementation.name == 'cpython' and not threaded and (3, 11) <= sys.version_info[:2] <= (3, 14) else 1)
'@
    $basePython = $null
    $candidateNumber = 0
    foreach ($candidate in (@($localPythons) + @(Get-InstalledPython) | Select-Object -Unique)) {
        if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $candidateNumber++
        $check = Invoke-QnnStep $candidate @('-X', 'utf8', '-I', '-c', $platformCheck) "qnn-python-$candidateNumber" 20 -Probe
        $detail = if ($check.Output) { $check.Output } else { $check.Status }
        $summary.Add("Python candidate: $candidate | $detail")
        if ($check.Passed) { $basePython = $candidate; break }
    }
    if (!$basePython) { throw 'No compatible Python found. Install standard CPython 3.11-3.14 (Windows ARM64) and rerun. See Handoff.MD.' }
    $python = $basePython
    $createVenv = $localPythons -notcontains $basePython
    if ($createVenv) {
        if (Test-Path -LiteralPath $venv) { $venv = $armVenv }
        if (Test-Path -LiteralPath $venv) { throw "The QNN environment at $venv is unusable. Move it aside and rerun." }
        $python = Join-Path $venv 'Scripts/python.exe'
    }
    $summary.Add("Python: $python")

    $stage = 'QNN Python dependencies'
    if ($createVenv) { Invoke-QnnStep $basePython @('-X', 'utf8', '-m', 'venv', $venv) 'qnn-venv' 180 }
    $requirements = Join-Path $source 'tools/qnn-probe/requirements-win-arm64.txt'
    Invoke-QnnStep $python @('-X', 'utf8', '-m', 'pip', 'install', '--require-virtualenv', '--disable-pip-version-check', '--no-input',
        '--only-binary=:all:', '-r', $requirements) 'qnn-dependencies' 900
    $summary.Add('QNN Python dependencies: PASS')

    $stage = 'Replay assets'
    & (Join-Path $PSScriptRoot 'verify_replay_assets.ps1') -InstallDirectory $InstallDirectory
    $summary.Add('Installed model and clip hashes: PASS')

    $stage = 'Native build'
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly | Out-Host
    $summary.Add('Native ARM64 backend build: PASS')

    $stage = 'Adreno DFlash capture'
    $capture = $null
    if (!$FullReplay) {
        foreach ($run in (Get-ChildItem -LiteralPath (Split-Path -Parent $LogDirectory) -Directory | Sort-Object Name -Descending)) {
            $candidate = Join-Path $run.FullName 'verify-capture'
            $missing = @('capture.json', 'target_logits.f32', 'layer-27/ffn_swiglu.f32', 'layer-27/ffn_inp.f32',
                         'layer-27/ffn_out.f32', 'layer-27/layer_out.f32') | Where-Object {
                !(Test-Path -LiteralPath (Join-Path $candidate $_) -PathType Leaf)
            }
            if (!$missing) {
                $capture = $candidate
                $summary.Add("Capture: reused $($run.Name)")
                break
            }
        }
    }
    if (!$capture) {
        $capture = Join-Path $LogDirectory 'verify-capture'
        $captureLog = Join-Path $LogDirectory 'adreno-capture.txt'
        & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $InstallDirectory `
            -NativeBuildDirectory $BuildDirectory -Transcribe -Draft -CaptureDirectory $capture -CaptureAllLayers -ReportPath $captureLog | Out-Host
        $captureDetails = Get-Content -Encoding UTF8 -LiteralPath $captureLog
        foreach ($line in ($captureDetails -match '^(Capture:|Capture layers:|Transcription probe:|Exit code:|Startup probe error:)')) {
            $summary.Add($line)
        }
        if (!($captureDetails -match '^Capture: PASS') -or !($captureDetails -match '^Transcription probe: PASS$') -or
            !($captureDetails -match '^Exit code: 0 \(0x00000000\)$')) {
            throw "Adreno DFlash capture did not complete. See $captureLog"
        }
    }

    $toolsDir = Join-Path $source 'tools/qnn-probe'
    $target = Join-Path $InstallDirectory 'models/target.gguf'
    if (!$FullReplay) {
        $stage = 'Final-layer FFN down'
        $output = Join-Path $LogDirectory 'ffn-down-probe'
        $step = Invoke-QnnStep $python @('-X', 'utf8', (Join-Path $toolsDir 'probe_ffn_down.py'), '--capture', $capture,
            '--target', $target, '--server', (Join-Path $BuildDirectory 'bin/qwen3_asr_server.exe'),
            '--output', $output) 'ffn-down-probe' 210 -Probe
        $reportPath = Join-Path $output 'ffn_down_report.json'
        if (!(Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            foreach ($line in ($step.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 2)) {
                $summary.Add($line.Trim())
            }
            throw "No FFN down report ($($step.Status))."
        }
        $probe = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
        $summary.Add(('FP32 vs captured down L2: {0:P3} | FP16 input rounding alone: {1:P3}' -f
            $probe.dense_vs_captured.relative_l2_error, $probe.fp16_input_vs_dense.relative_l2_error))
        foreach ($variant in $probe.variants.PSObject.Properties) {
            $value = $variant.Value
            if ($value.error) { $summary.Add("$($variant.Name): $($value.error)"); continue }
            $summary.Add(('{0} | vs FP32 L2 {1:P3} | vs captured L2 {2:P3}' -f
                $variant.Name, $value.vs_dense.relative_l2_error, $value.vs_captured.relative_l2_error))
        }
        if ($probe.htp.htp_vs_qdq_reference) {
            $summary.Add(('HTP | vs QDQ L2 {0:P3} | vs FP32 L2 {1:P3} | QAIRT executes {2}' -f
                $probe.htp.htp_vs_qdq_reference.relative_l2_error, $probe.htp.vs_dense.relative_l2_error, $probe.htp.qaairt_execute_events))
        }
        if ($probe.htp.error) { $summary.Add("HTP error: $($probe.htp.error)") }
        if ($probe.logits) {
            $matches = foreach ($entry in $probe.logits.PSObject.Properties) { "$($entry.Name)=$($entry.Value.matches)/8" }
            $summary.Add("Top-1 vs captured logits | $($matches -join ' | ')")
            $candidates = if ($probe.matching_native_variants) { $probe.matching_native_variants -join ', ' } else { 'none' }
            $summary.Add("Native variants within 5% and 8/8: $candidates")
        }
        if ($step.Passed -and $probe.passed) { $summary.Add('FFN down probe: PASS'); return }
        $summary.Add("FFN down probe stage: $($probe.last_stage) | $($step.Status)")
        throw "FFN down gate remains unresolved. See $reportPath"
    }

    $stage = 'Target replay'
    $draft = Join-Path $InstallDirectory 'models/draft-4.gguf'
    $targetDir = Join-Path $LogDirectory 'target-replay'
    $previous = Get-ChildItem -LiteralPath (Split-Path -Parent $LogDirectory) -Directory |
        Where-Object { $_.Name -lt (Split-Path -Leaf $LogDirectory) } | Sort-Object Name -Descending | Select-Object -First 1
    if ($previous) {
        $previousTarget = Join-Path $previous.FullName 'target-replay'
        if (!(Test-Path -LiteralPath (Join-Path $previousTarget 'target_replay.json') -PathType Leaf)) {
            $previousEntries = @(Get-TargetJournal $previousTarget)
            if ($previousEntries.Count) {
                $summary.Add("Previous incomplete replay | saved: $($previousEntries.Count) | last layer: $($previousEntries[-1].layer)")
            }
        }
    }
    $targetStep = Invoke-QnnStep $python @('-X', 'utf8', (Join-Path $toolsDir 'replay_target.py'),
        '--capture', $capture, '--target', $target, '--draft', $draft, '--output', $targetDir) 'target-replay' 1050 -Probe
    $progressPath = Join-Path $targetDir 'target-progress.json'
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        $progress = Get-Content -Raw -LiteralPath $progressPath | ConvertFrom-Json
        if ($progress.phase -ne 'complete') {
            $where = if ($null -ne $progress.layer) { "layer $($progress.layer) | " } else { '' }
            $detail = ''
            if ($progress.worker) {
                $phasePath = Join-Path $targetDir "$($progress.worker).phase.txt"
                if (Test-Path -LiteralPath $phasePath -PathType Leaf) {
                    $detail = ' | ' + (Get-Content -Raw -LiteralPath $phasePath).Trim()
                }
            }
            $summary.Add("Last recorded step: $where$($progress.phase)$detail")
        }
    }
    $isolatedPath = Join-Path $targetDir 'last-layer-isolated.json'
    if (Test-Path -LiteralPath $isolatedPath -PathType Leaf) {
        $isolated = Get-Content -Raw -LiteralPath $isolatedPath | ConvertFrom-Json
        if ($isolated.htp_vs_cpu_same_input) {
            $summary.Add(('Isolated last layer | HTP/CPU L2 {0:P3} | HTP/Adreno L2 {1:P3} | QAIRT executes {2}' -f
                $isolated.htp_vs_cpu_same_input.relative_l2_error, $isolated.htp_chain_vs_native.relative_l2_error,
                $isolated.qaairt_execute_events))
        }
        if ($isolated.error) { $summary.Add("Isolated last layer error: $($isolated.error)") }
    }
    $targetReport = Join-Path $targetDir 'target_replay.json'
    if (Test-Path -LiteralPath $targetReport -PathType Leaf) {
        $replay = Get-Content -Raw -LiteralPath $targetReport | ConvertFrom-Json
        $chain = if ($replay.chain_complete) { 'complete' } else { 'interrupted' }
        $summary.Add("Decoder chain: $chain | HTP $($replay.htp_layers_passed)/$($replay.layer_count) | CPU $($replay.cpu_layers_passed)/$($replay.layer_count)")
        if ($replay.budget_exhausted) { $summary.Add("Decoder time budget reached | checked $($replay.layers_checked)/$($replay.layer_count) layers") }
        $summary.Add(('QAIRT executes: {0} | HTP layer medians summed: {1:F2} ms' -f
            $replay.htp_events, $replay.htp_layer_ms_sum))
        $last = $replay.last_layer
        $reference = $last.native_reference
        if (!$reference) {
            $lastReferencePath = Join-Path $targetDir 'last-layer-reference.json'
            if (Test-Path -LiteralPath $lastReferencePath -PathType Leaf) {
                $reference = Get-Content -Raw -LiteralPath $lastReferencePath | ConvertFrom-Json
            }
        }
        if ($reference) {
            $mode = if ($reference.boundary_capture) { 'per-stage' } else { 'whole-layer' }
            $summary.Add(('Last layer native reference | dense L2 {0:P3} | gate: {1}' -f $reference.dense_output_l2, $mode))
            $stages = foreach ($entry in ($reference.stage_l2.PSObject.Properties | Sort-Object Value -Descending | Select-Object -First 4)) {
                '{0}={1:P3}' -f $entry.Name, $entry.Value
            }
            if ($stages) { $summary.Add("Last layer largest stage L2: $($stages -join ' | ')") }
        }
        if ($replay.logits.native_hidden) {
            $logits = $replay.logits
            $matches = foreach ($name in @('native_hidden', 'cpu_chain', 'htp_chain', 'htp_isolated')) {
                if ($logits.$name) { "$name=$($logits.$name.matches)/8" }
            }
            $summary.Add("Logits top-1 vs Adreno | $($matches -join ' | ')")
        }
        if ($replay.logits.htp_chain) {
            $logits = $replay.logits
            $summary.Add(('HTP logits relative L2: {0:P3} | IDs: {1}' -f
                $logits.htp_chain.relative_l2_error, ($logits.htp_chain.top1 -join ',')))
            if ($logits.htp_chain.matches -ne 8) { $summary.Add("Adreno IDs: $($replay.native_top1 -join ',')") }
            $aux = foreach ($entry in $replay.aux.PSObject.Properties) {
                '{0}={1:P3}' -f $entry.Name, $entry.Value.htp_chain_vs_native.relative_l2_error
            }
            $summary.Add("DFlash auxiliary input relative L2: $($aux -join ' | ')")
        }
        if ($replay.accepted_by_top1) { $summary.Add('Final down projection above 5% accepted by complete-chain top-1 agreement.') }
        if ($replay.logits_error) { $summary.Add("Host logits error: $($replay.logits_error)") }
        if ($replay.failed_layers.Count) { $summary.Add("Failed layers (zero-indexed): $($replay.failed_layers -join ',')") }
        foreach ($entry in ($replay.native_reference_failures.PSObject.Properties | Select-Object -First 2)) {
            $summary.Add("Layer $($entry.Name) native reference above 5%: $($entry.Value -join ', ')")
        }
        foreach ($entry in ($replay.errors.PSObject.Properties | Select-Object -First 2)) {
            $summary.Add("Layer $($entry.Name) error: $(($entry.Value -split '\r?\n')[0])")
        }
        if ($replay.passed -and $replay.backend -eq 'htp' -and $targetStep.Passed) {
            $summary.Add('Target replay: PASS')
            return
        }
        if ($replay.passed) {
            foreach ($line in ($targetStep.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 2)) {
                $summary.Add($line.Trim())
            }
        }
        throw "Target replay did not pass ($($targetStep.Status)). See $targetReport"
    } else {
        $entries = @(Get-TargetJournal $targetDir)
        if ($entries.Count) {
            $passedLayers = @($entries | Where-Object passed)
            $summary.Add("Saved layer results: $($entries.Count) | passed: $($passedLayers.Count)")
        }
        foreach ($line in ($targetStep.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 3)) {
            $summary.Add($line.Trim())
        }
        if ($progress) { throw "Target replay stopped ($($targetStep.Status)). See $targetDir" }
    }
    $summary.Add("Target replay: FAIL ($($targetStep.Status)) | running layer-0 diagnostics")
    $failures = @('target-replay')
    $postRopePassed = $false
    foreach ($case in @(
        @{Name = 'full-decoder'; Prepare = 'prepare_decoder_layer.py'; More = @('--target', $target, '--full'); Output = 'actual_u16.npy'}
        @{Name = 'decoder-layer'; Prepare = 'prepare_decoder_layer.py'; More = @('--target', $target); Output = 'actual_u16.npy'}
        @{Name = 'full-ffn'; Prepare = 'prepare_ffn.py'; More = @('--target', $target); Output = 'actual_u16.npy'}
        @{Name = 'attention'; Prepare = 'prepare_attention.py'; More = @(); Output = 'actual_f16.npy'}
    )) {
        $name = $case.Name
        $layer = $name -in @('full-decoder', 'decoder-layer')
        if (!$layer -and $postRopePassed) { break }
        $fixture = Join-Path $LogDirectory "$name-fixture"
        $cpuOutput = Join-Path $LogDirectory "$name-cpu"
        $htpOutput = Join-Path $LogDirectory "$name-htp"
        try {
            $summary.Add("--- $name ---")
            Invoke-QnnStep $python (@('-X', 'utf8', (Join-Path $toolsDir $case.Prepare),
                '--capture', $capture, '--output', $fixture) + $case.More) "$name-prepare" 180
            $prep = Get-Content -Raw -LiteralPath (Join-Path $fixture 'preparation.json') | ConvertFrom-Json
            if ($layer) {
                $summary.Add("KV append: $($prep.history_tokens) history + $($prep.staged_tokens) staged | static columns: $($prep.cache_columns)")
                if ($name -eq 'full-decoder') {
                    $qkv = $prep.dense_qkv_vs_native
                    $summary.Add(('Q/K/V vs Adreno capture L2: {0:P3} / {1:P3} / {2:P3}' -f
                        $qkv.Q.relative_l2_error, $qkv.K.relative_l2_error, $qkv.V.relative_l2_error))
                }
                $summary.Add(('Mixed precision L2 | vs dense Q8_0 {0:P3} | vs Adreno layer {1:P3}' -f
                    $prep.mixed_precision_vs_dense.relative_l2_error, $prep.mixed_precision_vs_native_capture.relative_l2_error))
            } elseif ($name -eq 'attention') {
                $summary.Add("KV columns: $($prep.cache_columns) | visible per query: $($prep.visible_keys_per_query -join ',')")
                $summary.Add(('FP16 vs native Adreno attention | relative L2: {0:P4}' -f $prep.fp16_vs_native_capture.relative_l2_error))
            } else {
                $summary.Add(('A16/U8 re-encoding vs dense Q8_0 | relative L2: {0:P4}' -f $prep.qdq_vs_dense_q8_0.relative_l2_error))
            }

            $arguments = @('-X', 'utf8', (Join-Path $toolsDir 'projection.py'), '--replay', $fixture)
            $cpuPassed = Invoke-ReplayCpu $python $arguments "$name-cpu" $cpuOutput -Fp32:$layer
            if (!$cpuPassed -and $name -eq 'attention') {
                $cpuOutput = Join-Path $LogDirectory "$name-cpu-fp32"
                $cpuPassed = Invoke-ReplayCpu $python $arguments "$name-cpu-fp32" $cpuOutput -Fp32
            }
            if (!$cpuPassed -and $name -eq 'full-ffn') { throw 'CPU reference failed.' }
            $htpArguments = $arguments + @('--backend', 'htp', '--output', $htpOutput)
            if ($cpuPassed) {
                $htpArguments += @('--cpu-output', (Join-Path $cpuOutput $case.Output))
            } else {
                $summary.Add('HTP diagnostic: using the independent reference while CPU comparison is unavailable.')
            }
            $step = Invoke-QnnStep $python $htpArguments "$name-htp" 180 -Probe
            $htpReport = Join-Path $htpOutput 'projection_probe.json'
            if (!(Test-Path -LiteralPath $htpReport -PathType Leaf)) {
                foreach ($line in ($step.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 2)) {
                    $summary.Add($line.Trim())
                }
                throw "No HTP result ($($step.Status)). See $name-htp.stderr.log."
            }
            $htp = Get-Content -Raw -LiteralPath $htpReport | ConvertFrom-Json
            $summary.Add(('HTP vs independent reference | L2 {0:P4} | max / reference peak {1:P4}' -f
                $htp.relative_l2_error, $htp.max_error_fraction_of_reference_peak))
            if ($htp.cpu_comparison) {
                $summary.Add(('HTP vs CPU | L2 {0:P4} | max / reference peak {1:P4}' -f
                    $htp.cpu_comparison.relative_l2_error, $htp.cpu_comparison.max_error_fraction_of_reference_peak))
            }
            if ($layer -and $htp.kv_visibility) {
                $visibility = foreach ($check in $htp.kv_visibility.PSObject.Properties) {
                    $result = if ($null -eq $check.Value) { 'SKIP' } elseif ($check.Value) { 'PASS' } else { 'FAIL' }
                    "$($check.Name)=$result"
                }
                $summary.Add("KV visibility: $($visibility -join ' | ')")
            }
            if ($name -eq 'full-ffn') {
                $summary.Add(('HTP vs CPU: max/P95 {0}/{1:F1} steps | >2 steps {2}/{3}' -f
                    $htp.cpu_comparison.max_error_quantization_steps, $htp.cpu_comparison.p95_error_quantization_steps,
                    $htp.cpu_comparison.output_count_outside_tolerance, $htp.cpu_comparison.output_count))
            }
            $summary.Add("QAIRT execute events: $($htp.qnn_backend_execute_events) | $($step.Status)")
            if ($htp.timed_runs -gt 0) {
                $summary.Add(('Host round trip ms (median/P95): {0:F3} / {1:F3} | {2} runs' -f
                    $htp.host_median_ms, $htp.host_p95_ms, $htp.timed_runs))
            }
            if (!$step.Passed -or $htp.replay_kind -ne $name -or !$htp.accuracy_passed -or
                $htp.providers -notcontains 'QNNExecutionProvider' -or $htp.qnn_backend_execute_events -lt 1) {
                throw 'HTP replay requires matching output, QAIRT execution evidence, and a clean process exit.'
            }
            if (!$cpuPassed) { throw 'HTP diagnostic passed against the independent reference. A valid CPU pairing is still required.' }
            if (!$htp.cpu_comparison.accuracy_passed) { throw 'HTP comparison to the validated CPU reference failed.' }
            $summary.Add("${name}: PASS")
            if ($name -eq 'decoder-layer') { $postRopePassed = $true }
        } catch {
            $failures += $name
            $summary.Add("${name}: FAIL | $($_.Exception.Message)")
        }
    }
    if ($failures.Count) { throw "Replay failed: $($failures -join ', ')." }
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
