function Invoke-BoundedDownload([string]$Exe, [string[]]$Arguments, [int]$Seconds) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardError = $true
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $child = [Diagnostics.Process]::Start($start)
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $errors = $child.StandardError.ReadToEndAsync()
        if (!$child.WaitForExit($Seconds * 1000) -or
            !$errors.Wait([Math]::Max(0, $Seconds * 1000 - [int]$timer.ElapsedMilliseconds))) {
            return @{ Code = -1; Detail = "timed out after ${Seconds}s" }
        }
        $detail = [string]($errors.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($detail) { $detail = $detail.Trim() }
        return @{ Code = $child.ExitCode; Detail = $detail }
    } finally {
        try { if (!$child.HasExited) { $child.Kill() } } finally { $child.Dispose() }
    }
}
