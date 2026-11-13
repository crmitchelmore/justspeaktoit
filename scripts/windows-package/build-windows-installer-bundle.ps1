<#
.SYNOPSIS
Builds the unsigned beta or Microsoft Store .msixbundle (x64 and ARM64) from two verified runtime bundles.

.DESCRIPTION
Each runtime bundle directory (bundle-evidence.json and its ZIP) is
authenticated and laid out under the beta package identity
(package-identity-beta.json) with -Publisher, the exact subject of the signing
certificate. Each layout is packed with the pinned MakeAppx, then both packages
are bundled with the bundle version equal to the package version. The
independent Python reader proves the bundle holds exactly those two packages
under one identity. Signing is separate (sign-windows-installer.ps1). Keep
this file ASCII-only for Windows PowerShell 5.1.

-Channel store lays both packages out under the reserved Microsoft Store
identity (package-identity-store.json) instead. Its publisher is fixed by
Partner Center, so -Publisher may be omitted, and the bundle is never signed
here: the Store re-signs what it accepts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $X64Bundle,
    [Parameter(Mandatory = $true)] [string] $Arm64Bundle,
    [Parameter(Mandatory = $true)] [string] $ExpectedCommit,
    # An Alpha may reuse an equivalent runtime bundle built from an earlier
    # commit; each bundle is then checked against the commit it was built from.
    [string] $X64Commit = $ExpectedCommit,
    [string] $Arm64Commit = $ExpectedCommit,
    [Parameter(Mandatory = $true)] [string] $Version,
    [string] $Publisher,
    [ValidateSet('beta', 'store')] [string] $Channel = 'beta',
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

if ($Channel -eq 'store') {
    $reserved = (Read-JstiJson (Join-Path $PSScriptRoot 'package-identity-store.json')).identity.publisher
    if (-not $Publisher) { $Publisher = $reserved }
    if ($Publisher -cne $reserved) { throw "The store channel uses only its Partner Center publisher $reserved." }
    $prefix = 'JustSpeakToIt-store'
} else {
    if (-not $Publisher) { throw 'The beta channel needs -Publisher: the signing certificate subject.' }
    $prefix = 'JustSpeakToIt-windows'
}

$output = [System.IO.Path]::GetFullPath($Output)
if ((Test-Path -LiteralPath $output) -and (Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1)) {
    throw "Output must be a new or empty directory: $output"
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$log = Join-Path $output 'installer-bundle.log'
$packages = Join-Path $output 'packages'
New-Item -ItemType Directory -Force -Path $packages | Out-Null
$arguments = @()
foreach ($target in @(@{ Architecture = 'x64'; Bundle = $X64Bundle; Commit = $X64Commit },
        @{ Architecture = 'arm64'; Bundle = $Arm64Bundle; Commit = $Arm64Commit })) {
    $root = Join-Path $output ("layout-" + $target.Architecture)
    Invoke-JstiPython -Python $Python -LogPath $log -Arguments @(
        (Join-Path $PSScriptRoot 'build-windows-package-layout.py'), '--channel', $Channel, '--bundle', $target.Bundle,
        '--expected-commit', $target.Commit, '--version', $Version, '--publisher', $Publisher, '--output', $root) | Out-Null
    $evidence = Read-JstiJson (Join-Path $root 'package-layout-evidence.json')
    if ($evidence.package.architecture -ne $target.Architecture) {
        throw "The $($target.Architecture) input is a $($evidence.package.architecture) runtime bundle."
    }
    $package = Join-Path $packages ("{0}_{1}_{2}.msix" -f $prefix, $Version, $target.Architecture)
    & (Join-Path $PSScriptRoot 'pack-windows-package.ps1') -Layout (Join-Path $root 'layout') -Output $package `
        -ToolCache $ToolCache -Python $Python
    $arguments += @('--package', ("{0}={1}" -f $target.Architecture, $package))
}
# Only the two packages may be in the directory MakeAppx bundles.
Get-ChildItem -LiteralPath $packages -File | Where-Object { $_.Extension -ne '.msix' } | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination $output
}
$bundle = Join-Path $output ("{0}_{1}_unsigned.msixbundle" -f $prefix, $Version)
$tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
$result = Invoke-JstiTool -FilePath $tools.MakeAppx -LogPath $log `
    -Arguments @('bundle', '/v', '/o', '/bv', $Version, '/d', $packages, '/p', $bundle)
Assert-JstiMakeAppxPackSucceeded -Result $result -LogPath $log
$evidencePath = Join-Path $output 'installer-bundle.verification.json'
Invoke-JstiPython -Python $Python -LogPath $log -Arguments (@(
    (Join-Path $PSScriptRoot 'windows-installer.py'), 'verify-bundle', '--bundle', $bundle, '--publisher', $Publisher,
    '--version', $Version, '--unsigned', '--channel', $Channel, '--evidence', $evidencePath) + $arguments) | Out-Null
Write-JstiJson (Join-Path $output 'installer-bundle.json') ([ordered]@{
    schemaVersion = 1
    bundle = Read-JstiJson $evidencePath
    sourceCommit = $ExpectedCommit
    bundleCommits = [ordered]@{ x64 = $X64Commit; arm64 = $Arm64Commit }
    makeAppx = $tools.Evidence
    channel = $Channel
    status = $(if ($Channel -eq 'store') { 'Unsigned Microsoft Store bundle. The Store signs what it accepts.' }
        else { 'Unsigned bundle. Publication requires a publicly trusted, timestamped signature.' })
})
Write-Host "Bundled x64 and ARM64 $Channel packages $Version into $bundle."
