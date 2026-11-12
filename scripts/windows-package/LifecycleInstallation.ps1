# Registration, installed payload, Start menu entry and user data assertions
# for the package lifecycle test.
#
# Dot-sourced by test-windows-package-lifecycle.ps1, after its inputs and
# identity are derived. Functions read that script's state ($name, $aumid,
# the layouts, $report, $ledger and $failures) at call time. Keep this file
# ASCII-only.

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
        } elseif (@('appxblockmap.xml', 'appxsignature.p7x', '[content_types].xml',
                'appxmetadata/codeintegrity.cat') -notcontains $key) {
            [void] $problems.Add("unexpected $relative")
        }
    }
    foreach ($key in $expected.Keys) { [void] $problems.Add("missing $key") }
    return [ordered]@{ passed = ($problems.Count -eq 0); problems = @($problems); installLocation = $InstallLocation }
}

function Get-StartMenuEntry {
    $familyPrefix = "$($base.packageFamilyName)!"
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $entries = @(Get-StartApps | Where-Object {
            $_.AppID.StartsWith($familyPrefix, [StringComparison]::Ordinal)
        } | ForEach-Object { [ordered]@{ id = $_.AppID; name = $_.Name } })
        $source = 'Get-StartApps'
    } else {
        $shell = New-Object -ComObject Shell.Application
        $entries = @($shell.NameSpace('shell:AppsFolder').Items() | Where-Object {
            $_.Path.StartsWith($familyPrefix, [StringComparison]::Ordinal)
        } | ForEach-Object { [ordered]@{ id = $_.Path; name = $_.Name } })
        $source = 'shell:AppsFolder'
    }
    $match = @($entries | Where-Object { $_.id -ceq $aumid })
    $entryName = $null
    if ($match.Count) { $entryName = $match[0].name }
    return [ordered]@{ source = $source; present = ($match.Count -gt 0); name = $entryName; entries = $entries }
}

function Wait-StartMenuEntry([bool] $Present, [int] $Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $entry = Get-StartMenuEntry
        $ready = if ($Present) {
            $entry.present -and $entry.entries.Count -eq 1 -and
                $entry.entries[0].id -ceq $aumid -and $entry.name -eq $base.displayName
        } else {
            $entry.entries.Count -eq 0
        }
        if ($ready) { return $entry }
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
    Assert-Check "$Label has exactly one visible GUI Start entry and no CLI entry" (
        $entry.present -and $entry.name -eq $Expected.displayName -and $entry.entries.Count -eq 1 -and
        $entry.entries[0].id -ceq $Expected.appUserModelId) $entry
    Assert-Check "$Label registers its execution alias" (Wait-PathState $aliasPath $true 60) $aliasPath
    Assert-Check "$Label registers its CLI execution alias" (Wait-PathState $cliAliasPath $true 60) $cliAliasPath
    [xml] $installedManifest = Get-Content -LiteralPath (Join-Path $package.InstallLocation 'AppxManifest.xml') -Raw
    $applications = @($installedManifest.SelectNodes(
        "/*[local-name()='Package']/*[local-name()='Applications']/*[local-name()='Application']"))
    $cliApplications = @($applications | Where-Object { $_.GetAttribute('Id') -ceq $Expected.cliApplicationId })
    Assert-Check "$Label declares exactly the GUI and hidden CLI applications" (
        $applications.Count -eq 2 -and $applications[0].GetAttribute('Id') -ceq $Expected.applicationId -and
        $cliApplications.Count -eq 1 -and $cliApplications[0].GetAttribute('Executable') -ceq 'speak.exe' -and
        $cliApplications[0].SelectSingleNode("*[local-name()='VisualElements']").GetAttribute('AppListEntry') -ceq
            'none' -and
        $cliApplications[0].SelectNodes(".//*[local-name()='Extension']").Count -eq 1) $Expected.cliApplicationId
    $cliExtensions = @($installedManifest.SelectNodes(
        "//*[local-name()='Extension' and @Category='windows.appExecutionAlias' and @Executable='speak.exe']"))
    Assert-Check "$Label maps its CLI alias to speak.exe as a console" (
        $cliExtensions.Count -eq 1 -and
        $cliExtensions[0].ParentNode.ParentNode.GetAttribute('Id') -ceq $Expected.cliApplicationId -and
        $cliExtensions[0].SelectSingleNode("*[local-name()='AppExecutionAlias']").GetAttribute(
            'Subsystem', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10') -eq 'console' -and
        $cliExtensions[0].SelectSingleNode(".//*[local-name()='ExecutionAlias']").GetAttribute('Alias') -eq
            $Expected.cliExecutionAlias) $Expected.cliExecutionAlias
    return $package
}

function Assert-Removed([string] $Label, $Package) {
    # The package object reads its location from the live registration, which
    # is gone after removal; keep the path it had while installed.
    $installLocation = [string] $Package.InstallLocation
    # Exit/identity evidence was collected before this point. Release only
    # completed owned process handles before asking Windows to remove the app.
    $released = Close-JstiExitedProcesses $script:ledger $ownershipOperations
    Assert-Check "$Label releases exited owned process handles" ($released.failures.Count -eq 0) $released
    $deployment = Invoke-Deployment "Uninstall $Label" { Remove-AppxPackage -Package $Package.PackageFullName }
    Assert-Check "$Label uninstalls through the normal package removal" $deployment.succeeded $deployment
    Assert-Check "$Label leaves no registered version" ((Get-Registrations).Count -eq 0) @((Get-Registrations) | ForEach-Object { $_.PackageFullName })
    $entry = Wait-StartMenuEntry $false
    Assert-Check "$Label removes every family Start entry" (-not $entry.present -and $entry.entries.Count -eq 0) $entry
    Assert-Check "$Label removes its execution alias" (Wait-PathState $aliasPath $false 60) $aliasPath
    Assert-Check "$Label removes its CLI execution alias" (Wait-PathState $cliAliasPath $false 60) $cliAliasPath
    Assert-Check "$Label removes package-private app data" (Wait-PathState $packageDataDirectory $false 120) $packageDataDirectory
    $filesRemoved = $installLocation -and (Wait-PathState $installLocation $false 120)
    $removalDetails = $installLocation
    if (-not $filesRemoved) {
        # Read-only, capped diagnostics after the unchanged strict deadline.
        # Never delete retained files or turn delayed cleanup into a pass.
        $removalDetails = Get-PreviousPackageDiagnostics $name $Package.PackageFullName $installLocation
    }
    Add-Check "$Label removes its installed files" $filesRemoved $removalDetails
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
