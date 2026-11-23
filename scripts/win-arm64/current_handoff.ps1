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
$stage = 'Python runtime'
try {
    # The fixed launcher starts this workflow from the user's checkout.
    $python = Join-Path (Get-Location).Path '.local/qnn-probe-venv/Scripts/python.exe'
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) {
        $python = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if (!$python) { throw 'Windows ARM64 Python 3.11-3.14 is required. See Handoff.MD.' }
    $summary.Add("Python: $python")

    $stage = 'QNN HTP projection'
    $source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $probe = Join-Path $source 'tools/qnn-probe/projection.py'
    $output = Join-Path $LogDirectory 'qnn-probe'
    $start = [Diagnostics.ProcessStartInfo]::new($python)
    $start.WorkingDirectory = $source
    $start.Arguments = '-X utf8 "' + $probe + '" --backend htp --output "' + $output + '"'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $child = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $finished = $child.WaitForExit(180000)
        if (!$finished) { $child.Kill(); $child.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $LogDirectory 'qnn.stdout.log'), $stdout.GetAwaiter().GetResult())
        $errors = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $LogDirectory 'qnn.stderr.log'), $errors)
        $status = $child.ExitCode
    } finally { $child.Dispose() }

    if (!$finished -or $status -ne 0) {
        foreach ($line in @($errors -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4)) {
            $summary.Add($line.Trim())
        }
        if ($errors -match 'ModuleNotFoundError') {
            $summary.Add('Use the approved ARM64 Python packages in tools/qnn-probe/requirements-win-arm64.txt.')
        }
        if (!$finished) { throw 'QNN projection timed out after 180 seconds.' }
        throw "QNN projection exited with code $status."
    }

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
