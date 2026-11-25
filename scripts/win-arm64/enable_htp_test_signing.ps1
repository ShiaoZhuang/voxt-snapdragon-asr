#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{40}$')][string]$SignerThumbprint)

$ErrorActionPreference = 'Stop'
$runs = Join-Path (Get-Location).Path '.local/win-arm64-handoff/runs'
# Match the operator's pinned signer, even if another route ran more recently.
$cert = $null
foreach ($run in (Get-ChildItem -LiteralPath $runs -Directory | Sort-Object Name -Descending)) {
    $file = Join-Path $run.FullName 'htp-signer.cer'
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    $der = [IO.File]::ReadAllBytes($file)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($der) -ne 'Cert') { continue }
    $candidate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
    if ($candidate.Thumbprint -eq $SignerThumbprint) { $cert = $candidate; break }
    $candidate.Dispose()
}
if (!$cert) { throw 'No exported public certificate matches the supplied Signer fingerprint. Run update_and_verify.ps1 -Route GgmlHexagon from the repository first.' }
$eku = $cert.Extensions['2.5.29.37']
$constraints = $cert.Extensions['2.5.29.19']
if ($cert.HasPrivateKey -or $cert.Subject -ne $cert.Issuer -or
    $cert.Subject -notmatch '^CN=Voxt HTP v73 test [0-9a-f-]{36}$' -or
    !$eku -or $eku.EnhancedKeyUsages.Count -ne 1 -or $eku.EnhancedKeyUsages[0].Value -ne '1.3.6.1.5.5.7.3.3' -or
    ($constraints -and $constraints.CertificateAuthority)) {
    throw 'Expected the public end-entity code-signing certificate from the Voxt v73 trial.'
}
if ((Get-Date) -lt $cert.NotBefore -or (Get-Date) -ge $cert.NotAfter) {
    throw 'Test certificate outside its validity period. Generate a fresh baseline first.'
}

$added = [Collections.Generic.List[string]]::new()
try {
    foreach ($name in 'Root','TrustedPublisher') {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($name, 'LocalMachine')
        try {
            $store.Open('ReadWrite')
            if (!$store.Certificates.Contains($cert)) {
                $store.Add($cert)
                $added.Add($name)
                Write-Host "Imported in LocalMachine/$name."
            } else { Write-Host "Already present in LocalMachine/$name." }
            if (!$store.Certificates.Contains($cert)) { throw "Import failed in LocalMachine/$name." }
            Write-Host "LocalMachine/$name confirmed | $($cert.Thumbprint)"
        } finally { $store.Close() }
    }
    $system = [Environment]::SystemDirectory
    if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess) {
        $system = Join-Path $env:windir 'Sysnative'
    }
    & (Join-Path $system 'bcdedit.exe') /set '{current}' testsigning on
    if ($LASTEXITCODE -ne 0) { throw "BCDEdit rejected the change (exit $LASTEXITCODE). See its message above." }
} catch {
    $cause = $_
    foreach ($name in $added) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($name, 'LocalMachine')
        try {
            $store.Open('ReadWrite')
            $store.Remove($cert)
            Write-Host "Rolled back this run's import in LocalMachine/$name."
        } catch { Write-Warning "Check LocalMachine/$name, fingerprint $SignerThumbprint. Rollback failed: $_" }
        finally { $store.Close() }
    }
    throw $cause
} finally { $cert.Dispose() }
Write-Host 'TESTSIGNING configured for the current boot entry. Restart Windows, then run update_and_verify.ps1 to read the active kernel state and test HTP0.'
