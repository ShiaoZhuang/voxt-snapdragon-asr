[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)
$ErrorActionPreference = 'Stop'
$Summary.Add('GGML Hexagon | zh-plain-1 | target on HTP0, audio and optional Q4 draft on Adreno')
try {
    $active = & (Join-Path $PSScriptRoot 'get_active_testsigning.ps1')
    $Summary.Add("Active kernel test signing: $active")
} catch { $Summary.Add("Active kernel test signing: unknown | $($_.Exception.Message)") }
& (Join-Path $PSScriptRoot 'verify_replay_assets.ps1') -InstallDirectory $InstallDirectory
$package = $env:VOXT_HTP_PACKAGE
if ($package -and $package -notin 'native','official') { throw "Unknown VOXT_HTP_PACKAGE: $package (use official or native)." }
$official = $package -ne 'native'
Write-Host '[voxt] Checking the Hexagon SDK and building GGML Hexagon.'
& (Join-Path $PSScriptRoot 'build_native.ps1') -BuildDirectory $BuildDirectory -BackendOnly -Hexagon -InstallHexagonSdk -ExternalHtpOps:$official | Out-Host
$product = Join-Path $BuildDirectory 'hexagon'
$Summary.Add('GGML Hexagon native Windows build: PASS')
$manifest = Get-Content -LiteralPath (Join-Path $product 'verify_native_manifest.json') -Raw | ConvertFrom-Json
function Get-CatalogSigner([string]$Path) {
    Add-Type -AssemblyName System.Security
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([IO.File]::ReadAllBytes($Path))
    if ($cms.SignerInfos.Count -ne 1) { throw 'Expected one embedded catalog signer.' }
    return $cms.SignerInfos[0].Certificate
}

$trialSignerId = $null
$previousRuns = @(Get-ChildItem -LiteralPath (Split-Path -Parent $LogDirectory) -Directory |
    Where-Object { $_.FullName -ne $LogDirectory } | Sort-Object Name -Descending)
if ($official) {
    $release = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../sources.lock.json') | ConvertFrom-Json).geniex_htp
    Write-Host '[voxt] Resolving the Microsoft-signed v73 library from the GenieX installation or pinned SDK package.'
    $ops = & (Join-Path $PSScriptRoot 'get_ggml_htp_bundle.ps1') -CacheDirectory (Join-Path $BuildDirectory 'sdk/geniex-htp') -Release $release
    $Summary.Add("HTP package: official GenieX | v73 SO/CAT match $($release.version)")
} else {
    if ($manifest.htp_build_error) { throw "llama.cpp DSP build failed | $($manifest.htp_build_error)" }
    if (!$manifest.htp_ops -or !$manifest.htp_ops_sha256) { throw 'The native build manifest has no v73 DSP library.' }
    $Summary.Add("llama.cpp DSP build: PASS | v73 package: $($manifest.htp_ops)")

    $ops = $manifest.htp_ops
    if ($env:GGML_HEXAGON_LIBHTP_DIR) { $ops = $env:GGML_HEXAGON_LIBHTP_DIR }
    $ops = (Resolve-Path -LiteralPath $ops).Path
    $library = Join-Path $ops 'libggml-htp-v73.so'
    if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $manifest.htp_ops_sha256) {
        throw 'The signed directory must contain the v73 DSP library produced by this llama.cpp build.'
    }
    if (!(Test-Path -LiteralPath (Join-Path $ops 'libggml-htp.cat')) -and
        !$env:VOXT_HTP_SIGNING_THUMBPRINT -and !$env:GGML_HEXAGON_LIBHTP_DIR) {
        # Past trials retain their public catalog after their temporary private key is removed.
        foreach ($run in $previousRuns) {
            $trial = Join-Path $run.FullName 'htp-v73-self-signed'
            $oldCat = Join-Path $trial 'libggml-htp.cat'
            if (!(Test-Path -LiteralPath $oldCat -PathType Leaf)) { continue }
            $oldReport = Join-Path $run.FullName 'workflow_summary.txt'
            if (!(Test-Path -LiteralPath $oldReport)) { continue }
            try { $oldSigner = Get-CatalogSigner $oldCat } catch { continue }
            if (!$oldSigner -or $oldSigner.NotAfter -le (Get-Date)) { continue }
            if (!(Select-String -LiteralPath $oldReport -Pattern "^HTP signing mode: temporary self-signed \| $($oldSigner.Thumbprint)$" -Quiet)) { continue }
            $oldLib = Join-Path $trial 'libggml-htp-v73.so'
            $oldInf = Join-Path $trial 'libggml-htp.inf'
            if (!(Test-Path -LiteralPath $oldLib) -or !(Test-Path -LiteralPath $oldInf)) { continue }
            if ((Get-FileHash -LiteralPath $oldLib).Hash -eq $manifest.htp_ops_sha256 -and
                (Get-FileHash -LiteralPath $oldInf).Hash -eq (Get-FileHash -LiteralPath (Join-Path $ops 'libggml-htp.inf')).Hash) {
                $trialSignerId = $oldSigner.Thumbprint
                $ops = $trial
                break
            }
        }
    }
    $ops = & (Join-Path $PSScriptRoot 'sign_htp_catalog.ps1') -PackageDirectory $ops `
        -TrialDirectory (Join-Path $LogDirectory 'htp-v73-self-signed') `
        -ToolCacheDirectory (Join-Path $BuildDirectory 'sdk/windows-signing-tools') -Summary $Summary
}
$Summary.Add("HTP library directory: $ops")
$catPath = Join-Path $ops 'libggml-htp.cat'
$catHash = (Get-FileHash -LiteralPath $catPath).Hash
$serverHash = (Get-FileHash -LiteralPath (Join-Path $product 'bin/qwen3_asr_server.exe')).Hash
$trust = 'unknown'
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $catPath
    $trust = [string]$sig.Status
    $cert = Get-CatalogSigner $catPath
    $Summary.Add("Windows catalog trust: $trust | SHA256 $catHash")
    if ($cert) {
        $id = $cert.Thumbprint
        $Summary.Add("Signer: $id | expires $($cert.NotAfter.ToString('yyyy-MM-dd HH:mm'))")
        if ($id -eq $trialSignerId -or $Summary.Contains("HTP signing mode: temporary self-signed | $id")) {
            $cerPath = Join-Path $LogDirectory 'htp-signer.cer'
            [IO.File]::WriteAllBytes($cerPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            $Summary.Add("Public test certificate: $cerPath")
            $Summary.Add("Elevated setup from repo root: .\.local\win-arm64-handoff\source\scripts\win-arm64\enable_htp_test_signing.ps1 -SignerThumbprint $id")
            foreach ($store in 'Root','TrustedPublisher') {
                $present = Test-Path -LiteralPath "Cert:\LocalMachine\$store\$id" -ErrorAction Stop
                $Summary.Add("LocalMachine/$store has signer: $present")
            }
        }
    }
} catch { $Summary.Add("Signer inspection unavailable | $($_.Exception.Message)") }
try {
    $settings = & bcdedit.exe /enum '{current}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'BCD read unavailable to this user' }
    $setting = @($settings -match '^\s*testsigning\s+' | Select-Object -First 1)
    $Summary.Add("BCD current testsigning: $(if ($setting.Count) { $setting[0].Trim() } else { 'not listed' })")
} catch { $Summary.Add("BCD current testsigning: unknown | $($_.Exception.Message)") }
$comparison = [ordered]@{library=(Get-FileHash -LiteralPath (Join-Path $ops 'libggml-htp-v73.so')).Hash; catalog=$catHash; server=$serverHash; trust=$trust; target='incomplete'}
foreach ($run in $previousRuns) {
    $record = Join-Path $run.FullName 'htp-target-check.json'
    if (!(Test-Path -LiteralPath $record -PathType Leaf)) { continue }
    try { $prior = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json } catch { continue }
    if ($prior.library -eq $comparison.library -and $prior.catalog -eq $catHash -and $prior.server -eq $serverHash) {
        $Summary.Add("Previous same server/SO/CAT ($($run.Name)): trust $($prior.trust) | HTP0 $($prior.target)")
        break
    }
}

$gpuMetricsPath = Join-Path $LogDirectory 'live-calibration.txt.metrics.json'
$gpuReference = if (Test-Path -LiteralPath $gpuMetricsPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $gpuMetricsPath | ConvertFrom-Json }
$target = $null
$failed = @()
foreach ($name in @('hexagon-target', 'hexagon-draft')) {
    Write-Host "[voxt] Running $name."
    $path = Join-Path $LogDirectory "$name.txt"
    $draft = $name -like '*-draft'
    $sessionOpenFailed = $false
    try {
        & (Join-Path $PSScriptRoot 'probe_opencl_startup.ps1') -InstallDirectory $InstallDirectory -NativeBuildDirectory $product `
            -ReportPath $path -MetricsPath "$path.metrics.json" -Backend hexagon -Transcribe -Draft:$draft -HexagonOpsDirectory $ops | Out-Host
        $lines = Get-Content -Encoding UTF8 -LiteralPath $path
        $session = @($lines -match 'ggml-hex: HTP0 new session :') | Select-Object -Last 1
        if ($session) { $Summary.Add("${name} HTP0 session: OPEN | $session") }
        if (!($lines -match '^Transcription probe: PASS$') -or !($lines -match '^Exit code: 0 \(0x00000000\)$')) {
            $sessionOpenFailed = [bool]($lines -match 'HTP0 failed to open session')
            $last = @($lines -match 'Startup probe error|Transcription probe: FAIL|No ready event|failed|error:|Exit code:' |
                Select-Object -First 4)
            throw "Transcription incomplete. $($last -join ' | ')"
        }
        $m = Get-Content -Raw -Encoding UTF8 -LiteralPath "$path.metrics.json" | ConvertFrom-Json
        if (!$m.ids.Count -or $m.tokens -le 0 -or $m.wall_ms -le 0 -or $m.finish -ne 'stop') {
            throw 'Missing generated token trace, request timing, or normal end of generation.'
        }
        $events = 0
        $inRequest = $false
        foreach ($line in $lines) {
            if ($line -match 'voxt: GGML Hexagon audio request started') { $inRequest = $true }
            if ($inRequest -and $line -match 'ggml-hex: HTP0 profile-op (?!OPBATCH).*\|usec [0-9]+ cycles [1-9][0-9]*') {
                $events++
            }
        }
        $rate = $m.tokens * 1000 / $m.wall_ms
        $Summary.Add(('{0} | {1} tokens / {2:F0} ms = {3:F2} request tok/s | DSP profile events {4}' -f
            $name, $m.tokens, $m.wall_ms, $rate, $events))
        if (!$events) { throw 'No timed HTP0 operation in GGML profiler.' }
        if ($draft -and ($m.rounds -le 0 -or $m.proposed -le 0)) { throw 'Missing speculative verification rounds.' }
        if ($gpuReference -and ($m.text -cne $gpuReference.text -or ($m.ids -join ',') -ne ($gpuReference.ids -join ','))) {
            throw 'Generated text/token sequence differs from the GPU calibration transcription.'
        }
        if (!$draft) { $target = $m; $comparison.target = "PASS ($events DSP events)" }
        elseif (!$target -or $m.text -cne $target.text -or ($m.ids -join ',') -ne ($target.ids -join ',')) {
            throw 'HTP Target-only reference missing or generated text/token sequence differs. Inspect the metrics JSON files.'
        }
        $Summary.Add("${name}: PASS | $($m.text)")
    } catch {
        $failed += $name
        $Summary.Add("${name}: FAIL | $($_.Exception.Message)")
        if (!$draft -and $sessionOpenFailed) {
            $comparison.target = 'session open failed'
            $Summary.Add('hexagon-draft: skipped because the same HTP0 library failed to open for Target-only.')
            break
        }
    } finally {
        if (!$draft) {
            $comparison | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'htp-target-check.json')
            $Summary.Add("Current HTP0 Target-only: $($comparison.target) | catalog trust $trust")
        }
    }
}
if ($failed.Count) { throw "Incomplete steps: $($failed -join ', '). See the details above." }
