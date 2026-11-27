[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$LogDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_tool_download.ps1')
$release = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'desktop_pilot.json') | ConvertFrom-Json
$repo = Split-Path -Parent (Split-Path -Parent $BuildDirectory)
$base = (New-Item -ItemType Directory -Force -Path (Join-Path $repo '.local/voxt-user-test')).FullName
$dest = Join-Path $base $release.tag
$notes = [Collections.Generic.List[string]]::new()
$stage = $null
try {
    if (Test-Path -LiteralPath $dest) {
        try {
            $null = & (Join-Path $dest 'open_voxt_user_test.ps1') -VerifyOnly
        } catch {
            $saved = "$dest.incomplete-$([guid]::NewGuid().ToString('N'))"
            Write-Host "[voxt] Repairing incomplete pilot ($($_.Exception.Message)). Previous files: $saved"
            [IO.Directory]::Move($dest,$saved)
        }
    }
    if (!(Test-Path -LiteralPath $dest)) {
        $stage = (New-Item -ItemType Directory -Path (Join-Path $base ([guid]::NewGuid().ToString('N')))).FullName
        Write-Host '[voxt] Resolving the verified all-HTP backend and models.'
        $backendScript = Join-Path $PSScriptRoot 'start_user_backend.ps1'
        $params = @{ InstallDirectory=$InstallDirectory; BuildDirectory=$BuildDirectory }
        # Reuse Pilot 1's completed device test only for the same verified native
        # binaries, signed DSP pair and GGUFs. ResolveOnly checks the source hashes.
        $previous = Join-Path $base 'voxt-snapdragon-user-test-1/pilot.json'
        $reuseBackend = $false
        $nativeManifest = Get-Content -Raw -LiteralPath (Join-Path $BuildDirectory 'hexagon/verify_native_manifest.json') | ConvertFrom-Json
        $assets = Get-Content -Raw -LiteralPath (Join-Path $InstallDirectory 'verify_manifest.json') | ConvertFrom-Json
        $lock = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../sources.lock.json') | ConvertFrom-Json
        if (Test-Path -LiteralPath $previous -PathType Leaf) {
            try {
                $prior = Get-Content -Raw -LiteralPath $previous | ConvertFrom-Json
                $reuseBackend = $prior.Tag -eq 'voxt-snapdragon-user-test-1'
                foreach ($name in 'qwen3_asr_server.exe','OpenCL.dll') {
                    $reuseBackend = $reuseBackend -and $prior.Files.("backend/$name") -eq $nativeManifest.files.$name
                }
                foreach ($name in 'models/target.gguf','models/mmproj.gguf','models/draft-4.gguf') {
                    $reuseBackend = $reuseBackend -and $prior.Files.$name -eq $assets.files.$name
                }
                foreach ($f in $lock.geniex_htp.files.PSObject.Properties) {
                    $reuseBackend = $reuseBackend -and $prior.Files.("ops/$($f.Name)") -eq $f.Value
                }
            } catch { $reuseBackend = $false }
        }
        if ($reuseBackend) {
            $cfg = & $backendScript @params -ResolveOnly
            Write-Host '[voxt] Reusing the matching all-HTP backend test from Pilot 1.'
            $notes.Add('All-HTP backend self-check: reused verified Pilot 1 result')
        } else {
            Write-Host '[voxt] Checking one public recording on the frozen backend.'
            $cfg = & $backendScript @params -LogDirectory $LogDirectory -PassThru
            $notes.Add('All-HTP Q8 Target + Q4 DFlash + original audio layout | backend transcription self-check: PASS')
        }

        $archive = Join-Path $stage 'desktop.zip'
        $url = "https://github.com/ShiaoZhuang/voxt-snapdragon-asr/releases/download/$($release.tag)/$($release.asset)"
        Write-Host '[voxt] Fetching the pinned Windows ARM64 Voxt desktop bundle.'
        $download = Invoke-PinnedPackageCurl (Get-Command curl.exe -CommandType Application | Select-Object -First 1).Source $url $archive 300 30
        if ($download.Code -ne 0) { throw "Desktop download: $($download.Detail)" }
        if ((Get-FileHash -LiteralPath $archive).Hash -ne $release.sha256) { throw 'Voxt desktop archive hash mismatch.' }
        $desktop = Join-Path $stage 'desktop'
        Expand-Archive -LiteralPath $archive -DestinationPath $desktop
        Remove-Item -LiteralPath $archive
        $bin = (New-Item -ItemType Directory -Path (Join-Path $stage 'backend')).FullName
        $hashes = [ordered]@{}
        foreach ($file in 'qwen3_asr_server.exe','OpenCL.dll') {
            Copy-Item -LiteralPath (Join-Path (Split-Path $cfg.Server) $file) -Destination $bin
            $sha = (Get-FileHash -LiteralPath (Join-Path $bin $file)).Hash
            if ($sha -ne $nativeManifest.files.$file) { throw "Snapshot hash mismatch: $file" }
            $hashes["backend/$file"] = $sha
        }
        # Keep the signed DSP executable and its catalog together, independent of GenieX updates.
        $ops = (New-Item -ItemType Directory -Path (Join-Path $stage 'ops')).FullName
        foreach ($f in $lock.geniex_htp.files.PSObject.Properties) {
            Copy-Item -LiteralPath (Join-Path $cfg.Environment.GGML_HEXAGON_LIBHTP_DIR $f.Name) -Destination $ops
            if ((Get-FileHash -LiteralPath (Join-Path $ops $f.Name)).Hash -ne $f.Value) { throw "DSP snapshot hash mismatch: $($f.Name)" }
            $hashes["ops/$($f.Name)"] = $f.Value
        }
        foreach ($file in 'Voxt.exe','voxtnew-helper.exe','mygo-sqlite3.dll') {
            $hashes["desktop/$file"] = (Get-FileHash -LiteralPath (Join-Path $desktop $file)).Hash
        }
        $models = (New-Item -ItemType Directory -Path (Join-Path $stage 'models')).FullName
        foreach ($name in 'target.gguf','mmproj.gguf','draft-4.gguf') {
            $from = Join-Path $cfg.Models $name
            $to = Join-Path $models $name
            try { New-Item -ItemType HardLink -Path $to -Target $from -ErrorAction Stop | Out-Null }
            catch { Copy-Item -LiteralPath $from -Destination $to }
            $hashes["models/$name"] = $assets.files.("models/$name")
        }
        $cfg.Environment.VOXT_SNAPDRAGON_MODELS = Join-Path $dest 'models'
        $cfg.Environment.GGML_HEXAGON_LIBHTP_DIR = Join-Path $dest 'ops'
        $cfg.Environment.VOXTNEW_OMNI_RUNTIME = Join-Path $dest 'backend/qwen3_asr_server.exe'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'open_voxt_user_test.ps1') -Destination $stage
        @{ Tag=$release.tag; Files=$hashes; Environment=$cfg.Environment; RemoveEnvironment=$cfg.RemoveEnvironment } |
            ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $stage 'pilot.json')
        [IO.Directory]::Move($stage,$dest)
        $stage = $null
    }
    $start = Join-Path $dest 'open_voxt_user_test.ps1'
    $shortcuts = [Environment]::GetFolderPath('DesktopDirectory')
    if ($shortcuts -and (Test-Path -LiteralPath $shortcuts)) {
        try {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $shortcuts 'Voxt Snapdragon Pilot 1.lnk'))
            $shortcut.TargetPath = (Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source
            $shortcut.Arguments = '-NoLogo -NoProfile -File "' + $start + '"'
            $shortcut.WorkingDirectory = $dest
            $shortcut.IconLocation = (Join-Path $dest 'desktop/Voxt.exe') + ',0'
            $shortcut.Save()
            $notes.Add('Daily launch: desktop shortcut Voxt Snapdragon Pilot 1')
        } catch { $notes.Add("Shortcut unavailable: $($_.Exception.Message)") }
    }
    & $start
    $notes.Add("Voxt ARM64 desktop | $($release.tag) | open: $start")
    $notes.Add('User check: focus Notepad, tap Caps Lock, speak, tap Caps Lock again. Check the text and Voxt History.')
} catch {
    $notes.Add("Desktop pilot INCOMPLETE | $($_.Exception.Message)")
    throw
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -Recurse -Force -LiteralPath $stage }
    $notes | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $LogDirectory 'workflow_summary.txt')
}
