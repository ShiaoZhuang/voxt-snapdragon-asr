[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)]$Release
)

$ErrorActionPreference = 'Stop'
$cache = (New-Item -ItemType Directory -Path $CacheDirectory -Force).FullName
$sdk = Join-Path $cache $Release.version

function Test-HexagonSdk([string]$Path) {
    $metadata = Join-Path $Path 'hexagon_sdk.json'
    if (!(Test-Path -LiteralPath $metadata -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $Path 'build/cmake/hexagon_fun.cmake') -PathType Leaf)) {
        return $false
    }
    try {
        $config = Get-Content -Raw -LiteralPath $metadata | ConvertFrom-Json
        $tools = @($config.root.tools.info)[0].path
        return ($tools -and (Test-Path -LiteralPath (Join-Path $Path "$tools/Tools/bin/hexagon-clang.exe") -PathType Leaf))
    } catch {
        return $false
    }
}

if (Test-HexagonSdk $sdk) {
    Write-Host "Using cached Hexagon SDK $($Release.version)."
    return $sdk
}

$curl = (Get-Command curl.exe -CommandType Application).Source
$tar = (Get-Command tar.exe -CommandType Application).Source
$stage = (New-Item -ItemType Directory -Path (Join-Path $cache ('.download-' + [guid]::NewGuid()))).FullName
try {
    $archive = Join-Path $stage 'hexagon-sdk.tar.xz'
    $unpacked = (New-Item -ItemType Directory -Path (Join-Path $stage 'unpacked')).FullName

    Write-Host "Downloading Hexagon SDK $($Release.version) for Windows ARM64 (about 900 MB)."
    $downloadArgs = @('--proto', '=https', '--proto-redir', '=https', '--fail', '--location', '--silent', '--show-error',
        '--retry', '2', '--retry-max-time', '900', '--connect-timeout', '20', '--max-time', '900', '--output', $archive, $Release.url)
    & $curl @downloadArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Hexagon SDK download failed (curl exit $LASTEXITCODE)." }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Release.sha256) {
        throw 'Hexagon SDK download SHA-256 mismatch.'
    }

    Write-Host 'Extracting the verified Hexagon SDK.'
    & $tar -xf $archive -C $unpacked | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Hexagon SDK extraction failed (tar exit $LASTEXITCODE)." }
    $source = Join-Path $unpacked $Release.version
    if (!(Test-HexagonSdk $source)) { throw 'Hexagon SDK archive is missing its CMake files or Windows compiler.' }

    if (Test-Path -LiteralPath $sdk) {
        if (Test-HexagonSdk $sdk) { return $sdk }
        $backup = "$sdk.incomplete-$([guid]::NewGuid())"
        Move-Item -LiteralPath $sdk -Destination $backup
        Write-Host "Moved the incomplete SDK cache to $backup."
    }
    [IO.Directory]::Move($source, $sdk)
    Write-Host "Installed Hexagon SDK in $sdk."
    return $sdk
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
