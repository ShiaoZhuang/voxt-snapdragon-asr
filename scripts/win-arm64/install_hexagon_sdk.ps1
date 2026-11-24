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

$tar = (Get-Command tar.exe -CommandType Application).Source
$archiveName = ([uri]$Release.url).Segments[-1]
$localArchive = Join-Path $cache $archiveName
$archive = $localArchive
if (!(Test-Path -LiteralPath $archive -PathType Leaf) -and $env:USERPROFILE) {
    $downloads = Join-Path $env:USERPROFILE "Downloads/$archiveName"
    if (Test-Path -LiteralPath $downloads -PathType Leaf) { $archive = $downloads }
}
$stage = (New-Item -ItemType Directory -Path (Join-Path $cache ('.download-' + [guid]::NewGuid()))).FullName
try {
    $unpacked = (New-Item -ItemType Directory -Path (Join-Path $stage 'unpacked')).FullName

    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        Write-Host "Using local Hexagon SDK archive at $archive."
    } else {
        $archive = Join-Path $stage $archiveName
        Write-Host "Downloading Hexagon SDK $($Release.version) for Windows ARM64 (about 900 MB)."
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $curlFailure = 'curl.exe unavailable'
        if ($curl) {
            $curlErrors = Join-Path $stage 'curl.stderr.log'
            $downloadArgs = @('--proto', '=https', '--proto-redir', '=https', '--fail', '--location', '--silent', '--show-error',
                '--retry', '2', '--retry-max-time', '900', '--connect-timeout', '20', '--max-time', '900',
                '--stderr', $curlErrors, '--output', $archive, $Release.url)
            & $curl.Source @downloadArgs | Out-Host
            if ($LASTEXITCODE -eq 0) {
                $curlFailure = $null
            } else {
                $curlFailure = "curl exit $LASTEXITCODE"
                if (Test-Path -LiteralPath $curlErrors -PathType Leaf) {
                    $detail = Get-Content -LiteralPath $curlErrors -Tail 1
                    if ($detail) { $curlFailure += " ($detail)" }
                }
            }
        }
        if ($curlFailure) {
            Write-Host "Retrying with PowerShell and Windows network settings after $curlFailure."
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Release.url -UseBasicParsing -OutFile $archive -TimeoutSec 900 -MaximumRedirection 5
            } catch {
                $detail = $_.Exception.GetBaseException().Message
                throw "Hexagon SDK download failed. $curlFailure. PowerShell: $detail. A downloaded $archiveName can be placed in Downloads or at $localArchive."
            }
        }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Release.sha256) {
        throw "Hexagon SDK SHA-256 mismatch for $archive."
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
