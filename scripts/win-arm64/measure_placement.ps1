[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$Product,
    [Parameter(Mandatory)][string]$Ops,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$cases = @(
    @{ Name='GPU-only'; Target='opencl' },
    @{ Name='HTP-only'; Target='hexagon' },
    @{ Name='GPU+GPU'; Target='opencl'; Draft='opencl' },
    @{ Name='HTP+GPU'; Target='hexagon'; Draft='opencl' },
    @{ Name='GPU+HTP'; Target='opencl'; Draft='hexagon' },
    @{ Name='HTP+HTP'; Target='hexagon'; Draft='hexagon' }
)
$probe = Join-Path $PSScriptRoot 'probe_opencl_startup.ps1'
$reference = $null
$failed = @{}
$results = @()
$csv = Join-Path $LogDirectory 'placement.csv'
for ($rep = 0; $rep -lt 3; $rep++) {
    for ($index = 0; $index -lt $cases.Count; $index++) {
        $case = $cases[($index + 2 * $rep) % $cases.Count]
        $name = $case.Name
        if ($failed.ContainsKey($name)) { continue }
        Write-Host "[voxt] Placement $name ($($rep+1)/3): fresh server, zh-plain-1."
        $path = Join-Path $LogDirectory "placement-$name-$rep.txt"
        $opts = @{Backend=$case.Target; NativeBuildDirectory=$Product; InstallDirectory=$InstallDirectory;
            HexagonOpsDirectory=$Ops; ReportPath=$path; MetricsPath="$path.metrics.json"; MeasurePlacement=$true; Transcribe=$true}
        if ($case.Draft) { $opts.Draft=$true; $opts.DraftBackend=$case.Draft }
        try {
            & $probe @opts | Out-Host
            $lines = @(Get-Content -Encoding UTF8 -LiteralPath $path)
            if (!($lines -match '^Transcription probe: PASS$') -or !($lines -match '^Exit code: 0 \(0x00000000\)$')) {
                throw (($lines -match 'failed to open session|Startup probe error|Transcription probe: FAIL|No ready event|Exit code:' | Select-Object -First 3) -join ' | ')
            }
            $m = Get-Content -Raw -Encoding UTF8 -LiteralPath "$path.metrics.json" | ConvertFrom-Json
            if (!$m.ids.Count -or $m.tokens -le 0 -or $m.wall_ms -le 0 -or $m.finish -ne 'stop' -or
                ($case.Draft -and ($m.rounds -lt 1 -or $m.proposed -lt 1))) { throw 'Incomplete token or speculation trace.' }
            if (!$reference -and $name -eq 'GPU-only') { $reference = $m }
            if ($reference -and ($m.text -cne $reference.text -or ($m.ids -join ',') -ne ($reference.ids -join ','))) {
                throw 'Token sequence/transcript differs from GPU-only.'
            }
            $devices = @(foreach ($line in $lines) {
                if ($line -match 'llama_prepare_model_devices: using device (GPUOpenCL|HTP0) ') { $Matches[1] }
            })
            $deviceName = @{opencl='GPUOpenCL'; hexagon='HTP0'}
            if (!$devices.Count -or $devices[0] -ne $deviceName[$case.Target] -or
                ($case.Draft -and ($devices.Count -lt 2 -or $devices[-1] -ne $deviceName[$case.Draft]))) {
                throw "Unexpected Target/Draft device selection: $($devices -join ', ')."
            }
            $buffers = @($lines -match '(model|KV|compute) buffer size\s*=')
            $needsHtp = $case.Target -eq 'hexagon' -or $case.Draft -eq 'hexagon'
            $events = 0
            $copyBytes = 0L
            $copyUs = 0L
            $inRequest = $false
            foreach ($line in $lines) {
                if ($line -match 'voxt: GGML Hexagon audio request started') { $inRequest = $true }
                if (!$inRequest) { continue }
                if ($line -match 'ggml-hex: HTP0 profile-op (?!OPBATCH).*\|usec [0-9]+ cycles [1-9][0-9]*') { $events++ }
                if ($line -match 'voxt: sync GPU/HTP copy (\d+) bytes (\d+) us') {
                    $copyBytes += [long]$Matches[1]
                    $copyUs += [long]$Matches[2]
                }
            }
            if ($needsHtp -and !$events) { throw 'No timed HTP0 op during transcription.' }
            if ($m.peak_private_bytes -le 0 -or $m.peak_working_bytes -le 0) { throw 'Missing request memory samples.' }
            $row = [pscustomobject]@{name=$name; trial=$rep+1; tokens=$m.tokens; ms=$m.wall_ms;
                tps=$m.tokens*1000/$m.wall_ms; private_MiB=$m.peak_private_bytes/1MB; ws_MiB=$m.peak_working_bytes/1MB;
                gpu_reference_matched=[bool]$reference; backend_allocations=($buffers -join ' | '); devices=($devices -join ',');
                sync_copy_bytes=$copyBytes; sync_copy_us=$copyUs; dsp_events=$events; draft_ms=$m.draft_ms;
                verify_ms=$m.verify_ms; context_ms=$m.context_ms; rounds=$m.rounds; accepted=$m.accepted; proposed=$m.proposed}
            $row | Export-Csv -NoTypeInformation -Encoding UTF8 -Append -LiteralPath $csv
            $results += $row
        } catch {
            $failed[$name]=$true
            $Summary.Add("${name}: FAIL | $($_.Exception.Message) | $path")
        }
    }
}
if (!$reference) { $Summary.Add('GPU-only reference unavailable. Other timings are diagnostic; cross-device token equality unverified.') }
$Summary.Add('Target+Draft | median of 3 request TPS | max sampled process private / working set MiB | observed synchronous GPU/HTP copy (median-TPS trial)')
foreach ($case in $cases) {
    $runs = @($results | Where-Object name -eq $case.Name | Sort-Object tps)
    if ($runs.Count -ne 3) { continue }
    $mid = $runs[1]
    $priv = ($runs | Measure-Object private_MiB -Maximum).Maximum
    $ws = ($runs | Measure-Object ws_MiB -Maximum).Maximum
    $Summary.Add(('{0} | {1:F2} tok/s | {2:F0}/{3:F0} MiB | {4:F2} MiB/{5:F2} ms | {6} HTP events' -f
        $mid.name,$mid.tps,$priv,$ws,($mid.sync_copy_bytes/1MB),($mid.sync_copy_us/1000),$mid.dsp_events))
}
if ($failed.Count) { throw "Placement failures: $($failed.Keys -join ', '). Completed measurements are in placement.csv." }
