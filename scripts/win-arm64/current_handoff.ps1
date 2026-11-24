[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [switch]$FullReplay
)

$ErrorActionPreference = 'Stop'
$paths = @{ InstallDirectory=$InstallDirectory; BuildDirectory=$BuildDirectory; LogDirectory=$LogDirectory }
$notes = [System.Collections.Generic.List[string]]::new()
$failed = @()
try {
    & (Join-Path $PSScriptRoot 'qnn_handoff.ps1') @paths -FullReplay
} catch {
    $failed += 'QNN'
    $notes.Add("QNN replay: FAIL | $($_.Exception.Message)")
}
if (!$FullReplay) {
    try {
        & (Join-Path $PSScriptRoot 'verify_ggml_hexagon.ps1') @paths -Summary $notes
    } catch {
        $failed += 'GGML Hexagon'
        $notes.Add("GGML Hexagon: INCOMPLETE | $($_.Exception.Message)")
    }
}
$notes | Add-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
if ($failed.Count) { throw "Incomplete verification: $($failed -join ', ')." }
