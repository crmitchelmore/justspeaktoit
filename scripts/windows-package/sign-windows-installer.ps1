<#
.SYNOPSIS
Signs a copy of the unsigned beta .msixbundle and proves the signature, publisher and payload.

.DESCRIPTION
Two signers share one verification path:

* -Metadata: Azure Artifact Signing through the pinned dlib (the published
  route; see sign-windows-package-artifact-signing.ps1 for the credential model);
* -CertificateThumbprint: a certificate already in CurrentUser\My. Alone, it is
  the CI rehearsal's ephemeral certificate. With -PublicCertificate it is a
  publicly trusted certificate whose key a provider exposes through the store
  (SSL.com eSigner CKA; see load-sslcom-esigner.ps1), named by -Method.

Every Artifact Signing and -PublicCertificate signature is RFC 3161
timestamped and verified against this machine's trust. The signer subject
read back from AppxSignature.p7x must equal the bundle publisher, and the
signed bundle must still hold exactly the bundled packages. SignTool signs the
bundle; the packages inside are covered by its block map and are not signed
separately. The unsigned input is never modified. Keep this file ASCII-only.
#>
[CmdletBinding(DefaultParameterSetName = 'ArtifactSigning')]
param(
    [Parameter(Mandatory = $true)] [string] $Bundle,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $Packages,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true, ParameterSetName = 'ArtifactSigning')] [string] $Metadata,
    [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')] [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string] $CertificateThumbprint,
    [Parameter(ParameterSetName = 'Certificate')] [switch] $PublicCertificate,
    [Parameter(ParameterSetName = 'Certificate')] [string] $Method = 'CI rehearsal certificate',
    [string] $TimestampUrl = 'http://timestamp.acs.microsoft.com',
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$bundle = (Resolve-Path -LiteralPath $Bundle).Path
$output = [System.IO.Path]::GetFullPath($Output)
if ($output -eq $bundle) { throw 'Sign a copy; the unsigned bundle must stay unchanged.' }
if (Test-Path -LiteralPath $output) { throw "Refusing to replace an existing file: $output" }
if ($TimestampUrl -notmatch '^https?://') { throw 'The timestamp URL must be an RFC 3161 HTTP(S) URL.' }
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stem = [System.IO.Path]::GetFileNameWithoutExtension($output)
$log = Join-Path $directory "$stem.sign.log"

$identity = Read-JstiBundleIdentity $bundle
$unsignedDigest = Get-JstiSha256 $bundle
$tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
$arguments = @('sign', '/v', '/fd', 'SHA256')
$evidence = [ordered]@{ schemaVersion = 1 }
if ($PSCmdlet.ParameterSetName -eq 'ArtifactSigning') {
    $settings = Read-JstiJson (Resolve-Path -LiteralPath $Metadata).Path
    foreach ($key in 'Endpoint', 'CodeSigningAccountName', 'CertificateProfileName') {
        if (-not $settings.$key) { throw "$Metadata lacks $key." }
    }
    $client = Get-JstiArtifactSigningClient -CacheDirectory $ToolCache
    $arguments += @('/debug', '/tr', $TimestampUrl, '/td', 'SHA256', '/dlib', $client.Dlib, '/dmdf', $Metadata)
    $evidence.method = 'Azure Artifact Signing'
    $evidence.account = [ordered]@{ endpoint = $settings.Endpoint; certificateProfile = $settings.CertificateProfileName }
    $evidence.timestampUrl = $TimestampUrl
    $evidence.artifactSigningClient = $client.Evidence
} else {
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $certificate -or -not $certificate.HasPrivateKey) { throw "No usable certificate $CertificateThumbprint in CurrentUser\My." }
    $arguments += @('/sha1', $CertificateThumbprint, '/s', 'My')
    if ($PublicCertificate) {
        $arguments += @('/tr', $TimestampUrl, '/td', 'SHA256')
        $evidence.timestampUrl = $TimestampUrl
    }
    $evidence.method = $Method
}
$public = $PSCmdlet.ParameterSetName -eq 'ArtifactSigning' -or $PublicCertificate
Copy-Item -LiteralPath $bundle -Destination $output
$sign = Invoke-JstiTool -FilePath $tools.SignTool -LogPath $log -Arguments ($arguments + @($output))
if ($sign.ExitCode -ne 0) {
    Remove-Item -LiteralPath $output -Force
    throw "SignTool failed with exit code $($sign.ExitCode); see $log. 0x8007000B means the bundle publisher differs from the certificate subject."
}
if ((Get-JstiSha256 $bundle) -ne $unsignedDigest) { throw 'The unsigned input changed while signing.' }
if ($public) {
    # A public certificate chains to a root Windows already trusts. The rehearsal's
    # self-signed certificate is proved by the App Installer install instead.
    $verify = Invoke-JstiTool -FilePath $tools.SignTool -LogPath $log -Arguments @('verify', '/pa', '/v', $output)
    if ($verify.ExitCode -ne 0) { throw "SignTool could not verify the signed bundle against this machine's trust; see $log." }
    if ($verify.StandardOutput -notmatch 'timestamped') { throw "The $($evidence.method) signature is not timestamped; see $log." }
}
$signer = Get-JstiPackageSigner $output
if ($signer.Subject -cne $identity.Publisher) {
    throw "Signer subject '$($signer.Subject)' must equal the bundle publisher '$($identity.Publisher)'."
}
$packageArguments = @()
foreach ($package in Get-ChildItem -LiteralPath $Packages -Filter '*.msix' -File) {
    $packageIdentity = Read-JstiPackageIdentity $package.FullName
    $packageArguments += @('--package', ("{0}={1}" -f $packageIdentity.Architecture, $package.FullName))
}
$verificationPath = Join-Path $directory "$stem.verification.json"
Invoke-JstiPython -Python $Python -LogPath $log -Arguments (@(
    (Join-Path $PSScriptRoot 'windows-installer.py'), 'verify-bundle', '--bundle', $output,
    '--publisher', $identity.Publisher, '--version', $identity.Version, '--signed',
    '--evidence', $verificationPath) + $packageArguments) | Out-Null
$evidence.unsignedBundle = [ordered]@{ name = [System.IO.Path]::GetFileName($bundle); sha256 = $unsignedDigest }
$evidence.signedBundle = [ordered]@{ name = [System.IO.Path]::GetFileName($output); sha256 = Get-JstiSha256 $output }
$evidence.publisher = $identity.Publisher
$evidence.certificate = [ordered]@{
    thumbprint = $signer.Thumbprint; subject = $signer.Subject; issuer = $signer.Issuer
    notBefore = $signer.NotBefore.ToUniversalTime().ToString('o'); notAfter = $signer.NotAfter.ToUniversalTime().ToString('o')
}
$evidence.signTool = $tools.Evidence.tools['signtool.exe']
$evidence.verification = Read-JstiJson $verificationPath
Write-JstiJson (Join-Path $directory "$stem.sign.json") $evidence
Write-Host "Signed $output as $($signer.Subject) ($($evidence.method))."
