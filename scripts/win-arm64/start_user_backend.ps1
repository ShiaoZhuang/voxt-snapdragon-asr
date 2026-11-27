[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [string]$BuildDirectory,
    [string]$LogDirectory,
    [switch]$ResolveOnly,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$workspace = $source
if ($source -match '[/\\]\.local[/\\]win-arm64-handoff[/\\]source$') {
    $workspace = (Resolve-Path -LiteralPath (Join-Path $source '../../..')).Path
}
if (!$InstallDirectory) { $InstallDirectory = Join-Path $workspace 'dist/voxt-snapdragon-veri-1' }
if (!$BuildDirectory) { $BuildDirectory = Join-Path $workspace 'build/win-arm64-native' }
$assets = (Resolve-Path -LiteralPath $InstallDirectory).Path
$product = Join-Path $BuildDirectory 'hexagon'
$manifestPath = Join-Path $product 'verify_native_manifest.json'
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "The verified native HTP build is missing at $product. Use -BuildDirectory to select the existing win-arm64-native build."
}
$native = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
$lock = Get-Content -LiteralPath (Join-Path $source 'sources.lock.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$frozen = '0d43c7c1b1cf42257e5eca9bd03b5036fd183b50'
if ($native.llama_cpp -ne $lock.llama_cpp.commit -or $native.build -notmatch '(?:^| )-DGGML_HEXAGON=ON(?: |$)' -or
    [string]$native.commit -notmatch '^[0-9a-f]{40}$') {
    throw "Expected a native Hexagon build of llama.cpp $($lock.llama_cpp.commit) in $product."
}
if ($native.commit -ne $frozen) {
    # Desktop-only releases may rebuild these exact same native sources.
    & git -C $source diff --quiet $frozen $native.commit -- native ':(exclude)native/windows-helper' patches/llama-voxt.patch scripts/win-arm64/build_native.ps1
    if ($LASTEXITCODE -ne 0) { throw "Native build $($native.commit) does not match the frozen backend $frozen." }
}
foreach ($name in 'qwen3_asr_server.exe','OpenCL.dll') {
    $file = Join-Path $product "bin/$name"
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $native.files.$name) {
        throw "Native build SHA-256 mismatch: $file"
    }
}
& (Join-Path $PSScriptRoot 'verify_replay_assets.ps1') -InstallDirectory $assets
$assetManifest = Get-Content -LiteralPath (Join-Path $assets 'verify_manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$weights = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'veri1-release-sha256.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$pinnedAssets = @{
    'models/target.gguf' = $lock.gguf_probe.files.'Qwen3-ASR-1.7B-Q8_0.gguf'
    'models/mmproj.gguf' = $weights.'mmproj.gguf'
    'models/draft-4.gguf' = $weights.'draft-4.gguf'
    'eval/zh-plain-1.wav' = $lock.benchmark.'Voxt/testdata/eval/zh-plain-1.wav'
}
foreach ($path in $pinnedAssets.Keys) {
    if (!$pinnedAssets[$path] -or $assetManifest.files.$path -ne $pinnedAssets[$path]) {
        throw "Asset differs from the frozen release: $path"
    }
}
$ops = & (Join-Path $PSScriptRoot 'get_ggml_htp_bundle.ps1') -CacheDirectory (Join-Path $BuildDirectory 'sdk/geniex-htp') -Release $lock.geniex_htp
$server = (Resolve-Path -LiteralPath (Join-Path $product 'bin/qwen3_asr_server.exe')).Path
$models = Join-Path $assets 'models'
$launch = [pscustomobject]@{
    Server = $server
    Models = $models
    Arguments = [string[]]@('--supervised','--host','127.0.0.1','--port','0',
        '--model-directory',$models,'--draft-model-path',$models,'--draft-bits','4',
        '--backend','hexagon','--draft-backend','hexagon','--audio-backend','hexagon')
    Environment = @{
        VOXTNEW_OMNI_RUNTIME = $server
        VOXT_SNAPDRAGON_MODELS = $models
        VOXTNEW_DRAFT_BITS = '4'
        VOXT_ASR_BACKEND = 'hexagon'
        VOXT_DRAFT_BACKEND = 'hexagon'
        VOXT_AUDIO_BACKEND = 'hexagon'
        GGML_HEXAGON_LIBHTP_DIR = $ops
        GGML_HEXAGON_DEVICES = 'HTP0'
        GGML_HEXAGON_OPBATCH = '2048'
        GGML_HEXAGON_OPQUEUE = '8'
        GGML_HEXAGON_OPFUSION = '1'
        GGML_HEXAGON_OPPOLL = '0'
        GGML_HEXAGON_VERBOSE = '0'
        GGML_HEXAGON_PROFILE = '0'
        LLAMA_ARG_BATCH = '2048'
        LLAMA_ARG_UBATCH = '512'
        LLAMA_ARG_LOG_VERBOSITY = '3'
        VOXT_AUDIO_CONV_LAYOUT = '0'
        VOXT_AUDIO_POS_BROADCAST = '0'
        VOXT_ASR_TRACE = '0'
        OMNI_DFLASH_PROFILE = '0'
    }
    RemoveEnvironment = [string[]]@('VOXT_QNN_VERIFY_DIR','VOXT_QNN_VERIFY_PORT','VOXT_QNN_VERIFY_TOKEN',
        'VOXT_VERIFY_CAPTURE_DIR','VOXT_VERIFY_CAPTURE_ALL_LAYERS','VOXT_TRACE_INTERDEVICE_COPY','LLAMA_DFLASH_DEV',
        'GGML_HEXAGON_OPFILTER','GGML_HEXAGON_OPTRACE')
    TestAudio = Join-Path $assets 'eval/zh-plain-1.wav'
}
if ($ResolveOnly) { return $launch }

if (!$LogDirectory) {
    $run = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $PID
    $LogDirectory = Join-Path $workspace ".local/win-arm64-user/$run"
}
$logs = (New-Item -ItemType Directory -Force -Path $LogDirectory).FullName
$report = Join-Path $logs 'user-backend.txt'
$metrics = Join-Path $logs 'user-backend.metrics.json'
Write-Host "[voxt] Verifying the frozen Q8 Target, Q4 DFlash and audio encoder on HTP0. Log: $report"
& (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $assets -Backend hexagon -Transcribe -Draft `
    -ReportPath $report -MetricsPath $metrics -UserBackendProfile $launch | Out-Host
$lines = @(Get-Content -Encoding UTF8 -LiteralPath $report)
if (!($lines -contains 'Transcription probe: PASS') -or !($lines -contains 'Exit code: 0 (0x00000000)')) {
    $detail = @($lines -match 'Startup probe error|Transcription probe: FAIL|No ready event|Exit code:|failed to open session' | Select-Object -First 3)
    throw "Frozen backend Final request or shutdown failed. $($detail -join ' | ') See $report"
}
$devices = @(foreach ($line in $lines) {
    if ($line -match 'llama_prepare_model_devices: using device (\S+) ') { $Matches[1] }
})
$audioDevices = @(foreach ($line in $lines) {
    if ($line -match 'mtmd_backends:\s+using (\S+) backend') { $Matches[1] }
})
if (!$devices.Count -or !$audioDevices.Count) {
    throw "Missing loader evidence after successful transcription (model device records: $($devices.Count)/2, audio: $($audioDevices.Count)/1). See $report"
}
if (($devices -join ',') -cne 'HTP0,HTP0' -or ($audioDevices -join ',') -cne 'HTP0') {
    throw "Unexpected Target/Draft or audio placement. Models: $devices. Audio: $audioDevices. See $report"
}
$m = Get-Content -LiteralPath $metrics -Encoding UTF8 -Raw | ConvertFrom-Json
$clips = Get-Content -LiteralPath (Join-Path $assets 'eval/clips.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$reference = ($clips.clips | Where-Object id -eq 'zh-plain-1').text
if (!$reference -or ($m.text -replace '[\p{P}\s]', '') -cne ($reference -replace '[\p{P}\s]', '') -or
    $m.finish -ne 'stop' -or $m.tokens -le 0 -or $m.rounds -le 0 -or $m.proposed -le 0 -or
    $m.accepted -lt 0 -or $m.accepted -gt $m.proposed -or $m.live_rounds -ne 0) {
    throw "Unexpected zh-plain-1 transcript or DFlash generation metadata. See $metrics"
}
Write-Host "[voxt] PASS | $($m.text) | $($m.tokens) tokens | $($m.rounds) DFlash rounds | $($m.wall_ms) ms | audio/Target/Draft HTP0"
if ($PassThru) { return $launch }
