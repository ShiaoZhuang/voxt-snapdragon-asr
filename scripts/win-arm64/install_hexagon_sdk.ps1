[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)]$Release
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke_bounded_download.ps1')
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
        $budget = 480
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $localHint = "Use the approved release archive $archiveName in Downloads or at $localArchive."
        Write-Host "[voxt] Downloading Hexagon SDK $($Release.version) (about 900 MB, up to 8 minutes total)."
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $curlFailure = 'curl.exe unavailable'
        if ($curl) {
            $downloadArgs = @('--proto', '=https', '--proto-redir', '=https', '--fail', '--location', '--silent', '--show-error',
                '--connect-timeout', '20', '--max-time', "$budget", '--speed-limit', '1024', '--speed-time', '30',
                '--output', $archive, $Release.url)
            $result = Invoke-BoundedDownload $curl.Source $downloadArgs $budget
            $curlFailure = if ($result.Code -eq 0) { $null } else { "curl exit $($result.Code): $($result.Detail)" }
        }
        if ($curlFailure) {
            Write-Host "[voxt] SDK download error | $curlFailure"
            if ($curlFailure -match 'unable to check revocation|CRYPT_E_(NO_REVOCATION_CHECK|REVOCATION_OFFLINE)|0x8009201[23]') {
                throw "Windows could not check certificate revocation. $curlFailure. $localHint"
            }
            $remaining = [int][Math]::Floor($budget - $timer.Elapsed.TotalSeconds)
            if ($remaining -lt 1) { throw "Hexagon SDK download budget exhausted. $curlFailure. $localHint" }
            Write-Host "[voxt] Retrying through Windows PowerShell (up to ${remaining}s)."
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
            $hostExe = (Get-Process -Id $PID).Path
            $result = Invoke-BoundedDownload $hostExe @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                (Join-Path $PSScriptRoot 'download_hexagon_sdk_web.ps1'), '-Uri', $Release.url,
                '-Archive', $archive, '-TimeoutSeconds', "$remaining") $remaining
            if ($result.Code -ne 0) {
                throw "Hexagon SDK download failed. $curlFailure. PowerShell: $($result.Detail). $localHint"
            }
        }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Release.sha256) {
        throw "Hexagon SDK SHA-256 mismatch for $archive."
    }

    Write-Host '[voxt] Extracting the verified Hexagon SDK.'
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
