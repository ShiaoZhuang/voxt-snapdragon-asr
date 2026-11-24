[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $PSScriptRoot '../../dist/voxt-snapdragon-veri-1'),
    [string]$ReportPath = (Join-Path ([IO.Path]::GetTempPath()) ('voxt-opencl-startup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')),
    [string]$NativeBuildDirectory,
    [string]$CaptureDirectory,
    [switch]$CaptureAllLayers,
    [switch]$Transcribe,
    [string]$MetricsPath,
    [string]$LiveVerifyDirectory,
    [switch]$Draft,
    [ValidateSet('opencl', 'hexagon')][string]$Backend = 'opencl'
)

$ErrorActionPreference = 'Stop'
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
if ($CaptureAllLayers -and !$CaptureDirectory) { throw '-CaptureAllLayers requires -CaptureDirectory.' }
if ($CaptureDirectory) {
    if (!$Draft -or !$Transcribe) { throw 'Capture requires -Draft and -Transcribe.' }
    $CaptureDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CaptureDirectory)
    if (Test-Path -LiteralPath $CaptureDirectory) { throw "Capture directory already exists: $CaptureDirectory" }
}
$serverName = 'qwen3_asr_server.exe'
$since = (Get-Date).AddDays(-2)

function Invoke-ClipProbe([int]$Port, [string]$Audio) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $form = [Net.Http.MultipartFormDataContent]::new()
    try {
        $wav = [Net.Http.StreamContent]::new([IO.File]::OpenRead($Audio))
        $wav.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('audio/wav')
        $form.Add($wav, 'file', [IO.Path]::GetFileName($Audio))
        $form.Add([Net.Http.StringContent]::new('zh'), 'language')
        $form.Add([Net.Http.StringContent]::new('true'), 'stream')
        $form.Add([Net.Http.StringContent]::new('true'), 'include_generation_metadata')
        $form.Add([Net.Http.StringContent]::new('256'), 'max_new_tokens')
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $response = $client.PostAsync("http://127.0.0.1:$Port/v1/audio/transcriptions", $form).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $timer.Stop()
            "Transcription HTTP $([int]$response.StatusCode) | Wall ms: $($timer.ElapsedMilliseconds)"
            $body.TrimEnd()
            $events = @($body -split '\r?\n' | Where-Object { $_ -match '^data: ' } | ForEach-Object { $_.Substring(6) })
            $done = $events | Where-Object { $_ -ne '[DONE]' } | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object type -eq 'transcript.text.done' | Select-Object -Last 1
            if (!$response.IsSuccessStatusCode -or !($events -contains '[DONE]') -or !$done.text -or !$done.generation_metadata) {
                throw 'Expected a nonempty transcript and a complete SSE response with generation metadata.'
            }
            $meta = $done.generation_metadata
            if ($MetricsPath) {
                [ordered]@{text=$done.text; ids=@($meta.token_ids); tokens=$meta.generated_token_count;
                    wall_ms=$timer.Elapsed.TotalMilliseconds; finish=$meta.finish_reason;
                    rounds=$meta.verify_round_count; live_rounds=$meta.live_verify_round_count; proposed=$meta.proposed_draft_token_count} |
                    ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $MetricsPath
            }
            if ($CaptureDirectory) {
                $capture = Get-Content -Raw -LiteralPath (Join-Path $CaptureDirectory 'capture.json') | ConvertFrom-Json
                $round = $done.generation_metadata.first_verify_rounds | Where-Object { @($_.proposals).Count -eq 7 } |
                    Select-Object -First 1
                $tokens = @($round.anchor) + @($round.proposals)
                if (!$round -or ($capture.tokens -join ',') -ne ($tokens -join ',') -or @($capture.positions).Count -ne 8) {
                    throw 'Capture tokens did not match the first full DFlash verification round.'
                }
                "Capture: PASS | layer $($capture.layer) | positions $($capture.positions[0])-$($capture.positions[7])"
                if ($CaptureAllLayers) {
                    "Capture layers: $($capture.layer_count) | logit columns: $($capture.logit_columns)"
                }
            }
            'Transcription probe: PASS'
        } finally { $response.Dispose() }
    } finally {
        $form.Dispose()
        $client.Dispose()
    }
}

& {
    if ($Backend -eq 'hexagon') { "=== Voxt GGML Hexagon Target startup | draft=$Draft ===" }
    elseif ($Draft) { '=== Voxt OpenCL Q4 DFlash startup ===' }
    else { '=== Voxt OpenCL Target startup ===' }
    'Time: ' + (Get-Date -Format o)
    "Windows: $([Environment]::OSVersion.VersionString) | PowerShell: $($PSVersionTable.PSVersion)"

    $child = $null
    try {
        $root = (Resolve-Path -LiteralPath $InstallDirectory).Path
        $server = Join-Path $root "bin/$serverName"
        if ($NativeBuildDirectory) {
            $nativeRoot = (Resolve-Path -LiteralPath $NativeBuildDirectory).Path
            $nativeBuild = Get-Content -Raw -LiteralPath (Join-Path $nativeRoot 'verify_native_manifest.json') | ConvertFrom-Json
            "Native Windows build: $($nativeBuild.commit) | compiler: $($nativeBuild.toolchain)"
            foreach ($name in @($serverName, 'OpenCL.dll')) {
                $hash = (Get-FileHash -LiteralPath (Join-Path $nativeRoot "bin/$name") -Algorithm SHA256).Hash
                if ($hash -ne $nativeBuild.files.$name) { throw "Native build SHA-256 mismatch: $name" }
                "Native SHA-256 $name $hash"
            }
            $server = Join-Path $nativeRoot "bin/$serverName"
        }
        $models = Join-Path $root 'models'
        foreach ($path in @($server, (Join-Path $models 'target.gguf'), (Join-Path $models 'mmproj.gguf'))) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $path" }
        }
        $audio = Join-Path $root 'eval/zh-plain-1.wav'
        if ($Transcribe -and !(Test-Path -LiteralPath $audio -PathType Leaf)) { throw "Missing $audio" }
        if ($Draft -and !(Test-Path -LiteralPath (Join-Path $models 'draft-4.gguf') -PathType Leaf)) { throw 'Missing Q4 Draft model.' }

        $start = [Diagnostics.ProcessStartInfo]::new($server)
        $start.Arguments = '--supervised --host 127.0.0.1 --port 0 --backend ' + $Backend + ' --model-directory "' + $models + '"'
        if ($Draft) { $start.Arguments += ' --draft-model-path "' + $models + '" --draft-bits 4' }
        $start.WorkingDirectory = $root
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $start.EnvironmentVariables['LLAMA_ARG_LOG_VERBOSITY'] = '5'
        if ($Backend -eq 'hexagon') {
            $start.EnvironmentVariables['GGML_HEXAGON_DEVICES'] = 'HTP0'
            $start.EnvironmentVariables['GGML_HEXAGON_PROFILE'] = '1'
            if (!$env:GGML_HEXAGON_LIBHTP_DIR -and $nativeBuild.htp_ops) {
                $start.EnvironmentVariables['GGML_HEXAGON_LIBHTP_DIR'] = $nativeBuild.htp_ops
            }
        }
        if ($Transcribe) {
            $start.EnvironmentVariables['VOXT_ASR_TRACE'] = '1'
            $start.EnvironmentVariables['OMNI_DFLASH_PROFILE'] = '1'
        }
        if ($LiveVerifyDirectory) {
            $start.EnvironmentVariables['VOXT_QNN_VERIFY_DIR'] = $LiveVerifyDirectory
            $start.EnvironmentVariables['LLAMA_DFLASH_DEV'] = '0'
        }
        if ($CaptureDirectory) { $start.EnvironmentVariables['VOXT_VERIFY_CAPTURE_DIR'] = $CaptureDirectory }
        if ($CaptureAllLayers) { $start.EnvironmentVariables['VOXT_VERIFY_CAPTURE_ALL_LAYERS'] = '1' }
        $child = [Diagnostics.Process]::Start($start)
        "Started PID: $($child.Id)"
        $stderr = $child.StandardError.ReadToEndAsync()
        $firstLine = $child.StandardOutput.ReadLineAsync()
        if ($firstLine.Wait(90000)) {
            $line = $firstLine.GetAwaiter().GetResult()
            if ($line) { "First stdout line: $line" }
            if ($Transcribe -and $line) {
                try {
                    $ready = $line | ConvertFrom-Json
                    $port = [int]$ready.port
                    if ($ready.event -ne 'ready' -or $ready.host -ne '127.0.0.1' -or $port -lt 1 -or $port -gt 65535) {
                        throw 'Invalid supervised ready event.'
                    }
                    Invoke-ClipProbe $port $audio
                } catch { "Transcription probe: FAIL. $_" }
            }
        } else {
            'No ready event after 90 seconds.'
        }

        # Closing stdin also asks the supervised server to stop if it reaches ready later.
        $child.StandardInput.Close()
        if (!$child.WaitForExit(5000)) {
            'Stopped the probe after waiting five seconds for shutdown.'
            $child.Kill()
            $child.WaitForExit()
        }
        'Exit code: {0} (0x{0:X8})' -f $child.ExitCode
        '=== Backend stderr ==='
        $stderr.GetAwaiter().GetResult().TrimEnd()
    } catch {
        "Startup probe error: $_"
    } finally {
        if ($child) {
            if (!$child.HasExited) {
                $child.Kill()
                $child.WaitForExit()
            }
            $child.Dispose()
        }
    }

    '=== Windows Application Error 1000 (past two days) ==='
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since
        } -ErrorAction Stop | ForEach-Object {
            $event = $_
            $fields = @{}
            $xml = [xml]($event.ToXml())
            foreach ($field in $xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']")) {
                $fields[$field.GetAttribute('Name')] = $field.InnerText
            }
            if ($fields['AppName'] -ieq $serverName) {
                [pscustomobject]@{
                    Time = $event.TimeCreated
                    ProcessId = $fields['ProcessId']
                    Module = $fields['ModuleName']
                    ModuleVersion = $fields['ModuleVersion']
                    ExceptionCode = $fields['ExceptionCode']
                    FaultingOffset = $fields['FaultingOffset']
                }
            }
        } | Select-Object -First 10
        if ($events) { $events | Format-List | Out-String -Width 200 }
        else { "No matching event for $serverName." }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound,*') { "No matching event for $serverName." }
        else { "Event log unavailable: $_" }
    }
} | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Output "Report saved to: $ReportPath"
