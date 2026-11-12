# Check recording and bounded, read-only failure diagnostics for the package
# lifecycle test.
#
# Dot-sourced by test-windows-package-lifecycle.ps1, after its inputs and
# identity are derived. Functions read that script's state ($name, $aumid,
# the layouts, $report, $ledger and $failures) at call time. Keep this file
# ASCII-only.

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

# Failure evidence only: read in a separate, time-bounded job. This never
# removes packages/files, changes the assertion, or proves absence of every
# possible OS reference. Unreadable, truncated and timed-out observations stay
# explicit; file contents and process command lines are not collected.
function Get-PreviousPackageDiagnostics(
    [string] $PackageName, [string] $PackageFullName, [string] $Location, [switch] $RemovalOnly
) {
    $result = [ordered]@{ packageFullName = $PackageFullName; location = $Location
        timeoutSeconds = 30; state = 'not-started'; observations = @(); error = $null }
    $job = $null
    try {
        $job = Start-Job -ArgumentList $PackageName, $PackageFullName, $Location, ([bool] $RemovalOnly) -ScriptBlock {
            param($PackageName, $PackageFullName, $Location, $RemovalOnly)
            $ErrorActionPreference = 'Stop'
            $kinds = @('registrations', 'provisioning', 'directory', 'processReferences')
            if ($RemovalOnly) { $kinds = @('registrations', 'directory') }
            foreach ($kind in $kinds) {
                $section = [ordered]@{ kind = $kind; rows = @(); truncated = $false; error = $null }
                try {
                    switch ($kind) {
                        'registrations' {
                            $items = @(Get-AppxPackage -AllUsers -Name $PackageName | Select-Object -First 33)
                            $section.truncated = $items.Count -gt 32
                            $section.rows = @($items | Select-Object -First 32 | ForEach-Object {
                                $users = @($_.PackageUserInformation)
                                [ordered]@{ packageFullName = $_.PackageFullName; installLocation = $_.InstallLocation
                                    isPreviousVersion = $_.PackageFullName -eq $PackageFullName; status = [string] $_.Status
                                    isPartiallyStaged = $_.IsPartiallyStaged; usersTruncated = $users.Count -gt 32
                                    users = @($users | Select-Object -First 32 | ForEach-Object {
                                        [ordered]@{ userSid = [string] $_.UserSecurityId; installState = [string] $_.InstallState }
                                    }) }
                            })
                        }
                        'provisioning' {
                            $items = @(Get-AppxProvisionedPackage -Online | Where-Object {
                                $_.DisplayName -eq $PackageName } | Select-Object -First 33)
                            $section.truncated = $items.Count -gt 32
                            $section.rows = @($items | Select-Object -First 32 | ForEach-Object {
                                [ordered]@{ packageName = $_.PackageName; version = [string] $_.Version
                                    architecture = [string] $_.Architecture }
                            })
                        }
                        'directory' {
                            $section.present = Test-Path -LiteralPath $Location
                            $section.scope = 'Immediate children only; no recursion or file contents'
                            if ($section.present) {
                                $items = @(Get-ChildItem -LiteralPath $Location -Force | Select-Object -First 257)
                                $section.truncated = $items.Count -gt 256
                                $section.rows = @($items | Select-Object -First 256 | ForEach-Object {
                                    [ordered]@{ name = $_.Name; directory = $_.PSIsContainer
                                        length = $(if ($_.PSIsContainer) { $null } else { $_.Length })
                                        attributes = [string] $_.Attributes }
                                })
                                $section.observedEntryCount = $section.rows.Count
                                $section.observedDirectoryCount = @($section.rows | Where-Object { $_.directory }).Count
                                $section.observedFileCount = $section.rows.Count - $section.observedDirectoryCount
                            }
                        }
                        'processReferences' {
                            $section.scope = 'Sampled process images/modules only; not kernel handles or all package graph references'
                            $section.unreadableProcessIds = @()
                            $section.unreadableCount = 0
                            $section.truncatedModuleLists = 0
                            $items = @(Get-Process | Select-Object -First 257)
                            $section.truncated = $items.Count -gt 256
                            $section.sampledProcessCount = [math]::Min($items.Count, 256)
                            $prefix = $Location.TrimEnd('\') + '\'
                            foreach ($process in ($items | Select-Object -First 256)) {
                                try {
                                    $modules = @($process.Modules | Select-Object -First 257)
                                    if ($modules.Count -gt 256) { $section.truncatedModuleLists++ }
                                    foreach ($module in ($modules | Select-Object -First 256)) {
                                        if ($module.FileName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                                            if ($section.rows.Count -lt 64) {
                                                $section.rows += [ordered]@{ processId = $process.Id; path = $module.FileName }
                                            } else { $section.truncated = $true }
                                        }
                                    }
                                } catch {
                                    $section.unreadableCount++
                                    if ($section.unreadableProcessIds.Count -lt 32) { $section.unreadableProcessIds += $process.Id }
                                } finally { $process.Dispose() }
                            }
                        }
                    }
                } catch { $section.error = $_.Exception.Message.Substring(0, [math]::Min(512, $_.Exception.Message.Length)) }
                # Emit each completed section so earlier evidence survives a later timeout.
                $section
            }
        }
        $null = Wait-Job -Job $job -Timeout 30
        $result.state = [string] $job.State
        if ($job.State -ne 'Completed') { Stop-Job -Job $job }
        $result.observations = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
    } catch { $result.error = $_.Exception.Message.Substring(0, [math]::Min(512, $_.Exception.Message.Length)) }
    finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
    return $result
}
