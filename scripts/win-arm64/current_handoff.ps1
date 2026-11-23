[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: real DFlash verification | layer-0 full FFN, eight positions | Adreno capture + HTP replay')
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path

function Invoke-QnnStep([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds, [switch]$Probe) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.WorkingDirectory = $source
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.EnvironmentVariables['PYTHON_MANAGER_AUTOMATIC_INSTALL'] = 'false'
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
    $assets = Get-Content -Raw -LiteralPath (Join-Path $InstallDirectory 'verify_manifest.json') | ConvertFrom-Json
    foreach ($relative in @('models/target.gguf', 'models/mmproj.gguf', 'models/draft-4.gguf', 'eval/zh-plain-1.wav')) {
        $path = Join-Path $InstallDirectory $relative
        $expectedHash = $assets.files.$relative
        if (!$expectedHash -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash) {
            throw "SHA-256 mismatch: $relative"
        }
    }
    $summary.Add('Installed model and clip hashes: PASS')

    $stage = 'Native build'
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly | Out-Host
    $summary.Add('Native ARM64 backend build: PASS')

    $stage = 'Adreno DFlash capture'
    $capture = Join-Path $LogDirectory 'verify-capture'
    $captureLog = Join-Path $LogDirectory 'adreno-capture.txt'
    & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $InstallDirectory `
        -NativeBuildDirectory $BuildDirectory -Transcribe -Draft -CaptureDirectory $capture -ReportPath $captureLog | Out-Host
    $captureDetails = Get-Content -Encoding UTF8 -LiteralPath $captureLog
    foreach ($line in ($captureDetails -match '^(Capture:|Transcription probe:|Exit code:|Startup probe error:)')) {
        $summary.Add($line)
    }
    if (!($captureDetails -match '^Capture: PASS') -or !($captureDetails -match '^Transcription probe: PASS$') -or
        !($captureDetails -match '^Exit code: 0 \(0x00000000\)$')) {
        throw "Adreno DFlash capture did not complete. See $captureLog"
    }

    $stage = 'Prepare QDQ replay'
    $toolsDir = Join-Path $source 'tools/qnn-probe'
    $fixture = Join-Path $LogDirectory 'replay-fixture'
    $target = Join-Path $InstallDirectory 'models/target.gguf'
    Invoke-QnnStep $python @('-X', 'utf8', (Join-Path $toolsDir 'prepare_ffn.py'),
        '--capture', $capture, '--target', $target, '--output', $fixture) 'prepare-replay' 180
    $preparation = Get-Content -Raw -LiteralPath (Join-Path $fixture 'preparation.json') | ConvertFrom-Json
    $summary.Add(('Dense Q8_0 vs Adreno capture | relative L2 error: {0:P4}' -f $preparation.dense_vs_native_capture.relative_l2_error))
    $summary.Add(('A16/U8 re-encoding vs dense Q8_0 | relative L2 error: {0:P4} | {1} weight scales' -f
        $preparation.qdq_vs_dense_q8_0.relative_l2_error, $preparation.weight_scale_count))

    $probe = Join-Path $toolsDir 'projection.py'
    $cpuOutput = Join-Path $LogDirectory 'cpu-replay'
    $htpOutput = Join-Path $LogDirectory 'htp-replay'
    $arguments = @('-X', 'utf8', $probe, '--replay', $fixture)
    $stage = 'CPU QDQ reference'
    Invoke-QnnStep $python ($arguments + @('--backend', 'cpu', '--output', $cpuOutput, '--warmup', '0', '--runs', '1')) 'cpu-replay' 180
    $cpu = Get-Content -Raw -LiteralPath (Join-Path $cpuOutput 'projection_probe.json') | ConvertFrom-Json
    $summary.Add("CPU QDQ vs independent reference: $($cpu.max_error_quantization_steps) steps max")

    $stage = 'HTP QDQ replay'
    $step = Invoke-QnnStep $python ($arguments + @('--backend', 'htp', '--output', $htpOutput,
        '--cpu-output', (Join-Path $cpuOutput 'actual_u16.npy'))) 'htp-replay' 180 -Probe
    $htpReport = Join-Path $htpOutput 'projection_probe.json'
    if (!(Test-Path -LiteralPath $htpReport -PathType Leaf)) {
        foreach ($line in ($step.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 2)) {
            $summary.Add($line.Trim())
        }
        throw "No HTP replay result ($($step.Status)). See htp-replay.stderr.log."
    }
    $htp = Get-Content -Raw -LiteralPath $htpReport | ConvertFrom-Json
    $summary.Add("HTP vs independent reference: $($htp.max_error_quantization_steps) steps max")
    $summary.Add(('HTP vs CPU QDQ: max/P95 {0}/{1:F1} steps | >2 steps {2}/{3}' -f
        $htp.cpu_comparison.max_error_quantization_steps, $htp.cpu_comparison.p95_error_quantization_steps,
        $htp.cpu_comparison.output_count_outside_tolerance, $htp.cpu_comparison.output_count))
    $summary.Add(('HTP vs CPU QDQ: relative L2 {0:P4} | max error / reference peak {1:P4}' -f
        $htp.cpu_comparison.relative_l2_error, $htp.cpu_comparison.max_error_fraction_of_reference_peak))
    $summary.Add("QAIRT execute events: $($htp.qnn_backend_execute_events) | $($step.Status)")
    if ($htp.timed_runs -gt 0) {
        $summary.Add(('Host round trip ms (median/P95): {0:F3} / {1:F3} | {2} runs' -f
            $htp.host_median_ms, $htp.host_p95_ms, $htp.timed_runs))
    }
    if (!$step.Passed -or $htp.replay_kind -ne 'full-ffn' -or !$htp.accuracy_passed -or !$htp.cpu_comparison.accuracy_passed -or
        $htp.providers -notcontains 'QNNExecutionProvider' -or $htp.qnn_backend_execute_events -lt 1) {
        throw 'HTP replay requires matching output, QAIRT execution evidence, and a clean process exit.'
    }
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
