[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: OpenCL Target-only vs Q4 DFlash on zh-plain-1')

function Invoke-HandoffClip([string]$Name, [switch]$Draft) {
    $summary.Add("--- $Name ---")
    $probe = Join-Path $LogDirectory "opencl-$Name.txt"
    & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -NativeBuildDirectory $BuildDirectory `
        -InstallDirectory $InstallDirectory -Transcribe -Draft:$Draft -ReportPath $probe | Out-Host
    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $probe)
    $done = $null
    foreach ($line in $lines) {
        if ($line -match '^(Started PID:|No ready event|Exit code:|Startup probe error:|Transcription HTTP|Transcription probe:)') {
            $summary.Add($line.Trim())
        } elseif ($line -match 'offloaded [0-9]+/[0-9]+ layers to GPU') {
            $summary.Add($Matches[0])
        } elseif ($line -match '^data: \{') {
            $eventData = $line.Substring(6) | ConvertFrom-Json
            if ($eventData.type -eq 'transcript.text.done') { $done = $eventData }
        }
    }
    if ($lines -notcontains 'Transcription probe: PASS' -or $lines -notcontains 'Exit code: 0 (0x00000000)') {
        $processLine = $lines | Where-Object { $_ -match '^Started PID: ' } | Select-Object -First 1
        if ($processLine -match '^Started PID: ([0-9]+)$') {
            $processHex = '{0:x}' -f [int]$Matches[1]
            $event = $lines | Select-String -Pattern "^\s*ProcessId\s*:\s*0x0*$processHex\s*$" -Context 0,4 | Select-Object -First 1
            if ($event) { foreach ($line in $event.Context.PostContext) { $summary.Add($line.Trim()) } }
        }
        $diagnostics = @($lines | Where-Object { $_ -match 'GGML_ASSERT|CL_[A-Z_]+|failed to|\bERROR\b' } | Select-Object -Last 3)
        foreach ($line in $diagnostics) { $summary.Add($line.Trim()) }
        throw "OpenCL did not complete the transcription and clean shutdown. See opencl-$Name.txt."
    }
    if (!$done.generation_metadata.token_ids.Count) { throw "Missing token trace. See opencl-$Name.txt." }
    $summary.Add("Generated tokens: $($done.generation_metadata.generated_token_count)")
    return $done
}

$stage = 'local assets'
try {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $InstallDirectory 'verify_manifest.json') | ConvertFrom-Json
    foreach ($relativePath in @('models/target.gguf', 'models/mmproj.gguf', 'models/draft-4.gguf', 'eval/zh-plain-1.wav')) {
        $asset = Join-Path $InstallDirectory $relativePath
        if (!(Test-Path -LiteralPath $asset -PathType Leaf)) { throw "Missing installed Veri 1 asset: $asset" }
        if ((Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash -ne $manifest.files.$relativePath) {
            throw "SHA-256 mismatch: $relativePath"
        }
    }

    $stage = 'native build'
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BackendOnly -BuildDirectory $BuildDirectory
    $summary.Add('Native build: PASS')

    $stage = 'OpenCL Target-only'
    $target = Invoke-HandoffClip 'target-only'
    if ($target.generation_metadata.verify_round_count -ne 0) { throw 'Target-only unexpectedly used speculative verification.' }

    $stage = 'OpenCL Q4 DFlash'
    $draft = Invoke-HandoffClip 'draft-q4' -Draft
    $metadata = $draft.generation_metadata
    $rounds = [int]$metadata.verify_round_count
    $proposed = [int]$metadata.proposed_draft_token_count
    $accepted = [int]$metadata.accepted_draft_token_count
    if ($rounds -le 0 -or $accepted -le 0 -or $proposed -lt $accepted -or $proposed -gt 7 * $rounds) {
        throw "Invalid DFlash counts: $accepted/$proposed accepted in $rounds rounds."
    }
    $average = $accepted / $rounds
    $summary.Add(('DFlash: {0}/{1} accepted in {2} rounds | avg_accept {3:F2} | avg_step {4:F2} | accept_rate {5:P1}' -f
        $accepted, $proposed, $rounds, $average, ($average + 1), ($accepted / $proposed)))
    $times = [ordered]@{ Draft=$metadata.draft_ms; Target=$metadata.target_ms; Context=$metadata.draft_context_ms }
    $total = 0.0
    foreach ($phase in $times.Keys) {
        if ($null -eq $times[$phase] -or $times[$phase] -lt 0) { throw "Missing or invalid timing for $phase." }
        $total += $times[$phase]
    }
    if ($total -le 0) { throw 'DFlash profiling returned zero total time.' }
    foreach ($phase in $times.Keys) {
        $summary.Add(('{0}: {1:F2} ms/round ({2:P1})' -f $phase, ($times[$phase] / $rounds), ($times[$phase] / $total)))
    }

    $stage = 'greedy token comparison'
    if (($target.generation_metadata.token_ids -join ',') -ne ($metadata.token_ids -join ',') -or $target.text -cne $draft.text) {
        throw 'Target-only and Q4 DFlash outputs differ. Token IDs and verify rounds are in the two OpenCL logs.'
    }
    $summary.Add('Greedy token comparison: PASS (identical token IDs and transcript)')
    $summary.Add("Transcript: $($draft.text)")
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
