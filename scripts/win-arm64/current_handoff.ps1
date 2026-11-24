[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [switch]$FullReplay
)

$ErrorActionPreference = 'Stop'
$paths = @{ InstallDirectory=$InstallDirectory; BuildDirectory=$BuildDirectory; LogDirectory=$LogDirectory }
if ($FullReplay) {
    & (Join-Path $PSScriptRoot 'qnn_handoff.ps1') @paths -FullReplay
    return
}
$notes = [System.Collections.Generic.List[string]]::new()
$failures = @()
foreach ($route in @(
    @{ Name='QNN live'; Script='verify_live_qnn.ps1' },
    @{ Name='GGML Hexagon'; Script='verify_ggml_hexagon.ps1' }
)) {
    try {
        & (Join-Path $PSScriptRoot $route.Script) @paths -Summary $notes
    } catch {
        $failures += $route.Name
        $notes.Add("$($route.Name): INCOMPLETE | $($_.Exception.Message)")
    } finally {
        $notes | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
    }
}
if ($failures.Count) { throw "Incomplete routes: $($failures -join ', ')." }
