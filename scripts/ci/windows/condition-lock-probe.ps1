# windows.yml "Probe Windows NSConditionLock reuse-after-unlock hypothesis" step (manual opt-in, read-only).
# Dot-sourced by the step, so it runs exactly as the inline script did.
# Entirely separate SDK-observation report: compiler+child
# PID/argv/UTC/exit/stdout/stderr/hash ledgers below are stored in
# their OWN evidence directory/report file and are never merged
# into, or read by, the owned-test $report/isolation/WER logic
# above -- and never fed into Get-OwnedTestSelection. A broken
# probe capability (toolchain/compile/observation/stream failure)
# FAILS this step after retaining evidence; it is never
# success-shaped. An unbounded-mode child that does not reach its
# completion marker is diagnostic evidence consistent with (not
# proof of) the hypothesized trap, and ALSO fails this step
# (a trap is not a passing SDK qualification either) -- but is
# reported and classified distinctly from an unrelated/unknown
# failure that occurs before the required pre-call marker. A
# healthy, fully-completed unbounded run is the only result that
# does not fail this step, and does not itself prove the
# hypothesis false. A finite-mode `false` reacquire result is
# reported as-is, never reinterpreted as pass/fail either way.
$ErrorActionPreference = 'Stop'

function Invoke-BoundedProcess {
    # Reused byte-for-byte from the owned-recording diagnostics
    # step above (same generic bounded child-process launcher,
    # now also reused below for the compiler itself);
    # PowerShell `run:` blocks do not share function scope across
    # steps, so it is duplicated here rather than extracted.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [Parameter(Mandatory)][int]$WaitTimeoutSeconds,
        [int]$KillJoinTimeoutSeconds = 15
    )
    foreach ($path in @($StdOutPath, $StdErrPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -ErrorAction Stop
        }
    }
    $process = $null
    $processId = $null
    $exited = $false
    $killed = $false
    $killJoined = $null
    $killError = $null
    $observationError = $null
    $exitCodeSigned = $null
    $startUtc = [DateTime]::UtcNow
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow `
            -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath
        $processId = $process.Id
        try {
            $exited = $process.WaitForExit($WaitTimeoutSeconds * 1000)
        } catch {
            $observationError = $_.Exception.Message
            $exited = $false
        }
        if (-not $exited) {
            $killed = $true
            try {
                $process.Kill($true)
                $killJoined = $process.WaitForExit($KillJoinTimeoutSeconds * 1000)
            } catch {
                $killError = $_.Exception.Message
                $killJoined = $false
            }
        } else {
            try {
                $exitCodeSigned = $process.ExitCode
            } catch {
                $observationError = $_.Exception.Message
                $exited = $false
            }
        }
    } catch {
        $observationError = $_.Exception.Message
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
    [pscustomobject]@{
        ProcessId        = $processId
        StartUtc         = $startUtc.ToString('o')
        EndUtc           = [DateTime]::UtcNow.ToString('o')
        Exited           = $exited
        Killed           = $killed
        KillJoined       = $killJoined
        KillError        = $killError
        ObservationError = $observationError
        ExitCodeSigned   = $exitCodeSigned
        StdOutPath       = $StdOutPath
        StdErrPath       = $StdErrPath
    }
}

function Get-PhaseObservation {
    # Parses the GIVEN stream (stderr for this script) line-by-line
    # in emitted order. Each expected marker must appear exactly
    # once, in order; a duplicate, an out-of-order marker, a
    # marker belonging to the OTHER mode, or any other line
    # sharing the controlled diagnostic prefix is a violation and
    # invalidates the observation -- only lines WITHOUT the
    # controlled prefix are treated as ordinary runtime noise.
    param(
        [Parameter(Mandatory)][string]$StreamPath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][hashtable]$AllPhaseMarkers,
        [Parameter(Mandatory)][int]$AcquiredValueMarkerIndex
    )
    # Gate on the whole diagnostic namespace FIRST -- a line with
    # an unknown/missing mode token (e.g. "mystery:", "usage:"),
    # or even a bare/malformed namespace line with no following
    # separator at all, still belongs to this namespace and must
    # fall through to the unrecognized-marker violation below,
    # not be mistaken for ordinary unrelated runtime noise. Do
    # not require a trailing separator/space here -- that would
    # re-bake an assumed mode/format into the noise filter.
    $namespacePrefix = '^\[windows-condition-lock-diagnostic\]'
    $expected = $AllPhaseMarkers[$Mode]
    $otherExpected = $AllPhaseMarkers[$(if ($Mode -eq 'finite') { 'unbounded' } else { 'finite' })]
    $hits = New-Object 'bool[]' $expected.Count
    $nextIndex = 0
    $acquiredValue = $null
    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $StreamPath)) {
        if ($line -notmatch $namespacePrefix) { continue }
        $ownIndex = -1
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ($line -match $expected[$i]) { $ownIndex = $i; break }
        }
        if ($ownIndex -ge 0) {
            if ($ownIndex -eq $nextIndex) {
                $hits[$ownIndex] = $true
                if ($ownIndex -eq $AcquiredValueMarkerIndex) {
                    $valueMatch = [regex]::Match($line, 'acquired=(true|false)')
                    if ($valueMatch.Success) { $acquiredValue = [bool]::Parse($valueMatch.Groups[1].Value) }
                }
                $nextIndex++
            } elseif ($ownIndex -lt $nextIndex) {
                $violations.Add("duplicate marker for already-reached phase ${ownIndex}: $line")
            } else {
                $violations.Add("out-of-order marker (expected phase $nextIndex next, saw phase ${ownIndex}): $line")
            }
            continue
        }
        $isForeign = $false
        foreach ($pattern in $otherExpected) {
            if ($line -match $pattern) { $isForeign = $true; break }
        }
        if ($isForeign) {
            $violations.Add("foreign-mode marker unexpected in $Mode stream: $line")
        } else {
            $violations.Add("unrecognized controlled-prefix marker: $line")
        }
    }
    [pscustomobject]@{
        MarkerHits    = $hits
        PhaseReached  = $nextIndex
        PhaseCount    = $expected.Count
        AcquiredValue = $acquiredValue
        Violations    = @($violations)
    }
}

# ---- Main flow -------------------------------------------------
# Ordered, per-mode phase markers the script actually writes to
# STDERR (never stdout -- `emit()` in the script writes exclusively
# to `FileHandle.standardError`). Index 3 (0-based) is the
# required marker immediately BEFORE the unbounded mode's
# suspected trap site; its presence/absence (together with the
# child's own exit/signal outcome) is what distinguishes
# trap-consistent evidence from an unrelated/unknown failure --
# never an absent final marker alone.
$expectedPhaseMarkers = @{
    finite    = @(
        '^\[windows-condition-lock-diagnostic\] finite: creating NSConditionLock\(condition: 0\)$'
        '^\[windows-condition-lock-diagnostic\] finite: first lock\(\)$'
        '^\[windows-condition-lock-diagnostic\] finite: unlock\(withCondition: 1\)$'
        '^\[windows-condition-lock-diagnostic\] finite: second lock\(before: now\+0\.25s\) -- about to reacquire$'
        '^\[windows-condition-lock-diagnostic\] finite: second lock\(before:\) returned acquired=(true|false)$'
        '^\[windows-condition-lock-diagnostic\] finite: completed without trapping$'
    )
    unbounded = @(
        '^\[windows-condition-lock-diagnostic\] unbounded: creating NSConditionLock\(condition: 0\)$'
        '^\[windows-condition-lock-diagnostic\] unbounded: first lock\(\)$'
        '^\[windows-condition-lock-diagnostic\] unbounded: unlock\(withCondition: 1\)$'
        '^\[windows-condition-lock-diagnostic\] unbounded: about to call second lock\(\) \(suspected trap site\)$'
        '^\[windows-condition-lock-diagnostic\] unbounded: second lock\(\) returned \(did not trap in this run\)$'
        '^\[windows-condition-lock-diagnostic\] unbounded: completed without trapping$'
    )
}
# 0-based index of the required pre-call marker (unbounded mode
# only). "trap-consistent-evidence" requires BOTH phaseReached to
# equal exactly this index + 1 (stopped immediately after this
# marker, not before, not after reaching a later one) AND the
# exact signed exit code below -- anything else is classified as
# an unrelated/unknown failure, never inferred from timing alone.
$requiredPreCallMarkerIndex = 3
# Signed 32-bit value of 0xC000001D (STATUS_ILLEGAL_INSTRUCTION).
$requiredTrapExitCodeSigned = -1073741795

$scriptPath = 'scripts/ci/windows/windows-condition-lock-diagnostic.swift'
$evidenceRoot = Join-Path $env:RUNNER_TEMP 'condition-lock-probe-evidence'
$evidenceDir = Join-Path $evidenceRoot ([Guid]::NewGuid().ToString('n'))
$report = [ordered]@{
    scriptPath            = $scriptPath
    evidenceDir           = $evidenceDir
    sourceCommit          = $null
    sourceCommitError     = $null
    sourceTree            = $null
    sourceTreeError       = $null
    scriptSHA256          = $null
    scriptHashError       = $null
    compilerVersion       = $null
    compile               = $null
    probeExecutable       = $null
    probeExecutableSHA256 = $null
    finite                = $null
    unbounded             = $null
    failures              = @()
    failureMessage        = $null
}
$failures = New-Object System.Collections.Generic.List[string]
try {
    New-Item -ItemType Directory -Path $evidenceDir -Force -ErrorAction Stop | Out-Null

    try {
        $report.sourceCommit = (& git rev-parse HEAD 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD exited $LASTEXITCODE" }
    } catch {
        $report.sourceCommitError = $_.Exception.Message
        $failures.Add("sourceCommit observation failed: $($report.sourceCommitError)")
    }
    try {
        $report.sourceTree = (& git rev-parse 'HEAD^{tree}' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD^{tree} exited $LASTEXITCODE" }
    } catch {
        $report.sourceTreeError = $_.Exception.Message
        $failures.Add("sourceTree observation failed: $($report.sourceTreeError)")
    }
    try {
        $report.scriptSHA256 = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        $report.scriptHashError = $_.Exception.Message
        $failures.Add("scriptSHA256 observation failed: $($report.scriptHashError)")
    }

    $report.compilerVersion = (& swift --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "swift --version failed (exit $LASTEXITCODE); probe's own toolchain observation is unavailable, reported as a broken-capability failure."
    }

    $probeExe = Join-Path $evidenceDir 'windows-condition-lock-diagnostic.exe'
    $compileStdOutPath = Join-Path $evidenceDir 'compile.stdout.log'
    $compileStdErrPath = Join-Path $evidenceDir 'compile.stderr.log'
    $compileArgv = @('-O', $scriptPath, '-o', $probeExe)
    $compileResult = Invoke-BoundedProcess -FilePath 'swiftc' -ArgumentList $compileArgv `
        -StdOutPath $compileStdOutPath -StdErrPath $compileStdErrPath `
        -WaitTimeoutSeconds 60 -KillJoinTimeoutSeconds 10
    # Ledger assigned IMMEDIATELY, before any hash/read/parse call
    # below that can throw and lose the compiler's own PID/exit
    # observation.
    $report.compile = [ordered]@{
        argv             = @('swiftc') + $compileArgv
        processId        = $compileResult.ProcessId
        startUtc         = $compileResult.StartUtc
        endUtc           = $compileResult.EndUtc
        exited           = $compileResult.Exited
        killed           = $compileResult.Killed
        killJoined       = $compileResult.KillJoined
        killError        = $compileResult.KillError
        observationError = $compileResult.ObservationError
        exitCodeSigned   = $compileResult.ExitCodeSigned
        stdOutPath       = $compileStdOutPath
        stdErrPath       = $compileStdErrPath
        stdOutSHA256     = $null
        stdOutReadError  = $null
        stdErrSHA256     = $null
        stdErrReadError  = $null
        executableProduced = $null
    }
    try {
        $report.compile.stdOutSHA256 = (Get-FileHash -LiteralPath $compileStdOutPath -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        $report.compile.stdOutReadError = $_.Exception.Message
        $failures.Add("compile stdout stream unavailable: $($report.compile.stdOutReadError)")
    }
    try {
        $report.compile.stdErrSHA256 = (Get-FileHash -LiteralPath $compileStdErrPath -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        $report.compile.stdErrReadError = $_.Exception.Message
        $failures.Add("compile stderr stream unavailable: $($report.compile.stdErrReadError)")
    }
    $report.compile.executableProduced = Test-Path -LiteralPath $probeExe
    if (-not $compileResult.Exited -or $compileResult.Killed -or $compileResult.ObservationError -or $compileResult.KillError) {
        throw "swiftc -O did not complete normally compiling '$scriptPath' (exited=$($compileResult.Exited), killed=$($compileResult.Killed), observationError=$($compileResult.ObservationError), killError=$($compileResult.KillError)); children not run -- reported as a broken-capability probe failure, not evidence either way."
    }
    if ($compileResult.ExitCodeSigned -ne 0) {
        throw "swiftc -O failed to compile '$scriptPath' (exit $($compileResult.ExitCodeSigned)); children not run -- reported as a broken-capability probe failure, not evidence either way."
    }
    if (-not $report.compile.executableProduced) {
        throw "swiftc -O exited 0 but '$probeExe' was not produced; children not run."
    }
    $report.probeExecutable = $probeExe
    try {
        $report.probeExecutableSHA256 = (Get-FileHash -LiteralPath $probeExe -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        $failures.Add("Could not hash produced executable '$probeExe': $($_.Exception.Message)")
    }

    $priorModeRetired = $true
    $priorModeLabel = $null
    foreach ($mode in @('finite', 'unbounded')) {
        if (-not $priorModeRetired) {
            # The PRIOR mode's child was never positively confirmed
            # retired (clean exit, or killed AND join confirmed) --
            # launching another child on top of that uncertainty is
            # a safety hazard, so this mode is skipped with an
            # explicit reason and no new process is started.
            $entry = [ordered]@{
                launched       = $false
                skipped        = $true
                skipReason     = "previous mode ('$priorModeLabel') was not positively retired (clean exit, or killed with confirmed join) before this mode could safely launch; no new child process was started."
                classification = 'skipped-unretired-predecessor'
            }
            $report[$mode] = $entry
            $failures.Add("$mode mode skipped: $($entry.skipReason)")
            continue
        }

        $stdOutPath = Join-Path $evidenceDir "$mode.stdout.log"
        $stdErrPath = Join-Path $evidenceDir "$mode.stderr.log"
        $result = Invoke-BoundedProcess -FilePath $probeExe -ArgumentList @($mode) `
            -StdOutPath $stdOutPath -StdErrPath $stdErrPath -WaitTimeoutSeconds 10 -KillJoinTimeoutSeconds 10
        # Ledger assigned IMMEDIATELY, before any hash/marker-parse
        # call below that can throw and lose this child's own
        # PID/exit observation.
        $entry = [ordered]@{
            argv                 = @($probeExe, $mode)
            launched             = $true
            skipped              = $false
            processId            = $result.ProcessId
            startUtc             = $result.StartUtc
            endUtc               = $result.EndUtc
            exited               = $result.Exited
            killed               = $result.Killed
            killJoined           = $result.KillJoined
            killError            = $result.KillError
            observationError     = $result.ObservationError
            exitCodeSigned       = $result.ExitCodeSigned
            stdOutPath           = $stdOutPath
            stdOutSHA256         = $null
            stdOutReadError      = $null
            stdErrPath           = $stdErrPath
            stdErrSHA256         = $null
            stdErrReadError      = $null
            expectedPhaseMarkers = $expectedPhaseMarkers[$mode]
            phaseMarkerHits      = $null
            phaseReached         = $null
            phaseCount           = $expectedPhaseMarkers[$mode].Count
            markerViolations     = $null
            finiteAcquiredValue  = $null
            requiredPreCallMarkerReached = $null
            classification       = $null
        }
        $report[$mode] = $entry

        $streamError = $false
        try {
            $entry.stdOutSHA256 = (Get-FileHash -LiteralPath $stdOutPath -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            $entry.stdOutReadError = $_.Exception.Message
            $streamError = $true
        }
        try {
            $entry.stdErrSHA256 = (Get-FileHash -LiteralPath $stdErrPath -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            $entry.stdErrReadError = $_.Exception.Message
            $streamError = $true
        }

        $phaseObservation = $null
        if (-not $entry.stdErrReadError) {
            try {
                # The script's markers are on STDERR, never stdout
                # (`emit()` writes exclusively to
                # `FileHandle.standardError`).
                $acquiredMarkerIndex = if ($mode -eq 'finite') { 4 } else { -1 }
                $phaseObservation = Get-PhaseObservation -StreamPath $stdErrPath -Mode $mode `
                    -AllPhaseMarkers $expectedPhaseMarkers -AcquiredValueMarkerIndex $acquiredMarkerIndex
            } catch {
                $entry.stdErrReadError = "phase-marker parse failed: $($_.Exception.Message)"
                $streamError = $true
            }
        }
        if ($null -ne $phaseObservation) {
            $entry.phaseMarkerHits = $phaseObservation.MarkerHits
            $entry.phaseReached = $phaseObservation.PhaseReached
            $entry.markerViolations = $phaseObservation.Violations
            $entry.finiteAcquiredValue = $phaseObservation.AcquiredValue
            $entry.requiredPreCallMarkerReached = $phaseObservation.PhaseReached -gt $requiredPreCallMarkerIndex
        }

        $violationCount = @($entry.markerViolations).Count
        $fullyCompleted = ($entry.phaseReached -eq $entry.phaseCount)
        $healthyExit = ($entry.exited -and -not $entry.killed -and -not $entry.observationError -and -not $entry.killError -and $entry.exitCodeSigned -eq 0)

        if ($streamError) {
            $entry.classification = 'stream-read-or-parse-failure'
            $failures.Add("$mode mode: stdout/stderr read, hash, or marker-parse failure (stdOutReadError=$($entry.stdOutReadError), stdErrReadError=$($entry.stdErrReadError)).")
        } elseif ($entry.observationError -or $entry.killError) {
            $entry.classification = 'observation-failure'
            $failures.Add("$mode mode: process observation/kill failure (observationError=$($entry.observationError), killError=$($entry.killError)).")
        } elseif ($violationCount -gt 0) {
            # Duplicate/out-of-order/foreign-mode/unrecognized
            # controlled markers invalidate the observation
            # outright, regardless of exit code or marker count.
            $entry.classification = 'marker-validation-failure'
            $failures.Add("$mode mode: $violationCount controlled-marker violation(s): $(($entry.markerViolations) -join '; ').")
        } elseif ($entry.killed) {
            # A timeout (forcibly killed) is never trap-consistent
            # evidence, regardless of how far phaseReached got.
            $entry.classification = 'timeout'
            $failures.Add("$mode mode timed out and was killed (phaseReached=$($entry.phaseReached)/$($entry.phaseCount)).")
        } elseif ($healthyExit -and $fullyCompleted) {
            if ($mode -eq 'finite' -and $entry.finiteAcquiredValue -eq $false) {
                # A healthy, fully-marked finite run that reports
                # acquired=false is an unsupported/broken capability
                # observation, never a passing SDK qualification.
                $entry.classification = 'broken-capability'
                $failures.Add('finite mode completed healthily but reported acquired=false on reacquire; reported as an unsupported/broken capability observation.')
            } else {
                # A healthy, fully-completed unbounded run means the
                # hypothesized trap did NOT occur in this run; this
                # does not itself disprove the hypothesis for other
                # runs/environments.
                $entry.classification = 'healthy-complete'
            }
        } elseif ($mode -eq 'finite') {
            $entry.classification = 'broken-capability'
            $failures.Add("finite mode did not reach a healthy, fully-marked completion (exited=$($entry.exited), exitCodeSigned=$($entry.exitCodeSigned), phaseReached=$($entry.phaseReached)/$($entry.phaseCount)); reported as a broken-capability probe failure.")
        } elseif ($healthyExit -and -not $fullyCompleted) {
            # Clean exit code but markers don't support full
            # completion: an internal inconsistency, not evidence
            # either way for the hypothesized trap.
            $entry.classification = 'inconsistent-incomplete'
            $failures.Add("unbounded mode exited 0 but only reached phase $($entry.phaseReached)/$($entry.phaseCount); inconsistent observation, not treated as trap-consistent evidence.")
        } elseif ($entry.exitCodeSigned -eq $requiredTrapExitCodeSigned -and $entry.phaseReached -eq ($requiredPreCallMarkerIndex + 1)) {
            # Diagnostic evidence consistent with (never proof of)
            # the hypothesized trap REQUIRES the exact signed exit
            # code AND stopping exactly at the pre-call marker (not
            # before, not after reaching a later marker). This
            # still fails the step: evidence is not a passing
            # qualification.
            $entry.classification = 'trap-consistent-evidence'
            $failures.Add("unbounded mode exited with the exact hypothesized trap code ($requiredTrapExitCodeSigned / 0xC000001D) immediately after the required pre-call marker (phaseReached=$($entry.phaseReached)/$($entry.phaseCount)); reported as trap-consistent diagnostic evidence, not proof, and not a passing SDK qualification.")
        } else {
            # Any other abnormal exit -- wrong exit code, or
            # progressed past/stopped short of the exact pre-call
            # marker -- is never inferred as the hypothesized trap
            # from timing or an absent marker alone.
            $entry.classification = 'unrelated-or-unknown-failure'
            $failures.Add("unbounded mode exited abnormally (exitCodeSigned=$($entry.exitCodeSigned), phaseReached=$($entry.phaseReached)/$($entry.phaseCount)) that does not match the exact hypothesized trap signature; reported as an unrelated/unknown failure, not trap-consistent evidence.")
        }

        $priorModeRetired = (($entry.exited) -and (-not $entry.observationError) -and (-not $entry.killError)) -or (($entry.killed) -and ($entry.killJoined -eq $true))
        $priorModeLabel = $mode
    }
} catch {
    $failures.Add($_.Exception.Message)
} finally {
    $report.failures = @($failures)
    $report.failureMessage = if ($failures.Count -gt 0) { ($failures -join ' | ') } else { $null }
    $reportPath = Join-Path $evidenceDir 'condition-lock-probe-report.json'
    if (Test-Path -LiteralPath $evidenceDir) {
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
        Get-Content -LiteralPath $reportPath
    } else {
        Write-Warning "Evidence directory '$evidenceDir' is unavailable; report could not be persisted to it."
        $report | ConvertTo-Json -Depth 8
    }
}
# ANY accumulated failure -- broken-capability (toolchain/compile/
# observation/stream), finite mode's own non-completion, an
# internally inconsistent unbounded exit, an unrelated/unknown
# unbounded failure, OR trap-consistent unbounded evidence --
# fails this step after the report above has already persisted
# every ledger and classification. A trap is diagnostic evidence,
# never a green/passing SDK qualification.
if ($report.failures.Count -gt 0) { throw $report.failureMessage }
