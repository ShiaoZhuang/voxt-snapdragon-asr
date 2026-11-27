[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Study,
    [Parameter(Mandatory)][string]$Product,
    [Parameter(Mandatory)][string]$Ops,
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$studies = [ordered]@{
    Hetero = @('measure_hetero_suite.py', 'hetero-suite-summary.txt', '^long-zh HTP/HTP median')
    QnnReply = @('measure_qnn_reply.ps1', 'qnn-reply-summary.txt', '^QNN reply')
    Queue = @('measure_htp_queue.py', 'htp-queue-summary.txt', '^Queue candidate|^Queue depth|^Queue storage change|^Queue pair')
    ConvLayout = @('measure_htp_conv_layout.py', 'htp-conv-layout-summary.txt', '^Rechecking both archived|^Archive unavailable|packed/view warm medians')
    LongPair = @('measure_htp_long_pair.py', 'htp-long-pair-summary.txt', '^Phase values|^[1-4] .* steady |^Launches .* steady |^Independent long-all')
    Wait = @('measure_htp_wait.py', 'htp-wait-summary.txt', 'wait/poll \| median wall')
    Fusion = @('measure_htp_fusion.py', 'htp-fusion-summary.txt', 'warm median request')
    Dispatch = @('measure_htp_dispatch.py', 'htp-dispatch-summary.txt', '^Warm request median')
    QnnHtpAudio = @('verify_live_qnn.ps1', 'qnn-htp-audio-summary.txt', 'request tok/s|hybrid /')
    HtpSuite = @('measure_htp_suite.py', 'htp-suite-summary.txt', '^long-.+s \|')
}
$auto = $Study -eq 'Explore'
if (!$auto -and !$studies.Contains($Study)) { throw "Unknown experiment: $Study" }
$server = Join-Path $Product 'bin/qwen3_asr_server.exe'
$dsp = (Get-FileHash -LiteralPath (Join-Path $Ops 'libggml-htp-v73.so')).Hash
$longPairRelease = '45810259713f380b5eefe2e133cc07b4b6c45010'
$lockFile = Join-Path $PSScriptRoot '../../sources.lock.json'
$release = (Get-Content -Raw -LiteralPath $lockFile | ConvertFrom-Json).geniex_htp
$official = $release.files.'libggml-htp-v73.so' -eq $dsp

$previous = @(Get-ChildItem -LiteralPath (Split-Path -Parent $LogDirectory) -Directory | Where-Object { $_.FullName -ne $LogDirectory } | Sort-Object Name -Descending)
function Get-Highlights([string]$Path, [string]$Pattern) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $lines -match $Pattern
    $lines -match '^(FAIL|INCOMPLETE)'
}
function Find-HtpArchive([string]$Revision, [string]$Subdirectory) {
    foreach ($run in $previous) {
        $folder = if ($Subdirectory) { Join-Path $run.FullName $Subdirectory } else { $run.FullName }
        $raw = Join-Path $folder 'htp-suite.jsonl'
        $report = Join-Path $run.FullName 'handoff_report.txt'
        $summaryFile = Join-Path $folder 'htp-suite-summary.txt'
        if (!(Test-Path -LiteralPath $raw) -or !(Test-Path -LiteralPath $report) -or !(Test-Path -LiteralPath $summaryFile)) { continue }
        $lines = @(Get-Content -LiteralPath $report -Encoding UTF8)
        if ($lines -contains "Commit: $Revision" -and $lines -contains 'Result: PASS | Stage: verify' -and
            $lines -contains "HTP package: official GenieX | v73 SO/CAT match $($release.version)" -and
            (Get-Content -LiteralPath $summaryFile -Encoding UTF8 -Tail 1) -match '^PASS \|') { return $raw }
    }
}
function Find-ConvProfileArchive {
    # The 79c8ac8 run wrote all four profiled responses and both native traces
    # before the original physical-shape comparison could fail.
    $captureRevision = '79c8ac84411d437266bf0908e76e966668b5d4cb'
    $repo = Join-Path $PSScriptRoot '../..'
    & git -C $repo diff --quiet $captureRevision HEAD -- sources.lock.json patches native scripts/win-arm64/build_native.ps1 scripts/win-arm64/measure_htp_suite.py
    if ($LASTEXITCODE -ne 0) { return }
    foreach ($run in $previous) {
        $report = Join-Path $run.FullName 'handoff_report.txt'
        $started = Join-Path $run.FullName 'ConvLayout-started.txt'
        if (!(Test-Path -LiteralPath $report) -or !(Test-Path -LiteralPath $started)) { continue }
        if ((Get-Content -LiteralPath $started -TotalCount 1) -ne "ConvLayout-v1-$dsp") { continue }
        $lines = @(Get-Content -LiteralPath $report -Encoding UTF8)
        if ($lines -notcontains "Commit: $captureRevision" -or
            $lines -notcontains "HTP package: official GenieX | v73 SO/CAT match $($release.version)" -or
            !($lines -match 'HTP convolution output shapes or multiplicities differ')) { continue }
        $dir = Join-Path $run.FullName 'ConvLayout'
        if (!(Test-Path -LiteralPath $dir -PathType Container)) { $dir = $run.FullName }
        return $dir
    }
}
if ($auto -and $official) {
    $old = Find-HtpArchive '3a82b3fe279d7034e93b55cb2b94fd7889f222b0' ''
    $new = Find-HtpArchive '736e7aff4e2e24d036733aa4eb9ee987d0144b6c' 'HtpSuite'
    if ($old -and $new) {
        $comparePath = Join-Path $LogDirectory 'historical-htp-comparison.txt'
        $comparison = @(& python (Join-Path $PSScriptRoot 'summarize_htp_baseline.py') --path $old --compare $new)
        if ($LASTEXITCODE -eq 0) {
            $comparison | Set-Content -LiteralPath $comparePath -Encoding UTF8
            $Summary.Add('Archived 3a82b3f -> 736e7af | three warm requests per mode, median ms')
            foreach ($line in ($comparison -match '^long-all/')) { $Summary.Add($line) }
        } else { $Summary.Add('Archive comparison unavailable; see workflow.stderr.log.') }
    }
}
# Finished baseline campaigns are available by explicit route only. Explore never
# re-queues them, even if the owner has moved or deleted those measurement logs.
$names = if ($auto) { @('LongPair','QnnReply','Queue','ConvLayout') } else { @($Study) }
$pending = @()
$retry = @()
$studyKeys = @{}
foreach ($name in $names) {
    # Each named study is a measurement protocol. Bump its key to request a fresh
    # cohort after changing inputs or acceptance criteria. Publishing unrelated
    # commits must not invalidate results that were already handed back.
    $key = "$name-v1-$dsp"
    $studyKeys[$name] = $key
    $keys = @($key)
    if ($name -eq 'LongPair') { $keys += "$longPairRelease-$dsp" }
    $seen = $false
    $done = $null
    if ($auto) {
        foreach ($run in $previous) {
            $marker = Join-Path $run.FullName "$name-started.txt"
            if (!(Test-Path -LiteralPath $marker)) { continue }
            $startedKey = Get-Content -LiteralPath $marker -TotalCount 1
            if ($startedKey -notin $keys) { continue }
            $seen = $true
            $pass = Join-Path $run.FullName "$name-pass.txt"
            if ((Test-Path -LiteralPath $pass) -and (Get-Content -LiteralPath $pass -TotalCount 1) -eq $startedKey) {
                $done = $run
                break
            }
        }
    }
    if ($done) {
        $Summary.Add("$name | previously passed | $($done.Name)")
        $file = $studies[$name][1]
        $prior = Join-Path (Join-Path $done.FullName $name) $file
        if (!(Test-Path -LiteralPath $prior)) { $prior = Join-Path $done.FullName $file }
        foreach ($line in (Get-Highlights $prior $studies[$name][2])) { $Summary.Add($line) }
    } elseif ($seen) { $retry += $name } else { $pending += $name }
}
$failed = @()
foreach ($name in @($pending + $retry)) {
    $key = $studyKeys[$name]
    $runner, $file, $headline = $studies[$name]
    $dir = $LogDirectory
    if ($auto) { $dir = (New-Item -ItemType Directory -Path (Join-Path $LogDirectory $name) -Force).FullName }
    Set-Content -LiteralPath (Join-Path $LogDirectory "$name-started.txt") -Value $key
    Write-Host "[voxt] Starting $name | logs $dir"
    $result = Join-Path $dir $file
    $notes = [System.Collections.Generic.List[string]]::new()
    try {
        if ($name -eq 'QnnHtpAudio') {
            try {
                & (Join-Path $PSScriptRoot $runner) -InstallDirectory $InstallDirectory -BuildDirectory $Product -LogDirectory $dir -Summary $notes -HtpAudioOpsDirectory $Ops
            } finally { $notes | Set-Content -LiteralPath $result -Encoding UTF8 }
        } elseif ($name -eq 'QnnReply') {
            & (Join-Path $PSScriptRoot $runner) -PreviousRuns $previous -LogDirectory $dir -Summary $notes
            if (!(Select-String -LiteralPath $result -Pattern '^PASS \|' -Quiet)) { throw "Missing PASS in $file" }
        } else {
            $options = @()
            if ($auto -and $official -and $name -eq 'ConvLayout') {
                $archive = Find-ConvProfileArchive
                if ($archive) { $options = @('--profile-archive', $archive) }
            }
            & python -u (Join-Path $PSScriptRoot $runner) --server $server --assets $InstallDirectory --ops $Ops @options --logs $dir | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
            if (!(Select-String -LiteralPath $result -Pattern '^PASS \|' -Quiet)) { throw "Missing PASS in $file" }
        }
        $Summary.Add("$name | PASS")
        Set-Content -LiteralPath (Join-Path $LogDirectory "$name-pass.txt") -Value $key
    } catch {
        $failed += $name
        $Summary.Add("$name | INCOMPLETE | $($_.Exception.Message) | $dir")
        Write-Host "[voxt] $name failed: $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $result) {
            $lines = if ($auto) { Get-Highlights $result $headline } else { Get-Content -LiteralPath $result -Encoding UTF8 }
            foreach ($line in $lines) { $Summary.Add($line) }
        }
        $Summary | Set-Content -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt') -Encoding UTF8
    }
}
if ($failed.Count) { throw "Incomplete experiments: $($failed -join ', ')." }
