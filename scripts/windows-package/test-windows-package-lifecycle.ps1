<#
.SYNOPSIS
Installs, launches, fails, upgrades and uninstalls the developer MSIX on a disposable Windows machine.

.DESCRIPTION
Run with Windows PowerShell 5.1, elevated, on a disposable machine only: it
trusts an ephemeral test certificate machine-wide, installs and removes the
package for the current user and writes %LOCALAPPDATA%\JustSpeakToIt. It is
admitted only when none of the app's data, registrations, package data, alias,
processes or publisher certificates exist. A refused run changes nothing, not
even during cleanup. An admitted run records every package full name,
process, certificate and the data directory it creates
(LifecycleOwnership.ps1), removes exactly those, and fails if it cannot.

The unsigned packages are signed with a NonExportable self-signed certificate
created for this run through sign-windows-package.ps1, the same path an
externally supplied certificate uses. Its public part alone is trusted in
LocalMachine\TrustedPeople. Both are removed before the script ends.

Phases:
  1. Fresh machine: a tampered package is refused; the base version installs,
     registers its Start menu entry and alias, passes its self-tests inside the
     package identity, launches from the Start menu, creates its data in the
     real %LOCALAPPDATA%\JustSpeakToIt, uninstalls, and that data survives.
  2. Existing portable data: an untrusted package is refused; the base version
     installs, shows the portable History and recovers its interrupted
     recording in place.
  3. Failed upgrades: while running, tampered, untrusted and cancelled upgrades
     leave the previous version and all user data intact.
  4. The upgrade installs, keeps the family, data and launch behaviour.
  5. Uninstall keeps all user data; a reinstall shows it again.
Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BaseLayout,
    [Parameter(Mandatory = $true)] [string] $BasePackage,
    [Parameter(Mandatory = $true)] [string] $UpgradeLayout,
    [Parameter(Mandatory = $true)] [string] $UpgradePackage,
    [Parameter(Mandatory = $true)] [string] $ToolCache,
    [Parameter(Mandatory = $true)] [string] $Workspace,
    [string] $Python = 'python',
    [switch] $DisposableMachine
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')
. (Join-Path $PSScriptRoot 'LifecycleOwnership.ps1')

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this test with Windows PowerShell 5.1 (powershell.exe); it uses the Appx module and WinRT deployment API.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: trusting the ephemeral test certificate needs the local machine certificate store.'
}
$hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
if (-not $hosted -and -not $DisposableMachine) {
    throw 'This test trusts a temporary certificate machine-wide, installs packages and writes %LOCALAPPDATA%\JustSpeakToIt. Run it only on a GitHub-hosted runner or a throwaway VM with -DisposableMachine.'
}

if (-not ('Jsti.PackageLifecycle.Native' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'PackageLifecycleNative.cs')
}

# --- inputs and derived identity ---------------------------------------------------
$workspace = (New-Item -ItemType Directory -Force -Path $Workspace).FullName
$evidenceDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'evidence')).FullName
$packagesDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'packages')).FullName
$emptyDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'empty working directory')).FullName
$baseLayout = (Resolve-Path -LiteralPath $BaseLayout).Path
$upgradeLayout = (Resolve-Path -LiteralPath $UpgradeLayout).Path
$basePackage = (Resolve-Path -LiteralPath $BasePackage).Path
$upgradePackage = (Resolve-Path -LiteralPath $UpgradePackage).Path
$pythonPath = (Get-Command $Python -CommandType Application | Select-Object -First 1).Source
$support = Join-Path $PSScriptRoot 'lifecycle_support.py'
$settings = Read-JstiJson (Join-Path $PSScriptRoot 'package-identity.json')
$base = (Read-JstiJson (Join-Path $baseLayout 'package-manifest.json')).package
$upgrade = (Read-JstiJson (Join-Path $upgradeLayout 'package-manifest.json')).package
$bundleManifest = Read-JstiJson (Join-Path $baseLayout 'bundle-manifest.json')
if ($base.packageFamilyName -ne $upgrade.packageFamilyName -or $base.appUserModelId -ne $upgrade.appUserModelId) {
    throw 'Base and upgrade layouts must share one package family.'
}
foreach ($candidate in @($base, $upgrade)) {
    if ($candidate.cliApplicationId -cne $settings.cli.id -or
        $candidate.cliAppUserModelId -cne "$($candidate.packageFamilyName)!$($settings.cli.id)") {
        throw 'Base and upgrade layouts must declare the reviewed hidden CLI identity.'
    }
}
$versionOrder = [version] $upgrade.version -gt [version] $base.version
if (-not $versionOrder) { throw 'The upgrade layout must have a higher version than the base layout.' }
$name = $base.name
$aumid = $base.appUserModelId
$windowClass = $settings.application.windowClass
$dataDirectory = Join-Path $env:LOCALAPPDATA $settings.fileSystem.dataDirectoryName
$packageDataDirectory = Join-Path $env:LOCALAPPDATA ('Packages\' + $base.packageFamilyName)
$virtualisedDataDirectory = Join-Path $packageDataDirectory ('LocalCache\Local\' + $settings.fileSystem.dataDirectoryName)
$aliasPath = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $base.executionAlias)
$cliAliasPath = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $base.cliExecutionAlias)
. (Join-Path $PSScriptRoot '..\windows-bundle\BundleCLI.ps1')
. (Join-Path $PSScriptRoot '..\windows-bundle\FailureDiagnostics.ps1')
$systemRoot = $env:SystemRoot
$isolatedPath = "$systemRoot\System32;$systemRoot;$systemRoot\System32\Wbem;$systemRoot\System32\WindowsPowerShell\v1.0"
$readyPattern = '^(Enter and save the selected provider.s API key|Ready\. Ctrl\+Alt\+Space|Recording sounds unavailable\. Check audio output; dictation still works\.$)'
$controls = @{ transcript = 106; status = 107; history = 108; historyDetail = 109 }

$failures = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{
    schemaVersion = 1
    package = [ordered]@{ base = $base; upgrade = $upgrade }
    runner = $null
    admission = $null
    tools = $null
    certificates = New-Object System.Collections.ArrayList
    deployments = New-Object System.Collections.ArrayList
    runs = New-Object System.Collections.ArrayList
    launches = New-Object System.Collections.ArrayList
    checks = New-Object System.Collections.ArrayList
    cleanup = $null
    failures = @()
}
# Everything this run may change is recorded here after admission; cleanup
# touches nothing else, and nothing at all when admission fails.
$ledger = New-JstiLifecycleLedger
$ownershipOperations = Get-JstiWindowsOwnershipOperations $name

# Each phase's helpers live beside this script and share its state.
. (Join-Path $PSScriptRoot 'LifecycleChecks.ps1')
. (Join-Path $PSScriptRoot 'LifecycleDeployment.ps1')
. (Join-Path $PSScriptRoot 'LifecycleInstallation.ps1')
. (Join-Path $PSScriptRoot 'LifecycleAppRun.ps1')
$staticModules = Get-StaticRuntimeModules
$bundledModules = @($bundleManifest.dependencies.bundled.PSObject.Properties | ForEach-Object { $_.Value.name })

# --- the lifecycle ---------------------------------------------------------------------------------------------
$expectationsPath = Join-Path $workspace 'fixture-expectations.json'
try {
    $session = (Get-Process -Id $PID).SessionId
    $report.runner = [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        caption = (Get-CimInstance Win32_OperatingSystem).Caption
        build = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        architecture = $env:PROCESSOR_ARCHITECTURE
        powershell = $PSVersionTable.PSVersion.ToString()
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        harnessIntegrityLevel = [Jsti.PackageLifecycle.Native]::GetIntegrityLevel([uint32] $PID)
        session = $session
        explorerInSession = [bool] (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        enableLUA = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
        consentPromptBehaviorAdmin = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin'
        allowAllTrustedApps = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps'
        swiftOnPath = [bool] (Get-Command swift.exe -ErrorAction SilentlyContinue)
        dataDirectory = $dataDirectory
    }

    # Admit only a pristine machine. Every probe below is read-only; a refused
    # run changes nothing, and its cleanup is skipped.
    $observed = [ordered]@{
        dataDirectory = Test-Path -LiteralPath $dataDirectory
        registrations = @(Get-AppxPackage -Name $name -AllUsers | ForEach-Object { $_.PackageFullName })
        packageData = Test-Path -LiteralPath $packageDataDirectory
        alias = Test-Path -LiteralPath $aliasPath
        cliAlias = Test-Path -LiteralPath $cliAliasPath
        processes = @(Get-Process -Name SpeakWindows, speak -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        publisherCertificates = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\TrustedPeople |
            Where-Object { $_.Subject -eq $base.publisher } | ForEach-Object { $_.PSPath })
    }
    $report.admission = Test-JstiLifecycleAdmission $ledger $observed
    Assert-Check 'The machine has no Just Speak to It data, registration, alias, process or test certificate' (
        $report.admission.admitted) $report.admission
    Set-JstiOwnedDataDirectory $ledger $dataDirectory

    # --- signing with the ephemeral certificate through the external-signing path ---
    $trusted = New-EphemeralCertificate 'trusted signer'
    $untrusted = New-EphemeralCertificate 'untrusted signer for the negative control'
    Add-TrustedPeople $trusted
    $signer = Join-Path $PSScriptRoot 'sign-windows-package.ps1'
    $signedBase = Join-Path $packagesDirectory 'base-signed.msix'
    $signedUpgrade = Join-Path $packagesDirectory 'upgrade-signed.msix'
    $untrustedUpgrade = Join-Path $packagesDirectory 'upgrade-untrusted.msix'
    $tamperedUpgrade = Join-Path $packagesDirectory 'upgrade-tampered.msix'
    & $signer -Package $basePackage -Output $signedBase -ToolCache $ToolCache -CertificateThumbprint $trusted.Thumbprint -Layout $baseLayout -Python $Python
    & $signer -Package $upgradePackage -Output $signedUpgrade -ToolCache $ToolCache -CertificateThumbprint $trusted.Thumbprint -Layout $upgradeLayout -Python $Python
    & $signer -Package $upgradePackage -Output $untrustedUpgrade -ToolCache $ToolCache -CertificateThumbprint $untrusted.Thumbprint -Layout $upgradeLayout -Python $Python
    # Only a file the upgrade changes is read during the upgrade; unchanged files are reused from the installed base.
    $tamper = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'tamper', '--package', $signedUpgrade,
        '--output', $tamperedUpgrade, '--reference', $signedBase)
    Assert-Check 'A signed upgrade with one changed payload byte is prepared' ($tamper.ExitCode -eq 0) $tamper.StandardOutput.Trim()
    $report.tools = (Read-JstiJson (Join-Path $packagesDirectory 'base-signed.sign.json')).signTool

    # --- phase 1: fresh machine ---------------------------------------------------------
    $attempt = Invoke-Deployment 'Install a tampered package on a fresh machine' {
        Add-AppxPackage -Path $tamperedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'A tampered package is refused' (-not $attempt.succeeded) $attempt
    Assert-Check 'The refused package leaves nothing registered or written' (
        (Get-Registrations).Count -eq 0 -and -not (Test-Path -LiteralPath $dataDirectory)) $null

    $deployment = Invoke-Deployment 'Install the base version' {
        Add-AppxPackage -Path $signedBase } -Registers $base.packageFullName
    Assert-Check 'The base version installs' $deployment.succeeded $deployment
    $installed = Assert-Installed 'The base version' $base $baseLayout
    Assert-Check 'Installing creates no user data' (-not (Test-Path -LiteralPath $dataDirectory)) $dataDirectory
    Assert-AliasSelfTests 'base' $installed -All
    Assert-Check 'Self-tests write no user data' (-not (Test-Path -LiteralPath $dataDirectory)) $dataDirectory

    Invoke-StartMenuLaunch 'The base version on a fresh machine' $installed 0 '' | Out-Null
    $fresh = @(Get-ChildItem -LiteralPath $dataDirectory -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $_.FullName.Substring($dataDirectory.Length + 1) })
    Assert-Check 'A fresh packaged launch creates its data in the real %LOCALAPPDATA%\JustSpeakToIt' (
        Test-Path -LiteralPath (Join-Path $dataDirectory 'History') -PathType Container) $fresh
    Assert-Check 'A fresh packaged launch writes nothing to package-private AppData' (
        -not (Test-Path -LiteralPath $virtualisedDataDirectory)) $virtualisedDataDirectory
    Assert-Removed 'The base version installed on a fresh machine' $installed
    Assert-Check 'Data created by the packaged app survives uninstall' (
        Test-Path -LiteralPath (Join-Path $dataDirectory 'History') -PathType Container) $fresh
    Remove-Item -LiteralPath $dataDirectory -Recurse -Force

    # --- phase 2: existing portable-install data ------------------------------------------------
    $staging = Join-Path $workspace 'fixture'
    $made = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'fixture', '--directory', $staging,
        '--expectations', $expectationsPath)
    Assert-Check 'The synthetic portable-install fixture is written' ($made.ExitCode -eq 0) $made.StandardError.Trim()
    Copy-Item -LiteralPath $staging -Destination $dataDirectory -Recurse
    # This admitted run owns the fresh fixture; elevated defaults may name Administrators.
    $fixtureAccess = Get-Acl -LiteralPath $dataDirectory
    $fixtureAccess.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    Set-Acl -LiteralPath $dataDirectory -AclObject $fixtureAccess
    $expectations = Read-JstiJson $expectationsPath
    $transcript = $expectations.history.selectedTranscript
    $rows = [int] $expectations.history.rows
    Assert-UserData 'The seeded portable data' 'seeded'

    $attempt = Invoke-Deployment 'Install an untrusted package over portable data' {
        Add-AppxPackage -Path $untrustedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'A package signed by an untrusted certificate is refused' (-not $attempt.succeeded) $attempt
    Assert-Check 'The refused package leaves nothing registered' ((Get-Registrations).Count -eq 0) $null
    Assert-UserData 'The refused first install' 'seeded'

    $deployment = Invoke-Deployment 'Install the base version over portable data' {
        Add-AppxPackage -Path $signedBase } -Registers $base.packageFullName
    Assert-Check 'The base version installs over portable data' $deployment.succeeded $deployment
    $installed = Assert-Installed 'The base version over portable data' $base $baseLayout
    Assert-UserData 'Installing over portable data' 'seeded'
    Invoke-StartMenuLaunch 'The base version with portable data' $installed $rows $transcript | Out-Null
    Assert-UserData 'The first packaged launch' 'recovered'

    # --- phase 3: failed and cancelled upgrades ----------------------------------------------------
    # Cancellation runs first, before any refused attempt could leave the
    # upgrade staged and make its registration finish too quickly to cancel.
    $attempt = Invoke-WinRtAdd 'Cancel an upgrade' $signedUpgrade -Registers $upgrade.packageFullName -CancelImmediately
    # The task is Canceled, or the service reports ERROR_INSTALL_CANCEL / ERROR_CANCELLED.
    Assert-Check 'A cancelled upgrade does not complete' ($attempt.status -eq 'Canceled' -or (
        $attempt.status -eq 'Faulted' -and @('0x80073CF8', '0x800704C7') -contains $attempt.hresult)) $attempt
    Start-Sleep -Seconds 5
    Assert-PreviousIntact 'The cancelled upgrade' $base $baseLayout 'recovered'

    $attempt = Invoke-Deployment 'Upgrade with a tampered package' {
        Add-AppxPackage -Path $tamperedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'A tampered upgrade is refused' (-not $attempt.succeeded) $attempt
    Assert-PreviousIntact 'The refused tampered upgrade' $base $baseLayout 'recovered'

    $attempt = Invoke-Deployment 'Upgrade with an untrusted package' {
        Add-AppxPackage -Path $untrustedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'An upgrade signed by an untrusted certificate is refused' (-not $attempt.succeeded) $attempt
    Assert-PreviousIntact 'The refused untrusted upgrade' $base $baseLayout 'recovered'

    $running = Invoke-StartMenuLaunch 'The base version during an upgrade attempt' $installed $rows $transcript -LeaveRunning
    try {
        $attempt = Invoke-WinRtAdd 'Upgrade while the base version runs' $signedUpgrade `
            -Registers $upgrade.packageFullName -TimeoutSeconds 120
        Assert-Check 'An upgrade is refused while the app runs' (-not $attempt.succeeded) $attempt
        Add-Check 'The in-use refusal is ERROR_PACKAGES_IN_USE' ($attempt.hresult -eq '0x80073D02') $attempt.hresult
        $state = Read-AppState $running.window
        Assert-Check 'The running app is unaffected by the refused upgrade' (
            -not $running.process.HasExited -and $state.transcript -ceq $transcript -and @($state.historyRows).Count -eq $rows) $state
    } finally {
        $exit = Stop-App $running.process $running.window
    }
    Assert-Check 'The app closes normally after the refused upgrade' ($exit -eq 0) $exit
    Assert-PreviousIntact 'The refused in-use upgrade' $base $baseLayout 'recovered'
    Invoke-StartMenuLaunch 'The base version after refused upgrades' $installed $rows $transcript | Out-Null

    # --- phase 4: upgrade -----------------------------------------------------------------------------
    # Base-version exit and identity evidence is complete. Release only exited
    # ledger-owned process handles before Windows replaces the installed files.
    $released = Close-JstiExitedProcesses $script:ledger $ownershipOperations
    Assert-Check 'The upgrade releases exited owned process handles' ($released.failures.Count -eq 0) $released
    # Read before the upgrade: the object's location follows the live registration.
    $previousLocation = [string] $installed.InstallLocation
    $deployment = Invoke-Deployment 'Upgrade to the next version' {
        Add-AppxPackage -Path $signedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'The upgrade installs' $deployment.succeeded $deployment
    $previous = $installed
    $installed = Assert-Installed 'The upgraded version' $upgrade $upgradeLayout
    Assert-Check 'The upgrade keeps the package family and moves to a new install location' (
        $installed.PackageFamilyName -eq $previous.PackageFamilyName -and
        $installed.InstallLocation -ne $previousLocation) @($previousLocation, $installed.InstallLocation)
    Assert-UserData 'The upgrade' 'recovered'
    Assert-AliasSelfTests 'upgrade' $installed
    Invoke-StartMenuLaunch 'The upgraded version' $installed $rows $transcript | Out-Null
    Assert-UserData 'The upgraded launch' 'recovered'
    Add-Check 'The previous version''s files are removed after the upgrade' (
        $previousLocation -and (Wait-PathState $previousLocation $false 120)) $previousLocation
    if (-not $report.checks[$report.checks.Count - 1].passed) {
        $report.previousVersionDiagnostics = Get-PreviousPackageDiagnostics $name $base.packageFullName $previousLocation
    }

    # --- phase 5: uninstall keeps data; reinstall finds it ----------------------------------------------
    Assert-Removed 'The upgraded version' $installed
    Assert-UserData 'Uninstall' 'recovered'
    $deployment = Invoke-Deployment 'Reinstall after uninstall' {
        Add-AppxPackage -Path $signedUpgrade } -Registers $upgrade.packageFullName
    Assert-Check 'The package reinstalls after uninstall' $deployment.succeeded $deployment
    $installed = Assert-Installed 'The reinstalled version' $upgrade $upgradeLayout
    Invoke-StartMenuLaunch 'The reinstalled version' $installed $rows $transcript | Out-Null
    Assert-Removed 'The reinstalled version' $installed
    Assert-UserData 'The final uninstall' 'recovered'
} catch {
    $failures.Add("$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    Write-Host "Lifecycle stopped: $($_.Exception.Message)"
} finally {
    # Only ledger-owned state is touched; nothing at all after a refused admission.
    try {
        $cleanup = Invoke-JstiLifecycleCleanup -Ledger $ledger -Operations $ownershipOperations
    } catch {
        $cleanup = [ordered]@{ admitted = [bool] $ledger.Admitted; skipped = $false
            failures = @("cleanup stopped: $($_.Exception.Message)") }
    }
    $report.cleanup = $cleanup
    if ($cleanup.skipped) {
        Write-Host 'Admission was refused: no package, process, certificate or file was changed.'
    } else {
        Add-Check 'Every package, process, certificate and data directory this run created is removed' (
            $cleanup.failures.Count -eq 0) $cleanup
    }
    $report.failures = @($failures)
    Write-JstiJson (Join-Path $evidenceDirectory 'package-lifecycle-evidence.json') $report
}

if ($failures.Count) { throw ('Package lifecycle failed: ' + ($failures -join '; ')) }
Write-Host 'Install, launch, failed upgrades, upgrade, uninstall and reinstall passed with user data retained.'
