[CmdletBinding()]
param(
    [string]$PackageDirectory = (Join-Path $PSScriptRoot '..\..\dist\voxt-snapdragon-veri-1'),
    [string]$ReportPath = (Join-Path ([IO.Path]::GetTempPath()) ('voxt-snapdragon-probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt'))
)

$pkg = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageDirectory)
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)

# Capture independent diagnostic failures without losing the rest of the report.
& {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    '=== Voxt Snapdragon environment probe ==='
    'Time: ' + (Get-Date -Format o)
    $rt = [System.Runtime.InteropServices.RuntimeInformation]

    '=== Windows and hardware ==='
    "OS architecture: $($rt::OSArchitecture) | PowerShell process: $($rt::ProcessArchitecture) | PowerShell: $($PSVersionTable.PSVersion)"
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Format-List
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List
    Get-CimInstance Win32_ComputerSystem | ForEach-Object {
        'RAM: {0:N1} GiB' -f ($_.TotalPhysicalMemory / 1GB)
    }
    $diskRoot = [IO.Path]::GetPathRoot($pkg)
    if ($diskRoot -match '^[A-Z]:\\$') {
        $disk = [IO.DriveInfo]::new($diskRoot)
        'Drive {0} free: {1:N1} GiB' -f $disk.Name, ($disk.AvailableFreeSpace / 1GB)
    }
    Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion | Format-List
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'Hexagon|\bNPU\b|Neural Processor|Qualcomm AI' } |
            Select-Object Status, Class, FriendlyName | Format-Table -AutoSize
    }

    '=== Native OpenCL registration and backend ==='
    $key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors'
    if (Test-Path -LiteralPath $key) {
        $vendors = Get-Item -LiteralPath $key
        foreach ($name in $vendors.GetValueNames()) {
            "ICD: $([IO.Path]::GetFileName($name)) | enabled: $($vendors.GetValue($name) -eq 0)"
        }
    } else { 'Khronos registry key not found; backend enumeration is the functional check.' }
    $server = Join-Path $pkg 'bin\qwen3_asr_server.exe'
    if (Test-Path -LiteralPath $server) {
        $start = [Diagnostics.ProcessStartInfo]::new($server, '--list-devices')
        $start.WorkingDirectory = Split-Path -Parent $server
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = $null
        try {
            $process = [Diagnostics.Process]::Start($start)
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(20000)) {
                $process.Kill()
                $process.WaitForExit()
                'Backend device enumeration timed out after 20 seconds.'
            }
            $stdout.GetAwaiter().GetResult().Trim()
            $stderr.GetAwaiter().GetResult().Trim()
            "Backend exit code: $($process.ExitCode)"
        } catch { "Backend enumeration failed: $_" }
        finally { if ($process) { $process.Dispose() } }
    } else { 'Veri 1 backend not found in the default installation directory.' }

    '=== Model and partial download sizes ==='
    foreach ($dir in @((Join-Path $pkg 'models'), (Join-Path $pkg '.downloads'))) {
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match '\.gguf' } |
                Select-Object Name, @{Name='MiB'; Expression={ [math]::Round($_.Length / 1MB, 1) }} |
                Format-Table -AutoSize
        }
    }

    '=== Small download probes ==='
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --version | Select-Object -First 1
        $hf = 'https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/mmproj-Qwen3-ASR-1.7B-bf16.gguf?download=true'
        $gh = 'https://github.com/ShiaoZhuang/voxt-snapdragon-asr/releases/download/veri-1/mmproj.gguf'
        $probeArgs = @('--location', '--fail', '--silent', '--show-error', '--connect-timeout', '8', '--max-time', '20',
                       '--range', '0-1048575', '--max-filesize', '2097152', '--output', 'NUL',
                       '--write-out', 'HTTP %{http_code} | bytes %{size_download} | B/s %{speed_download}\n')
        foreach ($url in @($gh, $hf)) {
            "Source: $(([uri]$url).Host)"
            $result = & $curl.Source @probeArgs $url 2>&1
            $exitCode = $LASTEXITCODE
            $result | ForEach-Object { $_.ToString() }
            "curl exit code: $exitCode"
            if ($exitCode -in 35, 60 -and ($result -join ' ') -match '\bschannel\b' -and
                ($result -join ' ') -match 'CRYPT_E_(NO_REVOCATION_CHECK|REVOCATION_OFFLINE)|0x8009201[23]') {
                'Retry with the installer''s Schannel best-effort revocation option:'
                & $curl.Source --ssl-revoke-best-effort @probeArgs $url 2>&1 | ForEach-Object { $_.ToString() }
                "Retry curl exit code: $LASTEXITCODE"
            }
        }
    } else { 'curl.exe not found.' }
} *>&1 | Out-String -Width 220 | Set-Content -LiteralPath $ReportPath -Encoding UTF8 -ErrorAction Stop

Write-Output "Report saved to: $ReportPath"
