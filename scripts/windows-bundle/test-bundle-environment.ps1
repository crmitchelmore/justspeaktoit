$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BundleEnvironment.ps1')

# This script runs in its own PowerShell process. No environment values are
# printed; the sentinel verifies that clearing tooling cannot remove Env:.
$env:JSTI_BUNDLE_ENV_SENTINEL = 'preserved'
$originalPath = $env:Path
$originalRoot = $env:SystemRoot
Get-ChildItem Env: | Where-Object { $_.Name -like 'SWIFT*' } | Remove-Item

foreach ($hasSwift in @($false, $true)) {
    if ($hasSwift) { $env:SWIFT_BUNDLE_TEST = 'synthetic-toolchain' }
    $env:SDKROOT = 'synthetic-sdk'
    $env:DEVELOPER_DIR = 'synthetic-developer'
    $env:ICU_DATA = 'synthetic-data'
    Clear-BundleToolchainEnvironment
    if (Get-ChildItem Env: | Where-Object { $_.Name -like 'SWIFT*' }) { throw 'Swift variable survived.' }
    foreach ($name in @('SDKROOT', 'DEVELOPER_DIR', 'ICU_DATA')) {
        if (Test-Path -LiteralPath "Env:$name") { throw "Toolchain variable survived: $name" }
    }
    if ($env:JSTI_BUNDLE_ENV_SENTINEL -ne 'preserved' -or $env:Path -cne $originalPath -or
        $env:SystemRoot -cne $originalRoot) { throw 'Isolation removed an unrelated environment variable.' }
}
Write-Host 'Bundle environment isolation passed with and without Swift variables.'
