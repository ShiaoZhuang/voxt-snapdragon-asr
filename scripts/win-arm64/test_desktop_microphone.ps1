# Optional hardware check. Audio stays in memory and is discarded after counting PCM samples.
param([Parameter(Mandatory=$true)][string]$Helper)
$ErrorActionPreference = 'Stop'
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = (Resolve-Path -LiteralPath $Helper).ProviderPath
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($start)
try {
    function Send-Helper([string]$id, [string]$method, [hashtable]$arguments) {
        $line = @{id=$id; method=$method; params=$arguments} | ConvertTo-Json -Depth 5 -Compress
        $p.StandardInput.WriteLine($line)
        $p.StandardInput.Flush()
    }
    function Receive-Helper {
        $line = $p.StandardOutput.ReadLineAsync()
        if (-not $line.Wait(10000)) { throw 'Helper did not respond within ten seconds.' }
        if (-not $line.Result) { throw 'Helper closed its output.' }
        $message = $line.Result | ConvertFrom-Json
        if ($message.error) { throw ("{0}: {1}" -f $message.error.code,$message.error.message) }
        return $message
    }
    Send-Helper 'hello' 'helper.hello' @{protocol=1; app='desktop-mic-check'}
    $hello = Receive-Helper
    if ($hello.id -ne 'hello' -or $hello.result.protocol -ne 1) { throw 'Wrong helper handshake.' }
    Write-Host 'Speak into the default Windows microphone for about three seconds.'
    Send-Helper 'microphone' 'capture.start' @{sampleRate=16000; frameMs=100; maxSeconds=8}
    $frames = 0
    $samples = 0
    $peak = -120.0
    $started = $false
    $sentStop = $false
    $finished = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($clock.Elapsed.TotalSeconds -gt 15) { throw 'Microphone check timed out.' }
        $m = Receive-Helper
        if ($m.id -eq 'microphone') {
            if (-not $sentStop -or $m.result.reason -ne 'stopped' -or $m.result.frames -ne $frames -or $m.result.samples -ne $samples) {
                throw 'Recording ended early or final counts differ from the received audio.'
            }
            $finished = $true
            continue
        }
        if ($m.id -eq 'stop') {
            if (-not $finished -or -not $m.result.stopped) { throw 'Stop was acknowledged before the recording finished.' }
            break
        }
        if ($m.params.job -ne 'microphone') { continue }
        switch ($m.method) {
            'capture.started' {
                if ($started -or $m.params.sampleRate -ne 16000) { throw 'Unexpected capture format or duplicate start.' }
                $started = $true
            }
            'capture.level' { $peak = [Math]::Max($peak,[double]$m.params.peak) }
            'capture.pcm' {
                $length = [Convert]::FromBase64String($m.params.data).Length
                if (-not $started -or $m.params.seq -ne $frames -or $m.params.offset -ne $samples -or $length -lt 2 -or $length % 2) {
                    throw 'Missing, out-of-order or invalid PCM16 audio frame.'
                }
                $frames++
                $samples += [int]($length/2)
                if ($samples -ge 48000 -and -not $sentStop) {
                    Send-Helper 'stop' 'capture.stop' @{job='microphone'}
                    $sentStop = $true
                }
            }
        }
    }
    if ($peak -le -85) { throw ("Frames arrived, but input was silent ({0:F1} dBFS). Check the microphone and repeat while speaking." -f $peak) }
    Send-Helper 'shutdown' 'helper.shutdown' @{}
    $bye = Receive-Helper
    if ($bye.id -ne 'shutdown' -or -not $p.WaitForExit(3000) -or $p.ExitCode -ne 0) { throw 'Helper shutdown failed.' }
    Write-Host ("PASS: {0} ordered frames, {1} mono PCM16 samples at 16000 Hz, peak {2:F1} dBFS." -f $frames,$samples,$peak)
} finally {
    if (-not $p.HasExited) {
        $p.StandardInput.Close()
        if (-not $p.WaitForExit(3000)) { $p.Kill(); $p.WaitForExit() }
    }
    $p.Dispose()
}
