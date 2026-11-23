[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: Voxt 31 clips | Adreno OpenCL | Target-only + Q4 DFlash')
$stage = 'local assets'
try {
    if (!(Test-Path -LiteralPath (Join-Path $InstallDirectory 'verify_manifest.json') -PathType Leaf)) {
        throw "Missing installed Veri 1 manifest at $InstallDirectory"
    }

    $stage = 'native build'
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory
    $summary.Add('Native backend and benchmark build: PASS')

    $stage = 'Voxt benchmark'
    $results = Join-Path $LogDirectory 'verification'
    & (Join-Path $PSScriptRoot 'run_verify.ps1') -OpenCLOnly -NativeBuildDirectory $BuildDirectory `
        -InstallDirectory $InstallDirectory -OutputDirectory $results
    $stats = Get-Content -Raw -LiteralPath (Join-Path $results 'verify_stats.json') | ConvertFrom-Json
    $report = Join-Path $results 'verify_report.md'
    foreach ($line in @(Get-Content -Encoding UTF8 -LiteralPath $report | Where-Object { $_ -match '^(Preflight failed:|Device query failed:|  GPUOpenCL:)' })) {
        $summary.Add($line.Trim())
    }

    foreach ($name in @('opencl-target-only', 'opencl-draft-q4')) {
        $run = $stats.runs.$name
        if (!$run) { continue }
        if ($run.error) {
            $summary.Add("${name}: FAIL | $($run.error)")
            if ($run.diagnostic) { $summary.Add("  $($run.diagnostic)") }
            continue
        }
        $m = $run.metrics
        $total = $run.aggregate
        $label = if ($run.passed) { 'PASS' } else { 'FAIL' }
        $summary.Add(('{0}: {1} | {2} clips | error {3:P2} | dict {4}/10 | wall sum {5:F1} s' -f
            $name, $label, $m.clips, $m.error_rate, $m.dictionary_hits, ($total.elapsed_ms / 1000)))
        if ($name -like '*draft*') {
            $summary.Add(('  avg_accept {0:F2} | avg_step {1:F2} | rate {2:P1} | clean {3:F2}' -f
                $m.avg_accept, $m.avg_step, $m.accept_rate, $m.clean_avg_accept))
            if ($null -ne $m.greedy_token_mismatches) {
                $summary.Add("  Token mismatches: $($m.greedy_token_mismatches.Count) $($m.greedy_token_mismatches -join ', ')".TrimEnd())
            }
            $summary.Add(('  zh-plain {0:P2} | en {1:P2} | long {2:P2}' -f
                $m.sets.'zh-plain', $m.sets.en, $m.sets.long))
            $timed = $total.draft_ms + $total.target_ms + $total.context_ms
            if ($timed -gt 0 -and $total.rounds -gt 0) {
                $summary.Add(('  ms/round: Draft {0:F2} ({1:P1}) | Target {2:F2} ({3:P1}) | Context {4:F2} ({5:P1})' -f
                    ($total.draft_ms / $total.rounds), ($total.draft_ms / $timed),
                    ($total.target_ms / $total.rounds), ($total.target_ms / $timed),
                    ($total.context_ms / $total.rounds), ($total.context_ms / $timed)))
            } else { $summary.Add('  DFlash profiling unavailable.') }
        }
    }
    $summary.Add("Full report: $report")
    if (!$stats.passed) { throw 'One or more Voxt benchmark gates failed.' }
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
