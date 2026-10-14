# Shared, device-free CLI checks and per-root static reachability. No deployment APIs.

function Get-BundleStaticModules($Dependencies, [string] $Root) {
    $reached = @{}
    $reached[$Root.ToLowerInvariant()] = $true
    $required = @{}
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($property in $Dependencies.bundled.PSObject.Properties) {
            $entry = $property.Value
            $lower = $entry.name.ToLowerInvariant()
            if ($reached.ContainsKey($lower)) { continue }
            foreach ($reference in $entry.importedBy) {
                if ($reference.kind -eq 'static' -and $reached.ContainsKey($reference.importer.ToLowerInvariant())) {
                    $reached[$lower] = $true
                    $required[$lower] = $entry.name
                    $changed = $true
                    break
                }
            }
        }
    }
    return @($required.Keys | Sort-Object | ForEach-Object { $required[$_] })
}

function Invoke-BundleCLIReadOnly {
    param(
        [Parameter(Mandatory = $true)] [string] $Executable,
        [Parameter(Mandatory = $true)] [ValidateSet('--help', '--version')] [string] $Argument,
        [Parameter(Mandatory = $true)] [string] $WorkingDirectory,
        [Parameter(Mandatory = $true)] [string] $IsolatedPath,
        [ValidateRange(1, 30)] [int] $Seconds = 15,
        [scriptblock] $OnStarted,
        [scriptblock] $StartProcess = { param($Info) [System.Diagnostics.Process]::Start($Info) }
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Argument
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($key in @($startInfo.EnvironmentVariables.Keys)) {
        if ($key -like 'SWIFT*' -or $key -like 'JSTI_*' -or @('SDKROOT', 'DEVELOPER_DIR', 'ICU_DATA') -contains $key) {
            $startInfo.EnvironmentVariables.Remove($key)
        }
    }
    $startInfo.EnvironmentVariables['PATH'] = $IsolatedPath
    $process = & $StartProcess $startInfo
    try {
        if ($OnStarted) { & $OnStarted $process }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($Seconds * 1000)
        if (-not $exited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) {
            throw "$Executable $Argument redirected streams did not close within the bounded wait."
        }
        $output = $stdout.Result
        $errors = $stderr.Result
        $matches = if ($Argument -eq '--version') {
            $output.Trim() -match '^speak [A-Za-z0-9][A-Za-z0-9.+-]{0,63}$'
        } else {
            $output -match '(?m)^speak .+ automation CLI for Just Speak To It\r?$' -and
                $output -match '(?m)^USAGE\r?$' -and $output -match 'speak --help \| --version'
        }
        $failures = @()
        if (-not $exited) { $failures += "CLI did not exit within $Seconds seconds." }
        if ($process.ExitCode -ne 0) { $failures += "CLI exited with code $($process.ExitCode)." }
        if (-not $matches) { $failures += "CLI stdout did not contain the expected $Argument output." }
        if (-not [string]::IsNullOrWhiteSpace($errors)) { $failures += "CLI wrote unexpected stderr: $errors" }
        return [ordered]@{
            executable = $Executable; argument = $Argument; exitCode = $process.ExitCode
            output = $output; errors = $errors; timedOut = -not $exited
            passed = $failures.Count -eq 0; failures = $failures
            evidenceKind = 'Redirected stdout and exit only; PE/hash/native-host evidence is separate, not sampled modules.'
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        # Lifecycle cleanup retains its owned process object.
        if (-not $OnStarted) { $process.Dispose() }
    }
}
