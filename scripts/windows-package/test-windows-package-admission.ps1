<#
.SYNOPSIS
Proves the lifecycle test refuses a machine with an existing installation and changes nothing.

.DESCRIPTION
Run with Windows PowerShell 5.1, elevated, on a disposable machine only. After
its own pristine admission this control creates an existing installation: the
base package signed with its own ephemeral certificate, the synthetic portable
data, and the installed app running with that History open. It records all of
it, then runs test-windows-package-lifecycle.ps1 in a child Windows PowerShell.
The child must refuse admission, skip its cleanup and exit non-zero, and the
registration, running app, window, user data, alias, package data and
certificates must be exactly as before. The control then removes only what it
created, through the same ownership ledger. Keep this file ASCII-only.
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

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this control with Windows PowerShell 5.1 (powershell.exe).' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated.' }
$hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
if (-not $hosted -and -not $DisposableMachine) {
    throw 'This control installs a package and trusts a temporary certificate. Run it only on a GitHub-hosted runner or a throwaway VM with -DisposableMachine.'
}
Add-Type -Path (Join-Path $PSScriptRoot 'PackageLifecycleNative.cs')

$workspace = (New-Item -ItemType Directory -Force -Path $Workspace).FullName
$evidenceDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'evidence')).FullName
$baseLayout = (Resolve-Path -LiteralPath $BaseLayout).Path
$basePackage = (Resolve-Path -LiteralPath $BasePackage).Path
$pythonPath = (Get-Command $Python -CommandType Application | Select-Object -First 1).Source
$support = Join-Path $PSScriptRoot 'lifecycle_support.py'
$settings = Read-JstiJson (Join-Path $PSScriptRoot 'package-identity.json')
$base = (Read-JstiJson (Join-Path $baseLayout 'package-manifest.json')).package
$name = $base.name
$dataDirectory = Join-Path $env:LOCALAPPDATA $settings.fileSystem.dataDirectoryName
$packageDataDirectory = Join-Path $env:LOCALAPPDATA ('Packages\' + $base.packageFamilyName)
$aliasPath = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $base.executionAlias)
$expectationsPath = Join-Path $workspace 'fixture-expectations.json'
$childWorkspace = Join-Path $workspace 'refused-lifecycle'
$childEvidencePath = Join-Path $childWorkspace 'evidence\package-lifecycle-evidence.json'

$ledger = New-JstiLifecycleLedger
$ownershipOperations = Get-JstiWindowsOwnershipOperations $name
$script:fixturePaths = @()
$failures = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{ schemaVersion = 1; package = $base; admission = $null; existing = $null; child = $null
    after = $null; checks = New-Object System.Collections.ArrayList; cleanup = $null; failures = @() }

function Add-Check([string] $Name, [bool] $Passed, $Details) {
    [void] $script:report.checks.Add([ordered]@{ name = $Name; passed = $Passed; details = $Details })
    if ($Passed) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures.Add($Name) }
}

function Assert-Check([string] $Name, [bool] $Passed, $Details) {
    Add-Check $Name $Passed $Details
    if (-not $Passed) { throw "Admission control check failed: $Name" }
}

function Get-ObservedState {
    return [ordered]@{
        dataDirectory = Test-Path -LiteralPath $dataDirectory
        registrations = @(Get-AppxPackage -Name $name -AllUsers | ForEach-Object { $_.PackageFullName })
        packageData = Test-Path -LiteralPath $packageDataDirectory
        alias = Test-Path -LiteralPath $aliasPath
        processes = @(Get-Process -Name SpeakWindows -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        publisherCertificates = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\TrustedPeople |
            Where-Object { $_.Subject -eq $base.publisher } | ForEach-Object { $_.PSPath } | Sort-Object)
    }
}

function Get-UserData([string] $Label) {
    $path = Join-Path $evidenceDirectory "data-$Label.json"
    $result = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'check', '--directory', $dataDirectory,
        '--expectations', $expectationsPath, '--state', 'recovered', '--report', $path)
    $data = Read-JstiJson $path
    $files = [ordered]@{}
    # Fixture files are user data; files the app itself may refresh are excluded.
    foreach ($property in $data.files.PSObject.Properties) {
        if ($script:fixturePaths -contains $property.Name) { $files[$property.Name] = $property.Value.sha256 }
    }
    return [ordered]@{ passed = ($result.ExitCode -eq 0); failures = @($data.failures); files = $files }
}

function Get-ExistingState($Process, [IntPtr] $Window) {
    $registration = @(Get-AppxPackage -Name $name) | Select-Object -First 1
    $state = [ordered]@{
        registrations = @(Get-AppxPackage -Name $name -AllUsers | ForEach-Object { $_.PackageFullName })
        installLocation = $(if ($registration) { $registration.InstallLocation } else { $null })
        processRunning = -not $Process.HasExited
        processId = $Process.Id
        historyRows = $null
        transcript = $null
        data = Get-UserData $(if ($script:report.existing) { 'after' } else { 'before' })
        alias = Test-Path -LiteralPath $aliasPath
        packageData = Test-Path -LiteralPath $packageDataDirectory
        publisherCertificates = (Get-ObservedState).publisherCertificates
    }
    if ($state.processRunning) {
        $state.historyRows = [Jsti.PackageLifecycle.Native]::GetListBoxCount($Window, 108)
        $state.transcript = [Jsti.PackageLifecycle.Native]::GetControlText($Window, 106)
    }
    return $state
}

$process = $null
$window = [IntPtr]::Zero
try {
    $report.admission = Test-JstiLifecycleAdmission $ledger (Get-ObservedState)
    Assert-Check 'The control starts on a machine without the app' $report.admission.admitted $report.admission
    Set-JstiOwnedDataDirectory $ledger $dataDirectory

    # --- an existing installation: signed package, user data and the running app ---
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $base.publisher -KeyUsage DigitalSignature `
        -FriendlyName 'JSTI ephemeral CI admission control' -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Add-JstiOwnedCertificate $ledger $certificate.Thumbprint
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
    $store.Open('ReadWrite')
    try {
        $store.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificate.RawData)))
    } finally { $store.Close() }
    $signed = Join-Path $workspace 'existing-signed.msix'
    & (Join-Path $PSScriptRoot 'sign-windows-package.ps1') -Package $basePackage -Output $signed -ToolCache $ToolCache `
        -CertificateThumbprint $certificate.Thumbprint -Layout $baseLayout -Python $Python
    Add-JstiOwnedPackage $ledger $base.packageFullName
    Add-AppxPackage -Path $signed
    $staging = Join-Path $workspace 'fixture'
    $made = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'fixture', '--directory', $staging,
        '--expectations', $expectationsPath)
    Assert-Check 'The existing user data is written' ($made.ExitCode -eq 0) $made.StandardError.Trim()
    Copy-Item -LiteralPath $staging -Destination $dataDirectory -Recurse
    $expectations = Read-JstiJson $expectationsPath
    $script:fixturePaths = @($expectations.files.PSObject.Properties | ForEach-Object { $_.Name })
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path -LiteralPath $aliasPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Assert-Check 'The existing installation provides its alias' (Test-Path -LiteralPath $aliasPath) $aliasPath

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $aliasPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $workspace
    $process = [System.Diagnostics.Process]::Start($startInfo)
    Add-JstiOwnedProcess $ledger $process
    $deadline = (Get-Date).AddSeconds(90)
    $rows = -1
    while ((Get-Date) -lt $deadline -and $rows -ne [int] $expectations.history.rows) {
        if ($process.HasExited) { throw "The existing app exited with $($process.ExitCode)." }
        if ($window -eq [IntPtr]::Zero) { $window = [Jsti.PackageLifecycle.Native]::FindWindow([uint32] $process.Id, $settings.application.windowClass) }
        if ($window -ne [IntPtr]::Zero) { try { $rows = [Jsti.PackageLifecycle.Native]::GetListBoxCount($window, 108) } catch { } }
        Start-Sleep -Milliseconds 250
    }
    Assert-Check 'The existing app is running with its History open' ($rows -eq [int] $expectations.history.rows) $rows
    $report.existing = Get-ExistingState $process $window
    Assert-Check 'The existing user data is intact before the refused run' $report.existing.data.passed $report.existing.data

    # --- the lifecycle test must refuse this machine and change nothing ---
    # The child runs under the machine's normal execution policy; nothing overrides it.
    $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'test-windows-package-lifecycle.ps1'),
        '-BaseLayout', $BaseLayout, '-BasePackage', $BasePackage, '-UpgradeLayout', $UpgradeLayout,
        '-UpgradePackage', $UpgradePackage, '-ToolCache', $ToolCache, '-Workspace', $childWorkspace, '-Python', $Python)
    if ($DisposableMachine) { $arguments += '-DisposableMachine' }
    $child = Invoke-JstiTool -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Arguments $arguments -LogPath (Join-Path $evidenceDirectory 'refused-lifecycle.log') -TimeoutSeconds 600
    $childEvidence = $null
    if (Test-Path -LiteralPath $childEvidencePath) { $childEvidence = Read-JstiJson $childEvidencePath }
    $report.child = [ordered]@{ exitCode = $child.ExitCode; admission = $(if ($childEvidence) { $childEvidence.admission })
        cleanup = $(if ($childEvidence) { $childEvidence.cleanup }) }
    Add-Check 'The lifecycle test fails on a machine with an existing installation' ($child.ExitCode -ne 0) $child.ExitCode
    Add-Check 'The lifecycle test refuses admission and skips its cleanup' (
        $childEvidence -and -not $childEvidence.admission.admitted -and $childEvidence.cleanup.skipped -and
        @($childEvidence.admission.blocking) -contains 'registrations' -and
        @($childEvidence.admission.blocking) -contains 'processes' -and
        @($childEvidence.admission.blocking) -contains 'dataDirectory') $report.child
    Add-Check 'The refused lifecycle test runs nothing after admission' ($childEvidence -and
        @($childEvidence.deployments).Count -eq 0 -and @($childEvidence.runs).Count -eq 0 -and
        @($childEvidence.launches).Count -eq 0 -and @($childEvidence.certificates).Count -eq 0) $null

    $report.after = Get-ExistingState $process $window
    $before = $report.existing
    $after = $report.after
    Add-Check 'The existing registration and version are unchanged' (
        (@($before.registrations) -join ',') -eq (@($after.registrations) -join ',') -and
        $before.installLocation -eq $after.installLocation) @($before.registrations, $after.registrations)
    Add-Check 'The existing app is still running and still shows its History' (
        $after.processRunning -and $after.historyRows -eq $before.historyRows -and $after.transcript -ceq $before.transcript) $after
    Add-Check 'The existing user data is unchanged' ($after.data.passed -and
        (($before.data.files | ConvertTo-Json -Compress) -eq ($after.data.files | ConvertTo-Json -Compress))) $after.data
    Add-Check 'The existing alias, package data and certificates are unchanged' (
        $after.alias -eq $before.alias -and $after.packageData -eq $before.packageData -and
        (@($after.publisherCertificates) -join ',') -eq (@($before.publisherCertificates) -join ',')) $after
} catch {
    $failures.Add("$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    Write-Host "Admission control stopped: $($_.Exception.Message)"
} finally {
    if ($process -and -not $process.HasExited -and $window -ne [IntPtr]::Zero) {
        [void] [Jsti.PackageLifecycle.Native]::RequestClose($window)
        [void] $process.WaitForExit(60000)
    }
    try {
        $cleanup = Invoke-JstiLifecycleCleanup -Ledger $ledger -Operations $ownershipOperations
    } catch {
        $cleanup = [ordered]@{ admitted = [bool] $ledger.Admitted; skipped = $false
            failures = @("cleanup stopped: $($_.Exception.Message)") }
    }
    $report.cleanup = $cleanup
    if (-not $cleanup.skipped) {
        Add-Check 'Everything the control created is removed' ($cleanup.failures.Count -eq 0) $cleanup
    }
    $report.failures = @($failures)
    Write-JstiJson (Join-Path $evidenceDirectory 'package-admission-evidence.json') $report
}

if ($failures.Count) { throw ('Admission control failed: ' + ($failures -join '; ')) }
Write-Host 'The lifecycle test refused a machine with an existing installation and changed nothing.'
