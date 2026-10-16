# Pure fixtures: no executable, GUI, device, credentials or deployment is touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BundleCLI.ps1')
function Assert-That([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$dependencies = @'
{
  "bundled": {
    "shared.dll": {"name":"shared.dll","importedBy":[{"importer":"SpeakWindows.exe","kind":"static"},{"importer":"speak.exe","kind":"static"}]},
    "gui.dll": {"name":"gui.dll","importedBy":[{"importer":"SpeakWindows.exe","kind":"static"}]},
    "cli.dll": {"name":"cli.dll","importedBy":[{"importer":"speak.exe","kind":"static"}]},
    "leaf.dll": {"name":"leaf.dll","importedBy":[{"importer":"shared.dll","kind":"static"}]},
    "delayed.dll": {"name":"delayed.dll","importedBy":[{"importer":"speak.exe","kind":"delay"}]},
    "delayleaf.dll": {"name":"delayleaf.dll","importedBy":[{"importer":"delayed.dll","kind":"static"}]},
    "whisper.dll": {"name":"whisper.dll","importedBy":[{"importer":"SpeakWindows.exe","kind":"runtime-loaded"}]},
    "lateleaf.dll": {"name":"lateleaf.dll","importedBy":[{"importer":"whisper.dll","kind":"runtime-static"}]}
  }
}
'@ | ConvertFrom-Json
Assert-That ((@(Get-BundleStaticModules $dependencies 'SpeakWindows.exe') -join ',') -eq 'gui.dll,leaf.dll,shared.dll') `
    'GUI sampling must require its complete static closure, never CLI-only/delayed/runtime-loaded modules.'
Assert-That ((@(Get-BundleStaticModules $dependencies 'speak.exe') -join ',') -eq 'cli.dll,leaf.dll,shared.dll') `
    'CLI sampling must not require GUI-only imports.'

function New-FakeProcess([string] $Output, [string] $Errors, [int] $ExitCode, [bool] $Exits = $true) {
    $fake = [pscustomobject]@{
        StandardOutput = New-Object System.IO.StringReader $Output
        StandardError = New-Object System.IO.StringReader $Errors
        ExitCode = $ExitCode; HasExited = $false; Exits = $Exits; Killed = $false; Disposed = $false
    }
    $fake | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $this.HasExited = $this.Exits; return $this.Exits }
    $fake | Add-Member ScriptMethod Kill { $this.Killed = $true; $this.HasExited = $true; $this.Exits = $true }
    $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return $fake
}

$help = "speak - automation CLI for Just Speak To It`n`nUSAGE`n  speak --help | --version`n"
$cases = @(
    @{ argument = '--help'; output = $help; errors = ''; code = 0; exits = $true; passed = $true },
    @{ argument = '--version'; output = "speak 0.0.0-dev`n"; errors = ''; code = 0; exits = $true; passed = $true },
    @{ argument = '--help'; output = 'GUI self-test passed'; errors = ''; code = 0; exits = $true; passed = $false },
    @{ argument = '--version'; output = 'speak '; errors = ''; code = 0; exits = $true; passed = $false },
    @{ argument = '--help'; output = $help; errors = ''; code = 9; exits = $true; passed = $false },
    @{ argument = '--help'; output = $help; errors = 'pipe connection attempted'; code = 0; exits = $true; passed = $false },
    @{ argument = '--help'; output = $help; errors = ''; code = 0; exits = $false; passed = $false }
)
foreach ($case in $cases) {
    $script:fake = New-FakeProcess $case.output $case.errors $case.code $case.exits
    $run = Invoke-BundleCLIReadOnly -Executable 'C:\Bundle with spaces\speak.exe' -Argument $case.argument `
        -WorkingDirectory 'C:\Unrelated directory' -IsolatedPath 'C:\Windows\System32' -Seconds 1 `
        -StartProcess {
            param($Info)
            Assert-That ($Info.FileName -eq 'C:\Bundle with spaces\speak.exe') 'The executable path must remain exact.'
            Assert-That ($Info.WorkingDirectory -eq 'C:\Unrelated directory') 'Use an unrelated working directory.'
            Assert-That ($Info.EnvironmentVariables['PATH'] -eq 'C:\Windows\System32') 'PATH must remain isolated.'
            Assert-That (-not $Info.UseShellExecute -and $Info.RedirectStandardOutput -and $Info.RedirectStandardError) `
                'Keep streams redirected and do not invoke a shell.'
            Assert-That (@($Info.EnvironmentVariables.Keys | Where-Object {
                $_ -like 'JSTI_*' -or $_ -like 'SWIFT*' -or @('ICU_DATA', 'SDKROOT', 'DEVELOPER_DIR') -contains $_
            }).Count -eq 0) 'Probe/toolchain overrides must not reach the CLI.'
            return $script:fake
        }
    Assert-That ($run.passed -eq $case.passed) 'Wrong CLI result.'
    Assert-That (($run.failures.Count -eq 0) -eq $case.passed) 'CLI failures must include a readable reason.'
    Assert-That ($run.timedOut -eq (-not $case.exits)) 'Timeout evidence must be explicit.'
    Assert-That ($script:fake.Disposed) 'Unowned process handles must be disposed.'
    if (-not $case.exits) { Assert-That $script:fake.Killed 'A timed-out process must be stopped by its own handle.' }
    Assert-That (-not $run.Contains('modulesFromBundle')) 'A short CLI receipt must not claim sampled modules.'
}
$script:fake = New-FakeProcess "speak 0.0.0-dev`n" '' 0
$script:owned = $null
$null = Invoke-BundleCLIReadOnly -Executable 'C:\Alias.exe' -Argument '--version' -WorkingDirectory 'C:\Empty' `
    -IsolatedPath 'C:\Windows' -OnStarted { param($Process) $script:owned = $Process } `
    -StartProcess { param($Info) $script:fake }
Assert-That ($script:owned -eq $script:fake -and -not $script:fake.Disposed) 'Lifecycle must retain its owned process.'
try {
    Invoke-BundleCLIReadOnly -Executable 'C:\Alias.exe' -Argument 'listen' -WorkingDirectory 'C:\Empty' `
        -IsolatedPath 'C:\Windows' -StartProcess { throw 'Must not start' }
    throw 'Non-read-only arguments must be refused.'
} catch [System.Management.Automation.ParameterBindingException] { }
Write-Host 'Bundle CLI fixtures passed (root reachability, output, isolation, timeout and ownership).'
