<#
.SYNOPSIS
Installs, launches, fails, upgrades and uninstalls the developer MSIX on a disposable Windows machine.

.DESCRIPTION
Run with Windows PowerShell 5.1, elevated, on a disposable machine only: it
trusts an ephemeral test certificate machine-wide, installs and removes the
package for the current user and writes %LOCALAPPDATA%\JustSpeakToIt. It refuses
to start if any of that state already exists, and removes what it created.

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

Add-Type -Path (Join-Path $PSScriptRoot 'PackageLifecycleNative.cs')

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
$versionOrder = [version] $upgrade.version -gt [version] $base.version
if (-not $versionOrder) { throw 'The upgrade layout must have a higher version than the base layout.' }
$name = $base.name
$aumid = $base.appUserModelId
$windowClass = $settings.application.windowClass
$dataDirectory = Join-Path $env:LOCALAPPDATA $settings.fileSystem.dataDirectoryName
$packageDataDirectory = Join-Path $env:LOCALAPPDATA ('Packages\' + $base.packageFamilyName)
$virtualisedDataDirectory = Join-Path $packageDataDirectory ('LocalCache\Local\' + $settings.fileSystem.dataDirectoryName)
$aliasPath = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $base.executionAlias)
$systemRoot = $env:SystemRoot
$isolatedPath = "$systemRoot\System32;$systemRoot;$systemRoot\System32\Wbem;$systemRoot\System32\WindowsPowerShell\v1.0"
$readyPattern = '^(Enter and save the selected provider.s API key|Ready\. Ctrl\+Alt\+Space)'
$controls = @{ transcript = 106; status = 107; history = 108; historyDetail = 109 }

$failures = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{
    schemaVersion = 1
    package = [ordered]@{ base = $base; upgrade = $upgrade }
    runner = $null
    tools = $null
    certificates = New-Object System.Collections.ArrayList
    deployments = New-Object System.Collections.ArrayList
    runs = New-Object System.Collections.ArrayList
    launches = New-Object System.Collections.ArrayList
    checks = New-Object System.Collections.ArrayList
    cleanup = $null
    failures = @()
}
$script:certificateThumbprints = New-Object System.Collections.ArrayList
$script:ownsDataDirectory = $false

# --- recording ---------------------------------------------------------------------------
function Add-Check([string] $Name, [bool] $Passed, $Details) {
    [void] $script:report.checks.Add([ordered]@{ name = $Name; passed = $Passed; details = $Details })
    if ($Passed) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures.Add($Name) }
}

function Assert-Check([string] $Name, [bool] $Passed, $Details) {
    Add-Check $Name $Passed $Details
    if (-not $Passed) { throw "Lifecycle check failed: $Name" }
}

function Get-RegistryValue([string] $Path, [string] $Value) {
    $item = Get-ItemProperty -LiteralPath $Path -Name $Value -ErrorAction SilentlyContinue
    if ($item) { return $item.$Value }
    return $null
}

function Wait-PathState([string] $Path, [bool] $Present, [int] $Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if ((Test-Path -LiteralPath $Path) -eq $Present) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return ((Test-Path -LiteralPath $Path) -eq $Present)
}

# --- certificates -----------------------------------------------------------------------------
function New-EphemeralCertificate([string] $Role) {
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $base.publisher -KeyUsage DigitalSignature `
        -FriendlyName "JSTI ephemeral CI package test ($Role)" -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    [void] $script:certificateThumbprints.Add($certificate.Thumbprint)
    [void] $script:report.certificates.Add([ordered]@{
        role = $Role; thumbprint = $certificate.Thumbprint; subject = $certificate.Subject
        notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o'); privateKeyExportable = $false
        trustedMachineWide = $false })
    return $certificate
}

function Add-TrustedPeople($Certificate) {
    # Only the public certificate is added; the private key never leaves CurrentUser\My.
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
    $store.Open('ReadWrite')
    try {
        $public = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$Certificate.RawData)
        $store.Add($public)
    } finally { $store.Close() }
    foreach ($entry in $script:report.certificates) {
        if ($entry.thumbprint -eq $Certificate.Thumbprint) { $entry.trustedMachineWide = $true }
    }
}

function Remove-EphemeralCertificates {
    $remaining = @()
    foreach ($thumbprint in $script:certificateThumbprints) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$thumbprint" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -DeleteKey -ErrorAction SilentlyContinue
        foreach ($store in @('Cert:\LocalMachine\TrustedPeople', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root')) {
            if (Test-Path -LiteralPath "$store\$thumbprint") { $remaining += "$store\$thumbprint" }
        }
    }
    return $remaining
}

# --- deployment -----------------------------------------------------------------------------------
function Get-HResult([string] $Message, [int] $Fallback) {
    $match = [regex]::Match($Message, '0x[0-9A-Fa-f]{8}')
    if ($match.Success) { return '0x' + $match.Value.Substring(2).ToUpperInvariant() }
    return '0x{0:X8}' -f $Fallback
}

function Invoke-Deployment([string] $Label, [scriptblock] $Operation) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $record = [ordered]@{ label = $Label; api = 'Appx cmdlet'; succeeded = $false; hresult = $null; message = $null; log = @() }
    try {
        & $Operation | Out-Null
        $record.succeeded = $true
    } catch {
        $record.message = $_.Exception.Message
        $record.hresult = Get-HResult $record.message $_.Exception.HResult
        $activity = [regex]::Match($record.message, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($activity.Success) {
            try {
                $record.log = @(Get-AppxLog -ActivityId $activity.Value | Select-Object -First 40 |
                    ForEach-Object { '{0} {1}' -f $_.Id, $_.Message })
            } catch { $record.log = @('Get-AppxLog failed: ' + $_.Exception.Message) }
        }
    }
    $record.seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    [void] $script:report.deployments.Add($record)
    $outcome = if ($record.succeeded) { 'succeeded' } else { 'failed ' + $record.hresult }
    Write-Host "$Label $outcome ($($record.seconds) s)"
    return $record
}

function Initialize-WinRtDeployment {
    if ($script:asTask) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]
    $null = [Windows.Management.Deployment.DeploymentResult, Windows.Management.Deployment, ContentType = WindowsRuntime]
    $null = [Windows.Management.Deployment.DeploymentProgress, Windows.Management.Deployment, ContentType = WindowsRuntime]
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 2 -and
        $_.GetParameters().Count -eq 2 -and $_.GetParameters()[1].ParameterType -eq [System.Threading.CancellationToken]
    } | Select-Object -First 1
    $script:asTask = $method.MakeGenericMethod([Windows.Management.Deployment.DeploymentResult],
        [Windows.Management.Deployment.DeploymentProgress])
    $script:packageManager = New-Object Windows.Management.Deployment.PackageManager
}

function Invoke-WinRtAdd([string] $Label, [string] $Path, [switch] $CancelImmediately, [int] $TimeoutSeconds = 240) {
    # The PackageManager API behind Add-AppxPackage and App Installer, used where
    # the test needs a bounded wait or a real cancellation of the operation.
    Initialize-WinRtDeployment
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $source = New-Object System.Threading.CancellationTokenSource
    $operation = $script:packageManager.AddPackageAsync((New-Object System.Uri $Path), $null,
        [Windows.Management.Deployment.DeploymentOptions]::None)
    $task = $script:asTask.Invoke($null, @($operation, $source.Token))
    if ($CancelImmediately) { $source.Cancel() }
    $finished = $false
    try { $finished = $task.Wait($TimeoutSeconds * 1000) } catch { $finished = $true }
    $record = [ordered]@{ label = $Label; api = 'PackageManager.AddPackageAsync'; cancelRequested = [bool] $CancelImmediately
        timedOut = -not $finished; status = $null; succeeded = $false; hresult = $null; message = $null }
    if (-not $finished) {
        $source.Cancel()
        try { [void] $task.Wait(60000) } catch { }
    }
    $record.status = [string] $task.Status
    $record.succeeded = $task.Status -eq 'RanToCompletion'
    if ($task.Exception) {
        $inner = $task.Exception.InnerException
        $record.message = $inner.Message
        $record.hresult = Get-HResult $inner.Message $inner.HResult
    }
    $record.seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    [void] $script:report.deployments.Add($record)
    Write-Host "$Label $($record.status) $($record.hresult) ($($record.seconds) s)"
    return $record
}

# --- registration and payload ------------------------------------------------------------------
# The unary comma keeps an empty or single-item result an array for .Count and [0].
function Get-Registrations { return ,@(Get-AppxPackage -Name $name) }

function Get-RegistrationRecord($Package) {
    return [ordered]@{
        packageFullName = $Package.PackageFullName; packageFamilyName = $Package.PackageFamilyName
        publisher = $Package.Publisher; publisherId = $Package.PublisherId; version = [string] $Package.Version
        architecture = [string] $Package.Architecture; installLocation = $Package.InstallLocation
        signatureKind = [string] $Package.SignatureKind; status = [string] $Package.Status
        isDevelopmentMode = $Package.IsDevelopmentMode; nonRemovable = $Package.NonRemovable
    }
}

function Test-InstalledPayload([string] $InstallLocation, [string] $Layout) {
    $manifest = Read-JstiJson (Join-Path $Layout 'package-manifest.json')
    $expected = @{}
    foreach ($row in $manifest.files) { $expected[$row.path.ToLowerInvariant()] = $row.sha256 }
    $expected['package-manifest.json'] = Get-JstiSha256 (Join-Path $Layout 'package-manifest.json')
    $problems = New-Object System.Collections.ArrayList
    $root = $InstallLocation.TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $key = $relative.ToLowerInvariant()
        if ($expected.ContainsKey($key)) {
            if ((Get-JstiSha256 $file.FullName) -ne $expected[$key]) { [void] $problems.Add("changed $relative") }
            $expected.Remove($key)
        } elseif (@('appxblockmap.xml', 'appxsignature.p7x', '[content_types].xml') -notcontains $key) {
            [void] $problems.Add("unexpected $relative")
        }
    }
    foreach ($key in $expected.Keys) { [void] $problems.Add("missing $key") }
    return [ordered]@{ passed = ($problems.Count -eq 0); problems = @($problems); installLocation = $InstallLocation }
}

function Get-StartMenuEntry {
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $match = @(Get-StartApps | Where-Object { $_.AppID -eq $aumid })
        $entryName = $null
        if ($match.Count) { $entryName = $match[0].Name }
        return [ordered]@{ source = 'Get-StartApps'; present = ($match.Count -gt 0); name = $entryName }
    }
    $shell = New-Object -ComObject Shell.Application
    $items = @($shell.NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Path -eq $aumid })
    $entryName = $null
    if ($items.Count) { $entryName = $items[0].Name }
    return [ordered]@{ source = 'shell:AppsFolder'; present = ($items.Count -gt 0); name = $entryName }
}

function Wait-StartMenuEntry([bool] $Present, [int] $Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $entry = Get-StartMenuEntry
        if ($entry.present -eq $Present) { return $entry }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $entry
}

function Assert-Installed([string] $Label, $Expected, [string] $Layout) {
    $registrations = Get-Registrations
    $records = @($registrations | ForEach-Object { Get-RegistrationRecord $_ })
    Assert-Check "$Label registers exactly one version of the family" ($registrations.Count -eq 1) $records
    $package = $registrations[0]
    $record = Get-RegistrationRecord $package
    Assert-Check "$Label registers the expected identity and signature" (
        $package.PackageFullName -eq $Expected.packageFullName -and
        $package.PackageFamilyName -eq $Expected.packageFamilyName -and
        $package.Publisher -ceq $Expected.publisher -and [string] $package.Version -eq $Expected.version -and
        [string] $package.SignatureKind -ne 'None' -and -not $package.IsDevelopmentMode -and
        [string] $package.Status -eq 'Ok' -and -not $package.NonRemovable) $record
    $payload = Test-InstalledPayload $package.InstallLocation $Layout
    Assert-Check "$Label installs exactly the verified payload" $payload.passed $payload
    $entry = Wait-StartMenuEntry $true
    Assert-Check "$Label appears in the Start menu" ($entry.present -and $entry.name -eq $Expected.displayName) $entry
    Assert-Check "$Label registers its execution alias" (Wait-PathState $aliasPath $true 60) $aliasPath
    return $package
}

function Assert-Removed([string] $Label, $Package) {
    $deployment = Invoke-Deployment "Uninstall $Label" { Remove-AppxPackage -Package $Package.PackageFullName }
    Assert-Check "$Label uninstalls through the normal package removal" $deployment.succeeded $deployment
    Assert-Check "$Label leaves no registered version" ((Get-Registrations).Count -eq 0) @((Get-Registrations) | ForEach-Object { $_.PackageFullName })
    $entry = Wait-StartMenuEntry $false
    Assert-Check "$Label removes its Start menu entry" (-not $entry.present) $entry
    Assert-Check "$Label removes its execution alias" (Wait-PathState $aliasPath $false 60) $aliasPath
    Assert-Check "$Label removes package-private app data" (Wait-PathState $packageDataDirectory $false 120) $packageDataDirectory
    Add-Check "$Label removes its installed files" (Wait-PathState $Package.InstallLocation $false 120) $Package.InstallLocation
}

# --- user data ---------------------------------------------------------------------------------------
function Test-UserData([string] $Label, [string] $State) {
    $reportPath = Join-Path $evidenceDirectory ('data-' + ($Label -replace '[^A-Za-z0-9]+', '-') + '.json')
    $result = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'check', '--directory', $dataDirectory,
        '--expectations', $expectationsPath, '--state', $State, '--report', $reportPath)
    $failures = @('user data check did not run: ' + $result.StandardError.Trim())
    $created = @()
    if (Test-Path -LiteralPath $reportPath) {
        $data = Read-JstiJson $reportPath
        $failures = @($data.failures)
        $created = @($data.appCreatedFiles)
    }
    return [ordered]@{ passed = ($result.ExitCode -eq 0); state = $State; failures = $failures; appCreatedFiles = $created }
}

function Assert-UserData([string] $Label, [string] $State) {
    $data = Test-UserData $Label $State
    Assert-Check "$Label keeps every user file" $data.passed $data
    Assert-Check "$Label writes nothing to package-private AppData" (-not (Test-Path -LiteralPath $virtualisedDataDirectory)) $virtualisedDataDirectory
}

function Assert-PreviousIntact([string] $Label, $Expected, [string] $Layout, [string] $State) {
    $registrations = Get-Registrations
    Assert-Check "$Label keeps the previous version as the only registration" (
        $registrations.Count -eq 1 -and $registrations[0].PackageFullName -eq $Expected.packageFullName) @(
        $registrations | ForEach-Object { $_.PackageFullName })
    $payload = Test-InstalledPayload $registrations[0].InstallLocation $Layout
    Assert-Check "$Label leaves the previous version's files unchanged" $payload.passed $payload
    Assert-UserData $Label $State
}

# --- running the installed app ---------------------------------------------------------------------------
function Get-StaticRuntimeModules {
    $names = @()
    foreach ($property in $bundleManifest.dependencies.bundled.PSObject.Properties) {
        if (@($property.Value.importedBy | Where-Object { $_.kind -eq 'static' }).Count) { $names += $property.Value.name }
    }
    return $names
}
$staticModules = Get-StaticRuntimeModules
$bundledModules = @($bundleManifest.dependencies.bundled.PSObject.Properties | ForEach-Object { $_.Value.name })

function Get-ModuleProvenance($Loaded, [string] $InstallLocation) {
    $root = $InstallLocation.TrimEnd('\') + '\'
    $windows = $systemRoot.TrimEnd('\') + '\'
    $fromPackage = @(); $fromWindows = @(); $foreign = @()
    foreach ($path in ($Loaded.Values | Sort-Object)) {
        if ($path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $fromPackage += $path.Substring($root.Length) }
        elseif ($path.StartsWith($windows, [System.StringComparison]::OrdinalIgnoreCase)) { $fromWindows += $path }
        else { $foreign += $path }
    }
    $missing = @($staticModules | Where-Object { $fromPackage -notcontains $_ })
    $elsewhere = @()
    foreach ($path in $fromWindows + $foreign) {
        if ($bundledModules -contains [System.IO.Path]::GetFileName($path)) { $elsewhere += $path }
    }
    return [ordered]@{
        fromPackage = $fromPackage; fromWindowsCount = $fromWindows.Count; foreign = $foreign
        staticRuntimeModulesNotObserved = $missing; bundledModulesLoadedElsewhere = $elsewhere
        passed = ($fromPackage -contains 'SpeakWindows.exe') -and $foreign.Count -eq 0 -and $missing.Count -eq 0 -and
            $elsewhere.Count -eq 0
    }
}

function Read-LoadedModules($Process) {
    $loaded = @{}
    $Process.Refresh()
    foreach ($module in $Process.Modules) { $loaded[$module.FileName.ToLowerInvariant()] = $module.FileName }
    return $loaded
}

function Invoke-AliasRun([string] $Label, [string] $Arguments, $Installed, [int] $Seconds, [hashtable] $Environment = @{},
                         [switch] $Handshake) {
    # CreateProcess on the execution alias starts the packaged app with its
    # package identity while keeping this harness's streams and environment.
    $release = Join-Path $evidenceDirectory "$Label.release"
    Remove-Item -LiteralPath $release -Force -ErrorAction SilentlyContinue
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $aliasPath
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $emptyDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $variables = $startInfo.EnvironmentVariables
    foreach ($key in @($variables.Keys)) {
        if ($key -like 'SWIFT*' -or @('SDKROOT', 'DEVELOPER_DIR', 'ICU_DATA') -contains $key -or $key -like 'JSTI_*') {
            $variables.Remove($key)
        }
    }
    $variables['PATH'] = $isolatedPath
    if ($Handshake) { $variables['JSTI_BUNDLE_PROBE_RELEASE_PATH'] = $release }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    $loaded = @{}
    $identity = $null; $integrity = $null; $identityError = $null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        if ($null -eq $identity -and $null -eq $identityError) {
            try {
                $identity = [string] [Jsti.PackageLifecycle.Native]::GetPackageFullName([uint32] $process.Id)
                $integrity = [Jsti.PackageLifecycle.Native]::GetIntegrityLevel([uint32] $process.Id)
            } catch { $identityError = $_.Exception.Message }
        }
        try {
            foreach ($entry in (Read-LoadedModules $process).GetEnumerator()) { $loaded[$entry.Key] = $entry.Value }
            if ($Handshake) {
                $modules = Get-ModuleProvenance $loaded $Installed.InstallLocation
                if ($modules.staticRuntimeModulesNotObserved.Count -eq 0) { [System.IO.File]::WriteAllText($release, 'sampled') }
            }
        } catch { }
        if ($watch.Elapsed.TotalSeconds -gt $Seconds) {
            $process.Kill()
            throw "$Label exceeded $Seconds seconds."
        }
        Start-Sleep -Milliseconds 20
    }
    $process.WaitForExit()
    $output = $standardOutput.Result
    [System.IO.File]::WriteAllText((Join-Path $evidenceDirectory "$Label.log"), $output + $standardError.Result,
        (New-Object System.Text.UTF8Encoding $false))
    $run = [ordered]@{
        label = $Label; arguments = $Arguments; exitCode = $process.ExitCode; packageFullName = $identity
        integrityLevel = $integrity; identityError = $identityError
        modules = Get-ModuleProvenance $loaded $Installed.InstallLocation; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    }
    [void] $script:report.runs.Add($run)
    $run.output = $output
    return $run
}

function Start-FromStartMenu($Installed) {
    $existing = @(Get-Process -Name SpeakWindows -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $launch = [ordered]@{ method = 'IApplicationActivationManager.ActivateApplication'; activationResult = $null; processId = $null }
    try {
        $activation = [Jsti.PackageLifecycle.Native]::Activate($aumid, '')
        $launch.activationResult = '0x{0:X8}' -f $activation.HResult
        if ($activation.HResult -eq 0 -and $activation.ProcessId -ne 0) { $launch.processId = [int] $activation.ProcessId }
    } catch { $launch.activationResult = $_.Exception.Message }
    if (-not $launch.processId) {
        # The shell performs the same AUMID activation from the user's session.
        $launch.method = 'explorer.exe shell:AppsFolder'
        Start-Process -FilePath (Join-Path $systemRoot 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $aumid)
        $deadline = (Get-Date).AddSeconds(60)
        while (-not $launch.processId -and (Get-Date) -lt $deadline) {
            $candidate = Get-Process -Name SpeakWindows -ErrorAction SilentlyContinue | Where-Object {
                $existing -notcontains $_.Id -and $_.Path -and
                $_.Path.StartsWith($Installed.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -First 1
            if ($candidate) { $launch.processId = $candidate.Id } else { Start-Sleep -Milliseconds 250 }
        }
        if (-not $launch.processId) { throw "Start menu activation did not start the installed app: $($launch.activationResult)" }
    }
    $process = [System.Diagnostics.Process]::GetProcessById($launch.processId)
    $null = $process.Handle
    return @{ process = $process; record = $launch }
}

function Read-AppState([IntPtr] $Window) {
    return [ordered]@{
        status = [Jsti.PackageLifecycle.Native]::GetControlText($Window, $controls.status)
        transcript = [Jsti.PackageLifecycle.Native]::GetControlText($Window, $controls.transcript)
        historyRows = @([Jsti.PackageLifecycle.Native]::GetListBoxItems($Window, $controls.history))
        historyDetail = [Jsti.PackageLifecycle.Native]::GetControlText($Window, $controls.historyDetail)
    }
}

function Wait-AppReady($Process, [int] $Rows, [string] $Transcript) {
    $deadline = (Get-Date).AddSeconds(90)
    $window = [IntPtr]::Zero
    $state = $null
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) { throw "The installed app exited with $($Process.ExitCode) while starting." }
        if ($window -eq [IntPtr]::Zero) { $window = [Jsti.PackageLifecycle.Native]::FindWindow([uint32] $Process.Id, $windowClass) }
        if ($window -ne [IntPtr]::Zero) {
            try { $state = Read-AppState $window } catch { $state = [ordered]@{ error = $_.Exception.Message } }
            if ($state.status -match $readyPattern -and @($state.historyRows).Count -eq $Rows -and
                $state.transcript -ceq $Transcript) { return @{ window = $window; state = $state } }
        }
        Start-Sleep -Milliseconds 250
    }
    throw ('The installed app did not show the expected History in 90 seconds: ' + ($state | ConvertTo-Json -Compress))
}

function Stop-App($Process, [IntPtr] $Window) {
    [void] [Jsti.PackageLifecycle.Native]::RequestClose($Window)
    if (-not $Process.WaitForExit(60000)) {
        $Process.Kill()
        throw 'The installed app did not exit within 60 seconds of WM_CLOSE.'
    }
    return $Process.ExitCode
}

function Invoke-StartMenuLaunch([string] $Label, $Installed, [int] $Rows, [string] $Transcript, [switch] $LeaveRunning) {
    $started = Start-FromStartMenu $Installed
    $process = $started.process
    $finished = $false
    try {
        $ready = Wait-AppReady $process $Rows $Transcript
        $record = [ordered]@{
            label = $Label; launch = $started.record
            packageFullName = [Jsti.PackageLifecycle.Native]::GetPackageFullName([uint32] $process.Id)
            integrityLevel = [Jsti.PackageLifecycle.Native]::GetIntegrityLevel([uint32] $process.Id)
            executable = $process.Path; state = $ready.state
            modules = Get-ModuleProvenance (Read-LoadedModules $process) $Installed.InstallLocation; exitCode = $null
        }
        [void] $script:report.launches.Add($record)
        Assert-Check "$Label starts from the Start menu entry with the package identity" (
            $record.packageFullName -eq $Installed.PackageFullName) $record.launch
        Assert-Check "$Label runs the installed executable" (
            $process.Path -eq (Join-Path $Installed.InstallLocation 'SpeakWindows.exe')) $process.Path
        Assert-Check "$Label loads the Swift and Visual C++ runtime only from its package" $record.modules.passed $record.modules
        if ($LeaveRunning) {
            $finished = $true
            return @{ process = $process; window = $ready.window; record = $record }
        }
        $record.exitCode = Stop-App $process $ready.window
        Assert-Check "$Label closes normally" ($record.exitCode -eq 0) $record.exitCode
        $finished = $true
        return $record
    } finally {
        if (-not $finished -and -not $process.HasExited) { $process.Kill() }
    }
}

function Assert-AliasSelfTests([string] $Label, $Installed, [switch] $All) {
    $run = Invoke-AliasRun "$Label-bundle-self-test" '--bundle-self-test' $Installed 60 -Handshake
    Assert-Check "$Label bundle self-test passes inside the package identity" (
        $run.exitCode -eq 0 -and $run.output -match 'JSTI_BUNDLE_SELF_TEST_OK' -and
        $run.packageFullName -eq $Installed.PackageFullName) $run
    Assert-Check "$Label bundle self-test loads its runtime only from the package" $run.modules.passed $run.modules
    if (-not $All) { return }
    $run = Invoke-AliasRun "$Label-self-test" '--self-test' $Installed 120
    Assert-Check "$Label native self-test passes inside the package identity" (
        $run.exitCode -eq 0 -and $run.output -match 'self-test passed' -and
        $run.packageFullName -eq $Installed.PackageFullName) (@{ exitCode = $run.exitCode; packageFullName = $run.packageFullName })
    $snapshot = Join-Path $evidenceDirectory "$Label-ui-smoke.bmp"
    $run = Invoke-AliasRun "$Label-ui-smoke-test" '--ui-smoke-test' $Installed 60 @{ JSTI_UI_SNAPSHOT_PATH = $snapshot }
    Assert-Check "$Label window smoke test passes inside the package identity" (
        $run.exitCode -eq 0 -and $run.output -match 'Native window creation and shutdown passed' -and
        (Test-Path -LiteralPath $snapshot) -and $run.packageFullName -eq $Installed.PackageFullName) (
        @{ exitCode = $run.exitCode; snapshot = (Test-Path -LiteralPath $snapshot) })
}

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

    # Refuse anything but a pristine machine: this test must never touch real user state.
    $pristine = [ordered]@{
        dataDirectory = Test-Path -LiteralPath $dataDirectory
        registered = @(Get-AppxPackage -Name $name -AllUsers).Count -gt 0
        packageData = Test-Path -LiteralPath $packageDataDirectory
        alias = Test-Path -LiteralPath $aliasPath
        publisherCertificates = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\TrustedPeople |
            Where-Object { $_.Subject -eq $base.publisher }).Count -gt 0
    }
    Assert-Check 'The machine has no prior Just Speak to It data, package or test certificate' (
        -not ($pristine.Values -contains $true)) $pristine
    $script:ownsDataDirectory = $true

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
    $tamper = Invoke-JstiTool -FilePath $pythonPath -Arguments @('-B', $support, 'tamper', '--package', $signedUpgrade, '--output', $tamperedUpgrade)
    Assert-Check 'A signed upgrade with one changed payload byte is prepared' ($tamper.ExitCode -eq 0) $tamper.StandardOutput.Trim()
    $report.tools = (Read-JstiJson (Join-Path $packagesDirectory 'base-signed.sign.json')).signTool

    # --- phase 1: fresh machine ---------------------------------------------------------
    $attempt = Invoke-Deployment 'Install a tampered package on a fresh machine' { Add-AppxPackage -Path $tamperedUpgrade }
    Assert-Check 'A tampered package is refused' (-not $attempt.succeeded) $attempt
    Assert-Check 'The refused package leaves nothing registered or written' (
        (Get-Registrations).Count -eq 0 -and -not (Test-Path -LiteralPath $dataDirectory)) $null

    $deployment = Invoke-Deployment 'Install the base version' { Add-AppxPackage -Path $signedBase }
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
    $expectations = Read-JstiJson $expectationsPath
    $transcript = $expectations.history.selectedTranscript
    $rows = [int] $expectations.history.rows
    Assert-UserData 'The seeded portable data' 'seeded'

    $attempt = Invoke-Deployment 'Install an untrusted package over portable data' { Add-AppxPackage -Path $untrustedUpgrade }
    Assert-Check 'A package signed by an untrusted certificate is refused' (-not $attempt.succeeded) $attempt
    Assert-Check 'The refused package leaves nothing registered' ((Get-Registrations).Count -eq 0) $null
    Assert-UserData 'The refused first install' 'seeded'

    $deployment = Invoke-Deployment 'Install the base version over portable data' { Add-AppxPackage -Path $signedBase }
    Assert-Check 'The base version installs over portable data' $deployment.succeeded $deployment
    $installed = Assert-Installed 'The base version over portable data' $base $baseLayout
    Assert-UserData 'Installing over portable data' 'seeded'
    Invoke-StartMenuLaunch 'The base version with portable data' $installed $rows $transcript | Out-Null
    Assert-UserData 'The first packaged launch' 'recovered'

    # --- phase 3: failed and cancelled upgrades ----------------------------------------------------
    # Cancellation runs first, before any refused attempt could leave the
    # upgrade staged and make its registration finish too quickly to cancel.
    $attempt = Invoke-WinRtAdd 'Cancel an upgrade' $signedUpgrade -CancelImmediately
    # The task is Canceled, or the service reports ERROR_INSTALL_CANCEL / ERROR_CANCELLED.
    Assert-Check 'A cancelled upgrade does not complete' ($attempt.status -eq 'Canceled' -or (
        $attempt.status -eq 'Faulted' -and @('0x80073CF8', '0x800704C7') -contains $attempt.hresult)) $attempt
    Start-Sleep -Seconds 5
    Assert-PreviousIntact 'The cancelled upgrade' $base $baseLayout 'recovered'

    $attempt = Invoke-Deployment 'Upgrade with a tampered package' { Add-AppxPackage -Path $tamperedUpgrade }
    Assert-Check 'A tampered upgrade is refused' (-not $attempt.succeeded) $attempt
    Assert-PreviousIntact 'The refused tampered upgrade' $base $baseLayout 'recovered'

    $attempt = Invoke-Deployment 'Upgrade with an untrusted package' { Add-AppxPackage -Path $untrustedUpgrade }
    Assert-Check 'An upgrade signed by an untrusted certificate is refused' (-not $attempt.succeeded) $attempt
    Assert-PreviousIntact 'The refused untrusted upgrade' $base $baseLayout 'recovered'

    $running = Invoke-StartMenuLaunch 'The base version during an upgrade attempt' $installed $rows $transcript -LeaveRunning
    try {
        $attempt = Invoke-WinRtAdd 'Upgrade while the base version runs' $signedUpgrade -TimeoutSeconds 120
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
    $deployment = Invoke-Deployment 'Upgrade to the next version' { Add-AppxPackage -Path $signedUpgrade }
    Assert-Check 'The upgrade installs' $deployment.succeeded $deployment
    $previous = $installed
    $installed = Assert-Installed 'The upgraded version' $upgrade $upgradeLayout
    Assert-Check 'The upgrade keeps the package family and moves to a new install location' (
        $installed.PackageFamilyName -eq $previous.PackageFamilyName -and
        $installed.InstallLocation -ne $previous.InstallLocation) @($previous.InstallLocation, $installed.InstallLocation)
    Assert-UserData 'The upgrade' 'recovered'
    Assert-AliasSelfTests 'upgrade' $installed
    Invoke-StartMenuLaunch 'The upgraded version' $installed $rows $transcript | Out-Null
    Assert-UserData 'The upgraded launch' 'recovered'
    Add-Check 'The previous version''s files are removed after the upgrade' (
        Wait-PathState $previous.InstallLocation $false 120) $previous.InstallLocation

    # --- phase 5: uninstall keeps data; reinstall finds it ----------------------------------------------
    Assert-Removed 'The upgraded version' $installed
    Assert-UserData 'Uninstall' 'recovered'
    $deployment = Invoke-Deployment 'Reinstall after uninstall' { Add-AppxPackage -Path $signedUpgrade }
    Assert-Check 'The package reinstalls after uninstall' $deployment.succeeded $deployment
    $installed = Assert-Installed 'The reinstalled version' $upgrade $upgradeLayout
    Invoke-StartMenuLaunch 'The reinstalled version' $installed $rows $transcript | Out-Null
    Assert-Removed 'The reinstalled version' $installed
    Assert-UserData 'The final uninstall' 'recovered'
} catch {
    $failures.Add("$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    Write-Host "Lifecycle stopped: $($_.Exception.Message)"
} finally {
    $cleanup = [ordered]@{}
    try {
        Get-Process -Name SpeakWindows -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path -like ('*\WindowsApps\' + $name + '_*') } | Stop-Process -Force
        foreach ($package in @(Get-AppxPackage -Name $name)) { Remove-AppxPackage -Package $package.PackageFullName }
        $cleanup.registrationsRemaining = @(Get-AppxPackage -Name $name).Count
    } catch { $cleanup.packageError = $_.Exception.Message }
    try {
        $cleanup.certificatesRemaining = @(Remove-EphemeralCertificates)
        Add-Check 'Every ephemeral test certificate and private key is removed' (
            $cleanup.certificatesRemaining.Count -eq 0) $cleanup.certificatesRemaining
    } catch { $cleanup.certificateError = $_.Exception.Message; $failures.Add('Certificate cleanup failed') }
    try {
        if ($script:ownsDataDirectory -and (Test-Path -LiteralPath $dataDirectory)) {
            Remove-Item -LiteralPath $dataDirectory -Recurse -Force
        }
        $cleanup.testDataRemoved = -not (Test-Path -LiteralPath $dataDirectory)
    } catch { $cleanup.dataError = $_.Exception.Message }
    $report.cleanup = $cleanup
    $report.failures = @($failures)
    Write-JstiJson (Join-Path $evidenceDirectory 'package-lifecycle-evidence.json') $report
}

if ($failures.Count) { throw ('Package lifecycle failed: ' + ($failures -join '; ')) }
Write-Host 'Install, launch, failed upgrades, upgrade, uninstall and reinstall passed with user data retained.'
