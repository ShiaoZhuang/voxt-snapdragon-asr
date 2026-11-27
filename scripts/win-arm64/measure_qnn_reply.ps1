[CmdletBinding()]
param(
    [System.IO.DirectoryInfo[]]$PreviousRuns = @(),
    [string]$CaptureDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$LogDirectory = (New-Item -ItemType Directory -Force -Path $LogDirectory).FullName
$scriptPath = Join-Path $PSScriptRoot '../../tools/qnn-probe/benchmark_reply.py'
$python = @('qnn-probe-venv', 'qnn-probe-venv-arm64') | ForEach-Object {
    Join-Path (Get-Location).Path ".local/$_/Scripts/python.exe"
} | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$python) { $python = 'python' }
$notes = [System.Collections.Generic.List[string]]::new()
try {
    $captures = @(if ($CaptureDirectory) {
        $CaptureDirectory
    } else {
        foreach ($run in $PreviousRuns) {
            foreach ($relative in 'QnnHtpAudio/qnn-htp-audio/live-calibration','qnn-htp-audio/live-calibration') {
                $folder = Join-Path $run.FullName $relative
                if (Test-Path -LiteralPath (Join-Path $folder 'capture.json') -PathType Leaf) { $folder }
            }
        }
    })
    if (!$captures.Count) { throw 'No archived QnnHtpAudio live-calibration was found.' }
    foreach ($capture in $captures) {
        $notes.Add("Capture | $capture")
        $lines = @(& $python -X utf8 -u $scriptPath --capture $capture --logs $LogDirectory)
        if ($LASTEXITCODE -eq 0 -and ($lines -match '^PASS \|')) {
            foreach ($line in $lines) { $notes.Add($line) }
            return
        }
        $notes.Add("Capture replay failed | exit $LASTEXITCODE")
    }
    throw 'No archived capture passed the byte-for-byte reply replay.'
} catch {
    $notes.Add("INCOMPLETE | $($_.Exception.Message)")
    throw
} finally {
    $notes | Set-Content -LiteralPath (Join-Path $LogDirectory 'qnn-reply-summary.txt') -Encoding UTF8
    foreach ($line in $notes) { $Summary.Add($line) }
}
