function Invoke-BoundedWindowsTool([string]$Tool, [string[]]$Arguments, [int]$TimeoutSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new($Tool)
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.WorkingDirectory = Split-Path -Parent $Tool
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

# Used for release packages with a SHA-256 pinned by the caller.
function Invoke-PinnedPackageCurl([string]$Curl, [string]$Url, [string]$Destination, [int]$Seconds, [int]$StallSeconds) {
    $options = @('--proto', '=https', '--proto-redir', '=https', '--fail', '--location', '--silent', '--show-error',
        '--connect-timeout', '15', '--speed-limit', '1024', '--speed-time', "$StallSeconds", '--output', $Destination)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-BoundedWindowsTool $Curl ($options + @('--max-time', "$Seconds", $Url)) $Seconds
    $lookupFailed = $result.Code -in 35, 60 -and $result.Detail -match '\bschannel\b' -and
        $result.Detail -match 'CRYPT_E_(NO_REVOCATION_CHECK|REVOCATION_OFFLINE)|0x8009201[23]' -and
        $result.Detail -notmatch 'CRYPT_E_REVOKED|CERT_E_REVOKED|0x80092010|0x800B010C'
    $result.RevocationLookupFailed = $lookupFailed
    $remaining = [int][Math]::Floor($Seconds - $timer.Elapsed.TotalSeconds)
    if (!$lookupFailed -or $remaining -lt 1) { return $result }

    Write-Host '[voxt] Download in progress (attempt 2 of 2; Schannel revocation lookup unavailable).'
    $retry = Invoke-BoundedWindowsTool $Curl ($options + @('--ssl-revoke-best-effort', '--max-time', "$remaining", $Url)) $remaining
    $retry.RevocationLookupFailed = $true
    if ($retry.Code -ne 0) { $retry.Detail = "$($result.Detail) | Retry: $($retry.Detail)" }
    return $retry
}
