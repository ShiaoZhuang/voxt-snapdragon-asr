[CmdletBinding()]
param([switch]$Quick, [string]$OutputDirectory, [string]$InstallDirectory, [switch]$OpenCLFix, [string]$NativeBuildDirectory)

$ErrorActionPreference = 'Stop'
$scriptRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if (!$InstallDirectory) {
    $InstallDirectory = $scriptRoot
    if (!(Test-Path -LiteralPath (Join-Path $scriptRoot 'verify_manifest.json') -PathType Leaf)) {
        $InstallDirectory = Join-Path $scriptRoot 'dist/voxt-snapdragon-veri-1'
    }
}
$root = (Resolve-Path -LiteralPath $InstallDirectory).Path
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $root ("verify-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output directory already exists: $OutputDirectory" }
$output = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$report = [System.Collections.Generic.List[string]]::new()
$matrix = [ordered]@{}
$runtimeUpdate = $null
$nativeBuild = $null
$passed = $true
$previousBackend = $env:VOXT_ASR_BACKEND
$previousTrace = $env:VOXT_ASR_TRACE
$report.Add('# Voxt Snapdragon verification')
$report.Add('')
$report.Add('Date: ' + (Get-Date -Format o))
$report.Add('Mode: ' + $(if ($Quick) { 'smoke' } else { '31 clips' }))
$report.Add('Windows: ' + [Environment]::OSVersion.VersionString)

function Invoke-Captured($Exe, [string[]]$Arguments, $Prefix, [int]$TimeoutSeconds) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.WorkingDirectory = $root
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $child = [System.Diagnostics.Process]::Start($start)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $finished = $child.WaitForExit(1000 * $TimeoutSeconds)
        if (!$finished) { $child.Kill(); $child.WaitForExit() }
        [IO.File]::WriteAllText("$Prefix.jsonl", $stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText("$Prefix.log", $stderr.GetAwaiter().GetResult())
        if (!$finished) { throw 'Timed out' }
        if ($child.ExitCode -ne 0) { throw "Exit code $($child.ExitCode); see $Prefix.log" }
    } finally { $child.Dispose() }
}

function Get-RunTotals($Rows) {
    $total = [ordered]@{ units=0; edits=0; rounds=0; accepted=0; proposed=0; draft_ms=0.0; target_ms=0.0; context_ms=0.0; elapsed_ms=0.0 }
    foreach ($row in $Rows) {
        $total.units += $row.score.N
        $total.edits += $row.score.Sub + $row.score.Del + $row.score.Ins
        $total.elapsed_ms += $row.elapsed_ms
        foreach ($event in $row.final_events) {
            $m = $event.generation_metadata
            if ($null -eq $m -or $null -eq $m.verify_round_count) { throw 'Voxt generation metadata is missing' }
            $total.rounds += $m.verify_round_count
            $total.accepted += $m.accepted_draft_token_count
            $total.proposed += $m.proposed_draft_token_count
            $total.draft_ms += $m.draft_ms
            $total.target_ms += $m.target_ms
            $total.context_ms += $m.draft_context_ms
        }
    }
    return $total
}

try {
    if ($OpenCLFix -and $NativeBuildDirectory) { throw 'Specify either -OpenCLFix or -NativeBuildDirectory.' }
    # An emulated PowerShell process can report its own architecture.
    $osArch = $env:PROCESSOR_ARCHITEW6432
    if (!$osArch) { $osArch = $env:PROCESSOR_ARCHITECTURE }
    if (!$osArch) { throw 'Unable to determine Windows architecture from PROCESSOR_ARCHITECTURE or PROCESSOR_ARCHITEW6432.' }
    $report.Add("OS architecture: $osArch")
    if ($osArch -ne 'ARM64') { throw "Expected Windows ARM64, found $osArch" }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'verify_manifest.json') | ConvertFrom-Json
    $report.Add("Build source: $($manifest.commit)")
    $report.Add("llama.cpp source: $($manifest.llama_cpp)")
    $report.Add("Toolchain: $($manifest.toolchain)")
    $report.Add("Build flags: $($manifest.build)")
    $report.Add("Weight types: $($manifest.weights)")
    foreach ($property in $manifest.files.PSObject.Properties) {
        if ($NativeBuildDirectory -and $property.Name -notmatch '^(models|eval)/') { continue }
        $path = Join-Path $root $property.Name
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual.ToLowerInvariant() -ne $property.Value) { throw "SHA-256 mismatch: $($property.Name)" }
    }
    $report.Add($(if ($NativeBuildDirectory) { 'Installed model and evaluation hashes: passed' } else { 'Manifest hashes: passed' }))
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $report.Add("Machine: $($computer.Manufacturer) $($computer.Model), $([math]::Round($computer.TotalPhysicalMemory / 1GB, 1)) GiB RAM")
        foreach ($gpu in Get-CimInstance Win32_VideoController) {
            $report.Add("Display driver: $($gpu.Name) $($gpu.DriverVersion)")
        }
    } catch { $report.Add("CIM inventory: $_") }

    $server = Join-Path $root 'bin/qwen3_asr_server.exe'
    $runner = Join-Path $root 'bin/final-benchmark.exe'
    if ($NativeBuildDirectory) {
        $localRoot = (Resolve-Path -LiteralPath $NativeBuildDirectory).Path
        $nativeBuild = Get-Content -Raw -LiteralPath (Join-Path $localRoot 'verify_native_manifest.json') | ConvertFrom-Json
        $report.Add("Native Windows build: $($nativeBuild.commit)")
        $report.Add("Native llama.cpp source: $($nativeBuild.llama_cpp)")
        $report.Add("Native Voxt runner source: $($nativeBuild.voxt)")
        $report.Add("Native OpenCL loader source: $($nativeBuild.opencl_loader)")
        $report.Add("Native toolchain: $($nativeBuild.toolchain)")
        $report.Add("Native build flags: $($nativeBuild.build)")
        $localBin = Join-Path $localRoot 'bin'
        foreach ($name in @('qwen3_asr_server.exe', 'OpenCL.dll', 'final-benchmark.exe')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $localBin $name) -Algorithm SHA256).Hash
            if ($hash -ne $nativeBuild.files.$name) { throw "Native build SHA-256 mismatch: $name" }
            $report.Add("Native SHA-256 $name $($nativeBuild.files.$name)")
        }
        $server = Join-Path $localBin 'qwen3_asr_server.exe'
        $runner = Join-Path $localBin 'final-benchmark.exe'
    }
    if ($OpenCLFix) {
        $fix = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'veri1-opencl-fix.json') | ConvertFrom-Json
        $server = Join-Path $root "bin/$($fix.server)"
        if (!(Test-Path -LiteralPath $server -PathType Leaf)) { throw 'Run fetch_veri1.ps1 -OpenCLFixOnly first.' }
        $serverHash = (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash
        if ($serverHash -ne $fix.server_sha256) { throw "SHA-256 mismatch: $($fix.server)" }
        $runtimeUpdate = [ordered]@{ source_commit=$fix.source_commit; server_sha256=$fix.server_sha256 }
        $report.Add("OpenCL fix runtime: $($fix.source_commit) ($($fix.server_sha256))")
    }
    $models = Join-Path $root 'models'
    $eval = Join-Path $root 'eval'
    $devices = Join-Path $output 'devices'
    try { Invoke-Captured $server @('--list-devices') $devices 30 }
    catch { $report.Add("Device query failed: $_") }
    foreach ($file in @("$devices.jsonl", "$devices.log")) {
        if (Test-Path -LiteralPath $file) {
            $report.Add('')
            $report.Add('~~~text')
            $report.Add((Get-Content -Raw -Encoding UTF8 -LiteralPath $file))
            $report.Add('~~~')
        }
    }

    $env:VOXT_ASR_TRACE = '1'
    foreach ($backend in @('cpu', 'opencl')) {
        $env:VOXT_ASR_BACKEND = $backend
        foreach ($mode in @('target-only', 'draft-q4')) {
            $name = "$backend-$mode"
            $prefix = Join-Path $output $name
            $report.Add('')
            $report.Add("## $name")
            $arguments = @('-binary', $server, '-target', $models, '-eval', $eval)
            if ($mode -eq 'draft-q4') { $arguments += @('-draft', $models, '-draft-bits', '4') }
            if ($Quick) { $arguments += @('-only', 'zh-plain-1') }
            try {
                Invoke-Captured $runner $arguments $prefix 1800
                $rows = @(Get-Content -Encoding UTF8 -LiteralPath "$prefix.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
                $main = @($rows | Where-Object variant -eq 'main zh')
                $expected = if ($Quick) { 1 } else { 31 }
                if ($main.Count -ne $expected -or @($main.clip | Select-Object -Unique).Count -ne $expected) {
                    throw "Expected $expected distinct main clips, found $($main.Count)"
                }
                $total = Get-RunTotals $main
                if ($total.units -le 0) { throw 'No reference units' }
                $errorRate = $total.edits / $total.units
                $status = $errorRate -le .034
                $biased = @($main | Where-Object set -eq 'dict')
                $termCount = 0
                foreach ($row in $biased) { $termCount += @($row.terms_found | Where-Object { $_ }).Count }
                if (!$Quick) { $status = $status -and ($termCount -ge 7) }
                $report.Add(('Error rate: {0:P2} ({1}/{2}), dictionary hits: {3}' -f $errorRate, $total.edits, $total.units, $termCount))
                if ($mode -eq 'draft-q4') {
                    $clean = Get-RunTotals @($main | Where-Object { $_.clip -in @('zh-plain-1','en-3','en-4') })
                    $average = if ($total.rounds) { $total.accepted / $total.rounds } else { 0 }
                    $rate = if ($total.proposed) { $total.accepted / $total.proposed } else { 0 }
                    $cleanAverage = if ($clean.rounds) { $clean.accepted / $clean.rounds } else { 0 }
                    $report.Add(('avg_accept {0:F2}, avg_step {1:F2}, accept_rate {2:P1}, clean avg_accept {3:F2}' -f $average, (1+$average), $rate, $cleanAverage))
                    $timed = $total.draft_ms + $total.target_ms + $total.context_ms
                    if ($timed -gt 0 -and $total.rounds -gt 0) {
                        foreach ($phase in @('draft_ms', 'target_ms', 'context_ms')) {
                            $report.Add(('  {0}: {1:P1}, {2:F2} ms/round' -f $phase, ($total[$phase] / $timed), ($total[$phase] / $total.rounds)))
                        }
                    }
                    if ($Quick) { $status = $status -and ($total.accepted -gt 0) }
                    else { $status = $status -and ($average -ge 3.0) -and ($cleanAverage -ge 5.3) }
                    if ($matrix.Contains("$backend-target-only") -and $matrix["$backend-target-only"].rows) {
                        $plain = @{}
                        foreach ($row in $matrix["$backend-target-only"].rows) { $plain["$($row.clip)/$($row.variant)"] = $row }
                        $tokenDiffs = @()
                        foreach ($row in $main) {
                            $control = $plain["$($row.clip)/main zh"]
                            $draftIds = @($row.final_events | ForEach-Object { $_.generation_metadata.token_ids })
                            $plainIds = @($control.final_events | ForEach-Object { $_.generation_metadata.token_ids })
                            if (!$draftIds.Count -or ($draftIds -join ',') -ne ($plainIds -join ',')) {
                                $tokenDiffs += $row.clip
                            }
                        }
                        $report.Add("Greedy token mismatches: $($tokenDiffs.Count) $($tokenDiffs -join ', ')")
                        $status = $status -and ($tokenDiffs.Count -eq 0)
                    } else { $status = $false }
                }
                foreach ($group in @($main | Group-Object set)) {
                    $groupTotal = Get-RunTotals $group.Group
                    $report.Add(('{0}: {1:P2} ({2}/{3})' -f $group.Name, ($groupTotal.edits / $groupTotal.units), $groupTotal.edits, $groupTotal.units))
                }
                if ($mode -eq 'draft-q4') {
                    $sanity = $main | Where-Object clip -eq 'zh-plain-1' | Select-Object -First 1
                    if ($sanity) {
                        $metadata = $sanity.final_events[0].generation_metadata
                        $report.Add('First verification rounds on zh-plain-1:')
                        $report.Add('~~~json')
                        $report.Add((ConvertTo-Json -InputObject @($metadata.first_verify_rounds) -Depth 8))
                        $report.Add('~~~')
                    }
                }
                $report.Add('Gate: ' + $(if ($status) { 'PASS' } else { 'FAIL' }))
                $report.Add('')
                $report.Add('| Clip | Edits/units | Accepted/proposed | Rounds | Wall ms |')
                $report.Add('|---|---:|---:|---:|---:|')
                foreach ($row in $main) {
                    $one = Get-RunTotals @($row)
                    $report.Add(('| {0} | {1}/{2} | {3}/{4} | {5} | {6:F0} |' -f $row.clip, $one.edits, $one.units, $one.accepted, $one.proposed, $one.rounds, $one.elapsed_ms))
                }
                $matrix[$name] = [ordered]@{passed=$status; aggregate=$total; rows=$rows }
                $passed = $passed -and $status
            } catch {
                $passed = $false
                $matrix[$name] = [ordered]@{passed=$false; error=$_.ToString()}
                $report.Add("FAIL: $_")
                if (Test-Path -LiteralPath "$prefix.log") {
                    $report.Add('')
                    $report.Add('~~~text')
                    $report.Add(((Get-Content -Encoding UTF8 -Tail 25 -LiteralPath "$prefix.log") -join "`n"))
                    $report.Add('~~~')
                }
            }
        }
    }
} catch {
    $passed = $false
    $report.Add('')
    $report.Add("Preflight failed: $_")
} finally {
    $env:VOXT_ASR_BACKEND = $previousBackend
    $env:VOXT_ASR_TRACE = $previousTrace
    $report.Add('')
    $report.Add('Overall: ' + $(if ($passed) { 'PASS' } else { 'FAIL' }))
    $report | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'verify_report.md')
    $stats = [ordered]@{ passed=$passed; quick=[bool]$Quick; runs=$matrix }
    if ($runtimeUpdate) { $stats.runtime_update = $runtimeUpdate }
    if ($nativeBuild) { $stats.native_build = $nativeBuild }
    $stats | ConvertTo-Json -Depth 20 |
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'verify_stats.json')
    Write-Output "Results: $output"
}
if (!$passed) { exit 1 }
