<#
.SYNOPSIS
Builds the unsigned .msix for each runtime bundle, one .msixbundle holding them all, and the update-channel files.

.DESCRIPTION
Each -Bundles directory is a verified runtime bundle (the x64 cross-build's
windows-runtime-bundle, the ARM64 workflow's windows-runtime-bundle-arm64).
For each one this builds a layout at -Version with -Publisher (the certificate
subject, or the unsigned developer placeholder), packs it with the pinned
MakeAppx, then bundles every package into JustSpeakToIt-Developer_<version>_unsigned.msixbundle
and writes the App Installer file and winget template for the release asset
the signed bundle would become. Output layout:

    <Output>/JustSpeakToIt-Developer_<version>_<arch>/layout
    <Output>/JustSpeakToIt-Developer_<version>_<arch>_unsigned.msix
    <Output>/JustSpeakToIt-Developer_<version>_unsigned.msixbundle
    <Output>/update-channel/

Nothing is signed, uploaded or published. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string[]] $Bundles,
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [string] $Publisher,
    [string] $ExpectedCommit,
    [string] $Tag,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$output = [System.IO.Path]::GetFullPath($Output)
if ((Test-Path -LiteralPath $output) -and (Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1)) {
    throw "The output directory must be new or empty: $output"
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$log = Join-Path $output 'release-packages.log'
$stem = 'JustSpeakToIt-Developer'
$packages = @()
foreach ($bundle in $Bundles) {
    $evidence = Read-JstiJson (Join-Path (Resolve-Path -LiteralPath $bundle).Path 'bundle-evidence.json')
    $architecture = $evidence.architecture
    if (-not $architecture) { $architecture = 'x64' }
    $root = Join-Path $output "${stem}_${Version}_$architecture"
    $arguments = @((Join-Path $PSScriptRoot 'build-windows-package-layout.py'), '--bundle', $bundle, '--version', $Version,
                   '--output', $root)
    if ($ExpectedCommit) { $arguments += @('--expected-commit', $ExpectedCommit) }
    if ($Publisher) { $arguments += @('--publisher', $Publisher) }
    Invoke-JstiPython -Python $Python -LogPath $log -Arguments $arguments | Out-Null
    $package = Join-Path $output "${stem}_${Version}_${architecture}_unsigned.msix"
    & (Join-Path $PSScriptRoot 'pack-windows-package.ps1') -Layout (Join-Path $root 'layout') -Output $package `
        -ToolCache $ToolCache -Python $Python
    $packages += $package
}
$bundlePath = Join-Path $output "${stem}_${Version}_unsigned.msixbundle"
& (Join-Path $PSScriptRoot 'bundle-windows-packages.ps1') -Packages $packages -Output $bundlePath -ToolCache $ToolCache `
    -Python $Python
if (-not $Tag) { $Tag = "windows-developer-$Version" }
Invoke-JstiPython -Python $Python -LogPath $log -Arguments @(
    (Join-Path $PSScriptRoot 'update_channel.py'), '--package', $bundlePath, '--channel', 'developer', '--tag', $Tag,
    '--output', (Join-Path $output 'update-channel'), '--published-name', "${stem}_${Version}.msixbundle") | Out-Null
Write-Host "Built $($packages.Count) packages, $bundlePath and its update-channel preview. Nothing was signed or published."
