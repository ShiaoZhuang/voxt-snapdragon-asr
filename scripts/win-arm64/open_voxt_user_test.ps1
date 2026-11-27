# Installed alongside the frozen application and backend. No fetch or compile.
[CmdletBinding()]
param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'pilot.json') | ConvertFrom-Json
$exe = Join-Path $PSScriptRoot 'desktop/Voxt.exe'
foreach ($name in 'desktop/Voxt.exe','desktop/voxtnew-helper.exe','desktop/mygo-sqlite3.dll',
    'backend/qwen3_asr_server.exe','backend/OpenCL.dll','models/target.gguf','models/mmproj.gguf','models/draft-4.gguf',
    'ops/libggml-htp-v73.so','ops/libggml-htp.cat') {
    if (!$config.Files.$name) { throw "Incomplete pilot manifest: $name" }
}
foreach ($pair in $config.Files.PSObject.Properties) {
    $file = Join-Path $PSScriptRoot $pair.Name
    if ((Get-FileHash -LiteralPath $file).Hash -ne $pair.Value) { throw "User-test file hash mismatch: $file" }
}
if (!(Test-Path -LiteralPath $config.Environment.VOXT_SNAPDRAGON_MODELS -PathType Container)) { throw 'The verified model directory is missing.' }
if ($VerifyOnly) { return }
$existing = @(Get-Process -Name Voxt -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($existing.Count) { Write-Host "[voxt] Voxt is already running (PID $($existing[0].Id))."; return }
foreach ($key in $config.RemoveEnvironment) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
foreach ($pair in $config.Environment.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable($pair.Name, [string]$pair.Value, 'Process')
}
$env:VOXTNEW_OMNI_RUNTIME = Join-Path $PSScriptRoot 'backend/qwen3_asr_server.exe'
$env:VOXTNEW_HELPER = Join-Path $PSScriptRoot 'desktop/voxtnew-helper.exe'
$logDir = (New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'logs')).FullName
$run = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$app = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru `
    -RedirectStandardOutput (Join-Path $logDir "$run.stdout.log") -RedirectStandardError (Join-Path $logDir "$run.stderr.log")
if ($app.WaitForExit(4000)) {
    $detail = Get-Content -LiteralPath (Join-Path $logDir "$run.stderr.log") -Tail 8
    throw "Voxt exited at startup ($($app.ExitCode)): $detail. Logs: $logDir"
}
Write-Host "[voxt] Voxt launched (PID $($app.Id)). Logs: $logDir"
