[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('Test: native OpenCL build and one zh-plain-1 transcription')
$stage = 'local assets'
try {
    foreach ($relativePath in @('models/target.gguf', 'models/mmproj.gguf', 'eval/zh-plain-1.wav')) {
        if (!(Test-Path -LiteralPath (Join-Path $InstallDirectory $relativePath) -PathType Leaf)) {
            throw "Missing installed Veri 1 asset: $relativePath. Installation directory: $InstallDirectory"
        }
    }

    $stage = 'native build'
    & (Join-Path $PSScriptRoot 'build_native.ps1') -BackendOnly -BuildDirectory $BuildDirectory
    $summary.Add('Native build: PASS')

    $stage = 'OpenCL clip'
    $probe = Join-Path $LogDirectory 'opencl_probe.txt'
    & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -NativeBuildDirectory $BuildDirectory `
        -InstallDirectory $InstallDirectory -Transcribe -ReportPath $probe
    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $probe)
    foreach ($line in $lines) {
        if ($line -match '^(Started PID:|First stdout line:|No ready event|Exit code:|Startup probe error:|Transcription HTTP|Transcription probe:)') {
            $summary.Add($line.Trim())
        } elseif ($line -match '^data: \{') {
            $eventData = $line.Substring(6) | ConvertFrom-Json
            if ($eventData.type -eq 'transcript.text.done') {
                $summary.Add("Transcript: $($eventData.text)")
                $summary.Add("Generated tokens: $($eventData.generation_metadata.generated_token_count)")
            }
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
        throw 'OpenCL did not complete the transcription and clean shutdown. See opencl_probe.txt.'
    }
} catch {
    $summary.Add("Failed step: $stage")
    $summary.Add("Error: $($_.Exception.Message)")
    throw
} finally {
    $summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
