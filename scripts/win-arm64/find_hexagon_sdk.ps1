# Resolve an installed SDK, including a user/machine setting newer than this shell.
$roots = @(foreach ($scope in @('Process', 'User', 'Machine')) {
    $value = [Environment]::GetEnvironmentVariable('HEXAGON_SDK_ROOT', $scope)
    if ($value) { [Environment]::ExpandEnvironmentVariables($value.Trim('"')) }
})
if ($env:HEXAGON_TOOLS_ROOT -and (Test-Path -LiteralPath $env:HEXAGON_TOOLS_ROOT -PathType Container)) {
    $dir = Get-Item -LiteralPath $env:HEXAGON_TOOLS_ROOT
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'hexagon_sdk.json') -PathType Leaf) {
            $roots += $dir.FullName
            break
        }
        $dir = $dir.Parent
    }
}
foreach ($base in @($env:SystemDrive, $env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique) {
    $roots += "$base/Qualcomm/Hexagon_SDK"
}
foreach ($root in ($roots | Select-Object -Unique)) {
    if (!(Test-Path -LiteralPath $root -PathType Container)) { continue }
    if (Test-Path -LiteralPath (Join-Path $root 'build/cmake/hexagon_fun.cmake') -PathType Leaf) {
        return (Resolve-Path -LiteralPath $root).Path
    }
    $versions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and [version]$_.Name -ge [version]'6.7' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($version in $versions) {
        if (Test-Path -LiteralPath (Join-Path $version.FullName 'build/cmake/hexagon_fun.cmake') -PathType Leaf) {
            return $version.FullName
        }
    }
}
throw "Hexagon SDK not found. Checked: $($roots -join ', '). Set HEXAGON_SDK_ROOT to the installed 6.7+ SDK directory containing build/cmake/hexagon_fun.cmake."
