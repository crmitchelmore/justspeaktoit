<#
.SYNOPSIS
Installs the beta through its .appinstaller file, checks it, upgrades it, refuses a downgrade and uninstalls it.

.DESCRIPTION
Uses the same deployment path as a user opening the downloaded
JustSpeakToIt.appinstaller: Add-AppxPackage -AppInstallerFile, which fetches
the MainBundle URI, applies the architecture-specific package from the bundle
and registers the .appinstaller URI as the update source. Checks after each
step:

  * exactly one registration of the beta family, at the expected version,
    publisher and the machine's native architecture, with the expected
    App Installer update URI;
  * the CLI execution alias answers --version and --help from the package;
  * with -UpgradeAppInstaller (local rehearsals, whose update URI is a file),
    publishing the newer file at the update URI makes Windows report an update
    for the installed package, applying it keeps the family, and a direct
    install of the older bundle is refused and leaves the newer version;
  * uninstall removes the registration and both execution aliases.

The script never imports a certificate. The rehearsal wrapper trusts its
ephemeral certificate before calling it; the published route must install with
the machine's default trust. Admission refuses a machine that already has the
family installed and changes nothing. Cleanup removes only registrations this
run created. Keep this file ASCII-only for Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $AppInstaller,
    [Parameter(Mandatory = $true)] [string] $ExpectedVersion,
    [Parameter(Mandatory = $true)] [string] $ExpectedPublisher,
    [Parameter(Mandatory = $true)] [string] $ExpectedUpdateUri,
    [string] $UpgradeAppInstaller,
    [string] $UpgradeVersion,
    [string] $DowngradeBundle,
    [Parameter(Mandatory = $true)] [string] $Workspace,
    [switch] $DisposableMachine
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')
. (Join-Path $PSScriptRoot '..\windows-bundle\BundleCLI.ps1')

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run with Windows PowerShell 5.1 (powershell.exe) for the Appx module.' }
$hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
if (-not $hosted -and -not $DisposableMachine) {
    throw 'This test installs and removes the Just Speak to It beta. Run it on a GitHub-hosted runner or a throwaway VM with -DisposableMachine.'
}
if ([bool] $UpgradeAppInstaller -ne [bool] $UpgradeVersion) { throw 'Pass -UpgradeAppInstaller and -UpgradeVersion together.' }
$updateTarget = [System.Uri] $ExpectedUpdateUri
if ($UpgradeAppInstaller -and -not $updateTarget.IsFile) {
    throw 'An upgrade rehearsal publishes the newer file at the update URI, so that URI must be a local file.'
}
if ($UpgradeVersion -and ([version] $UpgradeVersion -le [version] $ExpectedVersion)) { throw 'The upgrade must be newer.' }

$identity = Read-JstiJson (Join-Path $PSScriptRoot 'package-identity-beta.json')
$name = $identity.identity.name
$workspace = (New-Item -ItemType Directory -Force -Path $Workspace).FullName
$evidenceDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'evidence')).FullName
$emptyDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'empty')).FullName
$aliases = @(
    (Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $identity.application.executionAlias)),
    (Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $identity.cli.executionAlias)))
$systemRoot = $env:SystemRoot
$isolatedPath = "$systemRoot\System32;$systemRoot;$systemRoot\System32\Wbem;$systemRoot\System32\WindowsPowerShell\v1.0"
$native = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'X64' } 'ARM64' { 'Arm64' } default { $env:PROCESSOR_ARCHITECTURE } }
if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $native = 'Arm64' }

$owned = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{
    schemaVersion = 1
    runner = [ordered]@{
        os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
        architecture = $native; hosted = $hosted
    }
    expected = [ordered]@{ version = $ExpectedVersion; upgradeVersion = $UpgradeVersion; publisher = $ExpectedPublisher
        updateUri = $ExpectedUpdateUri }
    appInstallers = [ordered]@{}
    deployments = New-Object System.Collections.ArrayList
    runs = New-Object System.Collections.ArrayList
    checks = New-Object System.Collections.ArrayList
    cleanup = $null
    failures = @()
}

function Add-Check([string] $Name, [bool] $Passed, $Details) {
    [void] $script:report.checks.Add([ordered]@{ name = $Name; passed = $Passed; details = $Details })
    if (-not $Passed) { $script:failures.Add($Name) }
    Write-Host ("[{0}] {1}" -f $(if ($Passed) { 'pass' } else { 'FAIL' }), $Name)
}

function Assert-Check([string] $Name, [bool] $Passed, $Details) {
    Add-Check $Name $Passed $Details
    if (-not $Passed) { throw "Check failed: $Name" }
}

function Get-Registrations { return ,@(Get-AppxPackage -Name $name) }

function Get-UpdateUri([string] $FullName) {
    # Package.GetAppInstallerInfo() reports the .appinstaller URI App Installer polls for updates.
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]
        $manager = New-Object Windows.Management.Deployment.PackageManager
        $package = $manager.FindPackageForUser('', $FullName)
        $info = $package.GetAppInstallerInfo()
        if ($info) { return [string] $info.Uri }
        return $null
    } catch { return 'unavailable: ' + $_.Exception.Message }
}

function Wait-WinRT($Operation, [type] $ResultType) {
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(120000)) { throw 'The Windows Runtime operation did not finish in 120 s.' }
    return $task.Result
}

function Get-UpdateAvailability([string] $FullName) {
    # The same check App Installer runs on launch and in its background task.
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]
        $resultType = [Windows.ApplicationModel.PackageUpdateAvailabilityResult, Windows.ApplicationModel, ContentType = WindowsRuntime]
        $package = (New-Object Windows.Management.Deployment.PackageManager).FindPackageForUser('', $FullName)
        $result = Wait-WinRT $package.CheckUpdateAvailabilityAsync() $resultType
        $extended = $null
        if ($result.ExtendedError) { $extended = '0x{0:X8}' -f $result.ExtendedError.HResult }
        return [ordered]@{ availability = [string] $result.Availability; extendedError = $extended }
    } catch { return [ordered]@{ availability = 'unavailable'; extendedError = $_.Exception.Message } }
}

function Invoke-Deployment([string] $Label, [scriptblock] $Operation) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $record = [ordered]@{ label = $Label; succeeded = $false; hresult = $null; message = $null; log = @() }
    try {
        & $Operation | Out-Null
        $record.succeeded = $true
    } catch {
        $record.message = $_.Exception.Message
        $match = [regex]::Match($record.message, '0x[0-9A-Fa-f]{8}')
        $record.hresult = if ($match.Success) { $match.Value.ToUpperInvariant() } else { '0x{0:X8}' -f $_.Exception.HResult }
        $activity = [regex]::Match($record.message, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($activity.Success) {
            try {
                $record.log = @(Get-AppxLog -ActivityId $activity.Value | Select-Object -First 40 |
                    ForEach-Object { '{0} {1}' -f $_.Id, $_.Message })
            } catch { $record.log = @('Get-AppxLog failed: ' + $_.Exception.Message) }
        }
    }
    $registrations = Get-Registrations
    foreach ($package in $registrations) {
        if (-not $script:owned.Contains($package.PackageFullName)) { $script:owned.Add($package.PackageFullName) }
    }
    $record.seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    [void] $script:report.deployments.Add($record)
    Write-Host ("{0} {1} ({2} s)" -f $Label, $(if ($record.succeeded) { 'succeeded' } else { 'failed ' + $record.hresult }), $record.seconds)
    return $record
}

function Read-AppInstaller([string] $Label, [string] $Path) {
    [xml] $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $bundle = $document.AppInstaller.MainBundle
    $script:report.appInstallers[$Label] = [ordered]@{
        sha256 = Get-JstiSha256 $Path; uri = $document.AppInstaller.Uri; version = $document.AppInstaller.Version
        mainBundle = [ordered]@{ name = $bundle.Name; publisher = $bundle.Publisher; version = $bundle.Version; uri = $bundle.Uri }
    }
    return $script:report.appInstallers[$Label]
}

function Assert-Installed([string] $Label, [string] $Version) {
    $registrations = Get-Registrations
    Assert-Check "$Label registers exactly one beta package" ($registrations.Count -eq 1) (
        @($registrations | ForEach-Object { $_.PackageFullName }))
    $package = $registrations[0]
    $updateUri = Get-UpdateUri $package.PackageFullName
    $details = [ordered]@{
        packageFullName = $package.PackageFullName; packageFamilyName = $package.PackageFamilyName
        version = [string] $package.Version; architecture = [string] $package.Architecture
        publisher = $package.Publisher; signatureKind = [string] $package.SignatureKind
        isBundle = [bool] $package.IsBundle; updateUri = $updateUri
    }
    Assert-Check "$Label installs version $Version" ($details.version -eq $Version) $details
    Assert-Check "$Label installs the native $native package from the bundle" ($details.architecture -eq $native) $details
    Assert-Check "$Label is signed by the expected publisher" ($details.publisher -ceq $ExpectedPublisher) $details
    Assert-Check "$Label records the .appinstaller update source" ($updateUri -eq $ExpectedUpdateUri) $details
    foreach ($argument in @('--version', '--help')) {
        $cli = Invoke-BundleCLIReadOnly -Executable $aliases[1] -Argument $argument -WorkingDirectory $emptyDirectory `
            -IsolatedPath $isolatedPath
        $cli.label = "$Label-cli-" + $argument.TrimStart('-')
        [void] $script:report.runs.Add($cli)
        Assert-Check "$Label CLI alias $argument runs from the package" $cli.passed $cli
    }
    return $package
}

# --- admission: change nothing on a machine that already has the beta --------------------------
$existing = Get-Registrations
if ($existing.Count -ne 0) {
    throw "Refusing to run: $name is already installed ($($existing[0].PackageFullName)). Use a clean machine."
}
$report.admission = 'clean'

try {
    $base = Read-AppInstaller 'base' $AppInstaller
    Assert-Check 'The .appinstaller names the expected update URI, publisher and version' (
        $base.uri -eq $ExpectedUpdateUri -and $base.mainBundle.publisher -ceq $ExpectedPublisher -and
        $base.mainBundle.version -eq $ExpectedVersion -and $base.mainBundle.name -eq $name) $base
    $record = Invoke-Deployment 'install' { Add-AppxPackage -AppInstallerFile $AppInstaller }
    Assert-Check 'Install through the .appinstaller file succeeds with this machine''s trust' $record.succeeded $record
    $installed = Assert-Installed 'install' $ExpectedVersion

    if ($UpgradeAppInstaller) {
        $upgrade = Read-AppInstaller 'upgrade' $UpgradeAppInstaller
        Assert-Check 'The upgrade .appinstaller keeps the update URI and publisher' (
            $upgrade.uri -eq $ExpectedUpdateUri -and $upgrade.mainBundle.publisher -ceq $ExpectedPublisher -and
            $upgrade.mainBundle.version -eq $UpgradeVersion) $upgrade
        # Publish the newer file where the installed package looks for updates, as a release does.
        Copy-Item -LiteralPath $UpgradeAppInstaller -Destination $updateTarget.LocalPath -Force
        $availability = Get-UpdateAvailability $installed.PackageFullName
        $report.updateAvailability = $availability
        Add-Check 'Windows reports the published update for the installed package' (
            $availability.availability -in @('Available', 'Required')) $availability
        $record = Invoke-Deployment 'upgrade' { Add-AppxPackage -AppInstallerFile $updateTarget.LocalPath }
        Assert-Check 'Applying the update from the update URI succeeds' $record.succeeded $record
        $upgraded = Assert-Installed 'upgrade' $UpgradeVersion
        Assert-Check 'The upgrade keeps the package family' ($upgraded.PackageFamilyName -eq $installed.PackageFamilyName) @{
            before = $installed.PackageFamilyName; after = $upgraded.PackageFamilyName }
        if ($DowngradeBundle) {
            $record = Invoke-Deployment 'downgrade' { Add-AppxPackage -Path $DowngradeBundle }
            $after = Get-Registrations
            Add-Check 'A direct install of the older bundle is refused' (-not $record.succeeded) $record
            Add-Check 'The refused downgrade leaves the upgrade installed' (
                $after.Count -eq 1 -and [string] $after[0].Version -eq $UpgradeVersion) @(
                $after | ForEach-Object { $_.PackageFullName })
        }
    }

    $current = Get-Registrations
    $record = Invoke-Deployment 'uninstall' { $current | Remove-AppxPackage }
    Assert-Check 'Uninstall succeeds' $record.succeeded $record
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (@($aliases | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0)) {
        Start-Sleep -Milliseconds 500
    }
    $remaining = Get-Registrations
    Add-Check 'Uninstall removes the registration' ($remaining.Count -eq 0) @($remaining | ForEach-Object { $_.PackageFullName })
    Add-Check 'Uninstall removes both execution aliases' (
        @($aliases | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) $aliases
} catch {
    if (-not $failures.Contains($_.Exception.Message)) { $failures.Add($_.Exception.Message) }
} finally {
    $removed = New-Object System.Collections.ArrayList
    $registrations = Get-Registrations
    foreach ($package in $registrations) {
        if ($owned.Contains($package.PackageFullName)) {
            try { Remove-AppxPackage -Package $package.PackageFullName; [void] $removed.Add($package.PackageFullName) }
            catch { $failures.Add("Cleanup could not remove $($package.PackageFullName): $($_.Exception.Message)") }
        }
    }
    $report.cleanup = [ordered]@{ removed = $removed; remaining = @((Get-Registrations) | ForEach-Object { $_.PackageFullName }) }
    $report.failures = @($failures)
    Write-JstiJson (Join-Path $evidenceDirectory 'installer-lifecycle.json') $report
}
if ($failures.Count -gt 0) { throw ("Installer lifecycle failed: " + ($failures -join '; ')) }
Write-Host "Installed, upgraded and uninstalled $name through App Installer on $native."
