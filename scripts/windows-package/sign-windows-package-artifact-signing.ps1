<#
.SYNOPSIS
Signs a copy of an unsigned developer .msix with Azure Artifact Signing.

.DESCRIPTION
The key never leaves Microsoft's HSMs: the pinned SignTool sends only the
package digests through the pinned Artifact Signing dlib, which authenticates
with DefaultAzureCredential (in CI, the Azure CLI session that azure/login
opened through GitHub OIDC). -Metadata is the dlib metadata.json that
signing_configuration.py writes from the repository's GitHub variables.

The layout must have been built with --publisher set to the certificate
profile's exact subject. Artifact Signing issues short-lived certificates, so
every signature is RFC 3161 timestamped. After signing, the signer subject
read back from AppxSignature.p7x must equal the manifest publisher and the
signed package must equal the verified layout apart from its signature. The
unsigned input is never modified. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Package,
    [Parameter(Mandatory = $true)] [string] $Output,
    [Parameter(Mandatory = $true)] [string] $Layout,
    [Parameter(Mandatory = $true)] [string] $Metadata,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [string] $TimestampUrl = 'http://timestamp.acs.microsoft.com',
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

function Get-JstiPackageSigner([string] $Path) {
    # AppxSignature.p7x is 'PKCX' followed by a PKCS #7 SignedData blob.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Security
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('AppxSignature.p7x')
        if (-not $entry) { throw "$Path has no AppxSignature.p7x." }
        $stream = New-Object System.IO.MemoryStream
        $source = $entry.Open()
        try { $source.CopyTo($stream) } finally { $source.Dispose() }
        $bytes = $stream.ToArray()
    } finally { $zip.Dispose() }
    if ($bytes.Length -lt 5 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'PKCX') {
        throw 'AppxSignature.p7x does not start with PKCX.'
    }
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $cms.Decode($bytes[4..($bytes.Length - 1)])
    return $cms.SignerInfos[0].Certificate
}

$package = (Resolve-Path -LiteralPath $Package).Path
$layout = (Resolve-Path -LiteralPath $Layout).Path
$metadata = (Resolve-Path -LiteralPath $Metadata).Path
$output = [System.IO.Path]::GetFullPath($Output)
if ($output -eq $package) { throw 'Sign a copy; the unsigned developer package must stay unchanged.' }
if (Test-Path -LiteralPath $output) { throw "Refusing to replace an existing file: $output" }
if ($TimestampUrl -notmatch '^https?://') { throw 'The timestamp URL must be an RFC 3161 HTTP(S) URL.' }
$settings = Read-JstiJson $metadata
foreach ($key in 'Endpoint', 'CodeSigningAccountName', 'CertificateProfileName') {
    if (-not $settings.$key) { throw "$metadata lacks $key." }
}
$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stem = [System.IO.Path]::GetFileNameWithoutExtension($output)
$log = Join-Path $directory "$stem.sign.log"

$identity = Read-JstiPackageIdentity $package
$developerPublisher = (Read-JstiJson (Join-Path $PSScriptRoot 'package-identity.json')).identity.developerPublisher
if ($identity.Publisher -ceq $developerPublisher) {
    throw 'The package still has the placeholder developer publisher; rebuild the layout with --publisher.'
}
$unsignedDigest = Get-JstiSha256 $package

$tools = Get-JstiPackagingTools -CacheDirectory $ToolCache
$client = Get-JstiArtifactSigningClient -CacheDirectory $ToolCache
Copy-Item -LiteralPath $package -Destination $output
$arguments = @('sign', '/v', '/debug', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256',
               '/dlib', $client.Dlib, '/dmdf', $metadata, $output)
$sign = Invoke-JstiTool -FilePath $tools.SignTool -LogPath $log -Arguments $arguments
if ($sign.ExitCode -ne 0) {
    Remove-Item -LiteralPath $output -Force
    throw "SignTool failed with exit code $($sign.ExitCode); see $log. 0x8007000B means the manifest publisher differs from the certificate subject."
}
if ((Get-JstiSha256 $package) -ne $unsignedDigest) { throw 'The unsigned input changed while signing.' }

# The chain must reach a root this Windows trusts; /pa selects the default
# Authenticode policy used for packages.
$verify = Invoke-JstiTool -FilePath $tools.SignTool -LogPath $log -Arguments @('verify', '/pa', '/v', $output)
if ($verify.ExitCode -ne 0) { throw "SignTool could not verify the signed package; see $log." }
$certificate = Get-JstiPackageSigner $output
if ($certificate.Subject -cne $identity.Publisher) {
    throw "Signer subject '$($certificate.Subject)' must equal the manifest publisher '$($identity.Publisher)'. Set WINDOWS_MSIX_PUBLISHER to the certificate profile's subject."
}

$evidencePath = Join-Path $directory "$stem.verification.json"
Invoke-JstiPython -Python $Python -LogPath $log -Arguments @(
    (Join-Path $PSScriptRoot 'verify-windows-package.py'), '--package', $output, '--layout', $layout,
    '--signed', '--unsigned-reference', $package, '--evidence', $evidencePath) | Out-Null
$record = [ordered]@{
    schemaVersion = 1
    method = 'Azure Artifact Signing'
    unsignedPackage = [ordered]@{ name = [System.IO.Path]::GetFileName($package); sha256 = $unsignedDigest }
    signedPackage = [ordered]@{ name = [System.IO.Path]::GetFileName($output); sha256 = Get-JstiSha256 $output }
    publisher = $identity.Publisher
    certificate = [ordered]@{
        thumbprint = $certificate.Thumbprint; subject = $certificate.Subject; issuer = $certificate.Issuer
        notBefore = $certificate.NotBefore.ToUniversalTime().ToString('o')
        notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o')
    }
    account = [ordered]@{ endpoint = $settings.Endpoint; certificateProfile = $settings.CertificateProfileName }
    timestampUrl = $TimestampUrl
    signTool = $tools.Evidence.tools['signtool.exe']
    artifactSigningClient = $client.Evidence
    verification = Read-JstiJson $evidencePath
}
Write-JstiJson (Join-Path $directory "$stem.sign.json") $record
Write-Host "Signed $output through Azure Artifact Signing as $($certificate.Subject) (timestamped)."
