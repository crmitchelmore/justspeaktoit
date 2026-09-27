<#
.SYNOPSIS
Logs a disposable CI runner in to Certum SimplySign so SignTool can use the Certum certificate.

.DESCRIPTION
Certum's Open Source Code Signing certificate stays in Certum's SimplySign cloud
HSM. SimplySign Desktop presents it to Windows as a smart-card certificate in
Cert:\CurrentUser\My once its login dialog accepts the account e-mail and a
one-time password. This script:

1. refuses to run anywhere but a GitHub-hosted runner, because it installs software;
2. installs the pinned SimplySign Desktop MSI (SHA-256, size and a valid
   Authenticode signature are required);
3. computes the current one-time password from CERTUM_SIMPLYSIGN_OTP_URI with
   certum_signing.py and types the e-mail (CERTUM_SIMPLYSIGN_USERNAME) and the
   code into the login dialog;
4. waits for a certificate whose subject equals -Publisher exactly, with a
   private key, the code signing usage, a current validity period and, when
   given, -Thumbprint; and writes its thumbprint to $GITHUB_OUTPUT.

Neither secret is ever printed: both are masked first, and the code is passed
to the dialog only. The dialog is driven with keystrokes because SimplySign
Desktop has no command-line login; that makes this the fragile step, so a
failed login is retried once with a fresh code and then fails the job, never
falling back to an unsigned package. -Disconnect ends the session. Keep this
file ASCII-only for Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string] $Publisher,
    [ValidatePattern('^([0-9A-Fa-f]{40})?$')] [string] $Thumbprint = '',
    [string] $ToolCache = (Join-Path $env:RUNNER_TEMP 'certum-simplysign'),
    [string] $GitHubOutput = $env:GITHUB_OUTPUT,
    [string] $Python = 'python',
    [int] $CertificateTimeoutSeconds = 90,
    [switch] $Disconnect
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsPackageTools.ps1')

function Stop-JstiSimplySign {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'SimplySign*' } |
        ForEach-Object { try { $_.Kill(); $_.WaitForExit(10000) | Out-Null } catch { } }
}

if ($Disconnect) {
    Stop-JstiSimplySign
    Write-Host 'SimplySign Desktop session ended.'
    exit 0
}

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This script installs SimplySign Desktop and drives its login dialog; run it only on a disposable GitHub-hosted runner. Sign on your own PC with sign-windows-package-locally.ps1 instead.'
}
if (-not $Publisher) { throw 'Pass -Publisher: the certificate subject, exactly as WINDOWS_MSIX_PUBLISHER.' }
$username = $env:CERTUM_SIMPLYSIGN_USERNAME
if (-not $username -or -not $env:CERTUM_SIMPLYSIGN_OTP_URI) {
    throw 'CERTUM_SIMPLYSIGN_USERNAME and CERTUM_SIMPLYSIGN_OTP_URI must be set from the windows-signing environment secrets.'
}
Write-Host "::add-mask::$username"
Write-Host "::add-mask::$($env:CERTUM_SIMPLYSIGN_OTP_URI)"
$helper = Join-Path $PSScriptRoot 'certum_signing.py'
$check = Invoke-JstiTool -FilePath (Get-Command $Python -CommandType Application | Select-Object -First 1).Source `
    -Arguments @('-B', $helper, 'check')
if ($check.ExitCode -ne 0) { throw "CERTUM_SIMPLYSIGN_OTP_URI is not usable: $($check.StandardError.Trim())" }
Write-Host $check.StandardOutput.Trim()

# --- 1. The pinned SimplySign Desktop -------------------------------------------------
$pins = (Read-JstiJson (Join-Path $PSScriptRoot 'dependencies.json')).simplySignDesktop
New-Item -ItemType Directory -Force -Path $ToolCache | Out-Null
$installer = Join-Path $ToolCache $pins.name
if (-not (Test-Path -LiteralPath $installer)) {
    $partial = "$installer.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $pins.url -OutFile $partial -UseBasicParsing }
    finally { $ProgressPreference = $previousProgress }
    Move-Item -LiteralPath $partial -Destination $installer
}
$bytes = (Get-Item -LiteralPath $installer).Length
$digest = Get-JstiSha256 $installer
if ($bytes -ne $pins.bytes -or $digest -ne $pins.sha256) {
    Remove-Item -LiteralPath $installer -Force
    throw "$($pins.name) does not match its pin ($bytes bytes, SHA-256 $digest)."
}
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid') { throw "$($pins.name) has no valid Authenticode signature: $($signature.Status)" }
Write-Host "SimplySign Desktop $($pins.version) authenticated (signed by $($signature.SignerCertificate.Subject))."
$install = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
    '/i', "`"$installer`"", '/qn', '/norestart', '/l*v', "`"$(Join-Path $ToolCache 'install.log')`"")
if ($install.ExitCode -notin 0, 3010) { throw "SimplySign Desktop installation failed with exit code $($install.ExitCode)." }
$executable = $pins.executable
if (-not (Test-Path -LiteralPath $executable)) { throw "SimplySign Desktop is not at $executable after installation." }

# --- 2. Log in through the dialog ---------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class JstiForeground {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
}
'@

function Get-JstiSimplySignWindow {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'SimplySign*' -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
        Select-Object -First 1
}

function ConvertTo-JstiKeys([string] $Text) {
    # SendKeys treats + ^ % ~ ( ) { } [ ] as commands; brace each one.
    return [regex]::Replace($Text, '[+^%~(){}\[\]]', { param($match) '{' + $match.Value + '}' })
}

function Find-JstiCertificate {
    $now = Get-Date
    Get-ChildItem Cert:\CurrentUser\My | Where-Object {
        $_.Subject -ceq $Publisher -and $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -ge $now -and
        ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }) -and
        (-not $Thumbprint -or $_.Thumbprint -eq $Thumbprint.ToUpperInvariant())
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
}

$shell = New-Object -ComObject WScript.Shell
$certificate = $null
foreach ($attempt in 1, 2) {
    Stop-JstiSimplySign
    Start-Process -FilePath $executable | Out-Null
    $window = $null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $window -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $window = Get-JstiSimplySignWindow
    }
    if (-not $window) { Write-Host "SimplySign Desktop showed no login window (attempt $attempt)."; continue }
    $code = Invoke-JstiTool -FilePath (Get-Command $Python -CommandType Application | Select-Object -First 1).Source `
        -Arguments @('-B', $helper, 'code', '--minimum-remaining', '12')
    if ($code.ExitCode -ne 0) { throw "Could not compute the SimplySign one-time password: $($code.StandardError.Trim())" }
    $password = $code.StandardOutput.Trim()
    Write-Host "::add-mask::$password"
    [JstiForeground]::ShowWindow($window.MainWindowHandle, 9) | Out-Null
    [JstiForeground]::SetForegroundWindow($window.MainWindowHandle) | Out-Null
    $shell.AppActivate($window.Id) | Out-Null
    Start-Sleep -Milliseconds 800
    $shell.SendKeys((ConvertTo-JstiKeys $username))
    Start-Sleep -Milliseconds 200
    $shell.SendKeys('{TAB}')
    Start-Sleep -Milliseconds 200
    $shell.SendKeys($password)
    Start-Sleep -Milliseconds 200
    $shell.SendKeys('{ENTER}')
    $password = $null
    Write-Host "Submitted the SimplySign login (attempt $attempt); waiting for the certificate."
    $deadline = (Get-Date).AddSeconds($CertificateTimeoutSeconds)
    while (-not $certificate -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $certificate = Find-JstiCertificate
    }
    if ($certificate) { break }
}
if (-not $certificate) {
    $visible = @(Get-ChildItem Cert:\CurrentUser\My | ForEach-Object { "$($_.Subject) [$($_.Thumbprint)]" })
    Stop-JstiSimplySign
    throw ("No certificate with subject '$Publisher' appeared after two SimplySign logins. Certificates visible: " +
           ($(if ($visible.Count) { $visible -join '; ' } else { 'none' })) +
           '. Check the account, the one-time-password seed and that WINDOWS_MSIX_PUBLISHER is the exact subject.')
}
Write-Host "Certum certificate ready: $($certificate.Subject) [$($certificate.Thumbprint)], valid until $($certificate.NotAfter.ToString('u'))."
if ($GitHubOutput) {
    Add-Content -LiteralPath $GitHubOutput -Value "thumbprint=$($certificate.Thumbprint)" -Encoding utf8
}
