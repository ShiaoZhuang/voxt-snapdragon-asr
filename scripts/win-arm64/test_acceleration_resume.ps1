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
        if ($expectedArchive) {
            $index = [Array]::IndexOf($args, '--profile-archive')
            if ($file -ne 'measure_htp_conv_layout' -or $index -lt 0 -or $args[$index + 1] -ne $expectedArchive) {
                throw "Expected only ConvLayout with matching archived evidence, got $args"
            }
        }
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

    # Match the 79c8ac8 laptop report. Simulate unchanged native build inputs.
    function git { $global:LASTEXITCODE = 0 }
    $old = Join-Path $runs '01'
    Remove-Item -LiteralPath (Join-Path $old 'ConvLayout-pass.txt')
    $expectedArchive = Join-Path $old 'ConvLayout'
    Set-Content -LiteralPath (Join-Path $root 'sources.lock.json') -Value "{`"geniex_htp`":{`"version`":`"fixture`",`"files`":{`"libggml-htp-v73.so`":`"$hash`"}}}"
    Set-Content -LiteralPath (Join-Path $old 'handoff_report.txt') -Value @(
        'Commit: 79c8ac84411d437266bf0908e76e966668b5d4cb', 'HTP package: official GenieX | v73 SO/CAT match fixture',
        'INCOMPLETE: zh-plain-1: HTP convolution output shapes or multiplicities differ'
    )
    Run '05' 'Explore'
    if (!(Test-Path -LiteralPath (Join-Path $runs '05/ConvLayout-pass.txt'))) { throw 'Archived profile run did not pass' }
    Write-Output 'PASS | retired studies, historical LongPair, failure isolation, resume, explicit rerun and archived profiles'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
