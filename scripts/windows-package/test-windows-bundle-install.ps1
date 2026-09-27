<#
.SYNOPSIS
Installs the multi-architecture developer .msixbundle on a disposable runner and checks Windows picks this PC's package.

.DESCRIPTION
Signs a copy of the unsigned bundle with a NonExportable, three-hour
self-signed certificate whose subject is the bundle publisher, trusts only its
public part in LocalMachine\TrustedPeople, installs the bundle with
Add-AppxPackage and requires: one registration of the family at the bundle
version, the architecture matching this runner, the app's execution alias and
(when the bundle carries speak.exe) the speak alias, and speak --version
through that alias. It then uninstalls and removes the certificate and trust
it created. It refuses to run anywhere but a GitHub-hosted runner, or when the
package family is already installed. The full install, upgrade, failure and
data-retention lifecycle stays in test-windows-package-lifecycle.ps1 for the
single-architecture packages. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Bundle,
    [Parameter(Mandatory = $true)] [string[]] $Packages,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [string] $Evidence,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This test trusts a temporary certificate machine-wide and installs a package; run it only on a GitHub-hosted runner.'
}
$bundle = (Resolve-Path -LiteralPath $Bundle).Path
$identity = Read-JstiPackageIdentity $bundle
if (Get-AppxPackage -Name $identity.Name) { throw "$($identity.Name) is already installed; refusing to change it." }
$expectedArchitecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Arm64' } else { 'X64' }
$directory = (New-Item -ItemType Directory -Force -Path $Evidence).FullName
$signed = Join-Path $directory ([System.IO.Path]::GetFileName($bundle) -replace '_unsigned\.msixbundle$', '_test-signed.msixbundle')
$report = [ordered]@{ schemaVersion = 1; bundle = [System.IO.Path]::GetFileName($bundle); publisher = $identity.Publisher
                      version = $identity.Version; checks = @(); failures = @() }
$certificate = $null
$trusted = $null
$installed = $null

function Add-Check([string] $Name, [bool] $Passed, $Details) {
    $script:report.checks += [ordered]@{ name = $Name; passed = $Passed; details = $Details }
    if ($Passed) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:report.failures += $Name }
}

try {
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $identity.Publisher -KeyUsage DigitalSignature `
        -FriendlyName 'JSTI ephemeral CI bundle test' -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
    $store.Open('ReadWrite')
    try {
        $trusted = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificate.RawData)
        $store.Add($trusted)
    } finally { $store.Close() }
    & (Join-Path $PSScriptRoot 'sign-windows-package.ps1') -Package $bundle -Output $signed -ToolCache $ToolCache `
        -CertificateThumbprint $certificate.Thumbprint -BundlePackages $Packages -Method 'ephemeral CI test certificate' `
        -Python $Python
    Add-AppxPackage -Path $signed
    $installed = @(Get-AppxPackage -Name $identity.Name)
    Add-Check 'The bundle installs exactly one registration of its family' ($installed.Count -eq 1) @(
        $installed | ForEach-Object { $_.PackageFullName })
    $package = $installed[0]
    Add-Check "Windows installs this runner's $expectedArchitecture package from the bundle" (
        [string] $package.Architecture -eq $expectedArchitecture -and [string] $package.Version -eq $identity.Version -and
        [string] $package.Status -eq 'Ok') ([ordered]@{ architecture = [string] $package.Architecture
                                                       version = [string] $package.Version; status = [string] $package.Status })
    $manifest = [xml] (Get-Content -LiteralPath (Join-Path $package.InstallLocation 'AppxManifest.xml') -Raw)
    $aliases = @($manifest.GetElementsByTagName('desktop:ExecutionAlias') | ForEach-Object { $_.GetAttribute('Alias') })
    foreach ($alias in $aliases) {
        $path = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $alias)
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $path) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        Add-Check "The $alias execution alias is registered" (Test-Path -LiteralPath $path) $path
        if ($alias -eq 'speak.exe' -and (Test-Path -LiteralPath $path)) {
            $cli = Invoke-JstiTool -FilePath $path -Arguments @('--version') -TimeoutSeconds 60
            Add-Check 'speak --version runs through its alias from the installed bundle' (
                $cli.ExitCode -eq 0 -and $cli.StandardOutput -match '^speak ') ([ordered]@{
                    exitCode = $cli.ExitCode; output = $cli.StandardOutput; errors = $cli.StandardError })
        }
    }
    $protocols = @($manifest.GetElementsByTagName('uap3:Protocol') | ForEach-Object { $_.GetAttribute('Name') })
    Add-Check 'The installed bundle registers the justspeaktoit protocol' ($protocols -contains 'justspeaktoit') $protocols
} catch {
    $report.failures += "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
} finally {
    foreach ($package in @(Get-AppxPackage -Name $identity.Name)) {
        try { Remove-AppxPackage -Package $package.PackageFullName } catch { $report.failures += "Uninstall failed: $($_.Exception.Message)" }
    }
    if ($trusted) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
        $store.Open('ReadWrite')
        try { $store.Remove($trusted) } finally { $store.Close() }
    }
    if ($certificate) { Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $certificate.Thumbprint) -DeleteKey -ErrorAction SilentlyContinue }
    Add-Check 'Cleanup leaves no registration of the family' (@(Get-AppxPackage -Name $identity.Name).Count -eq 0) $null
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory 'bundle-install-evidence.json') -Encoding utf8
}
if ($report.failures.Count) { throw ($report.failures -join '; ') }
Write-Host 'The developer bundle installed the matching architecture, exposed its aliases and uninstalled cleanly.'
