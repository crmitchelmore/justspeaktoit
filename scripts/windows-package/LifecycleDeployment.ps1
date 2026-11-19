# Ephemeral test certificates and owned package deployment (Add-AppxPackage
# and the WinRT PackageManager) for the package lifecycle test.
#
# Dot-sourced by test-windows-package-lifecycle.ps1, after its inputs and
# identity are derived. Functions read that script's state ($name, $aumid,
# the layouts, $report, $ledger and $failures) at call time. Keep this file
# ASCII-only.

# --- certificates -----------------------------------------------------------------------------
function New-EphemeralCertificate([string] $Role) {
    Assert-JstiAdmitted $script:ledger
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $base.publisher -KeyUsage DigitalSignature `
        -FriendlyName "JSTI ephemeral CI package test ($Role)" -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Add-JstiOwnedCertificate $script:ledger $certificate.Thumbprint
    [void] $script:report.certificates.Add([ordered]@{
        role = $Role; thumbprint = $certificate.Thumbprint; subject = $certificate.Subject
        notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o'); privateKeyExportable = $false
        trustedMachineWide = $false })
    return $certificate
}

function Add-TrustedPeople($Certificate) {
    # Only the public certificate is added; the private key never leaves CurrentUser\My.
    Assert-JstiAdmitted $script:ledger
    if ($script:ledger.Certificates -notcontains $Certificate.Thumbprint) { throw 'Only a certificate this run created may be trusted.' }
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

# --- deployment -----------------------------------------------------------------------------------
function Get-HResult([string] $Message, [int] $Fallback) {
    $match = [regex]::Match($Message, '0x[0-9A-Fa-f]{8}')
    if ($match.Success) { return '0x' + $match.Value.Substring(2).ToUpperInvariant() }
    return '0x{0:X8}' -f $Fallback
}

function Invoke-Deployment([string] $Label, [scriptblock] $Operation, [string] $Registers) {
    # $Registers names the package full name the operation could register, so
    # cleanup owns it even when an expected refusal unexpectedly succeeds.
    Assert-JstiAdmitted $script:ledger
    if ($Registers) { Add-JstiOwnedPackage $script:ledger $Registers }
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

function Invoke-WinRtAdd([string] $Label, [string] $Path, [string] $Registers, [switch] $CancelImmediately,
                        [int] $TimeoutSeconds = 240) {
    # The PackageManager API behind Add-AppxPackage and App Installer, used where
    # the test needs a bounded wait or a real cancellation of the operation.
    if (-not $Registers) { throw 'A deployment must name the package full name it could register.' }
    Add-JstiOwnedPackage $script:ledger $Registers
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
