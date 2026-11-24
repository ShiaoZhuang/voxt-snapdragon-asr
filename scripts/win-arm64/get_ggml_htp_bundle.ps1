[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)]$Release
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke_bounded_download.ps1')

$cache = (New-Item -ItemType Directory -Path $CacheDirectory -Force).FullName
$bundle = Join-Path $cache $Release.version
$files = @($Release.files.PSObject.Properties)

function Test-HtpBundle([string]$Path) {
    foreach ($file in $files) {
        $member = Join-Path $Path $file.Name
        if (!(Test-Path -LiteralPath $member -PathType Leaf) -or
            (Get-FileHash -LiteralPath $member -Algorithm SHA256).Hash -ne $file.Value) {
            return $false
        }
    }
    return $true
}

if (Test-HtpBundle $bundle) { return $bundle }

$name = ([uri]$Release.url).Segments[-1]
$archive = Join-Path $cache $name
if (!(Test-Path -LiteralPath $archive -PathType Leaf) -and $env:USERPROFILE) {
    $downloads = Join-Path $env:USERPROFILE "Downloads/$name"
    if (Test-Path -LiteralPath $downloads -PathType Leaf) { $archive = $downloads }
}
$stage = (New-Item -ItemType Directory -Path (Join-Path $cache ('.bundle-' + [guid]::NewGuid()))).FullName
try {
    if (!(Test-Path -LiteralPath $archive -PathType Leaf)) {
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $hint = "Place the verified release archive $name in Downloads or $cache."
        if (!$curl) { throw "curl.exe unavailable. $hint" }
        $archive = Join-Path $stage $name
        Write-Host "[voxt] Downloading the signed GenieX HTP bundle $($Release.version) (up to 2 minutes)."
        $result = Invoke-BoundedDownload $curl.Source @('--proto', '=https', '--proto-redir', '=https',
            '--fail', '--location', '--silent', '--show-error', '--connect-timeout', '15',
            '--max-time', '120', '--speed-limit', '1024', '--speed-time', '20',
            '--output', $archive, $Release.url) 120
        if ($result.Code -ne 0) { throw "Signed HTP bundle download failed (curl exit $($result.Code)): $($result.Detail). $hint" }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Release.sha256) {
        throw "GenieX SDK archive SHA-256 mismatch: $archive"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unpacked = (New-Item -ItemType Directory -Path (Join-Path $stage 'unpacked')).FullName
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($file in $files) {
            $entry = $zip.GetEntry("sdk-windows-arm64/lib/llama_cpp/$($file.Name)")
            if (!$entry) { throw "Missing signed bundle member: $($file.Name)" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $unpacked $file.Name))
        }
    } finally { $zip.Dispose() }
    if (!(Test-HtpBundle $unpacked)) { throw 'GenieX HTP bundle member SHA-256 mismatch.' }

    if (Test-Path -LiteralPath $bundle) {
        [IO.Directory]::Move($bundle, "$bundle.incomplete-$([guid]::NewGuid())")
    }
    [IO.Directory]::Move($unpacked, $bundle)
    return $bundle
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
