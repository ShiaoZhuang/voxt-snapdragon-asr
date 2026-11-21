[CmdletBinding()]
param([string]$Destination)

$ErrorActionPreference = 'Stop'
if (!$Destination) { $Destination = Join-Path $PSScriptRoot '../../dist/voxt-snapdragon-veri-1' }
$destinationPath = (New-Item -ItemType Directory -Path $Destination -Force).FullName
$downloads = (New-Item -ItemType Directory -Path (Join-Path $destinationPath '.downloads') -Force).FullName
$baseUrl = 'https://github.com/ShiaoZhuang/voxt-snapdragon-asr/releases/download/veri-1'

function Test-SHA256($Path, $Expected) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
           ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Expected)
}

function Get-Asset($Name, $Expected) {
    $file = Join-Path $downloads $Name
    if (Test-SHA256 $file $Expected) { return $file }
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    $partial = "$file.part"
    Write-Host "Downloading $Name"
    & curl.exe --fail --location --retry 3 --connect-timeout 20 --continue-at - --output $partial "$baseUrl/$Name"
    if ($LASTEXITCODE -ne 0) { throw "Download failed for $Name. Run this script again to resume." }
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
foreach ($name in @('draft-4.gguf', 'mmproj.gguf')) {
    $path = Join-Path $models $name
    $expected = $manifest.files."models/$name"
    if (!(Test-SHA256 $path $expected)) {
        $asset = Get-Asset $name $releaseAssets.$name
        Move-Item -LiteralPath $asset -Destination $path -Force
    }
}
$target = Join-Path $models 'target.gguf'
$targetHash = $manifest.files.'models/target.gguf'
if (!(Test-SHA256 $target $targetHash)) {
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

Write-Output "Veri 1 is ready: $destinationPath"
Write-Output "Run: & '$(Join-Path $destinationPath 'scripts/win-arm64/run_verify.ps1')' -Quick"
