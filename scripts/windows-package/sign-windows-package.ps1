<#
.SYNOPSIS
Signs a copy of an unsigned developer .msix with an externally supplied certificate.

.DESCRIPTION
The certificate must already be in a Windows certificate store with its private
key (a hardware token or key storage provider may hold the key). This script
never creates, imports, exports or reads key material: it passes only the
thumbprint to the pinned SignTool. The certificate subject must equal the
manifest publisher exactly; rebuild the layout with --publisher otherwise. The
unsigned input is never modified. Supply -TimestampUrl for anything that must
stay valid after the certificate expires. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Package,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string] $CertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')] [string] $CertificateStoreLocation = 'CurrentUser',
    [string] $TimestampUrl,
    [string] $Layout,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$package = (Resolve-Path -LiteralPath $Package).Path
$output = [System.IO.Path]::GetFullPath($Output)
if ($output -eq $package) { throw 'Sign a copy; the unsigned developer package must stay unchanged.' }
if (Test-Path -LiteralPath $output) { throw "Refusing to replace an existing file: $output" }
if ($TimestampUrl -and $TimestampUrl -notmatch '^https?://') { throw 'The timestamp URL must be an RFC 3161 HTTP(S) URL.' }
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stem = [System.IO.Path]::GetFileNameWithoutExtension($output)
$log = Join-Path $directory "$stem.sign.log"

$identity = Read-JstiPackageIdentity $package
$certificate = Get-Item -LiteralPath ("Cert:\$CertificateStoreLocation\My\$CertificateThumbprint") -ErrorAction SilentlyContinue
if (-not $certificate) { throw "No certificate $CertificateThumbprint in $CertificateStoreLocation\My." }
if (-not $certificate.HasPrivateKey) { throw 'The signing certificate has no accessible private key.' }
if ($certificate.Subject -cne $identity.Publisher) {
    throw "Certificate subject '$($certificate.Subject)' must equal the manifest publisher '$($identity.Publisher)'. Rebuild the layout with --publisher set to the certificate subject."
}
$now = Get-Date
if ($certificate.NotBefore -gt $now -or $certificate.NotAfter -lt $now) { throw 'The signing certificate is not currently valid.' }
if (-not ($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) {
    throw 'The signing certificate lacks the code signing extended key usage.'
}
$unsignedDigest = Get-JstiSha256 $package

$tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
Copy-Item -LiteralPath $package -Destination $output
$arguments = @('sign', '/v', '/fd', 'SHA256', '/sha1', $CertificateThumbprint, '/s', 'My')
if ($CertificateStoreLocation -eq 'LocalMachine') { $arguments += '/sm' }
if ($TimestampUrl) { $arguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
$sign = Invoke-JstiTool -FilePath $tools.SignTool -LogPath $log -Arguments ($arguments + @($output))
if ($sign.ExitCode -ne 0) {
    Remove-Item -LiteralPath $output -Force
    throw "SignTool failed with exit code $($sign.ExitCode); see $log"
}
if ((Get-JstiSha256 $package) -ne $unsignedDigest) { throw 'The unsigned input changed while signing.' }

$verification = $null
if ($Layout) {
    $evidencePath = Join-Path $directory "$stem.verification.json"
    Invoke-JstiPython -Python $Python -LogPath $log -Arguments @(
        (Join-Path $PSScriptRoot 'verify-windows-package.py'), '--package', $output, '--layout', $Layout,
        '--signed', '--unsigned-reference', $package, '--evidence', $evidencePath) | Out-Null
    $verification = Read-JstiJson $evidencePath
}
$record = [ordered]@{
    schemaVersion = 1
    unsignedPackage = [ordered]@{ name = [System.IO.Path]::GetFileName($package); sha256 = $unsignedDigest }
    signedPackage = [ordered]@{ name = [System.IO.Path]::GetFileName($output); sha256 = Get-JstiSha256 $output }
    publisher = $identity.Publisher
    certificate = [ordered]@{
        thumbprint = $certificate.Thumbprint; subject = $certificate.Subject; issuer = $certificate.Issuer
        notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o'); store = "$CertificateStoreLocation\My"
    }
    timestamped = [bool] $TimestampUrl
    signTool = $tools.Evidence.tools['signtool.exe']
    verification = $verification
}
Write-JstiJson (Join-Path $directory "$stem.sign.json") $record
Write-Host "Signed $output with $($certificate.Thumbprint) for publisher $($identity.Publisher)."
