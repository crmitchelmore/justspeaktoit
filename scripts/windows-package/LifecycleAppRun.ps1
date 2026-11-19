# Runs the installed app through its aliases and the Start menu, and reads its
# loaded modules and UI state, for the package lifecycle test.
#
# Dot-sourced by test-windows-package-lifecycle.ps1, after its inputs and
# identity are derived. Functions read that script's state ($name, $aumid,
# the layouts, $report, $ledger and $failures) at call time. Keep this file
# ASCII-only.

# --- running the installed app ---------------------------------------------------------------------------
function Get-StaticRuntimeModules {
    return @(Get-BundleStaticModules $bundleManifest.dependencies 'SpeakWindows.exe')
}

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
    Assert-JstiAdmitted $script:ledger
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
    # Optional preparation precedes the original process/watch; no diagnostic
    # collector/event-query process starts on a passing run; the alias is never replayed.
    $eventCandidate = $Label -ceq 'base-ui-smoke-test' -and $Arguments -ceq '--ui-smoke-test' -and
        $Seconds -eq 60 -and ([string] $Installed.Architecture).ToLowerInvariant() -ceq 'arm64'
    $eventSetup = $null; $eventExecutable = $null; $eventHash = $null
    if ($eventCandidate) {
        try {
            $eventExecutable = Join-Path $Installed.InstallLocation 'SpeakWindows.exe'
            $eventHash = $bundleManifest.application.executables.'SpeakWindows.exe'
            $image = Get-Item -LiteralPath $eventExecutable -ErrorAction Stop
            if (-not $image.PSIsContainer -and -not ($image.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                    $eventHash -cmatch '^[0-9a-f]{64}\z' -and (Get-JstiSha256 $eventExecutable) -ceq $eventHash) {
                $eventSetup = New-JstiPackagedEventSetup $pythonPath
            }
        } catch { }
    }
    $eventStartedUTC = if ($eventCandidate) { [datetime]::UtcNow } else { $null }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $eventPid = if ($eventCandidate) { [int] $process.Id } else { 0 }
    Add-JstiOwnedProcess $script:ledger $process
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    $loaded = @{}
    $identity = $null; $integrity = $null; $identityError = $null
    # Conservative anchor BEFORE the unchanged original watch, never after it.
    $eventStartedTicks = if ($eventCandidate) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { [long] 0 }
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
    $eventEndedTicks = if ($eventCandidate) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { [long] 0 }
    $eventEndedUTC = if ($eventCandidate) { [datetime]::UtcNow } else { $null }
    $output = $standardOutput.Result
    [System.IO.File]::WriteAllText((Join-Path $evidenceDirectory "$Label.log"), $output + $standardError.Result,
        (New-Object System.Text.UTF8Encoding $false))
    $run = [ordered]@{
        label = $Label; arguments = $Arguments; exitCode = $process.ExitCode; packageFullName = $identity
        integrityLevel = $integrity; identityError = $identityError
        modules = Get-ModuleProvenance $loaded $Installed.InstallLocation; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    }
    $run.output = $output
    if ($eventCandidate) {
        $run.applicationErrorPreparation = if ($eventSetup) { 'prepared' } else { 'unavailable' }
    }
    [void] $script:report.runs.Add($run)
    if ($eventCandidate -and $run.exitCode -in @(-1073741819, -1073740940, -1073740791)) {
        # Only the original naturally failed process; original exit/checks stay
        # authoritative even when optional admission/collection is unavailable.
        try {
            $frequency = [System.Diagnostics.Stopwatch]::Frequency
            $context = @{
                originalPid = $eventPid; startedUTC = $eventStartedUTC; endedUTC = $eventEndedUTC
                startedTicks = $eventStartedTicks; endedTicks = $eventEndedTicks
                originalDeadlineTicks = $eventStartedTicks + (60 * $frequency); frequency = $frequency
            }
            $run.applicationErrorEvidence = Invoke-JstiPackagedEventDiagnostic $eventSetup $run $context `
                $eventExecutable $eventHash $Installed.PackageFullName
        } catch { $run.applicationErrorEvidence = @{ status = 'unavailable'; originalFailurePreserved = $true } }
    }
    return $run
}

function Start-FromStartMenu($Installed) {
    Assert-JstiAdmitted $script:ledger
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
    Add-JstiOwnedProcess $script:ledger $process
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
    foreach ($argument in @('--help', '--version')) {
        Assert-JstiAdmitted $script:ledger
        $cli = Invoke-BundleCLIReadOnly -Executable $cliAliasPath -Argument $argument `
            -WorkingDirectory $emptyDirectory -IsolatedPath $isolatedPath `
            -OnStarted { param($process) Add-JstiOwnedProcess $script:ledger $process }
        $cli.label = "$Label-cli-" + $argument.TrimStart('-')
        $cli.executableSHA256 = Get-JstiSha256 (Join-Path $Installed.InstallLocation 'speak.exe')
        [void] $script:report.runs.Add($cli)
        Assert-Check "$Label CLI alias $argument passes with the verified CLI bytes and no module-sampling claim" (
            $cli.passed -and $cli.executableSHA256 -eq $bundleManifest.application.executables.'speak.exe') $cli
    }
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
