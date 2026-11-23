[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: Hexagon HTP | 8 x 2048 by 2048 x 6144 QDQ projection')
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
        return @{ Passed = $false; Output = ''; Status = $message }
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
        return @{ Passed = $finished -and $status -eq 0; Output = $output.Trim(); Status = $detail }
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
    Invoke-QnnStep $python @('-X', 'utf8', $probe, '--backend', 'htp', '--output', $output) 'qnn' 180

    $report = Join-Path $output 'projection_probe.json'
    $result = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
    if ($result.backend -ne 'htp' -or $result.qnn_backend_execute_events -lt 1 -or
        $result.providers -notcontains 'QNNExecutionProvider') {
        throw 'QNN projection did not provide HTP execution evidence.'
    }
    $summary.Add("ONNX Runtime $($result.onnxruntime) | QNN EP $($result.onnxruntime_qnn)")
    $summary.Add("QAIRT backend execute events: $($result.qnn_backend_execute_events)")
    $summary.Add("Maximum output error: $($result.max_error_quantization_steps) quantization steps")
    $summary.Add(('Host round trip ms (median/p95): {0:F3} / {1:F3} | {2} runs' -f
        $result.host_median_ms, $result.host_p95_ms, $result.timed_runs))
    $summary.Add("Full report: $report")
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
