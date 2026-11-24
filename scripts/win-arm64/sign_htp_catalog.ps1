[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$TrialDirectory,
    [Parameter(Mandatory)][string]$ToolCacheDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_tool_download.ps1')
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$catalogName = 'libggml-htp.cat'
$catalog = Join-Path $package $catalogName
if (Test-Path -LiteralPath $catalog -PathType Leaf) { return $package }

function Find-WindowsKitTool([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($dir in $kitBins) {
        foreach ($arch in @('arm64', 'x86', 'x64')) {
            $candidate = Join-Path $dir "$arch/$Name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
}

function Get-NuGetSigningTool([string]$Tool, $Release) {
    $cache = (New-Item -ItemType Directory -Path $ToolCacheDirectory -Force).FullName
    $name = ([uri]$Release.url).Segments[-1]
    $cached = Join-Path $cache $name
    $archive = $cached
    if (!(Test-Path -LiteralPath $archive -PathType Leaf) -and $env:USERPROFILE) {
        $downloads = Join-Path $env:USERPROFILE "Downloads/$name"
        if (Test-Path -LiteralPath $downloads -PathType Leaf) { $archive = $downloads }
    }
    if (!(Test-Path -LiteralPath $archive -PathType Leaf)) {
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $hint = "Place $name in Downloads or $cache."
        if (!$curl) { throw "curl.exe not found. $hint" }
        $partial = "$cached.partial-$([guid]::NewGuid())"
        try {
            Write-Host "[voxt] Downloading $Tool from Microsoft NuGet (up to 90 seconds)."
            $result = Invoke-PinnedPackageCurl $curl.Source $Release.url $partial 90 20
            if ($result.Code -ne 0) { throw "$Tool package download failed (curl exit $($result.Code)) | $($result.Detail) | $hint" }
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Release.sha256) {
                throw "SHA-256 mismatch for downloaded $name."
            }
            [IO.File]::Move($partial, $cached)
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    } elseif ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Release.sha256) {
        throw "SHA-256 mismatch for $archive."
    }
    $destination = (New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $TrialDirectory) "windows-signing-tools/$Tool")).FullName
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            if (!$entry.Name -or !$entry.FullName.StartsWith($Release.prefix, [StringComparison]::Ordinal)) { continue }
            $relative = $entry.FullName.Substring($Release.prefix.Length)
            if ([IO.Path]::IsPathRooted($relative) -or ($relative -split '[/\\]') -contains '..') {
                throw "Invalid path in $name."
            }
            $target = Join-Path $destination $relative
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
    $exe = Join-Path $destination $Release.executable
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "$($Release.executable) missing from $name." }
    $Summary.Add("HTP signing tool ($Tool): Microsoft NuGet | $name")
    return $exe
}

$now = Get-Date
$thumbprint = [string]$env:VOXT_HTP_SIGNING_THUMBPRINT -replace '\s', ''
$candidates = @(foreach ($store in @('CurrentUser', 'LocalMachine')) {
    try {
        $entries = @(Get-ChildItem -Path "Cert:\$store\My" -CodeSigningCert | Where-Object {
            $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -gt $now -and
                (!$thumbprint -or $_.Thumbprint -eq $thumbprint)
        } | Sort-Object NotAfter -Descending)
        $Summary.Add("HTP code-signing certificates ($store/My): $($entries.Count)")
        foreach ($cert in $entries) { [pscustomobject]@{ Store = $store; Thumbprint = $cert.Thumbprint } }
    } catch {
        $Summary.Add("HTP certificate store $store/My unavailable | $($_.Exception.Message)")
    }
})
if (!$candidates.Count -and $thumbprint) {
    throw 'The requested certificate is unavailable or lacks a valid code-signing key.'
}

$kitBins = @($env:WINDOWS_SDK_BIN, $env:WindowsSdkVerBinPath) | Where-Object { $_ }
$kitRoot = ${env:ProgramFiles(x86)}
if (!$kitRoot) { $kitRoot = $env:ProgramFiles }
if ($kitRoot) {
    $kitDirectory = Join-Path $kitRoot 'Windows Kits/10/bin'
    if (Test-Path -LiteralPath $kitDirectory -PathType Container) {
        $kitBins += @(Get-ChildItem -LiteralPath $kitDirectory -Directory |
            Where-Object { $_.Name -match '^\d+(\.\d+){2,3}$' } |
            Sort-Object { [version]$_.Name } -Descending | ForEach-Object FullName)
    }
}
$inf2cat = Find-WindowsKitTool 'Inf2Cat.exe'
$signtool = Find-WindowsKitTool 'SignTool.exe'
if (!$inf2cat -or !$signtool) {
    $lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../sources.lock.json') -Raw | ConvertFrom-Json
    if (!$inf2cat) { $inf2cat = Get-NuGetSigningTool 'Inf2Cat' $lock.windows_signing_tools.inf2cat }
    if (!$signtool) { $signtool = Get-NuGetSigningTool 'SignTool' $lock.windows_signing_tools.signtool }
}
$windowsBuild = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber')
$os = if ($windowsBuild -ge 26200) { '10_25H2_ARM64' } elseif ($windowsBuild -ge 26100) { '10_GE_ARM64' } else { '10_NI_ARM64' }

$stage = (New-Item -ItemType Directory -Path (Join-Path $package ('.signing-' + [guid]::NewGuid()))).FullName
$trialCert = $null
try {
    $dspName = 'libggml-htp-v73.so'
    $infName = 'libggml-htp.inf'
    Copy-Item -LiteralPath (Join-Path $package $dspName), (Join-Path $package $infName) -Destination $stage
    Write-Host "[voxt] Generating the v73 catalog with Inf2Cat ($os)."
    $result = Invoke-BoundedWindowsTool $inf2cat @("/driver:$stage", "/os:$os", '/uselocaltime') 60
    if ($result.Code -ne 0) { throw "Inf2Cat failed (exit $($result.Code)) | $($result.Detail)" }
    $Summary.Add("Inf2Cat: PASS | $os")
    $stagedCatalog = Join-Path $stage $catalogName
    $unsignedCatalog = Join-Path $stage 'unsigned.cat'
    Move-Item -LiteralPath $stagedCatalog -Destination $unsignedCatalog

    if (!$candidates.Count) {
        Write-Host '[voxt] Creating a temporary self-signed certificate for the v73 load test.'
        $trialCert = New-SelfSignedCertificate -Type CodeSigningCert -CertStoreLocation 'Cert:\CurrentUser\My' `
            -Subject "CN=Voxt HTP v73 test $([guid]::NewGuid())" -KeyExportPolicy NonExportable `
            -HashAlgorithm SHA256 -NotAfter ((Get-Date).AddDays(1))
        $candidates = @([pscustomobject]@{ Store = 'CurrentUser'; Thumbprint = $trialCert.Thumbprint })
        $Summary.Add("HTP signing mode: temporary self-signed | $($trialCert.Thumbprint)")
    }

    $signingBudget = [Diagnostics.Stopwatch]::StartNew()
    $failures = @()
    $signed = $null
    foreach ($cert in $candidates) {
        $remaining = 75 - [int]$signingBudget.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        Copy-Item -LiteralPath $unsignedCatalog -Destination $stagedCatalog -Force
        $args = @('sign', '/fd', 'SHA256', '/s', 'My', '/sha1', $cert.Thumbprint)
        if ($cert.Store -eq 'LocalMachine') { $args += '/sm' }
        Write-Host "[voxt] Signing the v73 catalog with SignTool ($($cert.Store)/My, $($cert.Thumbprint))."
        $result = Invoke-BoundedWindowsTool $signtool ($args + $stagedCatalog) ([Math]::Min(30, $remaining))
        if ($result.Code -eq 0) { $signed = $cert; break }
        $failures += "$($cert.Store)/My $($cert.Thumbprint) (exit $($result.Code)) | $($result.Detail)"
    }
    if (!$signed) { throw "SignTool could not sign the catalog | $($failures -join ' || ')" }
    $Summary.Add("SignTool sign: PASS | $($signed.Store)/My $($signed.Thumbprint)")

    Write-Host '[voxt] Checking the signature and catalog members with SignTool.'
    $result = Invoke-BoundedWindowsTool $signtool @('verify', '/pa', '/c', $stagedCatalog,
        (Join-Path $stage $dspName), (Join-Path $stage $infName)) 45
    if ($result.Code -eq 0) {
        $Summary.Add('SignTool verify: PASS | v73 library and INF')
    } else {
        $Summary.Add("SignTool verify: exit $($result.Code) | $($result.Detail) | Testing the normal HTP loader.")
    }
    if ($trialCert) {
        $trial = (New-Item -ItemType Directory -Path $TrialDirectory).FullName
        Copy-Item -LiteralPath (Join-Path $stage $dspName), (Join-Path $stage $infName), $stagedCatalog -Destination $trial
        return $trial
    }
    [IO.File]::Move($stagedCatalog, $catalog)
    return $package
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($trialCert) {
        try {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($trialCert.Thumbprint)" -DeleteKey -Force
        } catch {
            $Summary.Add("Temporary HTP key cleanup failed | $($_.Exception.Message)")
        }
    }
}
