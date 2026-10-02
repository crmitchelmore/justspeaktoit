# Ownership rules for the disposable-machine package tests. Dot-source this file.
#
# A run may change only state it recorded after a pristine admission: the
# package full names it deployed, the processes it started, the certificates it
# created and the data directory that was absent when it was admitted. When
# admission fails, cleanup changes nothing at all. Every state-changing
# operation is injected, so test-lifecycle-ownership.ps1 verifies these rules
# with fakes on any host. Compatible with Windows PowerShell 5.1 and
# PowerShell 7. Keep this file ASCII-only.

function New-JstiLifecycleLedger {
    return [pscustomobject]@{
        Admitted = $false
        Admission = $null
        Packages = New-Object System.Collections.ArrayList
        Processes = New-Object System.Collections.ArrayList
        Certificates = New-Object System.Collections.ArrayList
        DataDirectory = $null
    }
}

function Test-JstiLifecycleAdmission {
    # $Observed maps each kind of pre-existing state to what was found. Any
    # true, non-zero or non-empty value blocks admission.
    param(
        [Parameter(Mandatory = $true)] $Ledger,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Observed
    )
    if ($null -ne $Ledger.Admission) { throw 'Admission is decided once per run.' }
    $blocking = @()
    foreach ($key in $Observed.Keys) {
        if (@($Observed[$key] | Where-Object { $_ }).Count) { $blocking += $key }
    }
    $Ledger.Admitted = ($blocking.Count -eq 0)
    $Ledger.Admission = [ordered]@{ admitted = $Ledger.Admitted; blocking = $blocking; observed = $Observed }
    return $Ledger.Admission
}

function Assert-JstiAdmitted($Ledger) {
    if (-not $Ledger.Admitted) { throw 'Refusing to create or change state without a pristine admission.' }
}

function Add-JstiOwnedPackage($Ledger, [string] $PackageFullName) {
    # Record before deploying: after admission, a registration with this full
    # name can only come from this run.
    Assert-JstiAdmitted $Ledger
    if ($Ledger.Packages -notcontains $PackageFullName) { [void] $Ledger.Packages.Add($PackageFullName) }
}

function Add-JstiOwnedProcess($Ledger, $Process) {
    Assert-JstiAdmitted $Ledger
    [void] $Ledger.Processes.Add($Process)
}

function Add-JstiOwnedCertificate($Ledger, [string] $Thumbprint) {
    Assert-JstiAdmitted $Ledger
    [void] $Ledger.Certificates.Add($Thumbprint)
}

function Set-JstiOwnedDataDirectory($Ledger, [string] $Path) {
    # Admission proved this directory absent, so anything later found there
    # was created by this run.
    Assert-JstiAdmitted $Ledger
    $Ledger.DataDirectory = $Path
}

function Invoke-JstiLifecycleCleanup {
    # $Operations holds scriptblocks: IsRunning(process), StopProcess(process),
    # GetRegistrations(), RemovePackage(fullName), RemoveCertificate(thumbprint),
    # FindCertificate(thumbprint), TestPath(path), RemoveDirectory(path).
    # Returns a record whose failures list every piece of owned state that could
    # not be removed; the caller must fail the run when it is not empty.
    param(
        [Parameter(Mandatory = $true)] $Ledger,
        [Parameter(Mandatory = $true)] [hashtable] $Operations
    )
    $record = [ordered]@{
        admitted = [bool] $Ledger.Admitted; skipped = $false; failures = @()
        stoppedProcesses = @(); removedPackages = @(); foreignRegistrations = @()
        removedCertificates = @(); dataDirectoryRemoved = $false
    }
    if (-not $Ledger.Admitted) {
        $record.skipped = $true
        return $record
    }
    $failures = New-Object System.Collections.ArrayList
    # Stop owned processes first: a running app blocks its own removal.
    foreach ($process in $Ledger.Processes) {
        try {
            if (& $Operations.IsRunning $process) {
                & $Operations.StopProcess $process
                $record.stoppedProcesses += $process.Id
            }
            if (& $Operations.IsRunning $process) { [void] $failures.Add("process $($process.Id) is still running") }
        } catch { [void] $failures.Add("stopping process $($process.Id): $($_.Exception.Message)") }
    }
    try {
        foreach ($fullName in @(& $Operations.GetRegistrations)) {
            if ($Ledger.Packages -notcontains $fullName) {
                $record.foreignRegistrations += $fullName
                continue
            }
            try {
                & $Operations.RemovePackage $fullName
                $record.removedPackages += $fullName
            } catch { [void] $failures.Add("removing ${fullName}: $($_.Exception.Message)") }
        }
        $remaining = @(& $Operations.GetRegistrations | Where-Object { $Ledger.Packages -contains $_ })
        if ($remaining.Count) { [void] $failures.Add('owned registrations remain: ' + ($remaining -join ', ')) }
    } catch { [void] $failures.Add("listing registrations: $($_.Exception.Message)") }
    if ($record.foreignRegistrations.Count) {
        # Admission proved the family absent, so another actor changed the
        # machine during the run. Never remove it; fail the run instead.
        [void] $failures.Add('registrations this run does not own appeared and were left untouched: ' +
            ($record.foreignRegistrations -join ', '))
    }
    foreach ($thumbprint in $Ledger.Certificates) {
        try {
            & $Operations.RemoveCertificate $thumbprint
            $left = @(& $Operations.FindCertificate $thumbprint)
            if ($left.Count) { [void] $failures.Add("certificate $thumbprint remains in " + ($left -join ', ')) }
            else { $record.removedCertificates += $thumbprint }
        } catch { [void] $failures.Add("removing certificate ${thumbprint}: $($_.Exception.Message)") }
    }
    if ($Ledger.DataDirectory) {
        try {
            if (& $Operations.TestPath $Ledger.DataDirectory) { & $Operations.RemoveDirectory $Ledger.DataDirectory }
            $record.dataDirectoryRemoved = -not (& $Operations.TestPath $Ledger.DataDirectory)
            if (-not $record.dataDirectoryRemoved) { [void] $failures.Add("test data remains at $($Ledger.DataDirectory)") }
        } catch { [void] $failures.Add("removing test data: $($_.Exception.Message)") }
    }
    $record.failures = @($failures)
    return $record
}

function Get-JstiWindowsOwnershipOperations([string] $PackageName) {
    # The real operations for a Windows run; each acts on one owned item.
    return @{
        IsRunning = { param($Process) -not $Process.HasExited }
        StopProcess = {
            param($Process)
            if (-not $Process.HasExited) {
                try { $Process.Kill() } catch { if (-not $Process.HasExited) { throw } }
            }
            [void] $Process.WaitForExit(30000)
        }
        GetRegistrations = { @(Get-AppxPackage -Name $PackageName | ForEach-Object { $_.PackageFullName }) }.GetNewClosure()
        RemovePackage = { param($FullName) Remove-AppxPackage -Package $FullName }
        RemoveCertificate = {
            param($Thumbprint)
            Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$Thumbprint" -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$Thumbprint" -DeleteKey -ErrorAction SilentlyContinue
        }
        FindCertificate = {
            param($Thumbprint)
            @('Cert:\LocalMachine\TrustedPeople', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root') |
                ForEach-Object { "$_\$Thumbprint" } | Where-Object { Test-Path -LiteralPath $_ }
        }
        TestPath = { param($Path) Test-Path -LiteralPath $Path }
        RemoveDirectory = { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force }
    }
}
