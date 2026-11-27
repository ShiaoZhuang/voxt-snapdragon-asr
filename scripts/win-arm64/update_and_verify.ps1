[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [ValidateSet('Hetero', 'HtpSuite', 'AudioEncoder', 'All', 'QnnLive', 'GgmlHexagon')][string]$Route = 'Hetero'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if (!$InstallDirectory) { $InstallDirectory = Join-Path $root 'dist/voxt-snapdragon-veri-1' }
$InstallDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDirectory)
$handoffRoot = (New-Item -ItemType Directory -Path (Join-Path $root '.local/win-arm64-handoff') -Force).FullName
$id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $PID
$logs = (New-Item -ItemType Directory -Path (Join-Path $handoffRoot "runs/$id") -Force).FullName
$worktree = Join-Path $handoffRoot 'source'
$branch = 'veri/native-win-arm64'
$remoteRef = "refs/remotes/origin/$branch"
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add("Time: $(Get-Date -Format o)")
$summary.Add("Source: origin/$branch")
$git = $null
$lock = $null
$gitStep = 0
$lastGitDetails = @()
$outcome = 'FAIL'
$stage = 'sync'

function Stop-HandoffProcess([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $Process.Kill($true)
    } else {
        & taskkill.exe /PID $Process.Id /T /F | Out-Null
        if (!$Process.HasExited) { $Process.Kill() }
    }
}

function Invoke-LoggedProcess([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $stdout = [IO.StreamWriter]::new((Join-Path $logs "$Name.stdout.log"), $false, [Text.UTF8Encoding]::new($false))
    try {
        $stderr = [IO.StreamWriter]::new((Join-Path $logs "$Name.stderr.log"), $false, [Text.UTF8Encoding]::new($false))
        try {
            $stdout.AutoFlush = $true
            $stderr.AutoFlush = $true
            $child = [Diagnostics.Process]::Start($start)
            try {
                $outLine = $child.StandardOutput.ReadLineAsync()
                $errLine = $child.StandardError.ReadLineAsync()
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $nextUpdate = 30
                $lastPhase = $Name
                while ($outLine -or $errLine -or !$child.HasExited) {
                    $didRead = $false
                    if ($outLine -and $outLine.IsCompleted) {
                        $line = $outLine.GetAwaiter().GetResult()
                        $outLine = $null
                        if ($null -ne $line) {
                            $stdout.WriteLine($line)
                            if ($Name -eq 'workflow' -and $line.StartsWith('[voxt] ')) {
                                Write-Host $line
                                $lastPhase = $line.Substring(7)
                                $nextUpdate = $timer.Elapsed.TotalSeconds + 30
                            }
                            $outLine = $child.StandardOutput.ReadLineAsync()
                        }
                        $didRead = $true
                    }
                    if ($errLine -and $errLine.IsCompleted) {
                        $line = $errLine.GetAwaiter().GetResult()
                        $errLine = $null
                        if ($null -ne $line) {
                            $stderr.WriteLine($line)
                            if ($Name -eq 'workflow') { Write-Host $line }
                            $errLine = $child.StandardError.ReadLineAsync()
                        }
                        $didRead = $true
                    }
                    if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        throw "$Name timed out after ${TimeoutSeconds}s. Last stage: $lastPhase"
                    }
                    if ($Name -eq 'workflow' -and $timer.Elapsed.TotalSeconds -ge $nextUpdate) {
                        Write-Host ("[voxt] Still running ({0:F0}s total) | {1}" -f $timer.Elapsed.TotalSeconds, $lastPhase)
                        $nextUpdate = $timer.Elapsed.TotalSeconds + 30
                    }
                    if (!$didRead) { Start-Sleep -Milliseconds 100 }
                }
                return $child.ExitCode
            } finally {
                try { Stop-HandoffProcess $child } finally { $child.Dispose() }
            }
        } finally { $stderr.Dispose() }
    } finally { $stdout.Dispose() }
}

function Invoke-HandoffGit([string[]]$Arguments) {
    $script:gitStep++
    $name = 'git-{0:D2}' -f $script:gitStep
    $status = Invoke-LoggedProcess $git $Arguments $name 180
    if ($status -ne 0) {
        $script:lastGitDetails = @(Get-Content -Encoding UTF8 -Tail 6 -LiteralPath (Join-Path $logs "$name.stderr.log"))
        throw "Git failed (exit $status): $($Arguments -join ' ')"
    }
    Get-Content -Encoding UTF8 -LiteralPath (Join-Path $logs "$name.stdout.log")
}

try {
    $lock = [IO.File]::Open((Join-Path $handoffRoot 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Write-Host '[1/2] Fetching the current Windows verification commit...'
    $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $origin = Invoke-HandoffGit @('-C', $root, 'remote', 'get-url', 'origin')
    if ($origin -notmatch '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)ShiaoZhuang/voxt-snapdragon-asr(\.git)?/?$') {
        throw 'The configured origin does not match the Voxt Snapdragon GitHub repository.'
    }
    $null = Invoke-HandoffGit @('-C', $root, 'fetch', '--no-tags', 'origin', "refs/heads/${branch}:$remoteRef")
    $revision = Invoke-HandoffGit @('-C', $root, 'rev-parse', "$remoteRef^{commit}")
    $summary.Add("Commit: $revision")
    if (Test-Path -LiteralPath $worktree) {
        if (!(Test-Path -LiteralPath (Join-Path $worktree '.git') -PathType Leaf)) { throw 'The handoff source directory is not a Git worktree.' }
        $common = Invoke-HandoffGit @('-C', $root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        $worktreeCommon = Invoke-HandoffGit @('-C', $worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        if ($worktreeCommon -ne $common -or (Invoke-HandoffGit @('-C', $worktree, 'rev-parse', '--abbrev-ref', 'HEAD')) -ne 'HEAD') {
            throw 'The handoff worktree must be a detached checkout of this repository.'
        }
        if (Invoke-HandoffGit @('-C', $worktree, 'status', '--porcelain')) { throw 'The handoff worktree has local changes.' }
        $null = Invoke-HandoffGit @('-C', $worktree, '-c', 'core.longpaths=true', 'merge', '--ff-only', $revision)
        if ((Invoke-HandoffGit @('-C', $worktree, 'rev-parse', 'HEAD')) -ne $revision) { throw 'The handoff worktree is ahead of the published commit.' }
    } else {
        $null = Invoke-HandoffGit @('-C', $root, '-c', 'core.longpaths=true', 'worktree', 'add', '--detach', $worktree, $revision)
    }

    $stage = 'verify'
    Write-Host '[2/2] Running the published test. Compilation may take several minutes.'
    Write-Host "Live logs: $logs"
    $pwsh = (Get-Process -Id $PID).Path
    $workflow = Join-Path $worktree 'scripts/win-arm64/current_handoff.ps1'
    $build = Join-Path $root 'build/win-arm64-native'
    $workflowArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $workflow,
        '-InstallDirectory', $InstallDirectory, '-BuildDirectory', $build, '-LogDirectory', $logs)
    if ($PSBoundParameters.ContainsKey('Route')) { $workflowArgs += @('-Route', $Route) }
    $status = Invoke-LoggedProcess $pwsh $workflowArgs 'workflow' 2100
    if ($status -ne 0) {
        $stderr = Join-Path $logs 'workflow.stderr.log'
        $stdout = Join-Path $logs 'workflow.stdout.log'
        $pattern = 'Tools still missing:|Access is denied|CMake Error|fatal error|error:|error [A-Z]+[0-9]+:'
        $errors = @(Select-String -Encoding UTF8 -LiteralPath $stderr,$stdout -Pattern $pattern -Context 0,2 |
            Select-Object -First 2 | ForEach-Object { $_.Line; $_.Context.PostContext })
        if (!$errors.Count) { $errors = @(Get-Content -Encoding UTF8 -Tail 6 -LiteralPath $stderr) }
        foreach ($line in $errors) {
            if ($line.Trim() -and !$summary.Contains($line.Trim())) { $summary.Add($line.Trim()) }
        }
        throw "Verification workflow exited with code $status."
    }
    $outcome = 'PASS'
} catch {
    foreach ($line in $lastGitDetails) { $summary.Add($line) }
    $summary.Add("Error: $($_.Exception.Message)")
} finally {
    if ($lock) { $lock.Dispose() }
    $details = Join-Path $logs 'workflow_summary.txt'
    if (Test-Path -LiteralPath $details -PathType Leaf) {
        foreach ($line in @(Get-Content -Encoding UTF8 -LiteralPath $details)) { $summary.Add($line) }
    }
    $report = Join-Path $logs 'handoff_report.txt'
    $summary.Insert(0, "Result: $outcome | Stage: $stage")
    $summary.Add("Logs: $logs")
    $summary | Set-Content -Encoding UTF8 -LiteralPath $report
    ''
    '===== VOXT SNAPDRAGON REPORT ====='
    $summary
    '===== END OF REPORT ====='
}
if ($outcome -ne 'PASS') { exit 1 }
