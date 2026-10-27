# Verifies the lifecycle ownership rules in LifecycleOwnership.ps1 against a
# fake machine. It changes no real package, process, certificate or file, so it
# runs on any host under Windows PowerShell 5.1 or PowerShell 7. Keep this file
# ASCII-only.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LifecycleOwnership.ps1')

$script:failed = 0
function Assert-That([bool] $Condition, [string] $Message) {
    if ($Condition) { Write-Host "PASS  $Message" } else { $script:failed++; Write-Host "FAIL  $Message" }
}

function New-FakeMachine([string[]] $Registrations = @(), [string[]] $Certificates = @(), [string[]] $Directories = @()) {
    $machine = [pscustomobject]@{
        Registrations = New-Object System.Collections.ArrayList
        Certificates = New-Object System.Collections.ArrayList
        Directories = New-Object System.Collections.ArrayList
        Calls = New-Object System.Collections.ArrayList
        FailRemovePackage = $false; IgnoreRemovePackage = $false; StickyProcess = $false
        StickyCertificate = $false; FailRemoveDirectory = $false
        FailDisposeProcess = $false; FailProcessState = $false
    }
    foreach ($item in $Registrations) { [void] $machine.Registrations.Add($item) }
    foreach ($item in $Certificates) { [void] $machine.Certificates.Add($item) }
    foreach ($item in $Directories) { [void] $machine.Directories.Add($item) }
    return $machine
}

function New-FakeProcess([int] $Id, [bool] $Running = $true) {
    return [pscustomobject]@{ Id = $Id; Running = $Running; Disposed = $false }
}

function Get-FakeOperations($Machine) {
    # Every mutation is logged, so a test can prove exactly what was touched.
    return @{
        IsRunning = {
            param($Process)
            if ($Machine.FailProcessState) { throw 'synthetic process-state failure' }
            [bool] $Process.Running
        }.GetNewClosure()
        DisposeProcess = {
            param($Process)
            [void] $Machine.Calls.Add("dispose $($Process.Id)")
            if ($Machine.FailDisposeProcess) { throw 'synthetic disposal failure' }
            $Process.Disposed = $true
        }.GetNewClosure()
        StopProcess = {
            param($Process)
            [void] $Machine.Calls.Add("stop $($Process.Id)")
            if (-not $Machine.StickyProcess) { $Process.Running = $false }
        }.GetNewClosure()
        GetRegistrations = { @($Machine.Registrations) }.GetNewClosure()
        RemovePackage = {
            param($FullName)
            [void] $Machine.Calls.Add("remove $FullName")
            if ($Machine.FailRemovePackage) { throw 'synthetic removal failure' }
            if (-not $Machine.IgnoreRemovePackage) { $Machine.Registrations.Remove($FullName) }
        }.GetNewClosure()
        RemoveCertificate = {
            param($Thumbprint)
            [void] $Machine.Calls.Add("certificate $Thumbprint")
            if (-not $Machine.StickyCertificate) { $Machine.Certificates.Remove($Thumbprint) }
        }.GetNewClosure()
        FindCertificate = {
            param($Thumbprint)
            @($Machine.Certificates | Where-Object { $_ -eq $Thumbprint } | ForEach-Object { "Cert:\CurrentUser\My\$_" })
        }.GetNewClosure()
        TestPath = { param($Path) $Machine.Directories -contains $Path }.GetNewClosure()
        RemoveDirectory = {
            param($Path)
            [void] $Machine.Calls.Add("delete $Path")
            if ($Machine.FailRemoveDirectory) { throw 'synthetic delete failure' }
            $Machine.Directories.Remove($Path)
        }.GetNewClosure()
    }
}

$family = 'com.justspeaktoit.windows.developer'
$existing = "${family}_0.0.5.1_x64__12qtdfzdxrxs0"
$base = "${family}_0.0.9.1_x64__12qtdfzdxrxs0"
$upgrade = "${family}_0.0.9.2_x64__12qtdfzdxrxs0"
$data = 'C:\Users\runner\AppData\Local\JustSpeakToIt'
$clean = [ordered]@{ dataDirectory = $false; registrations = @(); packageData = $false; alias = $false
    processes = @(); publisherCertificates = @() }

function New-AdmittedLedger {
    $ledger = New-JstiLifecycleLedger
    $admission = Test-JstiLifecycleAdmission $ledger $clean
    if (-not $admission.admitted) { throw 'A clean machine must be admitted.' }
    return $ledger
}

# A CLI alias by itself is user-owned state, even without GUI data or a registration.
$cliLedger = New-JstiLifecycleLedger
$cliAdmission = Test-JstiLifecycleAdmission $cliLedger ([ordered]@{ alias = $false; cliAlias = $true })
Assert-That (-not $cliAdmission.admitted -and (@($cliAdmission.blocking) -join ',') -eq 'cliAlias') `
    'An existing CLI-only alias blocks lifecycle admission'
$cliMachine = New-FakeMachine
$cliCleanup = Invoke-JstiLifecycleCleanup $cliLedger (Get-FakeOperations $cliMachine)
Assert-That ($cliCleanup.skipped -and $cliMachine.Calls.Count -eq 0) 'A CLI-only refusal changes nothing'

# --- a machine with an existing installation is refused and left untouched ---------
$machine = New-FakeMachine -Registrations @($existing) -Certificates @('USERCERT') -Directories @($data)
$userApp = New-FakeProcess 4242
$ledger = New-JstiLifecycleLedger
$admission = Test-JstiLifecycleAdmission $ledger ([ordered]@{
    dataDirectory = $true; registrations = @($existing); packageData = $true; alias = $true
    processes = @(4242); publisherCertificates = @('Cert:\CurrentUser\My\USERCERT') })
Assert-That (-not $admission.admitted) 'An existing installation blocks admission'
Assert-That ((@($admission.blocking) -join ',') -eq 'dataDirectory,registrations,packageData,alias,processes,publisherCertificates') 'Every kind of existing state is reported as blocking'
$attempts = @(
    { Add-JstiOwnedPackage $ledger $base }, { Add-JstiOwnedProcess $ledger $userApp },
    { Add-JstiOwnedCertificate $ledger 'NEW' }, { Set-JstiOwnedDataDirectory $ledger $data },
    { Close-JstiExitedProcesses $ledger (Get-FakeOperations $machine) })
foreach ($attempt in $attempts) {
    $refused = $false
    try { & $attempt } catch { $refused = $true }
    Assert-That $refused "Nothing can be owned without admission: $attempt"
}
$repeat = $false
try { $null = Test-JstiLifecycleAdmission $ledger $clean } catch { $repeat = $true }
Assert-That $repeat 'A refused run cannot be re-admitted'
$cleanup = Invoke-JstiLifecycleCleanup $ledger (Get-FakeOperations $machine)
Assert-That ($cleanup.skipped -and -not $cleanup.admitted -and $cleanup.failures.Count -eq 0) 'Cleanup after a refused admission is skipped'
Assert-That ($machine.Calls.Count -eq 0) 'A refused admission performs no process, package, certificate or file operation'
Assert-That ($userApp.Running -and $machine.Registrations -contains $existing -and
    $machine.Certificates -contains 'USERCERT' -and $machine.Directories -contains $data) 'The existing app, its version, certificate and data stay in place'

# --- an admitted run removes only what it owns ---------------------------------------------
$machine = New-FakeMachine -Registrations @($upgrade) -Certificates @('OWNED', 'USERCERT') -Directories @($data)
$ledger = New-AdmittedLedger
Add-JstiOwnedPackage $ledger $base
Add-JstiOwnedPackage $ledger $upgrade
Add-JstiOwnedPackage $ledger $upgrade
$running = New-FakeProcess 1
$finished = New-FakeProcess 2 $false
$foreignProcess = New-FakeProcess 3
Add-JstiOwnedProcess $ledger $running
Add-JstiOwnedProcess $ledger $finished
Add-JstiOwnedCertificate $ledger 'OWNED'
Set-JstiOwnedDataDirectory $ledger $data
$cleanup = Invoke-JstiLifecycleCleanup $ledger (Get-FakeOperations $machine)
Assert-That ($ledger.Packages.Count -eq 2) 'A full name is owned once however often it is deployed'
Assert-That ($cleanup.failures.Count -eq 0) 'Complete removal of owned state passes'
Assert-That ((@($machine.Calls) -join ';') -eq "stop 1;dispose 2;dispose 1;remove $upgrade;certificate OWNED;delete $data") 'Cleanup stops and releases owned processes before removing their package, certificate and data'
Assert-That (-not $running.Running -and $foreignProcess.Running) 'Only processes this run started are stopped'
Assert-That ($machine.Registrations.Count -eq 0 -and $machine.Certificates -contains 'USERCERT' -and
    $machine.Directories.Count -eq 0) 'Owned registrations, certificates and data are removed; others are kept'

# --- completed process handles are released before uninstall, once, without killing live/foreign state ---
$machine = New-FakeMachine
$ledger = New-AdmittedLedger
$live = New-FakeProcess 11
$finished = New-FakeProcess 12 $false
$foreign = New-FakeProcess 13 $false
Add-JstiOwnedProcess $ledger $live
Add-JstiOwnedProcess $ledger $finished
$released = Close-JstiExitedProcesses $ledger (Get-FakeOperations $machine)
Assert-That ($released.failures.Count -eq 0 -and (@($released.releasedProcessHandles) -join ',') -eq '12') `
    'Only the exited owned process handle is released'
Assert-That ($finished.Disposed -and -not $live.Disposed -and -not $foreign.Disposed -and $live.Running) `
    'Releasing completed handles never kills or disposes live or foreign processes'
Assert-That ($ledger.Processes.Count -eq 1 -and $ledger.Processes[0] -eq $live) `
    'Only successfully released processes leave the ownership ledger'
$null = Close-JstiExitedProcesses $ledger (Get-FakeOperations $machine)
Assert-That ((@($machine.Calls) -join ';') -eq 'dispose 12') 'Repeated release never disposes the same process twice'

foreach ($fault in @('FailDisposeProcess', 'FailProcessState')) {
    $machine = New-FakeMachine
    $machine.$fault = $true
    $ledger = New-AdmittedLedger
    $finished = New-FakeProcess 14 $false
    Add-JstiOwnedProcess $ledger $finished
    $released = Close-JstiExitedProcesses $ledger (Get-FakeOperations $machine)
    Assert-That ($released.failures.Count -eq 1 -and $released.failures[0] -like 'releasing exited process 14:*') `
        "$fault is reported as a resource-release failure"
    Assert-That (-not $finished.Disposed -and $ledger.Processes.Count -eq 1) `
        "$fault preserves ownership without claiming the handle was released"
    $machine.$fault = $false
    $released = Close-JstiExitedProcesses $ledger (Get-FakeOperations $machine)
    Assert-That ($released.failures.Count -eq 0 -and $finished.Disposed -and $ledger.Processes.Count -eq 0) `
        "$fault can retry a still-owned completed process safely"
}

# Final cleanup records disposal errors instead of silently passing or forgetting ownership.
$machine = New-FakeMachine
$machine.FailDisposeProcess = $true
$ledger = New-AdmittedLedger
$finished = New-FakeProcess 15 $false
Add-JstiOwnedProcess $ledger $finished
$cleanup = Invoke-JstiLifecycleCleanup $ledger (Get-FakeOperations $machine)
Assert-That ($cleanup.failures.Count -eq 1 -and $cleanup.failures[0] -like '*synthetic disposal failure*') `
    'Final cleanup propagates disposal failures'
Assert-That ($ledger.Processes.Count -eq 1 -and -not $finished.Disposed) `
    'A failed final disposal retains the exact owned process for diagnosis or retry'

# --- a registration the run does not own is never removed and fails the run -----------------
$machine = New-FakeMachine -Registrations @($existing, $upgrade)
$ledger = New-AdmittedLedger
Add-JstiOwnedPackage $ledger $upgrade
$cleanup = Invoke-JstiLifecycleCleanup $ledger (Get-FakeOperations $machine)
Assert-That ($machine.Registrations -contains $existing -and -not ($machine.Registrations -contains $upgrade)) 'A foreign registration is left in place while the owned one is removed'
Assert-That (@($cleanup.failures | Where-Object { $_ -like '*does not own*' }).Count -eq 1) 'A foreign registration fails the run'

# --- incomplete cleanup of owned state fails the run ------------------------------------------
$cases = @(
    @{ label = 'a failed package removal'; flag = 'FailRemovePackage'; expect = 'removing*synthetic removal failure' },
    @{ label = 'a registration that survives removal'; flag = 'IgnoreRemovePackage'; expect = 'owned registrations remain*' },
    @{ label = 'a process that keeps running'; flag = 'StickyProcess'; expect = 'process 7 is still running' },
    @{ label = 'a certificate that survives removal'; flag = 'StickyCertificate'; expect = 'certificate OWNED remains*' },
    @{ label = 'a failed data removal'; flag = 'FailRemoveDirectory'; expect = 'removing test data*' })
foreach ($case in $cases) {
    $machine = New-FakeMachine -Registrations @($upgrade) -Certificates @('OWNED') -Directories @($data)
    $machine.($case.flag) = $true
    $ledger = New-AdmittedLedger
    Add-JstiOwnedPackage $ledger $upgrade
    Add-JstiOwnedProcess $ledger (New-FakeProcess 7)
    Add-JstiOwnedCertificate $ledger 'OWNED'
    Set-JstiOwnedDataDirectory $ledger $data
    $cleanup = Invoke-JstiLifecycleCleanup $ledger (Get-FakeOperations $machine)
    Assert-That (@($cleanup.failures | Where-Object { $_ -like $case.expect }).Count -eq 1) "$($case.label) fails the run"
}

if ($script:failed) { throw "$($script:failed) lifecycle ownership checks failed." }
Write-Host 'Lifecycle ownership rules passed: a refused run changes nothing and cleanup removes only owned state.'
& (Join-Path $PSScriptRoot 'test-recording-feedback-readiness.ps1')

if (-not ('Jsti.PackageLifecycle.Native' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'PackageLifecycleNative.cs')
}
foreach ($case in @(
    @{ text = ''; expected = ''; label = 'empty stderr' },
    @{ text = 'startup failure'; expected = 'startup failure'; label = 'short stderr' },
    @{ text = ('x' * 5000); expected = (('x' * 32) + "`n[stderr truncated]`n"); label = 'oversized stderr' }
)) {
    $reader = New-Object System.IO.StringReader -ArgumentList (,[string] $case.text)
    try {
        $captured = [Jsti.PackageLifecycle.Native]::ReadBoundedOutputAsync($reader, 32).GetAwaiter().GetResult()
        Assert-That ($captured -ceq $case.expected) "$($case.label) retains exactly the bounded prefix"
        Assert-That ($reader.Read() -eq -1) "$($case.label) drains through EOF"
    } finally { $reader.Dispose() }
}
if ($script:failed) { throw "$($script:failed) lifecycle output checks failed." }
