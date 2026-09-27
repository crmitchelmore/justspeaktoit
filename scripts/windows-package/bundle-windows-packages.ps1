<#
.SYNOPSIS
Bundles one .msix per architecture into a single unsigned .msixbundle with the pinned MakeAppx.

.DESCRIPTION
Every input must share one package name, publisher and version and have its own
processor architecture (x64 and arm64). MakeAppx writes the bundle with full
validation; the independent Python reader then proves each bundled package is
its input byte for byte and that the bundle manifest describes them. Windows
installs only the package matching the PC from the bundle. A package family
may move from single .msix files to a bundle, never back. The output is
unsigned; sign it with sign-windows-package.ps1. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string[]] $Packages,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$output = [System.IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $output) { throw "Refusing to replace an existing bundle: $output" }
if (-not $output.EndsWith('.msixbundle', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The bundle must be an .msixbundle file.'
}
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stem = [System.IO.Path]::GetFileNameWithoutExtension($output)
$log = Join-Path $directory "$stem.bundle.log"

$inputs = @($Packages | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
$identities = @($inputs | ForEach-Object { Read-JstiPackageIdentity $_ })
$versions = @($identities | ForEach-Object { $_.Version } | Sort-Object -Unique)
if ($versions.Count -ne 1) { throw 'Every bundled package must have the same version.' }

# MakeAppx bundles every package in one directory; stage exactly the inputs.
$staging = Join-Path $directory "$stem.bundle-input"
if (Test-Path -LiteralPath $staging) { throw "Refusing to reuse $staging" }
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($package in $inputs) { Copy-Item -LiteralPath $package -Destination $staging }
    $tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
    $bundle = Invoke-JstiTool -FilePath $tools.MakeAppx -LogPath $log `
        -Arguments @('bundle', '/v', '/bv', $versions[0], '/d', $staging, '/p', $output)
    if ($bundle.ExitCode -ne 0) { throw "MakeAppx bundle failed with exit code $($bundle.ExitCode); see $log" }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
$evidencePath = Join-Path $directory "$stem.verification.json"
$arguments = @((Join-Path $PSScriptRoot 'verify-windows-msixbundle.py'), '--bundle', $output, '--unsigned',
               '--evidence', $evidencePath)
foreach ($package in $inputs) { $arguments += @('--package', $package) }
Invoke-JstiPython -Python $Python -LogPath $log -Arguments $arguments | Out-Null
$verification = Read-JstiJson $evidencePath
Write-JstiJson (Join-Path $directory "$stem.bundle.json") ([ordered]@{
    schemaVersion = 1
    bundle = $verification
    makeAppx = $tools.Evidence
    signed = $false
    status = 'Unsigned bundle. Installation needs a signature whose subject equals the publisher.'
})
Write-Host "Bundled $($inputs.Count) packages into $output ($($verification.sha256))."
