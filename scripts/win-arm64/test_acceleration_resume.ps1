# Regression coverage for the Explore handoff on PowerShell 5.1 and newer.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ("voxt-explore-" + [Guid]::NewGuid())
try {
    $scripts = (New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts/win-arm64')).FullName
    $runs = (New-Item -ItemType Directory -Path (Join-Path $root 'runs')).FullName
    $ops = (New-Item -ItemType Directory -Path (Join-Path $root 'ops')).FullName
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run_acceleration_studies.ps1') -Destination $scripts
    Set-Content -LiteralPath (Join-Path $root 'sources.lock.json') -Value '{"geniex_htp":{"version":"fixture","files":{"libggml-htp-v73.so":"other"}}}'
    $lib = Join-Path $ops 'libggml-htp-v73.so'
    Set-Content -LiteralPath $lib -Value 'fixture'
    $hash = (Get-FileHash -LiteralPath $lib).Hash

    # Simulate the archived LongPair result produced by the previous release.
    $prior = (New-Item -ItemType Directory -Path (Join-Path $runs '00')).FullName
    $legacyKey = "45810259713f380b5eefe2e133cc07b4b6c45010-$hash"
    foreach ($status in 'started','pass') {
        Set-Content -LiteralPath (Join-Path $prior "LongPair-$status.txt") -Value $legacyKey
    }

    Set-Content -LiteralPath (Join-Path $scripts 'measure_qnn_reply.ps1') -Value @'
param($PreviousRuns,$LogDirectory,$Summary)
if (!($PreviousRuns | Where-Object Name -eq '00')) { throw 'Archive not supplied' }
Set-Content -LiteralPath (Join-Path $LogDirectory 'qnn-reply-summary.txt') 'PASS | fixture'
'@
    function python {
        $file = [IO.Path]::GetFileNameWithoutExtension($args[1])
        $dir = $args[-1]
        if ($file -eq 'measure_htp_queue' -and $queueShouldFail) {
            $global:LASTEXITCODE = 1
            return
        }
        $report = $file.Replace('measure_', '').Replace('_', '-') + '-summary.txt'
        Set-Content -LiteralPath (Join-Path $dir $report) -Value 'PASS | fixture'
        $global:LASTEXITCODE = 0
    }
    $summary = [Collections.Generic.List[string]]::new()
    function Run([string]$Id, [string]$Study) {
        $summary.Clear()
        $log = (New-Item -ItemType Directory -Path (Join-Path $runs $Id)).FullName
        & (Join-Path $scripts 'run_acceleration_studies.ps1') -Product $root -Ops $ops -InstallDirectory $root -LogDirectory $log -Summary $summary -Study $Study
    }

    $queueShouldFail = $true
    try { Run '01' 'Explore'; throw 'Expected Queue failure' }
    catch { if ($_.Exception.Message -notmatch 'Incomplete experiments: Queue') { throw } }
    $first = @(Get-ChildItem -LiteralPath (Join-Path $runs '01') -Filter '*-started.txt' | ForEach-Object Name | Sort-Object)
    if (($first -join ',') -ne 'ConvLayout-started.txt,QnnReply-started.txt,Queue-started.txt') { throw "Unexpected studies: $first" }

    $queueShouldFail = $false
    Run '02' 'Explore'
    $started = @(Get-ChildItem -LiteralPath (Join-Path $runs '02') -Filter '*-started.txt')
    if ($started.Count -ne 1 -or $started[0].Name -ne 'Queue-started.txt') { throw 'Resume repeated a completed study' }
    Run '03' 'Explore'
    if (Get-ChildItem -LiteralPath (Join-Path $runs '03') -Filter '*-started.txt') { throw 'Completed campaign reran' }
    Run '04' 'Hetero'
    if (!(Test-Path -LiteralPath (Join-Path $runs '04/Hetero-pass.txt'))) { throw 'Explicit historical route failed' }
    Write-Output 'PASS | retired studies, historical LongPair, failure isolation, resume and explicit rerun'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
