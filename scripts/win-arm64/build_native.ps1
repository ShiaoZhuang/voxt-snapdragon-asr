[CmdletBinding()]
param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '../../build/win-arm64-native'),
    [ValidateRange(1,64)][int]$Jobs = 6,
    [switch]$ToolchainCheck,
    [switch]$BackendOnly,
    [switch]$Hexagon
)

$ErrorActionPreference = 'Stop'
$osArch = $env:PROCESSOR_ARCHITEW6432
if (!$osArch) { $osArch = $env:PROCESSOR_ARCHITECTURE }
if ($env:OS -ne 'Windows_NT' -or $osArch -ne 'ARM64') {
    throw 'Run this script on Windows ARM64.'
}
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$programRoots = @(${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique
$vsInstall = $env:VSINSTALLDIR
if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') {
    if (!$vsInstall) {
        $vswhere = (Get-Command vswhere.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (!$vswhere) {
            $vswhere = $programRoots | ForEach-Object { Join-Path $_ 'Microsoft Visual Studio/Installer/vswhere.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        }
        if ($vswhere) {
            $vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath |
                Select-Object -First 1
        }
    }
    if ($vsInstall) {
        $devShell = Join-Path $vsInstall 'Common7/Tools/Launch-VsDevShell.ps1'
        if (Test-Path -LiteralPath $devShell -PathType Leaf) {
            & $devShell -Arch arm64 -SkipAutomaticLocation | Out-Host
        }
    }
}

# Keep the active PATH first and fill in tools installed in standard locations.
$toolDirs = @(foreach ($programRoot in $programRoots) {
    Join-Path $programRoot 'Go/bin'
    Join-Path $programRoot 'CMake/bin'
    Join-Path $programRoot 'LLVM/bin'
})
if ($env:LOCALAPPDATA) { $toolDirs += Join-Path $env:LOCALAPPDATA 'Programs/Go/bin' }
if ($vsInstall) {
    $toolDirs += @(
        (Join-Path $vsInstall 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin')
        (Join-Path $vsInstall 'Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja')
        (Join-Path $vsInstall 'VC/Tools/Llvm/ARM64/bin')
        (Join-Path $vsInstall 'VC/Tools/Llvm/bin')
        (Join-Path $vsInstall 'VC/Tools/Llvm/x64/bin')
    )
}
$pathDirs = @($env:PATH -split [IO.Path]::PathSeparator)
$env:PATH = ($pathDirs + @($toolDirs | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) | Select-Object -Unique) -join [IO.Path]::PathSeparator

Write-Host "Visual Studio: $vsInstall | target: $($env:VSCMD_ARG_TGT_ARCH)"
$toolNames = @('git', 'cmake', 'ninja', 'clang', 'clang++', 'python')
if (!$BackendOnly) { $toolNames += 'go' }
$missing = @(foreach ($name in $toolNames) {
    $tool = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tool) { Write-Host "  $name = $($tool.Source)" }
    else { $name }
})
$problems = @()
if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') {
    $problems += 'Visual Studio ARM64 environment unavailable. Open your installed Developer PowerShell with the ARM64 target.'
}
if ($missing.Count) { $problems += "Tools still missing: $($missing -join ', '). Check approved installations or PATH." }
if ($missing -contains 'clang' -or $missing -contains 'clang++') {
    $problems += 'The pinned Windows ARM64 OpenCL backend requires Clang. Use the approved Visual Studio C++ Clang Compiler for Windows component or an approved LLVM installation.'
}
if ($problems.Count) { throw ($problems -join [Environment]::NewLine) }
if ($ToolchainCheck) {
    Write-Output 'Toolchain commands found. Run again without -ToolchainCheck to build.'
    return
}

function Invoke-BuildTool([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

function Get-PinnedSource([string]$Name, [string]$Repo, [string]$Revision) {
    $path = Join-Path $build "src/$Name-$($Revision.Substring(0,12))"
    if (!(Test-Path -LiteralPath $path)) {
        $stage = "$path-$([guid]::NewGuid())"
        try {
            Invoke-BuildTool git @('-c', 'core.longpaths=true', 'init', '-q', $stage) | Out-Host
            Invoke-BuildTool git @('-C', $stage, 'fetch', '--depth=1', '--no-tags', $Repo, $Revision) | Out-Host
            Invoke-BuildTool git @('-C', $stage, '-c', 'core.autocrlf=false', '-c', 'core.longpaths=true', 'checkout', '--detach', 'FETCH_HEAD') | Out-Host
            if ((Invoke-BuildTool git @('-C', $stage, 'rev-parse', 'HEAD')) -ne $Revision) { throw "Unexpected revision for $Name" }
            Move-Item -LiteralPath $stage -Destination $path
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    }
    if ((Invoke-BuildTool git @('-C', $path, 'rev-parse', 'HEAD')) -ne $Revision) { throw "Unexpected revision for $Name at $path" }
    return $path
}

function Assert-Arm64PE([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Missing MZ header: $Path" }
        $reader.BaseStream.Position = 0x3C
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xAA64) { throw "Expected native ARM64 PE: $Path" }
    } finally { $reader.Dispose() }
}

$build = (New-Item -ItemType Directory -Path $BuildDirectory -Force).FullName
$null = New-Item -ItemType Directory -Path (Join-Path $build 'src') -Force
$product = $build
if ($Hexagon) {
    $product = Join-Path $build 'hexagon'
    $sdk = $env:HEXAGON_SDK_ROOT
    if (!$sdk) {
        $candidate = Get-ChildItem -Path "$($env:SystemDrive)/Qualcomm/Hexagon_SDK/*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'build/cmake/hexagon_fun.cmake') } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($candidate) { $sdk = $candidate.FullName }
    }
    if (!$sdk -or !(Test-Path -LiteralPath (Join-Path $sdk 'build/cmake/hexagon_fun.cmake'))) {
        throw 'Hexagon SDK unavailable. Configure the installed Hexagon SDK 6.7+ with HEXAGON_SDK_ROOT.'
    }
}
$bin = (New-Item -ItemType Directory -Path (Join-Path $product 'bin') -Force).FullName
$lock = Get-Content -Raw -LiteralPath (Join-Path $root 'sources.lock.json') | ConvertFrom-Json
$patchSource = Join-Path $root 'patches/llama-voxt.patch'
$patch = Join-Path $build 'llama-voxt.patch'
# Existing worktrees may still have CRLF even after Git's attributes change.
$patchText = [IO.File]::ReadAllText($patchSource).Replace("`r`n", "`n")
[IO.File]::WriteAllText($patch, $patchText, [Text.UTF8Encoding]::new($false))
$patchId = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.Substring(0,12).ToLowerInvariant()
$python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
$clangVersion = (Invoke-BuildTool clang @('--version') | Select-Object -First 1)
$sourceCommit = Invoke-BuildTool git @('-C', $root, 'rev-parse', 'HEAD')
$llamaRevision = $lock.llama_cpp.commit
$llamaRepo = $lock.llama_cpp.repo
$revisionId = $llamaRevision.Substring(0,12)
$sourceRoot = Join-Path $build 'src'
if (!(Test-Path -LiteralPath (Join-Path $sourceRoot "llama-$patchId-$revisionId"))) {
    $cached = Get-ChildItem -LiteralPath $sourceRoot -Filter "llama-*-$revisionId" -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container } | Select-Object -First 1
    if ($cached -and (Invoke-BuildTool git @('-C', $cached.FullName, 'rev-parse', 'HEAD')) -eq $llamaRevision) {
        $llamaRepo = $cached.FullName
        Write-Host "Reusing cached llama.cpp source at $llamaRepo"
    }
}
$llama = Get-PinnedSource "llama-$patchId" $llamaRepo $llamaRevision
$changes = @(Invoke-BuildTool git @('-C', $llama, 'status', '--porcelain'))
if (!$changes.Count) {
    Invoke-BuildTool git @('-C', $llama, '-c', 'core.autocrlf=false', 'apply', '--whitespace=nowarn', $patch)
} else {
    Invoke-BuildTool git @('-C', $llama, '-c', 'core.autocrlf=false', 'apply', '--reverse', '--check', $patch)
}
$headers = Get-PinnedSource 'OpenCL-Headers' $lock.opencl.headers.repo $lock.opencl.headers.commit
$icd = Get-PinnedSource 'OpenCL-ICD-Loader' $lock.opencl.loader.repo $lock.opencl.loader.commit
$toolchainVersion = $clangVersion
$fileNames = @('qwen3_asr_server.exe', 'OpenCL.dll')
if (!$BackendOnly) {
    $voxt = Get-PinnedSource 'sglang-omni' $lock.voxt.repo $lock.voxt.public_commit

    # Prepare the current runner sources afresh, with Git downloads cached separately.
    $runnerSource = Join-Path $build ('runner-source-' + [guid]::NewGuid())
    $previousGoEnv = @{}
    foreach ($name in @('GOOS', 'GOARCH', 'CGO_ENABLED', 'GOTOOLCHAIN')) { $previousGoEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        Invoke-BuildTool $python @((Join-Path $root 'scripts/prepare_benchmark.py'), '--voxt-repo', $voxt, '--destination', $runnerSource, '--runner-only')
        $env:GOOS = 'windows'
        $env:GOARCH = 'arm64'
        $env:CGO_ENABLED = '0'
        $env:GOTOOLCHAIN = 'local'
        $goVersion = Invoke-BuildTool go @('version')
        Invoke-BuildTool go @('-C', (Join-Path $runnerSource 'Voxt'), 'build', '-mod=readonly', '-o', (Join-Path $bin 'final-benchmark.exe'), './cmd/final-benchmark')
        $toolchainVersion += " | $goVersion"
        $fileNames += 'final-benchmark.exe'
    } finally {
        foreach ($name in $previousGoEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $previousGoEnv[$name]) }
        if (Test-Path -LiteralPath $runnerSource) { Remove-Item -LiteralPath $runnerSource -Recurse -Force }
    }
}

$toolchain = Join-Path $llama 'cmake/arm64-windows-llvm.cmake'
$cmakeFlags = @('-G', 'Ninja', "-DCMAKE_TOOLCHAIN_FILE=$toolchain", '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_C_FLAGS=-D_WIN32_WINNT=0x0A00', '-DCMAKE_CXX_FLAGS=-D_WIN32_WINNT=0x0A00')
$icdBuild = Join-Path $build 'opencl'
Invoke-BuildTool cmake (@('-S', $icd, '-B', $icdBuild) + $cmakeFlags + @(
    "-DOPENCL_ICD_LOADER_HEADERS_DIR=$headers", '-DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=ON',
    '-DBUILD_TESTING=OFF', '-DOPENCL_ICD_LOADER_BUILD_TESTING=OFF'))
Invoke-BuildTool cmake @('--build', $icdBuild, '--target', 'OpenCL', '--parallel', "$Jobs")

$llamaBuild = Join-Path $build "llama-$patchId"
$backendFlags = @('-DGGML_NATIVE=OFF', '-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod', '-DGGML_OPENMP=OFF',
    '-DGGML_OPENCL=ON', '-DGGML_OPENCL_USE_ADRENO_KERNELS=ON')
if ($Hexagon) {
    $llamaBuild = Join-Path $product "llama-$patchId"
    # Use the driver's installed skels or a matching approved catalog and skels
    # supplied via GGML_HEXAGON_LIBHTP_DIR. The upstream signing target also
    # supports a certificate already configured for building these ops.
    $backendFlags += @('-DGGML_HEXAGON=ON', '-DPREBUILT_LIB_DIR=windows_aarch64', "-DHEXAGON_SDK_ROOT=$sdk",
        "-DHEXAGON_TOOLS_ROOT=$env:HEXAGON_TOOLS_ROOT", "-DGGML_HEXAGON_HTP_CERT=$env:HEXAGON_HTP_CERT")
}
Invoke-BuildTool cmake (@('-S', $llama, '-B', $llamaBuild) + $cmakeFlags + $backendFlags + @(
    '-DBUILD_SHARED_LIBS=OFF', "-DOpenCL_INCLUDE_DIR=$headers", "-DOpenCL_LIBRARY=$(Join-Path $icdBuild 'OpenCL.lib')",
    "-DPython3_EXECUTABLE=$python", "-DLLAMA_VOXT_SOURCE=$(Join-Path $root 'native')", "-DLLAMA_BUILD_COMMIT=$($lock.llama_cpp.commit)",
    '-DLLAMA_BUILD_NUMBER=0', '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_TOOLS=ON',
    '-DLLAMA_BUILD_SERVER=ON', '-DLLAMA_BUILD_BORINGSSL=OFF', '-DLLAMA_OPENSSL=OFF', '-DLLAMA_BUILD_UI=OFF', '-DLLAMA_USE_PREBUILT_UI=OFF'))
Invoke-BuildTool cmake @('--build', $llamaBuild, '--target', 'qwen3_asr_server', '--parallel', "$Jobs")
Copy-Item -LiteralPath (Join-Path $llamaBuild 'bin/qwen3_asr_server.exe'), (Join-Path $icdBuild 'OpenCL.dll') -Destination $bin -Force

$files = [ordered]@{}
foreach ($name in $fileNames) {
    $path = Join-Path $bin $name
    Assert-Arm64PE $path
    $files[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest = [ordered]@{
    commit=$sourceCommit; llama_cpp=$lock.llama_cpp.commit
    opencl_loader=$lock.opencl.loader.commit; opencl_headers=$lock.opencl.headers.commit
    toolchain=$toolchainVersion; build=($backendFlags -notlike '-DGGML_HEXAGON_HTP_CERT=*') -join ' '; files=$files
}
if ($Hexagon -and $env:HEXAGON_HTP_CERT) {
    $ops = Join-Path $llamaBuild 'ggml/src/ggml-hexagon'
    if (!(Test-Path -LiteralPath (Join-Path $ops 'libggml-htp.cat'))) { throw 'Signed GGML HTP catalog missing after build.' }
    $manifest.htp_ops = $ops
}
if (!$BackendOnly) { $manifest.voxt = $lock.voxt.public_commit }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $product 'verify_native_manifest.json')
Write-Output "Native ARM64 build ready at: $product"
