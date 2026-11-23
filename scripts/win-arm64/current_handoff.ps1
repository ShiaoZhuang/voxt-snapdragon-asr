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

function Invoke-QnnStep([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.WorkingDirectory = $source
    $start.Arguments = ((@('-X', 'utf8') + $Arguments) | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $child = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $finished = $child.WaitForExit(1000 * $TimeoutSeconds)
        if (!$finished) { $child.Kill(); $child.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $LogDirectory "$Name.stdout.log"), $stdout.GetAwaiter().GetResult())
        $errors = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $LogDirectory "$Name.stderr.log"), $errors)
        $status = $child.ExitCode
    } finally { $child.Dispose() }

    if (!$finished -or $status -ne 0) {
        foreach ($line in @($errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
            $summary.Add($line.Trim())
        }
        if (!$finished) { throw "$Name timed out after $TimeoutSeconds seconds." }
        throw "$Name exited with code $status."
    }
}

$stage = 'Python runtime'
try {
    # The fixed launcher starts this workflow from the user's checkout.
    $venv = Join-Path (Get-Location).Path '.local/qnn-probe-venv'
    $python = Join-Path $venv 'Scripts/python.exe'
    $basePython = $python
    $createVenv = !(Test-Path -LiteralPath $python -PathType Leaf)
    if ($createVenv) {
        $basePython = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if (!$basePython) { throw 'Windows ARM64 Python 3.11-3.14 is required. See Handoff.MD.' }
    $platformCheck = "import sys, sysconfig; print(sys.version); sys.exit(0 if sysconfig.get_platform() == 'win-arm64' and (3, 11) <= sys.version_info[:2] <= (3, 14) else 'Windows ARM64 Python 3.11-3.14 is required')"
    Invoke-QnnStep $basePython @('-c', $platformCheck) 'qnn-python' 20
    $summary.Add("Python: $python")

    $stage = 'QNN Python dependencies'
    if ($createVenv) { Invoke-QnnStep $basePython @('-m', 'venv', $venv) 'qnn-venv' 180 }
    $requirements = Join-Path $source 'tools/qnn-probe/requirements-win-arm64.txt'
    Invoke-QnnStep $python @('-m', 'pip', 'install', '--require-virtualenv', '--disable-pip-version-check', '--no-input',
        '--only-binary=:all:', '-r', $requirements) 'qnn-dependencies' 900
    $summary.Add('QNN Python dependencies: PASS')

    $stage = 'QNN HTP projection'
    $probe = Join-Path $source 'tools/qnn-probe/projection.py'
    $output = Join-Path $LogDirectory 'qnn-probe'
    Invoke-QnnStep $python @($probe, '--backend', 'htp', '--output', $output) 'qnn' 180

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
