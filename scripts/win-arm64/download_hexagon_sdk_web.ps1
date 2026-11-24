param(
    [Parameter(Mandatory)][uri]$Uri,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][int]$TimeoutSeconds
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $Archive -TimeoutSec $TimeoutSeconds -MaximumRedirection 5
} catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
