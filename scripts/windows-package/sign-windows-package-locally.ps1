<#
.SYNOPSIS
Signs CI-built Windows packages on the owner's own PC with the Certum certificate.

.DESCRIPTION
Use this when unattended CI signing is not wanted or not working. CI (with
WINDOWS_SIGNING_METHOD=certum-local) uploads the artifact
windows-msix-for-local-signing: unsigned x64 and ARM64 .msix packages and an
unsigned .msixbundle, all built with the certificate subject as Publisher, plus
their layouts. Download it, then on a Windows PC where the Certum certificate is
available (SimplySign Desktop logged in, or the cryptographic card in its
reader) run:

    ./scripts/windows-package/sign-windows-package-locally.ps1 -Artifact <download dir>

The script finds the Certum code signing certificate whose subject equals the
packages' Publisher (or -CertificateThumbprint), signs a copy of each package
and of the bundle with the pinned SignTool, timestamps at http://time.certum.pl,
reads each signature back, proves the payload is unchanged, and writes the
signed files and their receipts to -Output. It never exports or copies the key
and never uploads anything. Requires Windows PowerShell 5.1 or PowerShell 7 and
Python 3 on PATH. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Artifact,
    [string] $Output = (Join-Path (Get-Location) 'signed'),
    [ValidatePattern('^([0-9A-Fa-f]{40})?$')] [string] $CertificateThumbprint = '',
    [string] $TimestampUrl = 'http://time.certum.pl',
    [string] $ToolCache = (Join-Path $env:LOCALAPPDATA 'JustSpeakToIt-packaging-tools'),
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$artifact = (Resolve-Path -LiteralPath $Artifact).Path
$bundles = @(Get-ChildItem -LiteralPath $artifact -Filter '*_unsigned.msixbundle' -File)
$packages = @(Get-ChildItem -LiteralPath $artifact -Filter '*_unsigned.msix' -File)
if ($packages.Count -eq 0) { throw "No *_unsigned.msix packages in $artifact. Download the windows-msix-for-local-signing artifact." }
$publishers = @($packages + $bundles | ForEach-Object { (Read-JstiPackageIdentity $_.FullName).Publisher } | Sort-Object -Unique)
if ($publishers.Count -ne 1) { throw 'The packages do not share one publisher.' }
$publisher = $publishers[0]
if ($publisher -ceq (Read-JstiJson (Join-Path $PSScriptRoot 'package-identity.json')).identity.developerPublisher) {
    throw 'These are unsigned developer packages with the placeholder publisher. Use the windows-msix-for-local-signing artifact, built with WINDOWS_MSIX_PUBLISHER set to your certificate subject.'
}

$now = Get-Date
$candidates = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -ge $now -and
    ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }) -and
    ((-not $CertificateThumbprint -and $_.Subject -ceq $publisher) -or $_.Thumbprint -eq $CertificateThumbprint.ToUpperInvariant())
})
if ($candidates.Count -ne 1) {
    throw ("Found $($candidates.Count) valid code signing certificates for '$publisher'. Log in to SimplySign Desktop " +
           '(or insert the Certum card) and, if several match, pass -CertificateThumbprint.')
}
$certificate = $candidates[0]
if ($certificate.Subject -cne $publisher) {
    throw "Certificate subject '$($certificate.Subject)' differs from the packages' publisher '$publisher'."
}
Write-Host "Signing as $($certificate.Subject) [$($certificate.Thumbprint)], timestamped at $TimestampUrl."

New-Item -ItemType Directory -Force -Path $Output | Out-Null
$signedPackages = @()
foreach ($package in $packages) {
    $name = $package.Name -replace '_unsigned\.msix$', '.msix'
    $layout = Join-Path $artifact ($package.BaseName -replace '_unsigned$', '') | Join-Path -ChildPath 'layout'
    $arguments = @{
        Package = $package.FullName; Output = (Join-Path $Output $name); ToolCache = $ToolCache
        CertificateThumbprint = $certificate.Thumbprint; TimestampUrl = $TimestampUrl; Method = 'Certum (local)'
        Python = $Python
    }
    if (Test-Path -LiteralPath $layout) { $arguments.Layout = $layout }
    & (Join-Path $PSScriptRoot 'sign-windows-package.ps1') @arguments
    $signedPackages += (Join-Path $Output $name)
}
foreach ($bundle in $bundles) {
    $name = $bundle.Name -replace '_unsigned\.msixbundle$', '.msixbundle'
    # A bundle is signed as a whole; its inner packages stay the unsigned inputs it was built from.
    & (Join-Path $PSScriptRoot 'sign-windows-package.ps1') -Package $bundle.FullName -Output (Join-Path $Output $name) `
        -ToolCache $ToolCache -CertificateThumbprint $certificate.Thumbprint -TimestampUrl $TimestampUrl `
        -BundlePackages @($packages | ForEach-Object { $_.FullName }) -Method 'Certum (local)' -Python $Python
}
Write-Host "Signed $($packages.Count) package(s) and $($bundles.Count) bundle(s) into $Output. Nothing was uploaded."
Write-Host 'To describe a release, run update_channel.py on the signed bundle; publishing stays a separate, manual step.'
