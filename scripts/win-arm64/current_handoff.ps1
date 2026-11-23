[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: Hexagon HTP | [8,2048] x [2048,6144] QDQ projection diagnostics')
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

    $stage = 'QNN HTP projection'
    $probe = Join-Path $source 'tools/qnn-probe/projection.py'
    $output = Join-Path $LogDirectory 'qnn-probe'
    $cases = @(
        @{ Name = 'cpu-reference'; Backend = 'cpu'; Variant = 'default'; Timing = @('--warmup', '0', '--runs', '1') }
        @{ Name = 'htp-default'; Backend = 'htp'; Variant = 'default'; Timing = @() }
        @{ Name = 'htp-lut-off'; Backend = 'htp'; Variant = 'lut-off'; Timing = @() }
        @{ Name = 'htp-wide-a16'; Backend = 'htp'; Variant = 'wide-a16'; Timing = @() }
    )
    $cpuPassed = $false
    $htpPassed = @()
    foreach ($case in $cases) {
        $name = $case.Name
        $caseOutput = Join-Path $output $name
        $arguments = @('-X', 'utf8', $probe, '--backend', $case.Backend, '--variant', $case.Variant,
            '--output', $caseOutput) + $case.Timing
        $step = Invoke-QnnStep $python $arguments $name 180 -Probe
        $report = Join-Path $caseOutput 'projection_probe.json'
        if (!(Test-Path -LiteralPath $report -PathType Leaf)) {
            $summary.Add("${name}: NO RESULT | $($step.Status)")
            $lastError = $step.Errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 1
            if ($lastError) { $summary.Add($lastError.Trim()) }
            continue
        }
        $result = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
        $hasHtp = ($result.providers -contains 'QNNExecutionProvider') -and ($result.qnn_backend_execute_events -gt 0)
        $passed = $step.Passed -and $result.accuracy_passed -and ($result.backend -eq $case.Backend) -and
            ($result.variant -eq $case.Variant) -and ($case.Backend -eq 'cpu' -or $hasHtp)
        $verdict = if ($passed) { 'PASS' } else { 'FAIL' }
        $summary.Add(('  {0}: {1} | max/p95 error {2}/{3:F1} steps | outside {4}/{5} | stride {6}' -f
            $name, $verdict, $result.max_error_quantization_steps, $result.p95_error_quantization_steps,
            $result.output_count_outside_tolerance, $result.output_count, $result.actual_output_code_stride))
        if ($case.Backend -eq 'cpu') {
            $cpuPassed = $passed
        } else {
            $summary.Add("    QAIRT execute events: $($result.qnn_backend_execute_events) | $($step.Status)")
            if ($result.timed_runs -gt 0) {
                $summary.Add(('    Host round trip ms (median/p95): {0:F3} / {1:F3} | {2} runs' -f
                    $result.host_median_ms, $result.host_p95_ms, $result.timed_runs))
            }
            if ($passed) { $htpPassed += $name }
        }
    }
    $summary.Add("Projection reports: $output")
    if (!$cpuPassed) { throw 'CPU reference check failed.' }
    if (!$htpPassed.Count) { throw 'No HTP case passed accuracy, execution evidence, and clean process exit.' }
    $summary.Add("Passing HTP cases: $($htpPassed -join ', ')")
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
