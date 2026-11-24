param([Parameter(Mandatory)][string]$InstallDirectory)
$ErrorActionPreference = 'Stop'
$assets = Get-Content -Raw -LiteralPath (Join-Path $InstallDirectory 'verify_manifest.json') | ConvertFrom-Json
foreach ($relative in @('models/target.gguf', 'models/mmproj.gguf', 'models/draft-4.gguf', 'eval/zh-plain-1.wav')) {
    $path = Join-Path $InstallDirectory $relative
    $expectedHash = $assets.files.$relative
    if (!$expectedHash -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash) {
        throw "SHA-256 mismatch: $relative"
    }
}
