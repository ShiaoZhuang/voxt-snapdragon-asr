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
$revision = git -C $PSScriptRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40}$') { throw 'Cannot identify experiment revision.' }
$dsp = (Get-FileHash -LiteralPath (Join-Path $Ops 'libggml-htp-v73.so')).Hash
# The release immediately following 736e7af only extends orchestration and adds
# LongPair. All pre-existing experiments use the same code and binary inputs.
$oldRelease = '736e7aff4e2e24d036733aa4eb9ee987d0144b6c'
$parentRevision = git -C $PSScriptRoot rev-parse "HEAD^"
$acceptPrevious = $parentRevision -eq $oldRelease
$key = "$revision-$dsp"
$lockFile = Join-Path $PSScriptRoot '../../sources.lock.json'
$release = (Get-Content -Raw -LiteralPath $lockFile | ConvertFrom-Json).geniex_htp
$official = $release.files.'libggml-htp-v73.so' -eq $dsp

$previous = @(Get-ChildItem -LiteralPath (Split-Path -Parent $LogDirectory) -Directory | Where-Object { $_.FullName -ne $LogDirectory } | Sort-Object Name -Descending)
function Get-Highlights([string]$Name, [string]$Path, [string]$Pattern) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    if ($Name -eq 'Hetero') {
        foreach ($clip in 'zh-plain-1','long-zh') {
            $rates = @(foreach ($line in $lines) {
                if ($line -match "^(\S+/\S+) $clip \S+ \| \S+ ms (\S+) tok/s") {
                    "$($Matches[1]) $($Matches[2])"
                }
            })
            if ($rates.Count) { "$clip request tok/s (Target/Draft) | $($rates -join ' | ')" }
        }
    } else { $lines -match $Pattern }
    $lines -match '^(FAIL|INCOMPLETE)'
}
$pending = @()
$retry = @()
foreach ($name in $studies.Keys) {
    if (!$auto -and $name -ne $Study) { continue }
    $keys = @($key)
    if ($acceptPrevious -and $name -ne 'LongPair') { $keys += "$oldRelease-$dsp" }
    $seen = $false
    $done = $null
    if ($auto) {
        foreach ($run in $previous) {
            $marker = Join-Path $run.FullName "$name-started.txt"
            if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -TotalCount 1) -in $keys) {
                $seen = $true
                $pass = Join-Path $run.FullName "$name-pass.txt"
                if ((Test-Path -LiteralPath $pass) -and (Get-Content -LiteralPath $pass -TotalCount 1) -in $keys) { $done = $run; break }
            }
            # Standalone baselines predate study markers. Keep them explicitly historical.
            if (($revision -eq $oldRelease -or $acceptPrevious) -and $official -and $name -in 'Hetero','HtpSuite') {
                $report = Join-Path $run.FullName 'handoff_report.txt'
                $baseline = Join-Path $run.FullName $studies[$name][1]
                if (!(Test-Path -LiteralPath $baseline) -or !(Test-Path -LiteralPath $report)) { continue }
                $sha = if ($name -eq 'Hetero') { '3227849ed7b434286358cbf80f99e6694b3a690e' } else { '3a82b3fe279d7034e93b55cb2b94fd7889f222b0' }
                $reportLines = @(Get-Content -LiteralPath $report -Encoding UTF8)
                $baselineLines = @(Get-Content -LiteralPath $baseline -Encoding UTF8)
                if ($reportLines -notcontains "Commit: $sha" -or $reportLines -notcontains 'Result: PASS | Stage: verify' -or
                    $reportLines -notcontains "HTP package: official GenieX | v73 SO/CAT match $($release.version)" -or
                    $baselineLines[-1] -notmatch '^PASS \|' -or ($baselineLines -match '^(FAIL|INCOMPLETE)')) { continue }
                if ($name -eq 'HtpSuite') {
                    $raw = Join-Path $run.FullName 'htp-suite.jsonl'
                    if (!(Test-Path -LiteralPath $raw)) { continue }
                    $analysis = @(& python (Join-Path $PSScriptRoot 'summarize_htp_baseline.py') --path $raw)
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[voxt] Historical HtpSuite raw records did not validate in $($run.Name)."
                        continue
                    }
                    $analysis | Set-Content -LiteralPath (Join-Path $LogDirectory 'historical-htp-baseline.txt') -Encoding UTF8
                    foreach ($line in $analysis) { $Summary.Add($line) }
                }
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
        foreach ($line in (Get-Highlights $name $prior $studies[$name][2])) { $Summary.Add($line) }
        continue
    }
    if ($seen) { $retry += $name } else { $pending += $name }
}
$failed = @()
foreach ($name in @($pending + $retry)) {
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
        } else {
            & python -u (Join-Path $PSScriptRoot $runner) --server $server --assets $InstallDirectory --ops $Ops --logs $dir | Out-Host
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
            $lines = if ($auto) { Get-Highlights $name $result $headline } else { Get-Content -LiteralPath $result -Encoding UTF8 }
            foreach ($line in $lines) { $Summary.Add($line) }
        }
        $Summary | Set-Content -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt') -Encoding UTF8
    }
}
if ($failed.Count) { throw "Incomplete experiments: $($failed -join ', ')." }
