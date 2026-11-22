[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $PSScriptRoot '../../dist/voxt-snapdragon-veri-1'),
    [string]$ReportPath = (Join-Path ([IO.Path]::GetTempPath()) ('voxt-opencl-startup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt'))
)

$ErrorActionPreference = 'Stop'
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
$serverName = 'qwen3_asr_server.exe'
$since = (Get-Date).AddDays(-2)

& {
    '=== Voxt OpenCL Target startup ==='
    'Time: ' + (Get-Date -Format o)
    "Windows: $([Environment]::OSVersion.VersionString) | PowerShell: $($PSVersionTable.PSVersion)"

    $child = $null
    try {
        $root = (Resolve-Path -LiteralPath $InstallDirectory).Path
        $server = Join-Path $root "bin/$serverName"
        $models = Join-Path $root 'models'
        foreach ($path in @($server, (Join-Path $models 'target.gguf'), (Join-Path $models 'mmproj.gguf'))) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $path" }
        }

        $start = [Diagnostics.ProcessStartInfo]::new($server)
        $start.Arguments = '--supervised --host 127.0.0.1 --port 0 --backend opencl --model-directory "' + $models + '"'
        $start.WorkingDirectory = $root
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $start.EnvironmentVariables['LLAMA_ARG_LOG_VERBOSITY'] = '5'
        $child = [Diagnostics.Process]::Start($start)
        "Started PID: $($child.Id)"
        $stderr = $child.StandardError.ReadToEndAsync()
        $firstLine = $child.StandardOutput.ReadLineAsync()
        if ($firstLine.Wait(90000)) {
            $line = $firstLine.GetAwaiter().GetResult()
            if ($line) { "First stdout line: $line" }
        } else {
            'No ready event after 90 seconds.'
        }

        # Closing stdin also asks the supervised server to stop if it reaches ready later.
        $child.StandardInput.Close()
        if (!$child.WaitForExit(5000)) {
            'Stopped the probe after waiting five seconds for shutdown.'
            $child.Kill()
            $child.WaitForExit()
        }
        'Exit code: {0} (0x{0:X8})' -f $child.ExitCode
        '=== Backend stderr ==='
        $stderr.GetAwaiter().GetResult().TrimEnd()
    } catch {
        "Startup probe error: $_"
    } finally {
        if ($child) {
            if (!$child.HasExited) {
                $child.Kill()
                $child.WaitForExit()
            }
            $child.Dispose()
        }
    }

    '=== Windows Application Error 1000 (past two days) ==='
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since
        } -ErrorAction Stop | ForEach-Object {
            $event = $_
            $fields = @{}
            $xml = [xml]($event.ToXml())
            foreach ($field in $xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']")) {
                $fields[$field.GetAttribute('Name')] = $field.InnerText
            }
            if ($fields['AppName'] -ieq $serverName) {
                [pscustomobject]@{
                    Time = $event.TimeCreated
                    ProcessId = $fields['ProcessId']
                    Module = $fields['ModuleName']
                    ModuleVersion = $fields['ModuleVersion']
                    ExceptionCode = $fields['ExceptionCode']
                    FaultingOffset = $fields['FaultingOffset']
                }
            }
        } | Select-Object -First 10
        if ($events) { $events | Format-List | Out-String -Width 200 }
        else { "No matching event for $serverName." }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound,*') { "No matching event for $serverName." }
        else { "Event log unavailable: $_" }
    }
} | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Output "Report saved to: $ReportPath"
