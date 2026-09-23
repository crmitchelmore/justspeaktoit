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
    }
    foreach ($item in $Registrations) { [void] $machine.Registrations.Add($item) }
    foreach ($item in $Certificates) { [void] $machine.Certificates.Add($item) }
    foreach ($item in $Directories) { [void] $machine.Directories.Add($item) }
    return $machine
}

function New-FakeProcess([int] $Id, [bool] $Running = $true) {
    return [pscustomobject]@{ Id = $Id; Running = $Running }
}

function Get-FakeOperations($Machine) {
    # Every mutation is logged, so a test can prove exactly what was touched.
    return @{
        IsRunning = { param($Process) [bool] $Process.Running }
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
    { Add-JstiOwnedCertificate $ledger 'NEW' }, { Set-JstiOwnedDataDirectory $ledger $data })
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
Assert-That ((@($machine.Calls) -join ';') -eq "stop 1;remove $upgrade;certificate OWNED;delete $data") 'Cleanup touches exactly the owned running process, registration, certificate and data'
Assert-That (-not $running.Running -and $foreignProcess.Running) 'Only processes this run started are stopped'
Assert-That ($machine.Registrations.Count -eq 0 -and $machine.Certificates -contains 'USERCERT' -and
    $machine.Directories.Count -eq 0) 'Owned registrations, certificates and data are removed; others are kept'

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
