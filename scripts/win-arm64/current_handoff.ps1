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
try {
    & (Join-Path $PSScriptRoot 'verify_ggml_hexagon.ps1') @paths -Summary $notes
} catch {
    $notes.Add("GGML Hexagon: INCOMPLETE | $($_.Exception.Message)")
    throw
} finally {
    $notes | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
