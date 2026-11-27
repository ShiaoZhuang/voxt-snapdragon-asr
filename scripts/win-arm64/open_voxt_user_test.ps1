# Installed alongside the frozen application and backend. No fetch or compile.
[CmdletBinding()]
param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'pilot.json') | ConvertFrom-Json
$exe = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'desktop/Voxt.exe'))
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
$logDir = (New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'logs')).FullName
$session = (Get-Process -Id $PID).SessionId
$running = @(Get-Process -Name Voxt -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
$existing = $null
foreach ($candidate in $running) {
    $path = $candidate.Path
    if (!$path) { continue }
    if ([IO.Path]::GetFullPath($path) -eq $exe) {
        $existing = $candidate
    } elseif ($path -match '[/\\]\.local[/\\]voxt-user-test[/\\]voxt-snapdragon-user-test-[^/\\]+[/\\]desktop[/\\]Voxt\.exe$') {
        throw "Another Voxt pilot is running (PID $($candidate.Id), $path). In the Windows notification area, open its tray menu, choose Quit Voxt, then run this launcher again."
    }
}

function Get-LaunchRecord([Diagnostics.Process]$App) {
    $ticks = $App.StartTime.ToUniversalTime().Ticks
    Join-Path $logDir "process-$($App.Id)-$ticks.txt"
}

if ($existing) {
    $app = $existing
    $record = Get-LaunchRecord $app
    if (Test-Path -LiteralPath $record -PathType Leaf) { $run = [IO.File]::ReadAllText($record).Trim() }
    if (!$run -or $run -notmatch '^[0-9a-f]{32}$') {
        throw "Voxt is already running (PID $($app.Id)) without a launch record. Choose Quit Voxt in its tray menu, then reopen this pilot."
    }
    Write-Host "[voxt] Voxt is already running (PID $($app.Id))."
} else {
    foreach ($key in $config.RemoveEnvironment) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($pair in $config.Environment.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($pair.Name, [string]$pair.Value, 'Process')
    }
    $env:VOXTNEW_OMNI_RUNTIME = Join-Path $PSScriptRoot 'backend/qwen3_asr_server.exe'
    $env:VOXTNEW_HELPER = Join-Path $PSScriptRoot 'desktop/voxtnew-helper.exe'
    $run = [guid]::NewGuid().ToString('N')
    $env:VOXT_WINDOWS_HOTKEY_STATUS = Join-Path $logDir "$run.hotkey.json"
    $env:VOXT_WINDOWS_STARTUP_LOG = Join-Path $logDir "$run.startup.log"

    # The original verifier drains both workflow pipes to EOF. GUI descendants must never
    # inherit either pipe. The GUI opens its own startup log and stays in this user's session.
    if (!('VoxtPilotProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class VoxtPilotProcess {
    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo {
        public int size;
        public IntPtr reserved, desktop, title;
        public int x, y, width, height, xChars, yChars, fill, flags;
        public short show, reservedSize;
        public IntPtr reservedPtr, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcInfo {
        public IntPtr process, thread;
        public int processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcInfo info);
    [DllImport("kernel32.dll", ExactSpelling=true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static int Start(string exe, string directory) {
        var startup = new StartupInfo();
        startup.size = Marshal.SizeOf(typeof(StartupInfo));
        ProcInfo child;
        const uint DETACHED_PROCESS = 0x8;
        var commandLine = new StringBuilder("\"" + exe + "\"");
        if (!CreateProcessW(exe, commandLine, IntPtr.Zero, IntPtr.Zero, false, DETACHED_PROCESS,
                IntPtr.Zero, directory, ref startup, out child)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        CloseHandle(child.thread);
        CloseHandle(child.process);
        return child.processId;
    }
}
'@
    }
    $appId = [VoxtPilotProcess]::Start($exe, (Split-Path -Parent $exe))
    $app = Get-Process -Id $appId -ErrorAction SilentlyContinue
    if (!$app -or $app.HasExited) { throw "Voxt exited at startup. See $env:VOXT_WINDOWS_STARTUP_LOG" }
    [IO.File]::WriteAllText((Get-LaunchRecord $app), $run)
    Write-Host "[voxt] Voxt launched (PID $appId). Startup log: $env:VOXT_WINDOWS_STARTUP_LOG"
}

$statusFile = Join-Path $logDir "$run.hotkey.json"
$startupLog = Join-Path $logDir "$run.startup.log"
$deadline = [Diagnostics.Stopwatch]::StartNew()
while ($deadline.Elapsed.TotalSeconds -lt 15) {
    if ($app.HasExited) { throw "Voxt exited (code $($app.ExitCode)). See $startupLog" }
    if (Test-Path -LiteralPath $statusFile -PathType Leaf) {
        try { $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statusFile | ConvertFrom-Json }
        catch { $state = $null } # The helper may still be writing the first status.
        if ($state -and $state.installed -is [bool]) {
            if (!$state.installed) {
                throw "Voxt is open, but the helper could not register the hotkey: $($state.error). Check Voxt Settings and retry. Status: $statusFile"
            }
            if ($state.binding -cne 'Caps Lock') {
                throw "Voxt is open with a different transcribe key ($($state.binding)). Select Caps Lock in Voxt Settings, then run this launcher again."
            }
            Write-Host "[voxt] Caps Lock ready (Voxt PID $($app.Id)). Helper status: $statusFile"
            return
        }
    }
    Start-Sleep -Milliseconds 150
}
throw "Voxt is open (PID $($app.Id)). The helper has not confirmed Caps Lock within 15 seconds. Complete the welcome screen if shown, then rerun this launcher. Startup log: $startupLog"
