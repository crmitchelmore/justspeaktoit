<#
.SYNOPSIS
Packs a verified developer layout into an unsigned .msix with the pinned Windows SDK MakeAppx.

.DESCRIPTION
MakeAppx performs its full schema and semantic validation (no /nv) and writes a
SHA-256 block map. The independent Python reader then proves the package holds
exactly the layout's bytes. The output is unsigned: installing it requires
signing with a certificate whose subject equals the manifest publisher (see
sign-windows-package.ps1). Keep this file ASCII-only for Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Layout,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$layout = (Resolve-Path -LiteralPath $Layout).Path
$output = [System.IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $output) { throw "Refusing to replace an existing package: $output" }
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stem = [System.IO.Path]::GetFileNameWithoutExtension($output)
$log = Join-Path $directory "$stem.pack.log"
$verifier = Join-Path $PSScriptRoot 'verify-windows-package.py'

# The layout must still equal its package manifest before MakeAppx reads it.
$tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
$pack = Invoke-JstiTool -FilePath $tools.MakeAppx -LogPath $log `
    -Arguments @('pack', '/v', '/o', '/h', 'SHA256', '/d', $layout, '/p', $output)
if ($pack.ExitCode -ne 0) { throw "MakeAppx pack failed with exit code $($pack.ExitCode); see $log" }
$evidencePath = Join-Path $directory "$stem.verification.json"
Invoke-JstiPython -Python $Python -LogPath $log -Arguments @(
    $verifier, '--package', $output, '--layout', $layout, '--unsigned', '--evidence', $evidencePath) | Out-Null
$verification = Read-JstiJson $evidencePath
$record = [ordered]@{
    schemaVersion = 1
    package = $verification
    makeAppx = $tools.Evidence
    signed = $false
    status = 'Unsigned developer package. Installation needs an externally supplied signing certificate.'
}
Write-JstiJson (Join-Path $directory "$stem.pack.json") $record
Write-Host "Packed $($verification.payloadFiles) payload files into $output ($($verification.sha256))."
