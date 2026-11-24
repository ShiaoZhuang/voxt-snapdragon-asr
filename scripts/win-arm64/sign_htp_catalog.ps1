[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary
)

$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$catalogName = 'libggml-htp.cat'
$catalog = Join-Path $package $catalogName
if (Test-Path -LiteralPath $catalog -PathType Leaf) { return }

function Invoke-SigningTool([string]$Tool, [string[]]$Arguments, [int]$TimeoutSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new($Tool)
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000) -or
            ![Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), [Math]::Max(0, $TimeoutSeconds * 1000 - [int]$timer.ElapsedMilliseconds))) {
            return @{ Code = -1; Detail = "timed out after ${TimeoutSeconds}s" }
        }
        $output = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult())
        foreach ($part in $output) { if ($part.Trim()) { Write-Host $part.TrimEnd() } }
        $detail = @(($output -join "`n") -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4)
        return @{ Code = $process.ExitCode; Detail = ($detail -join ' | ') }
    } finally {
        try { if (!$process.HasExited) { $process.Kill(); $null = $process.WaitForExit(5000) } }
        finally { $process.Dispose() }
    }
}

function Find-WindowsKitTool([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($dir in $kitBins) {
        foreach ($arch in @('arm64', 'x86', 'x64')) {
            $candidate = Join-Path $dir "$arch/$Name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw "$Name was not found in PATH or the installed Windows SDK/WDK."
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
if (!$candidates.Count) {
    if ($thumbprint) { throw 'The requested certificate is unavailable or lacks a valid code-signing key.' }
    throw 'No valid code-signing certificate with a private key found in CurrentUser/My or LocalMachine/My.'
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
$windowsBuild = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber')
$os = if ($windowsBuild -ge 26200) { '10_25H2_ARM64' } elseif ($windowsBuild -ge 26100) { '10_GE_ARM64' } else { '10_NI_ARM64' }

$stage = (New-Item -ItemType Directory -Path (Join-Path $package ('.signing-' + [guid]::NewGuid()))).FullName
try {
    $dspName = 'libggml-htp-v73.so'
    $infName = 'libggml-htp.inf'
    Copy-Item -LiteralPath (Join-Path $package $dspName), (Join-Path $package $infName) -Destination $stage
    Write-Host "[voxt] Generating the v73 catalog with Inf2Cat ($os)."
    $result = Invoke-SigningTool $inf2cat @("/driver:$stage", "/os:$os", '/uselocaltime') 60
    if ($result.Code -ne 0) { throw "Inf2Cat failed (exit $($result.Code)) | $($result.Detail)" }
    $Summary.Add("Inf2Cat: PASS | $os")
    $stagedCatalog = Join-Path $stage $catalogName
    $unsignedCatalog = Join-Path $stage 'unsigned.cat'
    Move-Item -LiteralPath $stagedCatalog -Destination $unsignedCatalog

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
        $result = Invoke-SigningTool $signtool ($args + $stagedCatalog) ([Math]::Min(30, $remaining))
        if ($result.Code -eq 0) { $signed = $cert; break }
        $failures += "$($cert.Store)/My $($cert.Thumbprint) (exit $($result.Code)) | $($result.Detail)"
    }
    if (!$signed) { throw "SignTool could not sign the catalog | $($failures -join ' || ')" }
    $Summary.Add("SignTool sign: PASS | $($signed.Store)/My $($signed.Thumbprint)")

    Write-Host '[voxt] Checking the signature and catalog members with SignTool.'
    $result = Invoke-SigningTool $signtool @('verify', '/pa', '/c', $stagedCatalog,
        (Join-Path $stage $dspName), (Join-Path $stage $infName)) 45
    if ($result.Code -eq 0) {
        $Summary.Add('SignTool verify: PASS | v73 library and INF')
    } else {
        $Summary.Add("SignTool verify: exit $($result.Code) | $($result.Detail) | Testing the normal HTP loader.")
    }
    [IO.File]::Move($stagedCatalog, $catalog)
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
