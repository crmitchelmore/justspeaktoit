<#
.SYNOPSIS
Makes an SSL.com eSigner cloud certificate usable by SignTool on this runner.

.DESCRIPTION
Follows SSL.com's documented unattended eSigner CKA flow: install the pinned
eSigner CKA for the current user, configure it in product mode from the
account credentials and the automated-signing TOTP secret, then load the
certificate into CurrentUser\My. The private key stays in SSL.com's cloud HSM;
SignTool reaches it through the CKA key storage provider.

The credentials are read from SSLCOM_ESIGNER_USERNAME, SSLCOM_ESIGNER_PASSWORD
and SSLCOM_ESIGNER_TOTP_SECRET, are passed only to eSignerCKATool config, and
are never logged. Run only on an ephemeral runner in the windows-signing job.
Keep this file ASCII-only.
#>
param(
    [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string] $CertificateThumbprint,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [string] $Evidence,
    [int] $LoadTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

foreach ($name in 'SSLCOM_ESIGNER_USERNAME', 'SSLCOM_ESIGNER_PASSWORD', 'SSLCOM_ESIGNER_TOTP_SECRET') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set." }
}
$pins = (Read-JstiJson (Join-Path $PSScriptRoot 'dependencies.json')).sslcomEsignerCka
$cache = Join-Path $ToolCache 'sslcom-esigner'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$installer = Join-Path $cache $pins.name
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    Invoke-WebRequest -Uri $pins.url -OutFile $installer -UseBasicParsing
}
$bytes = (Get-Item -LiteralPath $installer).Length
$digest = Get-JstiSha256 $installer
if ($bytes -ne $pins.bytes -or $digest -ne $pins.sha256) {
    Remove-Item -LiteralPath $installer -Force
    throw "$($pins.name) does not match its pin ($bytes bytes, sha256 $digest)."
}
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid') { throw "$($pins.name) is not validly signed: $($signature.Status)." }

$directory = Join-Path $cache 'cka'
$log = Join-Path $cache 'install.log'
$install = Invoke-JstiTool -FilePath $installer -LogPath $log -TimeoutSeconds 600 -Arguments @(
    '/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$directory")
if ($install.ExitCode -ne 0) { throw "The eSigner CKA installer failed with exit code $($install.ExitCode); see $log." }
$tool = Join-Path $directory $pins.tool
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "The eSigner CKA install lacks $($pins.tool)." }

# No -LogPath: these arguments carry the credentials.
$config = Invoke-JstiTool -FilePath $tool -TimeoutSeconds 120 -Arguments @(
    'config', '-mode', 'product', '-user', $env:SSLCOM_ESIGNER_USERNAME, '-pass', $env:SSLCOM_ESIGNER_PASSWORD,
    '-totp', $env:SSLCOM_ESIGNER_TOTP_SECRET, '-key', (Join-Path $directory 'master.key'), '-r')
if ($config.ExitCode -ne 0) { throw "eSignerCKATool config failed with exit code $($config.ExitCode); check the eSigner credentials and TOTP secret." }
foreach ($verb in 'unload', 'load') {
    $step = Invoke-JstiTool -FilePath $tool -LogPath $log -TimeoutSeconds 120 -Arguments @($verb)
    if ($step.ExitCode -ne 0) { throw "eSignerCKATool $verb failed with exit code $($step.ExitCode); see $log." }
}

$thumbprint = $CertificateThumbprint.ToUpperInvariant()
$deadline = (Get-Date).AddSeconds($LoadTimeoutSeconds)
do {
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
    if ($certificate) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if (-not $certificate) { throw "eSigner CKA did not load certificate $thumbprint into CurrentUser\My; check SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT." }
if (-not $certificate.HasPrivateKey) { throw "Certificate $thumbprint has no eSigner private key binding." }
if (-not ($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) {
    throw "Certificate $thumbprint is not a code signing certificate."
}
Write-JstiJson $Evidence ([ordered]@{
    schemaVersion = 1
    esignerCka = [ordered]@{ name = $pins.name; sha256 = $digest; bytes = $bytes; signer = $signature.SignerCertificate.Subject }
    certificate = [ordered]@{ thumbprint = $thumbprint; subject = $certificate.Subject; issuer = $certificate.Issuer
                              notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o') }
})
Write-Host "Loaded eSigner certificate $thumbprint ($($certificate.Subject))."
