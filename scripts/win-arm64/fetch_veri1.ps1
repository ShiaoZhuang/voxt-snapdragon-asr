[CmdletBinding()]
param(
    [string]$Destination,
    [ValidateSet('GitHub', 'HuggingFace')]
    [string]$TargetSource = 'GitHub',
    [ValidateSet('GitHub', 'HuggingFace')]
    [string]$ProjectorSource = 'GitHub'
)

$ErrorActionPreference = 'Stop'
if (!$Destination) { $Destination = Join-Path $PSScriptRoot '../../dist/voxt-snapdragon-veri-1' }
$destinationPath = (New-Item -ItemType Directory -Path $Destination -Force).FullName
$downloads = (New-Item -ItemType Directory -Path (Join-Path $destinationPath '.downloads') -Force).FullName
$baseUrl = 'https://github.com/ShiaoZhuang/voxt-snapdragon-asr/releases/download/veri-1'

function Test-SHA256($Path, $Expected) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
           ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Expected)
}

function Get-Asset($Name, $Expected, $Url = "$baseUrl/$Name") {
    $file = Join-Path $downloads $Name
    if (Test-SHA256 $file $Expected) { return $file }
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    $partial = "$file.part"
    Write-Host "Downloading $Name"
    $curlLog = [IO.Path]::GetTempFileName()
    $curlOptions = @('--fail', '--location', '--retry', '3', '--connect-timeout', '20',
        '--continue-at', '-', '--silent', '--show-error', '--stderr', $curlLog,
        '--output', $partial, $Url)
    # Inspect curl's status explicitly, including on PowerShell 7.
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        & curl.exe @curlOptions
        $exitCode = $LASTEXITCODE
        $details = [IO.File]::ReadAllText($curlLog).Trim()
        if ($exitCode -in 35, 60 -and $details -match '\bschannel\b' -and
            $details -match 'CRYPT_E_(NO_REVOCATION_CHECK|REVOCATION_OFFLINE)|0x8009201[23]') {
            Write-Host 'Windows could not reach the certificate revocation service. Retrying with Schannel best-effort revocation.'
            & curl.exe --ssl-revoke-best-effort @curlOptions
            $exitCode = $LASTEXITCODE
            $details = [IO.File]::ReadAllText($curlLog).Trim()
        }
        if ($exitCode -ne 0) { throw "Download failed for $Name (curl $exitCode). $details Run this script again to resume." }
    } finally {
        Remove-Item -LiteralPath $curlLog
    }
    if (!(Test-SHA256 $partial $Expected)) {
        Remove-Item -LiteralPath $partial
        throw "SHA-256 mismatch: $Name. Run this script again to re-download."
    }
    Move-Item -LiteralPath $partial -Destination $file
    return $file
}

$releaseAssets = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'veri1-release-sha256.json') | ConvertFrom-Json
$manifestPath = Join-Path $destinationPath 'verify_manifest.json'
if (!(Test-Path -LiteralPath $manifestPath)) {
    $archive = Get-Asset 'veri1-runtime.zip' $releaseAssets.'veri1-runtime.zip'
    Expand-Archive -LiteralPath $archive -DestinationPath $destinationPath -Force
    Remove-Item -LiteralPath $archive
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.commit -ne '8da314d34c147e9fd37117e61e77a191f6e34c64') { throw 'Unexpected Veri 1 build manifest' }
$models = (New-Item -ItemType Directory -Path (Join-Path $destinationPath 'models') -Force).FullName
$lockPath = Join-Path $PSScriptRoot '../../sources.lock.json'
$upstream = (Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json).gguf_probe
$upstreamUrl = "https://huggingface.co/$($upstream.repo)/resolve/$($upstream.revision)"
$projectorName = 'mmproj.gguf'
$projectorUrl = "$baseUrl/$projectorName"
$projectorHash = $releaseAssets.'mmproj.gguf'
$projectorWeights = 'unquantized F16/F32 audio projector'
if ($ProjectorSource -eq 'HuggingFace') {
    $projectorName = 'mmproj-Qwen3-ASR-1.7B-bf16.gguf'
    $projectorUrl = "$upstreamUrl/${projectorName}?download=true"
    $projectorHash = $upstream.files.$projectorName
    $projectorWeights = 'upstream BF16/F16/F32 audio projector (alternate Veri 1 configuration)'
}
$projector = Join-Path $models 'mmproj.gguf'
if (!(Test-SHA256 $projector $projectorHash)) {
    $asset = Get-Asset $projectorName $projectorHash $projectorUrl
    Move-Item -LiteralPath $asset -Destination $projector -Force
}
if ($manifest.files.'models/mmproj.gguf' -ne $projectorHash) {
    $manifest.files.'models/mmproj.gguf' = $projectorHash
    $manifest.weights = "Q8_0 target, $projectorWeights, Q4_0 draft (Q6_K output)"
    $manifestPart = "$manifestPath.part"
    [IO.File]::WriteAllText($manifestPart, ($manifest | ConvertTo-Json -Depth 10))
    Move-Item -LiteralPath $manifestPart -Destination $manifestPath -Force
}
$draft = Join-Path $models 'draft-4.gguf'
if (!(Test-SHA256 $draft $manifest.files.'models/draft-4.gguf')) {
    $asset = Get-Asset 'draft-4.gguf' $releaseAssets.'draft-4.gguf'
    Move-Item -LiteralPath $asset -Destination $draft -Force
}
$target = Join-Path $models 'target.gguf'
$targetHash = $manifest.files.'models/target.gguf'
if (!(Test-SHA256 $target $targetHash)) {
    if ($TargetSource -eq 'HuggingFace') {
        $name = 'Qwen3-ASR-1.7B-Q8_0.gguf'
        if ($upstream.files.$name -ne $targetHash) { throw 'Hugging Face Target hash differs from the Veri 1 manifest' }
        $url = "$upstreamUrl/${name}?download=true"
        $asset = Get-Asset $name $targetHash $url
        Move-Item -LiteralPath $asset -Destination $target -Force
    } else {
        $assembly = "$target.part"
        $parts = @('target.gguf.part1', 'target.gguf.part2', 'target.gguf.part3')
        $completeSizes = @(0L, 805306368L, 1610612736L, 2165034944L)
        $size = if (Test-Path -LiteralPath $assembly) { (Get-Item -LiteralPath $assembly).Length } else { 0 }
        if ($size -notin $completeSizes) {
            $size = [long]$size
            if ($size -gt 2165034944) { $size = 0 }
            $size = [long]([math]::Floor($size / 805306368.0) * 805306368)
            $truncate = [IO.File]::Open($assembly, 'OpenOrCreate', 'Write')
            try { $truncate.SetLength($size) } finally { $truncate.Dispose() }
        }
        $startPart = if ($size -eq 2165034944) { 3 } else { [int]($size / 805306368L) }
        for ($i = $startPart; $i -lt $parts.Count; $i++) {
            $name = $parts[$i]
            $asset = Get-Asset $name $releaseAssets.$name
            $partStream = [IO.File]::OpenRead($asset)
            try {
                $output = [IO.File]::Open($assembly, 'Append', 'Write')
                try { $partStream.CopyTo($output) } finally { $output.Dispose() }
            } finally { $partStream.Dispose() }
            Remove-Item -LiteralPath $asset
        }
        if (!(Test-SHA256 $assembly $targetHash)) {
            Remove-Item -LiteralPath $assembly
            throw 'SHA-256 mismatch for assembled target.gguf. Run this script again to re-download.'
        }
        Move-Item -LiteralPath $assembly -Destination $target -Force
    }
}

Write-Output "Veri 1 is ready: $destinationPath"
Write-Output "Run: & '$(Join-Path $destinationPath 'scripts/win-arm64/run_verify.ps1')' -Quick"
