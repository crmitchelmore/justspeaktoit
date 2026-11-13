<#
.SYNOPSIS
Submits the unsigned Microsoft Store .msixbundle to Partner Center with the pinned msstore CLI.

.DESCRIPTION
Checks that the bundle carries exactly the reserved Store identity
(package-identity-store.json) and no signature, downloads the pinned Microsoft
Store Developer CLI (dependencies.json, microsoftStoreCli), verifies its digest
and Microsoft Authenticode signature, then runs `msstore publish` against the
reserved Store product. The Store re-signs the packages it accepts, so no
signing certificate is involved.

The Entra credentials are read from MICROSOFT_STORE_TENANT_ID,
MICROSOFT_STORE_CLIENT_ID, MICROSOFT_STORE_CLIENT_SECRET and
MICROSOFT_STORE_SELLER_ID, are passed only to `msstore reconfigure`, and are
never logged. The submission API updates an existing Store listing only: the
first submission is made by hand in Partner Center. -NoCommit leaves the new
submission as a draft. Run only on an ephemeral runner in the
microsoft-store environment. Keep this file ASCII-only.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Bundle,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [string] $Evidence,
    [switch] $NoCommit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

foreach ($name in 'MICROSOFT_STORE_TENANT_ID', 'MICROSOFT_STORE_CLIENT_ID', 'MICROSOFT_STORE_CLIENT_SECRET',
        'MICROSOFT_STORE_SELLER_ID') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set." }
}
$store = Read-JstiJson (Join-Path $PSScriptRoot 'package-identity-store.json')
$productId = $store.identity.storeProductId
$bundlePath = [System.IO.Path]::GetFullPath($Bundle)
$identity = Read-JstiBundleIdentity $bundlePath
if ($identity.Name -cne $store.identity.name -or $identity.Publisher -cne $store.identity.publisher) {
    throw "$bundlePath is $($identity.Name) by $($identity.Publisher), not the reserved Store identity."
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($bundlePath)
try { $signed = [bool] $zip.GetEntry('AppxSignature.p7x') } finally { $zip.Dispose() }
if ($signed) { throw "$bundlePath is signed; the Store bundle must be submitted unsigned." }

$pins = (Read-JstiJson (Join-Path $PSScriptRoot 'dependencies.json')).microsoftStoreCli
$cache = Join-Path $ToolCache 'msstore-cli'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache $pins.name
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    Invoke-WebRequest -Uri $pins.url -OutFile $archive -UseBasicParsing
}
$bytes = (Get-Item -LiteralPath $archive).Length
$digest = Get-JstiSha256 $archive
if ($bytes -ne $pins.bytes -or $digest -ne $pins.sha256) {
    Remove-Item -LiteralPath $archive -Force
    throw "$($pins.name) does not match its pin ($bytes bytes, sha256 $digest)."
}
$directory = Join-Path $cache 'cli'
if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
Expand-Archive -LiteralPath $archive -DestinationPath $directory
$tool = Join-Path $directory $pins.tool
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "$($pins.name) lacks $($pins.tool)." }
$signature = Get-AuthenticodeSignature -LiteralPath $tool
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "$($pins.tool) is not validly signed by Microsoft: $($signature.Status) $($signature.SignerCertificate.Subject)."
}

$log = Join-Path $cache 'msstore.log'
$settings = Invoke-JstiTool -FilePath $tool -LogPath $log -TimeoutSeconds 120 -Arguments @('settings', '-t', 'false')
if ($settings.ExitCode -ne 0) { throw "msstore settings failed with exit code $($settings.ExitCode); see $log." }
# No -LogPath: these arguments carry the credentials.
$configure = Invoke-JstiTool -FilePath $tool -TimeoutSeconds 300 -Arguments @(
    'reconfigure', '--tenantId', $env:MICROSOFT_STORE_TENANT_ID, '--sellerId', $env:MICROSOFT_STORE_SELLER_ID,
    '--clientId', $env:MICROSOFT_STORE_CLIENT_ID, '--clientSecret', $env:MICROSOFT_STORE_CLIENT_SECRET)
if ($configure.ExitCode -ne 0) {
    throw "msstore reconfigure failed with exit code $($configure.ExitCode); check the microsoft-store environment secrets and the Entra app's Partner Center Manager role."
}
$arguments = @('publish', $bundlePath, '--appId', $productId, '--verbose')
if ($NoCommit) { $arguments += '--noCommit' }
$publish = Invoke-JstiTool -FilePath $tool -LogPath $log -TimeoutSeconds 3600 -Arguments $arguments
Write-Host $publish.StandardOutput
if ($publish.ExitCode -ne 0) {
    Write-Host $publish.StandardError
    throw "msstore publish failed with exit code $($publish.ExitCode); see $log. The API only updates a product that already has a published submission."
}
Write-JstiJson $Evidence ([ordered]@{
    schemaVersion = 1
    productId = $productId
    bundle = [ordered]@{ name = [System.IO.Path]::GetFileName($bundlePath); sha256 = (Get-JstiSha256 $bundlePath)
                         identity = $identity.Name; publisher = $identity.Publisher; version = $identity.Version }
    msstore = [ordered]@{ name = $pins.name; sha256 = $digest; bytes = $bytes; signer = $signature.SignerCertificate.Subject }
    committed = -not $NoCommit
})
Write-Host "Submitted $($identity.Name) $($identity.Version) to Microsoft Store product $productId."
