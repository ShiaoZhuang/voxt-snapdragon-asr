[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [switch]$FullReplay,
    [ValidateSet('All', 'QnnLive', 'GgmlHexagon')][string]$Route = 'All'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$paths = @{ InstallDirectory=$InstallDirectory; BuildDirectory=$BuildDirectory; LogDirectory=$LogDirectory }
if ($FullReplay) {
    & (Join-Path $PSScriptRoot 'qnn_handoff.ps1') @paths -FullReplay
    return
}
$notes = [System.Collections.Generic.List[string]]::new()
$failures = @()
foreach ($step in @(
    @{ Id='QnnLive'; Name='QNN live'; Script='verify_live_qnn.ps1' },
    @{ Id='GgmlHexagon'; Name='GGML Hexagon'; Script='verify_ggml_hexagon.ps1' }
)) {
    if ($Route -ne 'All' -and $Route -ne $step.Id) { continue }
    Write-Host "[voxt] Starting $($step.Name)."
    try {
        & (Join-Path $PSScriptRoot $step.Script) @paths -Summary $notes
    } catch {
        $failures += $step.Name
        $notes.Add("$($step.Name): INCOMPLETE | $($_.Exception.Message)")
        Write-Host "[voxt] $($step.Name): INCOMPLETE | $($_.Exception.Message)"
    } finally {
        $notes | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
    }
}
if ($failures.Count) { throw "Incomplete routes: $($failures -join ', ')." }
