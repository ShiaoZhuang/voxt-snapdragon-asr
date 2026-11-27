[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [switch]$FullReplay,
    [ValidateSet('Explore', 'Hetero', 'Fusion', 'Dispatch', 'Wait', 'QnnHtpAudio', 'HtpSuite', 'AudioEncoder', 'All', 'QnnLive', 'GgmlHexagon')][string]$Route = 'Explore'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$paths = @{ InstallDirectory=$InstallDirectory; BuildDirectory=$BuildDirectory; LogDirectory=$LogDirectory }
if ($FullReplay) {
    & (Join-Path $PSScriptRoot 'qnn_handoff.ps1') @paths -FullReplay
    return
}
if (!$PSBoundParameters.ContainsKey('Route') -and $env:VOXT_VERIFY_ROUTE) {
    $Route = $env:VOXT_VERIFY_ROUTE
}
$notes = [System.Collections.Generic.List[string]]::new()
$failures = @()
foreach ($step in @(
    @{ Id='GgmlHexagon'; Name='GGML Hexagon'; Script='verify_ggml_hexagon.ps1' },
    @{ Id='QnnLive'; Name='QNN live'; Script='verify_live_qnn.ps1' }
)) {
    $audioTest = $Route -in 'Explore', 'Hetero', 'Fusion', 'Dispatch', 'Wait', 'QnnHtpAudio', 'HtpSuite', 'AudioEncoder' -and $step.Id -eq 'GgmlHexagon'
    if (!$audioTest -and $Route -ne 'All' -and $Route -ne $step.Id) { continue }
    Write-Host "[voxt] Starting $($step.Name)."
    try {
        $extra = @{}
        if ($audioTest -and $Route -notin 'AudioEncoder','HtpSuite') { $extra.Study = $Route }
        if ($audioTest -and $Route -eq 'HtpSuite') { $extra.HtpSuite = $true }
        if ($audioTest -and $Route -eq 'AudioEncoder') { $extra.AudioComparison = $true }
        if ($Route -eq 'All') { $extra.PlacementMatrix = $true }
        & (Join-Path $PSScriptRoot $step.Script) @paths @extra -Summary $notes
    } catch {
        $failureLog = Join-Path $LogDirectory "$($step.Id)-failure.txt"
        $location = "$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)"
        @($_.Exception.ToString(), $_.ScriptStackTrace) | Set-Content -Encoding UTF8 -LiteralPath $failureLog
        $failures += $step.Name
        $notes.Add("$($step.Name): INCOMPLETE | $($_.Exception.Message) | $location")
        Write-Host "[voxt] $($step.Name): INCOMPLETE | $($_.Exception.Message) | $location"
    } finally {
        $notes | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
    }
}
if ($failures.Count) { throw "Incomplete routes: $($failures -join ', ')." }
