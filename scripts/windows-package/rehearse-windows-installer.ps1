<#
.SYNOPSIS
Rehearses the signed beta installer end to end on a disposable runner, with no owner signing identity.

.DESCRIPTION
Builds two x64 + ARM64 beta bundles (base and upgrade) for a rehearsal
publisher, signs both with an ephemeral, non-exportable self-signed
certificate, and writes .appinstaller files with file:// URIs: the base and
upgrade files share one update URI, as the published file does. The public
certificate is trusted in LocalMachine\TrustedPeople only for the run, then
test-windows-installer.ps1 installs, upgrades, refuses a downgrade and
uninstalls. The certificate and its trust are removed before the script ends.

This proves the bundle, signature shape, App Installer file and update
lifecycle. It does not prove publisher trust: only a publicly trusted signing route,
verified without importing any certificate, does that. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $X64Bundle,
    [Parameter(Mandatory = $true)] [string] $Arm64Bundle,
    [Parameter(Mandatory = $true)] [string] $ExpectedCommit,
    [string] $X64Commit = $ExpectedCommit,
    [string] $Arm64Commit = $ExpectedCommit,
    [Parameter(Mandatory = $true)] [string] $BaseVersion,
    [Parameter(Mandatory = $true)] [string] $UpgradeVersion,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [string] $Workspace,
    [string] $Python = 'python',
    [switch] $SkipLifecycle,
    [switch] $DisposableMachine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

$hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
if (-not $hosted -and -not $DisposableMachine) {
    throw 'This rehearsal trusts a temporary certificate machine-wide. Run it on a GitHub-hosted runner or a throwaway VM with -DisposableMachine.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $SkipLifecycle -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: trusting the ephemeral certificate needs the local machine certificate store.'
}
$publisher = 'CN=Just Speak to It Installer Rehearsal, O=Just Speak to It CI'
$workspace = (New-Item -ItemType Directory -Force -Path $Workspace).FullName
$site = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'site')).FullName
$selfPath = Join-Path $site 'JustSpeakToIt.appinstaller'
$selfUri = ([System.Uri] $selfPath).AbsoluteUri
$installer = Join-Path $PSScriptRoot 'windows-installer.py'

$certificate = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature `
    -FriendlyName 'JSTI ephemeral installer rehearsal' -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(3) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$trusted = $false
$opened = $false
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
try {
    $signed = @{}
    foreach ($kind in 'base', 'upgrade') {
        $version = if ($kind -eq 'base') { $BaseVersion } else { $UpgradeVersion }
        $root = Join-Path $workspace "bundle-$kind"
        & (Join-Path $PSScriptRoot 'build-windows-installer-bundle.ps1') -X64Bundle $X64Bundle -Arm64Bundle $Arm64Bundle `
            -ExpectedCommit $ExpectedCommit -X64Commit $X64Commit -Arm64Commit $Arm64Commit -Version $version -Publisher $publisher -Output $root -ToolCache $ToolCache -Python $Python
        $unsigned = Join-Path $root ("JustSpeakToIt-windows_{0}_unsigned.msixbundle" -f $version)
        $output = Join-Path $site ("JustSpeakToIt-windows_{0}.msixbundle" -f $version)
        & (Join-Path $PSScriptRoot 'sign-windows-installer.ps1') -Bundle $unsigned -Output $output `
            -Packages (Join-Path $root 'packages') -ToolCache $ToolCache -CertificateThumbprint $certificate.Thumbprint -Python $Python
        $appInstaller = Join-Path $workspace "$kind.appinstaller"
        Invoke-JstiPython -Python $Python -LogPath (Join-Path $workspace 'appinstaller.log') -Arguments @(
            $installer, 'appinstaller', '--rehearsal', '--self-uri', $selfUri, '--bundle-uri', ([System.Uri] $output).AbsoluteUri,
            '--publisher', $publisher, '--version', $version, '--output', $appInstaller) | Out-Null
        $signed[$kind] = @{ Bundle = $output; AppInstaller = $appInstaller }
    }
    if ($SkipLifecycle) { return }
    # The published file is replaced in place on each release; the rehearsal does the same.
    Copy-Item -LiteralPath $signed.base.AppInstaller -Destination $selfPath -Force
    $public = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificate.RawData)
    $store.Open('ReadWrite')
    $opened = $true
    $store.Add($public)
    $trusted = $true
    $upgradeCopy = Join-Path $workspace 'upgrade-at-self-uri.appinstaller'
    Copy-Item -LiteralPath $signed.upgrade.AppInstaller -Destination $upgradeCopy
    & (Join-Path $PSScriptRoot 'test-windows-installer.ps1') -AppInstaller $selfPath -ExpectedVersion $BaseVersion `
        -ExpectedPublisher $publisher -ExpectedUpdateUri $selfUri -UpgradeAppInstaller $upgradeCopy `
        -UpgradeVersion $UpgradeVersion -DowngradeBundle $signed.base.Bundle -Workspace (Join-Path $workspace 'lifecycle') `
        -DisposableMachine:$DisposableMachine
} finally {
    if ($trusted) { $store.Remove($public) }
    if ($opened) { $store.Close() }
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $certificate.Thumbprint) -Force -ErrorAction SilentlyContinue
}
