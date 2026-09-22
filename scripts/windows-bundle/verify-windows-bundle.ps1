<#
.SYNOPSIS
Runs the Mac-built self-contained Windows bundle without any Swift installation.

.DESCRIPTION
Verifies the ZIP and every extracted file against the hashes recorded on the Mac,
isolates PATH to the Windows system directories, proves the runner cannot satisfy
the executable's runtime on its own (a copy without the bundled DLLs must fail to
start), then runs the production executable's self-test and native window smoke
test while sampling the process’s loaded module paths. Any non-system module must
come from the bundle directory. Evidence is written even when a check fails, and
every failure is reported before the script exits non-zero.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BundleDirectory,
    [Parameter(Mandatory = $true)] [string] $Workspace,
    [Parameter(Mandatory = $true)] [string] $ExpectedCommit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BundleEnvironment.ps1')
$StatusDllNotFound = -1073741515  # NTSTATUS 0xC0000135 as a signed exit code

function Get-Sha256([string] $path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ForbiddenPath([string] $relative, [string[]] $patterns) {
    $lower = $relative.ToLowerInvariant()
    $name = $lower.Split('/')[-1]
    foreach ($pattern in $patterns) {
        if ($lower -like $pattern -or $name -like $pattern) { return $true }
    }
    return $false
}

$bundleDirectory = (Resolve-Path -LiteralPath $BundleDirectory).Path
$workspace = (New-Item -ItemType Directory -Force -Path $Workspace).FullName
$evidenceDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'evidence')).FullName
$failures = [System.Collections.Generic.List[string]]::new()
$report = [ordered]@{
    schemaVersion = 1
    expectedCommit = $ExpectedCommit
    runner = [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        caption = (Get-CimInstance Win32_OperatingSystem).Caption
        architecture = $env:PROCESSOR_ARCHITECTURE
    }
    zip = $null
    isolation = $null
    negativeControl = $null
    resourceNegativeControl = $null
    runs = @()
    failures = @()
}

try {
    # --- 1. Artefact identity ---------------------------------------------------
    $evidence = Get-Content -LiteralPath (Join-Path $bundleDirectory 'bundle-evidence.json') -Raw | ConvertFrom-Json
    if ($evidence.application.sourceCommit -ne $ExpectedCommit) {
        throw "Bundle source commit $($evidence.application.sourceCommit) does not match $ExpectedCommit."
    }
    $zipPath = Join-Path $bundleDirectory $evidence.zip.name
    $zipHash = Get-Sha256 $zipPath
    if ($zipHash -ne $evidence.zip.sha256) { throw "Bundle ZIP hash mismatch: $zipHash" }
    if ((Get-Item -LiteralPath $zipPath).Length -ne $evidence.zip.bytes) { throw 'Bundle ZIP size mismatch.' }
    $report.zip = [ordered]@{ name = $evidence.zip.name; sha256 = $zipHash; bytes = $evidence.zip.bytes }

    $bundle = Join-Path $workspace 'Bundle with spaces κόσμε'
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $bundle -Force
    $bundle = (Resolve-Path -LiteralPath $bundle).Path
    $manifestPath = Join-Path $bundle 'bundle-manifest.json'
    if ((Get-Sha256 $manifestPath) -ne $evidence.manifest.sha256) { throw 'bundle-manifest.json hash mismatch.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.application.sourceCommit -ne $ExpectedCommit -or $manifest.application.appBuiltForTesting -ne $false -or
        $manifest.application.configuration -ne 'release') {
        throw 'Manifest does not describe an optimised production build of the expected commit.'
    }

    # --- 2. Every extracted file matches the manifest; nothing else is present ----
    $expected = @{}
    foreach ($item in $manifest.files) {
        $path = Join-Path $bundle ($item.path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Bundle file missing: $($item.path)" }
        if ((Get-Item -LiteralPath $path).Length -ne $item.bytes) { throw "Bundle file size mismatch: $($item.path)" }
        if ((Get-Sha256 $path) -ne $item.sha256) { throw "Bundle file hash mismatch: $($item.path)" }
        $expected[$item.path.ToLowerInvariant()] = $true
    }
    $expected['bundle-manifest.json'] = $true
    $forbidden = @($manifest.policy.forbiddenBundlePatterns)
    foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -File) {
        $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
        if (-not $expected.ContainsKey($relative.ToLowerInvariant())) { throw "Unexpected file in bundle: $relative" }
        if (Test-ForbiddenPath $relative $forbidden) { throw "Forbidden file shipped in bundle: $relative" }
    }
    if ((Get-ChildItem -LiteralPath $bundle -Recurse -File).Count -ne $expected.Count) { throw 'Bundle file count mismatch.' }
    Write-Host "Verified $($expected.Count) bundle files against the Mac-recorded manifest."

    # --- 3. Isolate the environment ----------------------------------------------
    $systemRoot = $env:SystemRoot
    $isolatedPath = "$systemRoot\System32;$systemRoot;$systemRoot\System32\Wbem;$systemRoot\System32\WindowsPowerShell\v1.0"
    $env:Path = $isolatedPath
    Clear-BundleToolchainEnvironment
    if (Get-Command swift.exe -ErrorAction SilentlyContinue) { throw 'A Swift toolchain is reachable on the isolated PATH.' }
    $bundled = @{}
    foreach ($property in $manifest.dependencies.bundled.PSObject.Properties) { $bundled[$property.Name] = $property.Value }
    $systemCopies = @()
    foreach ($entry in $bundled.Values) {
        foreach ($directory in $isolatedPath.Split(';')) {
            $candidate = Join-Path $directory $entry.name
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            if ($entry.source -eq 'swift-runtime') {
                throw "Isolation broken: the runner provides $($entry.name) at $candidate."
            }
            $systemCopies += [ordered]@{ module = $entry.name; path = $candidate; sha256 = (Get-Sha256 $candidate) }
        }
    }
    $report.isolation = [ordered]@{
        path = $isolatedPath
        swiftOnPath = $false
        icuDataOverride = $null
        bundlePath = $bundle
        workingDirectory = (Join-Path $workspace 'Empty working directory')
        systemCopiesOfBundledModules = $systemCopies
    }
    Write-Host "Isolated PATH: $isolatedPath"

    $emptyWorkingDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $workspace 'Empty working directory')).FullName
    if (Get-ChildItem -LiteralPath $emptyWorkingDirectory -Force) { throw 'Isolation working directory must be empty.' }

    # --- 4. Negative control: the executable alone must fail to start --------------
    $errorMode = Add-Type -Namespace Jsti -Name ErrorMode -PassThru -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);
'@
    $control = Join-Path $workspace 'control'
    if (Test-Path -LiteralPath $control) { Remove-Item -LiteralPath $control -Recurse -Force }
    New-Item -ItemType Directory -Path $control | Out-Null
    Copy-Item -LiteralPath (Join-Path $bundle 'SpeakWindows.exe') -Destination $control
    Get-ChildItem -LiteralPath $bundle -Directory -Filter '*.resources' | Copy-Item -Destination $control -Recurse
    $previousMode = $errorMode::SetErrorMode(0x8003)  # SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
    try {
        $controlProcess = Start-Process -FilePath (Join-Path $control 'SpeakWindows.exe') -ArgumentList '--self-test' `
            -WorkingDirectory $emptyWorkingDirectory -PassThru -NoNewWindow `
            -RedirectStandardOutput (Join-Path $evidenceDirectory 'negative-control.log') `
            -RedirectStandardError (Join-Path $evidenceDirectory 'negative-control-errors.log')
        if (-not $controlProcess.WaitForExit(30000)) {
            $controlProcess.Kill()
            throw 'Negative control did not exit within 30 seconds; a loader dialog or a runner-supplied runtime may have kept it alive.'
        }
    } finally {
        [void] $errorMode::SetErrorMode($previousMode)
    }
    $report.negativeControl = [ordered]@{
        description = 'SpeakWindows.exe copied without the bundled DLLs, same isolated PATH'
        exitCode = $controlProcess.ExitCode
        statusDllNotFound = ($controlProcess.ExitCode -eq $StatusDllNotFound)
    }
    if ($controlProcess.ExitCode -ne $StatusDllNotFound) {
        throw "Negative control exited with $($controlProcess.ExitCode); expected STATUS_DLL_NOT_FOUND ($StatusDllNotFound). The runner may be supplying runtime DLLs."
    }
    Write-Host "Negative control failed to start as expected (STATUS_DLL_NOT_FOUND)."

    # --- 5. Run the bundled production executable and record loaded modules -------
    function Invoke-Bundled([string] $arguments, [string] $label, [int] $seconds) {
        $parameters = @{
            FilePath = (Join-Path $bundle 'SpeakWindows.exe')
            ArgumentList = $arguments
            WorkingDirectory = $emptyWorkingDirectory
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = (Join-Path $evidenceDirectory "bundle-$label.log")
            RedirectStandardError = (Join-Path $evidenceDirectory "bundle-$label-errors.log")
        }
        $probeRelease = Join-Path $evidenceDirectory ('module-probe-' + $label + '.ready')
        Remove-Item -LiteralPath $probeRelease -Force -ErrorAction SilentlyContinue
        $env:JSTI_BUNDLE_PROBE_RELEASE_PATH = $probeRelease
        $process = Start-Process @parameters
        $loaded = @{}
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            try {
                $process.Refresh()
                foreach ($module in $process.Modules) { $loaded[$module.FileName.ToLowerInvariant()] = $module.FileName }
                $allStaticObserved = $true
                foreach ($entry in $bundled.Values) {
                    if (@($entry.importedBy | Where-Object { $_.kind -eq 'static' }).Count -eq 0) { continue }
                    $expectedPath = (Join-Path $bundle $entry.name).ToLowerInvariant()
                    if (-not $loaded.ContainsKey($expectedPath)) { $allStaticObserved = $false }
                }
                if ($allStaticObserved) { [System.IO.File]::WriteAllText($probeRelease, 'sampled') }
            } catch { }
            if ($stopwatch.Elapsed.TotalSeconds -gt $seconds) {
                $process.Kill()
                throw "$label exceeded $seconds seconds."
            }
            Start-Sleep -Milliseconds 20
        }
        $process.WaitForExit()
        # Write-Host keeps the log text out of this function's return value.
        Get-Content -LiteralPath (Join-Path $evidenceDirectory "bundle-$label.log") | ForEach-Object { Write-Host $_ }
        Get-Content -LiteralPath (Join-Path $evidenceDirectory "bundle-$label-errors.log") | ForEach-Object { Write-Host $_ }
        $fromBundle = @(); $fromSystem = @(); $foreign = @()
        foreach ($path in ($loaded.Values | Sort-Object)) {
            if ($path.StartsWith("$bundle\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $path.Substring($bundle.Length + 1).Replace('\', '/')
                if (-not $expected.ContainsKey($relative.ToLowerInvariant())) { $foreign += $path } else { $fromBundle += $relative }
            } elseif ($path.StartsWith("$systemRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $fromSystem += $path
            } else {
                $foreign += $path
            }
        }
        $missing = @()
        foreach ($entry in $bundled.Values) {
            $static = @($entry.importedBy | Where-Object { $_.kind -eq 'static' }).Count -gt 0
            $observed = @($fromBundle | Where-Object { $_ -ieq $entry.name }).Count -gt 0
            if ($static -and -not $observed) { $missing += $entry.name }
            foreach ($path in $fromSystem + $foreign) {
                if ([System.IO.Path]::GetFileName($path) -ieq $entry.name) { $foreign += "$path (bundled module loaded from outside the bundle)" }
            }
        }
        $run = [ordered]@{
            label = $label
            arguments = $arguments
            exitCode = $process.ExitCode
            modulesFromBundle = $fromBundle
            modulesFromSystemRoot = $fromSystem
            modulesFromElsewhere = $foreign
            staticallyImportedModulesNotObserved = $missing
        }
        $script:report.runs += $run
        if ($process.ExitCode -ne 0) { throw "$label failed with exit code $($process.ExitCode)." }
        if ($fromBundle.Count -lt 2) { throw "$label module evidence was not captured." }
        if ($foreign.Count) { throw "$label loaded modules from outside the bundle and Windows: $($foreign -join '; ')" }
        if ($missing.Count) { throw "$label did not load bundled modules from the bundle: $($missing -join ', ')" }
        return $run
    }

    try {
        $run = Invoke-Bundled '--bundle-self-test' 'foundation-resources' 30
        if (-not (Select-String -LiteralPath (Join-Path $evidenceDirectory 'bundle-foundation-resources.log') -Pattern 'JSTI_BUNDLE_SELF_TEST_OK' -Quiet)) {
            throw 'Bundled Foundation/resource success marker missing.'
        }
    } catch { $failures.Add($_.Exception.Message) }
    try {
        # This disposable control has the complete runtime/resource directory,
        # but its release-notes JSON is missing. The usual empty-catalogue
        # fallback must fail the explicit resource assertion.
        $resourceControl = Join-Path $workspace 'Missing resource control κόσμε'
        if (Test-Path -LiteralPath $resourceControl) { Remove-Item -LiteralPath $resourceControl -Recurse -Force }
        New-Item -ItemType Directory -Path $resourceControl | Out-Null
        Get-ChildItem -LiteralPath $bundle | Copy-Item -Destination $resourceControl -Recurse
        $resourceFiles = @(Get-ChildItem -LiteralPath $resourceControl -Recurse -File -Filter 'ReleaseNotes.json')
        if ($resourceFiles.Count -ne 1) { throw 'Expected exactly one bundled ReleaseNotes.json fixture.' }
        Remove-Item -LiteralPath $resourceFiles[0].FullName -Force
        $resourceErrors = Join-Path $evidenceDirectory 'missing-resource-errors.log'
        $resourceProcess = Start-Process -FilePath (Join-Path $resourceControl 'SpeakWindows.exe') `
            -ArgumentList '--bundle-self-test' -WorkingDirectory $emptyWorkingDirectory -PassThru -NoNewWindow `
            -RedirectStandardOutput (Join-Path $evidenceDirectory 'missing-resource.log') -RedirectStandardError $resourceErrors
        if (-not $resourceProcess.WaitForExit(30000)) {
            $resourceProcess.Kill()
            throw 'Missing-resource control did not exit within 30 seconds.'
        }
        $report.resourceNegativeControl = [ordered]@{ exitCode = $resourceProcess.ExitCode }
        if ($resourceProcess.ExitCode -eq 0 -or -not (Select-String -LiteralPath $resourceErrors `
            -Pattern 'Bundle resource lookup failed' -Quiet)) {
            throw 'The missing-resource control did not fail the real SwiftPM resource lookup.'
        }
    } catch { $failures.Add($_.Exception.Message) }
    try {
        $run = Invoke-Bundled '--self-test' 'self-test' 90
        if (-not (Select-String -LiteralPath (Join-Path $evidenceDirectory 'bundle-self-test.log') -Pattern 'self-test passed' -Quiet)) {
            throw 'Bundled self-test success marker missing.'
        }
        Write-Host "Self-test loaded $($run.modulesFromBundle.Count) modules from the bundle and $($run.modulesFromSystemRoot.Count) from Windows."
    } catch { $failures.Add($_.Exception.Message) }
    try {
        $env:JSTI_UI_SNAPSHOT_PATH = Join-Path $evidenceDirectory 'bundle-ui-smoke.bmp'
        $run = Invoke-Bundled '--ui-smoke-test' 'ui-smoke' 30
        if (-not (Select-String -LiteralPath (Join-Path $evidenceDirectory 'bundle-ui-smoke.log') -Pattern 'Native window creation and shutdown passed' -Quiet)) {
            throw 'Bundled native UI success marker missing.'
        }
        if (-not (Test-Path -LiteralPath $env:JSTI_UI_SNAPSHOT_PATH)) { throw 'Bundled native client snapshot missing.' }
        Write-Host "UI smoke test loaded $($run.modulesFromBundle.Count) modules from the bundle and $($run.modulesFromSystemRoot.Count) from Windows."
    } catch { $failures.Add($_.Exception.Message) }
} catch {
    $failures.Add("$($_.Exception.Message) (script line $($_.InvocationInfo.ScriptLineNumber))")
} finally {
    $report.failures = @($failures)
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'bundle-execution-evidence.json') -Encoding utf8
}

if ($failures.Count) {
    throw ($failures -join '; ')
}
Write-Host 'Self-contained bundle ran the production executable with no Swift installation on the isolated PATH.'
