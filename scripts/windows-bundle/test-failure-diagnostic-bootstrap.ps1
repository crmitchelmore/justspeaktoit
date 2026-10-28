# Pure fakes ONLY. The shared helper import defines functions without native work.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FailureDiagnostics.ps1')

function Assert-That([bool] $Condition, [string] $Case) {
    if (-not $Condition) { throw "Bootstrap fake failed: $Case" }
}

function New-FakeBootstrap([hashtable] $Options = @{}) {
    $state = @{
        Events = [System.Collections.Generic.List[string]]::new()
        Closed = [System.Collections.Generic.List[string]]::new()
        Now = $(if ($Options.ContainsKey('Now')) { [long] $Options.Now } else { [long] 0 }); ReadCalls = 0; ReadMaximums = [System.Collections.Generic.List[int]]::new()
        Inherited = @(); WaitDeadline = 0; Options = $Options
    }
    $state.Deadline = if ($Options.ContainsKey('Deadline')) { [long] $Options.Deadline } else { [long] 30000 }
    $state.Frequency = if ($Options.ContainsKey('Frequency')) { [long] $Options.Frequency } else { [long] 1000 }
    $adapter = @{
        Now = { return $state.Now }.GetNewClosure()
        CreateJob = {
            param($killOnClose, $inherit)
            Assert-That ($killOnClose -ceq $true -and $inherit -ceq $false) 'private-job-policy'
            [void] $state.Events.Add('job')
            if ($state.Options.jobFailure) { throw 'PRIVATE_FAILURE_CANARY' }
            return 'job-handle'
        }.GetNewClosure()
        CreatePipes = {
            [void] $state.Events.Add('pipes')
            if ($state.Options.pipeFailure) { throw 'PRIVATE_FAILURE_CANARY' }
            return @{ StdinRead = 'in-read'; StdinWrite = 'in-write'; StdoutRead = 'out-read'; StdoutWrite = 'out-write'; StderrRead = 'err-read'; StderrWrite = 'err-write' }
        }.GetNewClosure()
        CreateSuspended = {
            param($request, $inherited, $job, $pipes, $deadline, $frequency)
            Assert-That ($job -ceq 'job-handle' -and $deadline -eq $state.Deadline -and $frequency -eq $state.Frequency) 'creation-policy-before-first-instruction'
            [void] $state.Events.Add('suspended')
            $state.Inherited = @($inherited)
            if ($state.Options.createFailure) { throw 'PRIVATE_FAILURE_CANARY' }
            if ($state.Options.partialChild) { return @{ Process = 'process-handle'; Thread = $null } }
            return @{ Process = 'process-handle'; Thread = 'thread-handle' }
        }.GetNewClosure()
        Assign = {
            param($job, $process)
            Assert-That ($job -ceq 'job-handle' -and $process -ceq 'process-handle') 'exact-assignment'
            [void] $state.Events.Add('assign')
            if ($state.Options.expireAfterAssign) { $state.Now = 29000 }
            if ($state.Options.invalidAssignment) { return 'PRIVATE_FALSE_CANARY' }
            return -not $state.Options.assignmentFailure
        }.GetNewClosure()
        Resume = {
            param($thread)
            Assert-That ($thread -ceq 'thread-handle') 'exact-thread'
            Assert-That ($state.Closed.Contains('in-write') -and $state.Closed.Contains('out-write') -and $state.Closed.Contains('err-write')) 'eof-before-resume'
            [void] $state.Events.Add('resume')
            if ($state.Options.invalidResume) { return 'PRIVATE_FALSE_CANARY' }
            return -not $state.Options.resumeFailure
        }.GetNewClosure()
        ReadChunk = {
            param($process, $readers, $maximum, $deadline)
            Assert-That ($process -ceq 'process-handle' -and ($readers -join ',') -ceq 'out-read,err-read') 'owned-streams'
            Assert-That ($deadline -eq ($state.Deadline - 2 * $state.Frequency) -and $maximum -gt 0 -and $maximum -le 4096) 'bounded-read'
            [void] $state.Events.Add('read')
            $state.ReadCalls++
            [void] $state.ReadMaximums.Add($maximum)
            if ($state.Options.readFailure) { throw 'PRIVATE_FAILURE_CANARY' }
            if ($state.Options.expireAfterRead) { $state.Now = 29000 }
            $count = if ($state.Options.overflow) { $maximum + 1 } elseif ($state.Options.fullStream) { $maximum } else { 3 }
            if ($state.Options.emptyStream) { $count = 0 }
            $exited = if ($state.Options.tailDrain) { $state.ReadCalls -ge 2 } else { -not $state.Options.keepRunning }
            return @{ Bytes = [byte[]]::new($count); Exited = $exited }
        }.GetNewClosure()
        TerminateJob = {
            param($job)
            Assert-That ($job -ceq 'job-handle') 'exact-job-termination'
            [void] $state.Events.Add('terminate-job')
            return $true
        }.GetNewClosure()
        TerminateProcess = {
            param($process)
            Assert-That ($process -ceq 'process-handle') 'exact-process-termination'
            [void] $state.Events.Add('terminate-process')
            return $true
        }.GetNewClosure()
        Wait = {
            param($process, $deadline)
            Assert-That ($process -ceq 'process-handle') 'exact-reap'
            $state.WaitDeadline = $deadline
            [void] $state.Events.Add('wait')
            return -not $state.Options.waitFailure
        }.GetNewClosure()
        JobEmpty = {
            param($job, $deadline)
            Assert-That ($job -ceq 'job-handle' -and $deadline -eq $state.Deadline) 'bounded-job-reap'
            [void] $state.Events.Add('empty')
            return $true
        }.GetNewClosure()
        Close = {
            param($handle)
            [void] $state.Events.Add('close')
            [void] $state.Closed.Add($handle)
            if ($state.Options.closeFailure -and $state.Events.Contains('wait')) { throw 'PRIVATE_FAILURE_CANARY' }
            return $true
        }.GetNewClosure()
    }
    return @{ Adapter = $adapter; State = $state }
}

function Invoke-FakeBootstrap($Fixture, [long] $Deadline = 30000, [long] $Frequency = 1000) {
    return Invoke-JstiDiagnosticBootstrap -Adapter $Fixture.Adapter -Request 'PRIVATE_REQUEST_CANARY' `
        -DeadlineTicks $Deadline -Frequency $Frequency
}

$fixture = New-FakeBootstrap
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'finished' -and $result.cleanup -ceq 'complete' -and $result.streamBytes -eq 3) 'success'
Assert-That ($fixture.State.Events.IndexOf('suspended') -lt $fixture.State.Events.IndexOf('assign') -and $fixture.State.Events.IndexOf('assign') -lt $fixture.State.Events.IndexOf('resume')) 'assign-before-resume'
Assert-That (($fixture.State.Inherited -join ',') -ceq 'in-read,out-write,err-write') 'pipe-allowlist-excludes-job'
Assert-That (($fixture.State.Closed | Sort-Object -Unique).Count -eq 9 -and $fixture.State.Closed.Count -eq 9) 'close-each-handle-once'
Assert-That ($fixture.State.WaitDeadline -eq 30000 -and
    $fixture.State.Events.IndexOf('terminate-job') -lt $fixture.State.Events.IndexOf('wait') -and
    $fixture.State.Events.IndexOf('wait') -lt $fixture.State.Events.LastIndexOf('close')) 'reap-before-close'

$fixture = New-FakeBootstrap @{ assignmentFailure = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'failed' -and -not $result.resumed -and $result.cleanup -ceq 'complete') 'assignment-failure'
Assert-That ($fixture.State.Events.Contains('terminate-process') -and -not $fixture.State.Events.Contains('terminate-job') -and
    -not $fixture.State.Events.Contains('resume') -and $fixture.State.Closed.Count -eq 9) 'assignment-exact-handle-cleanup'

foreach ($failure in @('jobFailure', 'createFailure', 'pipeFailure', 'resumeFailure', 'readFailure', 'invalidAssignment', 'invalidResume')) {
    $fixture = New-FakeBootstrap @{ $failure = $true }
    $result = Invoke-FakeBootstrap $fixture
    $expectedCleanup = if ($failure -in @('jobFailure', 'createFailure', 'pipeFailure')) { 'incomplete' } else { 'complete' }
    Assert-That ($result.status -ceq 'failed' -and $result.cleanup -ceq $expectedCleanup) 'exception-contained-and-cleanup-truthful'
    $expectedClosed = if ($failure -ceq 'jobFailure') { 0 } elseif ($failure -ceq 'pipeFailure') { 1 } elseif ($failure -ceq 'createFailure') { 7 } else { 9 }
    Assert-That ($fixture.State.Closed.Count -eq $expectedClosed) 'all-returned-resources-closed'
    if ($failure -in @('jobFailure', 'createFailure', 'pipeFailure', 'invalidAssignment')) {
        Assert-That (-not $fixture.State.Events.Contains('resume')) 'pre-admission-failure-never-resumes'
    }
    Assert-That ((ConvertTo-Json -Compress $result) -notmatch 'PRIVATE|handle|read|write') 'no-private-projection'
}

$fixture = New-FakeBootstrap @{ partialChild = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'failed' -and $result.cleanup -ceq 'incomplete' -and
    -not $fixture.State.Events.Contains('resume') -and $fixture.State.Events.Contains('terminate-process') -and
    $fixture.State.Events.Contains('terminate-job') -and $fixture.State.Closed.Count -eq 8) 'partial-transfer-known-cleanup-unknown-remains'

$fixture = New-FakeBootstrap @{ expireAfterAssign = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'deadline' -and -not $result.resumed -and
    -not $fixture.State.Events.Contains('resume') -and $fixture.State.Events.Contains('terminate-job')) 'deadline-before-resume'

$fixture = New-FakeBootstrap
$result = Invoke-FakeBootstrap $fixture 6000
Assert-That ($result.status -ceq 'skipped' -and $fixture.State.Events.Count -eq 0) 'reserve-before-resource-acquisition'

$fixture = New-FakeBootstrap @{ fullStream = $true; keepRunning = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'streamLimit' -and $result.streamBytes -eq 65536 -and
    ($fixture.State.ReadMaximums | Measure-Object -Sum).Sum -eq 65536) 'combined-stream-cap'

$fixture = New-FakeBootstrap @{ overflow = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'failed' -and $result.streamBytes -eq 0 -and $result.cleanup -ceq 'complete') 'hostile-read-count'

foreach ($failure in @('waitFailure', 'closeFailure')) {
    $fixture = New-FakeBootstrap @{ $failure = $true }
    $result = Invoke-FakeBootstrap $fixture
    Assert-That ($result.status -ceq 'finished' -and $result.cleanup -ceq 'incomplete' -and
        $fixture.State.Closed.Count -eq 9) 'cleanup-failure-truthful-and-continues'
}

$fixture = New-FakeBootstrap @{ emptyStream = $true; keepRunning = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'sampleLimit' -and $fixture.State.ReadCalls -eq 4096 -and
    $result.cleanup -ceq 'complete') 'nonadvancing-clock-bounded'

$fixture = New-FakeBootstrap @{ expireAfterRead = $true; keepRunning = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'deadline' -and $fixture.State.ReadCalls -eq 1) 'absolute-deadline-not-reset'

foreach ($frequency in @(0, -1, 1000000001)) {
    $fixture = New-FakeBootstrap
    $result = Invoke-FakeBootstrap $fixture 30000 $frequency
    Assert-That ($result.status -ceq 'skipped' -and $fixture.State.Events.Count -eq 0) 'invalid-clock-no-acquisition'
}
$fixture = New-FakeBootstrap
[void] $fixture.Adapter.Remove('Assign')
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'skipped' -and $fixture.State.Events.Count -eq 0) 'missing-adapter-no-acquisition'

# Tail output is not complete until the adapter reports BOTH pipes drained.
$fixture = New-FakeBootstrap @{ tailDrain = $true }
$result = Invoke-FakeBootstrap $fixture
Assert-That ($result.status -ceq 'finished' -and $fixture.State.ReadCalls -eq 2 -and $result.streamBytes -eq 6) 'tail-before-exit-receipt'

# Real JSON deserialization uses Int64; reproject only finite canonical fields.
$value = '{"schema":1,"status":"observed","cleanup":"clean","private":"PRIVATE_CANARY","debugger":{"status":"observed","exceptionCode":"0xc0000374","frames":[{"index":0,"module":"app","rva":"0x123","private":"PRIVATE_CANARY"}]}}' | ConvertFrom-Json
$projection = ConvertTo-JstiDiagnosticProjection $value
$serialized = ConvertTo-Json -Compress -Depth 8 $projection
Assert-That ($serialized -notmatch 'PRIVATE|private' -and $projection.debugger.frames[0].rva -ceq '0x123') 'closed-projection-real-json'
$warnings = @()
$final = @{ runs = @(@{ failureDiagnostic = @{ diagnostic = $projection } }) } | ConvertTo-Json -Depth 8 -WarningVariable warnings
$roundTrip = $final | ConvertFrom-Json -Depth 8
Assert-That ($warnings.Count -eq 0 -and $roundTrip.runs[0].failureDiagnostic.diagnostic.debugger.frames[0].rva -ceq '0x123') 'existing-final-receipt-depth-preserves-frames'
foreach ($bad in @(
    '{"schema":"1","status":"observed"}',
    '{"schema":1,"status":"PRIVATE_CANARY"}',
    '{"schema":1,"status":"observed","debugger":{"status":"observed","frames":[{"index":0,"module":"PRIVATE_CANARY"}]}}',
    '{"schema":1,"status":"observed","debugger":{"status":"observed","frames":[{"index":0,"module":"app","rva":"PRIVATE_CANARY"}]}}',
    '{"schema":1,"status":"observed","debugger":{"status":"observed","frames":[{"index":1,"module":"app"}]}}'
)) {
    $refused = $false
    try { [void] (ConvertTo-JstiDiagnosticProjection ($bad | ConvertFrom-Json)) } catch { $refused = $true }
    Assert-That $refused 'invalid-projection-refused'
}
# .NET $ admits a terminal LF; every child numeric string must consume the whole string.
foreach ($suffix in @("`n", "`r", "`r`n")) {
    foreach ($field in @('version', 'exceptionCode', 'faultOffset', 'rva')) {
        $candidate = '{"schema":1,"status":"observed","applicationError":{"status":"observed","module":"app","version":"1.2.3.4","exceptionCode":"0xc0000374","faultOffset":"0x123"},"debugger":{"status":"observed","frames":[{"index":0,"module":"app","rva":"0x123"}]}}' | ConvertFrom-Json
        if ($field -ceq 'rva') { $candidate.debugger.frames[0].rva += $suffix }
        else { $candidate.applicationError.$field += $suffix }
        $refused = $false
        try { [void] (ConvertTo-JstiDiagnosticProjection $candidate) } catch { $refused = $true }
        Assert-That $refused 'numeric-terminal-newline-refused'
    }
}

# Exercise real bounded PE/identity admission using only owned synthetic bytes.
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jsti-bootstrap-fakes-' + [guid]::NewGuid().ToString('N'))
[void] [System.IO.Directory]::CreateDirectory($testRoot)
try {
    $file = Join-Path $testRoot 'python.exe'
    $pe = [byte[]]::new(512); $pe[0] = 0x4D; $pe[1] = 0x5A; $pe[0x3C] = 0x80
    $pe[0x80] = 0x50; $pe[0x81] = 0x45; $pe[0x84] = 0x64; $pe[0x85] = 0xAA
    [System.IO.File]::WriteAllBytes($file, $pe)
    $identity = Get-JstiDiagnosticIdentity $file @('python.exe')
    Assert-That ($identity.Hash -cmatch '^[0-9a-f]{64}$' -and $identity.Path -ceq $file) 'owned-synthetic-pe-admitted'
    $pe[0] = 0
    [System.IO.File]::WriteAllBytes($file, $pe)
    $refused = $false
    try { [void] (Get-JstiDiagnosticIdentity $file @('python.exe')) } catch { $refused = $true }
    Assert-That $refused 'invalid-pe-refused'
    $large = [System.IO.File]::OpenWrite($file)
    try { $large.SetLength(16777217) } finally { $large.Dispose() }
    $refused = $false
    try { [void] (Get-JstiDiagnosticIdentity $file @('python.exe')) } catch { $refused = $true }
    Assert-That $refused 'size-refused-before-hashing'
} finally { [System.IO.Directory]::Delete($testRoot, $true) }

# Ineligible failures must not even admit a host, much less create a process.
$originalIdentity = (Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$admissions = @{ Count = 0 }
Set-Item Function:Get-JstiDiagnosticIdentity -Value { $admissions.Count++; throw 'unavailable' }.GetNewClosure()
try {
    foreach ($case in @(
        @{ label = 'self-test'; arguments = '--ui-smoke-test'; exitCode = -1073740940; processMachine = '0xAA64' },
        @{ label = 'ui-smoke'; arguments = '--self-test'; exitCode = -1073740940; processMachine = '0xAA64' },
        @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = 0; processMachine = '0xAA64' },
        @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = 1; processMachine = '0xAA64' },
        @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = -1073740940; processMachine = '0x8664' }
    )) {
        $oldExit = $case.exitCode
        $frequency = [System.Diagnostics.Stopwatch]::Frequency
        $deadline = [System.Diagnostics.Stopwatch]::GetTimestamp() + 30 * $frequency
        $outcome = Invoke-JstiStandaloneDiagnostic @{} $case $null 'PRIVATE_PATH' ('0' * 64) $deadline $frequency ([datetime]::UtcNow) ([datetime]::UtcNow)
        Assert-That ($outcome.status -ceq 'unavailable' -and $outcome.originalFailurePreserved -ceq $true -and
            $case.exitCode -eq $oldExit -and $admissions.Count -eq 0) 'ineligible-no-bootstrap-or-verdict-change'
    }
    $eligible = @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = -1073740940; processMachine = '0xAA64' }
    $frequency = [System.Diagnostics.Stopwatch]::Frequency
    $deadline = [System.Diagnostics.Stopwatch]::GetTimestamp() + 30 * $frequency
    $outcome = Invoke-JstiStandaloneDiagnostic @{} $eligible $null 'PRIVATE_PATH' ('0' * 64) $deadline $frequency ([datetime]::UtcNow) ([datetime]::UtcNow)
    Assert-That ($admissions.Count -eq 1 -and $outcome.status -ceq 'unavailable' -and
        $eligible.exitCode -eq -1073740940) 'eligible-reaches-owned-host-admission-only'
} finally { Set-Item Function:Get-JstiDiagnosticIdentity -Value $originalIdentity }

# Actual parent request -> controller -> JSON projection, using only fake native operations.
# This proves derived child cutoff and original cleanup deadline together, not a copied formula.
$ownedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jsti-bridge-fake-' + [guid]::NewGuid().ToString('N'))
[void] [System.IO.Directory]::CreateDirectory($ownedRoot)
$identityFunction = (Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$adapterFunction = (Get-Item Function:New-JstiDiagnosticAdapter).ScriptBlock
$frequency = [System.Diagnostics.Stopwatch]::Frequency
$now = [System.Diagnostics.Stopwatch]::GetTimestamp()
$deadline = $now + 30 * $frequency
$fixture = New-FakeBootstrap @{ Now = $now; Deadline = $deadline; Frequency = $frequency }
$capture = @{ Request = $null; State = $null }
$create = $fixture.Adapter.CreateSuspended
$fixture.Adapter.CreateSuspended = {
    param($request, $inherited, $job, $pipes, $deadline, $frequency)
    $capture.Request = $request
    return & $create $request $inherited $job $pipes $deadline $frequency
}.GetNewClosure()
$fixture.Adapter.ReadChunk = {
    param($process, $readers, $maximum, $deadline)
    Assert-That ($deadline -eq $fixture.State.Deadline - 2 * $fixture.State.Frequency) 'derived-parent-work-cutoff'
    $json = [System.Text.Encoding]::UTF8.GetBytes('{"schema":1,"status":"no-reproduction","cleanup":"clean","private":"PRIVATE_CANARY","debugger":{"status":"no-reproduction","frames":[]}}')
    $capture.State.Output.Write($json, 0, $json.Length)
    return @{ Bytes = $json; Exited = $true }
}.GetNewClosure()
Set-Item Function:Get-JstiDiagnosticIdentity -Value { param($path, $names) return @{ Path = $path; Hash = '0' * 64 } }
Set-Item Function:New-JstiDiagnosticAdapter -Value {
    param($frequency, $state)
    $capture.State = $state
    return $fixture.Adapter
}.GetNewClosure()
try {
    $workspace = $ownedRoot; $systemRoot = 'C:\Windows'; $isolatedPath = 'C:\Windows\System32'
    $setup = @{ Host = @{ Path = 'C:\Owned\pwsh.exe'; Hash = '0' * 64 }; Python = @{ Path = 'C:\Owned\python.exe'; Hash = '0' * 64 } }
    $run = @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = -1073740940; processMachine = '0xAA64' }
    $result = Invoke-JstiStandaloneDiagnostic $setup $run @{ Id = 314 } 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency ([datetime]::UtcNow) ([datetime]::UtcNow)
    Assert-That ($result.status -ceq 'no-reproduction' -and $result.bootstrap.cleanup -ceq 'complete' -and
        $run.exitCode -eq -1073740940) 'optional-success-preserves-original-failure'
    $argv = $capture.Request.Arguments
    Assert-That (($argv[0..1] -join ',') -ceq '-I,-B' -and $argv[3] -ceq 'standalone-diagnostic' -and $argv[4] -ceq '--request') 'fixed-bridge-argv'
    $base64 = $argv[5].Replace('-', '+').Replace('_', '/')
    $base64 = $base64.PadRight($base64.Length + ((4 - $base64.Length % 4) % 4), '=')
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json
    Assert-That ($decoded.deadlineTicks -eq $deadline - 2 * $frequency -and
        $decoded.frequency -eq $frequency -and $fixture.State.WaitDeadline -eq $deadline) 'nested-reserves-share-original-clock'
    Assert-That (($result | ConvertTo-Json -Depth 8) -notmatch 'PRIVATE_CANARY') 'whole-parent-projection-canary-absent'
} finally {
    Set-Item Function:Get-JstiDiagnosticIdentity -Value $identityFunction
    Set-Item Function:New-JstiDiagnosticAdapter -Value $adapterFunction
    [System.IO.Directory]::Delete($ownedRoot, $true)
}

# Native workflow translation uses the actual shared wrapper, never a debugger.
function New-NativeFailureFixture([long] $Deadline, [long] $Frequency) {
    $moment = [datetime]::UtcNow.ToString('o')
    return @{
        label = 'ui-smoke-test'; arguments = @('--ui-smoke-test'); timedOut = $false
        processMachine = 'arm64'; nativeMachine = 'arm64'; exitCode = [long] 3221226356
        failures = @('exited with 3221226356')
        executable = @{ name = 'SpeakWindows.exe'; path = 'C:\Owned\SpeakWindows.exe'
            architecture = 'arm64'; native = $true; dll = $false; sha256 = '0' * 64 }
        diagnosticOwnerContext = @{ schema = 1; originalPid = 314; startedUTC = $moment; endedUTC = $moment
            deadlineTicks = $Deadline; frequency = $Frequency; exitCode = -1073740940 }
    }
}

$standaloneFunction = (Get-Item Function:Invoke-JstiStandaloneDiagnostic).ScriptBlock
$nativeCalls = @{ Count = 0; Last = $null; Status = 'no-reproduction' }
Set-Item Function:Invoke-JstiStandaloneDiagnostic -Value {
    param($setup, $run, $process, $exe, $sha, $deadline, $frequency, $started, $ended)
    $nativeCalls.Count++
    $nativeCalls.Last = @{ Run = $run; Process = $process; Executable = $exe; SHA256 = $sha
        Deadline = $deadline; Frequency = $frequency; Started = $started; Ended = $ended }
    return @{ status = $nativeCalls.Status; originalFailurePreserved = $true }
}.GetNewClosure()
try {
    $frequency = [System.Diagnostics.Stopwatch]::Frequency
    $deadline = [System.Diagnostics.Stopwatch]::GetTimestamp() + 30 * $frequency
    $setup = @{ Host = @{ Path = 'C:\Owned\pwsh.exe'; Hash = '0' * 64 }; Python = @{ Path = 'C:\Owned\python.exe'; Hash = '0' * 64 } }
    foreach ($code in @(0xC0000005L, 0xC0000374L, 0xC0000409L)) {
        $record = New-NativeFailureFixture $deadline $frequency
        $record.exitCode = $code
        $record.diagnosticOwnerContext.exitCode = [int] ($code - 4294967296L)
        $before = $record | ConvertTo-Json -Depth 12 -Compress
        $result = Invoke-JstiNativeFailureDiagnostic $setup $record 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        Assert-That ($result.status -ceq 'no-reproduction' -and $result.originalFailurePreserved) 'native-eligible-reaches-same-confined-bridge'
        Assert-That ($nativeCalls.Last.Run.exitCode -eq [int] ($code - 4294967296L) -and
            $nativeCalls.Last.Run.label -ceq 'ui-smoke' -and $nativeCalls.Last.Run.arguments -ceq '--ui-smoke-test' -and
            $nativeCalls.Last.Run.processMachine -ceq '0xAA64' -and $nativeCalls.Last.Process.Id -eq 314 -and
            $nativeCalls.Last.Deadline -eq $deadline -and $nativeCalls.Last.Frequency -eq $frequency) 'native-typed-shapes-and-original-clock'
        Assert-That (($record | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'native-original-record-unchanged'
    }
    foreach ($mutate in @(
        { param($r) $r.label = 'self-test' },
        { param($r) $r.arguments = @('--self-test') },
        { param($r) $r.arguments = @('--ui-smoke-test', 'PRIVATE_CANARY') },
        { param($r) $r.timedOut = $true },
        { param($r) $r.processMachine = 'x64' },
        { param($r) $r.nativeMachine = 'x64' },
        { param($r) $r.failures = @() },
        { param($r) $r.exitCode = 1 },
        { param($r) $r.executable.sha256 = '1' * 64 },
        { param($r) $r.executable.path = 'C:\Other\SpeakWindows.exe' },
        { param($r) $r.diagnosticOwnerContext.private = 'PRIVATE_CANARY' },
        { param($r) $r.diagnosticOwnerContext.originalPid = $true },
        { param($r) $r.diagnosticOwnerContext.deadlineTicks-- },
        { param($r) $r.diagnosticOwnerContext.frequency-- },
        { param($r) $r.diagnosticOwnerContext.exitCode = -1073741819 },
        { param($r) $r.diagnosticOwnerContext.startedUTC = '2026-10-28T12:00:00+01:00' },
        { param($r) $r.diagnosticOwnerContext.startedUTC = '2026-10-28T12:00:00Z'; $r.diagnosticOwnerContext.endedUTC = '2026-10-28T12:00:31Z' }
    )) {
        $record = New-NativeFailureFixture $deadline $frequency
        & $mutate $record
        $before = $nativeCalls.Count
        $result = Invoke-JstiNativeFailureDiagnostic $setup $record 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        Assert-That ($nativeCalls.Count -eq $before -and $result.status -ceq 'unavailable' -and
            $result.originalFailurePreserved -and ($result | ConvertTo-Json) -notmatch 'PRIVATE_CANARY') 'invalid-native-context-never-launches'
    }
    foreach ($status in @('deadline', 'unavailable', 'observed')) {
        $nativeCalls.Status = $status
        $record = New-NativeFailureFixture $deadline $frequency
        $result = Invoke-JstiNativeFailureDiagnostic $setup $record 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        Assert-That ($result.status -ceq $status -and $record.exitCode -eq 3221226356 -and
            $record.failures.Count -eq 1) 'diagnostic-result-never-promotes-original-failure'
    }

    # Actual bounded evidence update preserves UTC strings, other runs and all
    # original native fields, with only the finite diagnostic field appended.
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('jsti-native-receipt-fake-' + [guid]::NewGuid().ToString('N'))
    [void] [System.IO.Directory]::CreateDirectory($root)
    try {
        $path = Join-Path $root 'native.json'
        $record = New-NativeFailureFixture $deadline $frequency
        $evidence = @{ schemaVersion = 1; architecture = 'arm64'; host = @{ fixed = 'kept' }
            runs = @(@{ label = 'self-test'; exitCode = 0 }, $record) }
        $json = $evidence | ConvertTo-Json -Depth 12 -Compress
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
        Update-JstiNativeFailureEvidence $setup $path 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        $document = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($path))
        try {
            $saved = ConvertFrom-JstiEvidenceElement $document.RootElement
            Assert-That ($saved.runs[1].failureDiagnostic.status -ceq 'observed' -and
                $saved.runs[1].diagnosticOwnerContext.startedUTC -is [string] -and
                $saved.runs[1].diagnosticOwnerContext.startedUTC -ceq $record.diagnosticOwnerContext.startedUTC -and
                $saved.runs[0].exitCode -eq 0 -and $saved.host.fixed -ceq 'kept') 'native-json-preserves-original-types-and-other-receipts'
            $saved.runs[1].Remove('failureDiagnostic') | Out-Null
            Assert-That (($saved.runs[1] | ConvertTo-Json -Depth 12 -Compress) -ceq
                ($record | ConvertTo-Json -Depth 12 -Compress)) 'native-json-all-original-fields-exact'
        } finally { $document.Dispose() }
        Assert-That (@(Get-ChildItem -LiteralPath $root).Count -eq 1) 'native-no-owned-temp-leftover'
        [System.IO.File]::WriteAllText($path, 'INVALID_PRIVATE_CANARY')
        Update-JstiNativeFailureEvidence $setup $path 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        Assert-That ([System.IO.File]::ReadAllText($path) -ceq 'INVALID_PRIVATE_CANARY') 'invalid-json-original-preserved'
    } finally { [System.IO.Directory]::Delete($root, $true) }
} finally { Set-Item Function:Invoke-JstiStandaloneDiagnostic -Value $standaloneFunction }


# Every normalized Windows parent is admitted before the event host is launched.
$ancestorFixture = @{ Seen = @(); Reparse = ''; Missing = '' }
function Get-Item {
    param([string] $LiteralPath, $ErrorAction)
    $ancestorFixture.Seen += $LiteralPath
    if ($LiteralPath -ceq $ancestorFixture.Missing) { throw 'PRIVATE_CANARY' }
    return @{ PSIsContainer = $true; Attributes = $(if ($LiteralPath -ceq $ancestorFixture.Reparse) { 1024 } else { 0 }) }
}
try {
    Assert-JstiDiagnosticAncestors 'C:\Windows\System32\powershell.exe'
    Assert-That (($ancestorFixture.Seen -join ',') -ceq 'C:\Windows\System32,C:\Windows,C:\') 'all-host-ancestors-including-root'
    foreach ($field in @('Reparse', 'Missing')) {
        $ancestorFixture[$field] = 'C:\Windows'; $refused = $false
        try { Assert-JstiDiagnosticAncestors 'C:\Windows\System32\powershell.exe' } catch { $refused = $true }
        Assert-That $refused 'reparse-or-inaccessible-parent-refused'
        $ancestorFixture[$field] = ''
    }
} finally { Remove-Item Function:Get-Item }

# Event-only packaged path uses the same private bootstrap, never a target replay.
$packagedIdentityFunction = (Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$packagedAdapterFunction = (Get-Item Function:New-JstiDiagnosticAdapter).ScriptBlock
$packagedBootstrapFunction = (Get-Item Function:Invoke-JstiDiagnosticBootstrap).ScriptBlock
$packagedSystemRoot = $env:SystemRoot
$packagedWorkspace = $workspace
$packagedRoot = Join-Path ([IO.Path]::GetTempPath()) ('jsti-packaged-fake-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($packagedRoot)
$packagedFake = @{ Calls = 0; State = $null; Mode = 'clean'; Request = $null; Launch = $null; Cutoff = [long] 0 }
Set-Item Function:Get-JstiDiagnosticIdentity -Value {
    param($path, $names, [switch] $FrameworkPath)
    Assert-That $FrameworkPath 'packaged-framework-path-opt-in'
    return @{ Path = $path; Hash = '0' * 64 }
}
Set-Item Function:New-JstiDiagnosticAdapter -Value {
    param($frequency, $state)
    if ($packagedFake.Mode -ceq 'stream-cleanup') {
        $wrapper = [pscustomobject]@{ Inner = $state.Output }
        $wrapper | Add-Member ScriptMethod Write { param($b,$i,$n); $this.Inner.Write($b,$i,$n) }
        $wrapper | Add-Member ScriptMethod ToArray { return ,$this.Inner.ToArray() }
        $wrapper | Add-Member ScriptMethod Dispose { $this.Inner.Dispose(); throw 'PRIVATE_CANARY' }
        $state.Output = $wrapper
    }
    $packagedFake.State = $state
    return @{}
}
Set-Item Function:Invoke-JstiDiagnosticBootstrap -Value {
    param($adapter, $launch, [long] $cutoff, [long] $frequency)
    $packagedFake.Calls++; $packagedFake.Launch = $launch; $packagedFake.Cutoff = $cutoff
    Assert-That (($launch.Arguments[0..3] -join ',') -like '-I,-B,*,packaged-application-error') 'event-only-exact-command'
    Assert-That ($launch.Arguments[4] -ceq '--request' -and $launch.Arguments.Count -eq 6) 'event-only-no-extra-args'
    $encoded = $launch.Arguments[5].Replace('-', '+').Replace('_', '/')
    $encoded += '=' * ((4 - $encoded.Length % 4) % 4)
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    $packagedFake.Request = $request
    Assert-That ($request.deadlineTicks -eq ($cutoff - 2 * $frequency)) 'packaged-derived-child-cutoff'
    Assert-That ($request.label -ceq 'base-ui-smoke-test' -and $request.exitCode -eq -1073741819 -and
        $request.originalPid -eq 4242 -and $request.parentPid -eq $PID -and
        $request.originalDeadlineTicks - $request.startedTicks -eq 60 * $frequency) 'packaged-original-binding'
    Assert-That ($cutoff -le $request.originalDeadlineTicks -and
        $cutoff - [Diagnostics.Stopwatch]::GetTimestamp() -le 10 * $frequency) 'packaged-no-added-budget'
    Assert-That ($launch.Environment -notmatch 'PRIVATE_PARENT|OP_|API_KEY' -and
        $launch.Environment.Contains('USERPROFILE=')) 'packaged-private-environment'
    $projection = @{ schema = 1; status = 'observed'; cleanup = 'clean'
        applicationError = @{ status = 'observed'; module = 'app'; version = '1.2.3.4'
            exceptionCode = '0xc0000005'; faultOffset = '0x123' } }
    if ($packagedFake.Mode -ceq 'debugger') { $projection.debugger = @{ status = 'observed'; frames = @() } }
    if ($packagedFake.Mode -ceq 'private') { $projection.applicationError.private = 'PRIVATE_CANARY' }
    if ($packagedFake.Mode -ceq 'child-cleanup') { $projection.cleanup = 'failed' }
    if ($packagedFake.Mode -ceq 'malformed') { $text = 'PRIVATE_CANARY' }
    else { $text = $projection | ConvertTo-Json -Depth 8 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $packagedFake.State.Output.Write($bytes, 0, $bytes.Length)
    if ($packagedFake.Mode -ceq 'scratch-cleanup') {
        [IO.Directory]::Delete($launch.Directory, $true)
        [IO.File]::WriteAllText($launch.Directory, 'owned fake')
    }
    if ($packagedFake.Mode -ceq 'parent-cleanup') { return @{ status = 'finished'; cleanup = 'incomplete' } }
    return @{ status = 'finished'; cleanup = 'complete' }
}
try {
    $env:SystemRoot = 'C:\Windows'; $workspace = $packagedRoot
    $systemRoot = 'C:\Windows'; $isolatedPath = 'C:\Windows\System32'
    $setup = @{ Host = @{ Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; Hash = '0' * 64 }
        Python = @{ Path = 'C:\Owned\python.exe'; Hash = '0' * 64 } }
    $frequency = [Diagnostics.Stopwatch]::Frequency
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    $context = @{ originalPid = 4242; startedUTC = [datetime]::UtcNow.AddSeconds(-2); endedUTC = [datetime]::UtcNow.AddSeconds(-1)
        startedTicks = $now - 2 * $frequency; endedTicks = $now - $frequency
        originalDeadlineTicks = $now + 58 * $frequency; frequency = $frequency }
    $run = @{ label = 'base-ui-smoke-test'; arguments = '--ui-smoke-test'; exitCode = -1073741819
        packageFullName = 'owned-package'; identityError = $null; modules = @{ passed = $true }; original = 'kept' }
    $original = $run | ConvertTo-Json -Depth 8 -Compress
    foreach ($mode in @('clean', 'debugger', 'private', 'child-cleanup', 'malformed', 'parent-cleanup', 'stream-cleanup', 'scratch-cleanup', 'cutoff')) {
        $packagedFake.Mode = $mode
        $clockState = @{ Calls = 0; Start = [Diagnostics.Stopwatch]::GetTimestamp() }
        $fakeMode = $mode
        $clock = {
            $clockState.Calls++
            if ($fakeMode -ceq 'cutoff' -and $clockState.Calls -gt 1) { return $clockState.Start + 11 * $frequency }
            return $clockState.Start
        }.GetNewClosure()
        $result = Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package' $clock
        Assert-That (($run | ConvertTo-Json -Depth 8 -Compress) -ceq $original) 'packaged-original-failure-unchanged'
        Assert-That ($result.originalFailurePreserved -ceq $true) 'packaged-failure-preserved'
        if ($mode -ceq 'clean') {
            Assert-That ($result.status -ceq 'observed' -and $result.applicationErrorEvidence.applicationError.faultOffset -ceq '0x123') 'packaged-observed-event'
            Assert-That ($packagedFake.Request.PSObject.Properties.Name.Count -eq 17) 'packaged-closed-request'
        } else {
            Assert-That ($result.status -cne 'observed') 'packaged-malformed-or-unclean-refuses'
            Assert-That ($result.applicationErrorEvidence.status -cne 'observed' -and
                $result.applicationErrorEvidence.applicationError.status -cne 'observed') 'packaged-no-stale-observed-child'
        }
        Assert-That (($result | ConvertTo-Json -Depth 8 -Compress) -notmatch 'PRIVATE_CANARY|C:\\Owned|originalPid|startedUTC') 'packaged-closed-output'
    }
    $before = $packagedFake.Calls
    foreach ($replacement in @(0, 42, 3221225477L)) {
        $run.exitCode = $replacement
        [void] (Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package')
    }
    $run.exitCode = -1073741819
    foreach ($field in @('label', 'arguments', 'packageFullName')) {
        $saved = $run[$field]; $run[$field] = 'foreign'
        [void] (Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package')
        $run[$field] = $saved
    }
    $run.modules.passed = $false
    [void] (Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package')
    $run.modules.passed = $true
    $context.extra = 'PRIVATE_CANARY'
    [void] (Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package')
    $context.Remove('extra')
    Assert-That ($packagedFake.Calls -eq $before) 'packaged-noncandidate-no-diagnostic-launch'
    # The optional child must skip when the original remaining budget is small.
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    $context.startedTicks = $now - 55 * $frequency; $context.endedTicks = $now - $frequency
    $context.originalDeadlineTicks = $now + 5 * $frequency
    $result = Invoke-JstiPackagedEventDiagnostic $setup $run $context 'C:\Owned\SpeakWindows.exe' ('0' * 64) 'owned-package'
    Assert-That ($result.status -ceq 'deadline' -and $packagedFake.Calls -eq $before) 'packaged-insufficient-original-budget'
} finally {
    Set-Item Function:Get-JstiDiagnosticIdentity -Value $packagedIdentityFunction
    Set-Item Function:New-JstiDiagnosticAdapter -Value $packagedAdapterFunction
    Set-Item Function:Invoke-JstiDiagnosticBootstrap -Value $packagedBootstrapFunction
    $env:SystemRoot = $packagedSystemRoot; $workspace = $packagedWorkspace
    [IO.Directory]::Delete($packagedRoot, $true)
}

# Finite parser refusal facts cross the actual closed projector, never raw output.
$parserValue = '{"schema":1,"status":"invalid","cleanup":"clean","applicationError":{"status":"unavailable"},"debugger":{"status":"invalid","frames":[],"refusalFacts":{"reason":"ready-marker-count","completionClass":"nonzero","counts":{"ready":0,"fault":1,"end":1,"modules":1,"stack":1,"ip":0,"moduleRanges":0,"stackRows":0}}}}' | ConvertFrom-Json
$parserProjection = ConvertTo-JstiDiagnosticProjection $parserValue
Assert-That ($parserProjection.debugger.refusalFacts.reason -ceq 'ready-marker-count' -and
    $parserProjection.debugger.refusalFacts.counts.ready -eq 0) 'finite-refusal-facts-preserved'
$parserBaseline = $parserValue | ConvertTo-Json -Depth 8 -Compress
foreach ($mutation in @('unknown-reason', 'unknown-class', 'unknown-field', 'missing-field', 'unknown-count',
        'missing-count', 'bool-count', 'negative-count', 'oversize-count', 'fraction-count', 'case-count', 'not-invalid', 'cleanup-failed')) {
    $candidate = $parserBaseline | ConvertFrom-Json
    switch ($mutation) {
        'unknown-reason' { $candidate.debugger.refusalFacts.reason = 'PRIVATE_CANARY' }
        'unknown-class' { $candidate.debugger.refusalFacts.completionClass = 'ZERO' }
        'unknown-field' { $candidate.debugger.refusalFacts | Add-Member extra 'PRIVATE_CANARY' }
        'missing-field' { $candidate.debugger.refusalFacts.PSObject.Properties.Remove('reason') }
        'unknown-count' { $candidate.debugger.refusalFacts.counts | Add-Member extra 1 }
        'missing-count' { $candidate.debugger.refusalFacts.counts.PSObject.Properties.Remove('ready') }
        'bool-count' { $candidate.debugger.refusalFacts.counts.ready = $true }
        'negative-count' { $candidate.debugger.refusalFacts.counts.ready = -1 }
        'oversize-count' { $candidate.debugger.refusalFacts.counts.ready = 18 }
        'fraction-count' { $candidate.debugger.refusalFacts.counts.ready = 1.5 }
        'case-count' { $candidate.debugger.refusalFacts.counts.PSObject.Properties.Remove('ready'); $candidate.debugger.refusalFacts.counts | Add-Member Ready 1 }
        'not-invalid' { $candidate.debugger.status = 'observed' }
        'cleanup-failed' { $candidate.cleanup = 'failed' }
    }
    $refused = $false
    try { [void] (ConvertTo-JstiDiagnosticProjection $candidate) } catch { $refused = $true }
    Assert-That $refused 'malicious-parser-facts-refused'
}

# Exercise retirement in the real parent wrapper, with no native preparation.
$parserRoot = Join-Path ([IO.Path]::GetTempPath()) ('jsti-parser-facts-fake-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($parserRoot)
$parserIdentity = (Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$parserAdapter = (Get-Item Function:New-JstiDiagnosticAdapter).ScriptBlock
$parserBootstrap = (Get-Item Function:Invoke-JstiDiagnosticBootstrap).ScriptBlock
$parserOldWorkspace = $workspace; $parserOldSystemRoot = $systemRoot; $parserOldIsolatedPath = $isolatedPath
$parserFake = @{ State = $null; Mode = ''; Original = $parserBaseline }
Set-Item Function:Get-JstiDiagnosticIdentity -Value { param($path, $names) return @{ Path = $path; Hash = '0' * 64 } }
Set-Item Function:New-JstiDiagnosticAdapter -Value {
    param($frequency, $state)
    $parserFake.State = $state
    return @{}
}.GetNewClosure()
Set-Item Function:Invoke-JstiDiagnosticBootstrap -Value {
    param($adapter, $launch, [long] $deadline, [long] $frequency)
    $value = $parserFake.Original | ConvertFrom-Json
    if ($parserFake.Mode -ceq 'child-cleanup') { $value.cleanup = 'failed' }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 8 -Compress))
    $parserFake.State.Output.Write($bytes, 0, $bytes.Length)
    if ($parserFake.Mode -ceq 'stream-cleanup') {
        $parserFake.State.Output.Dispose()
        $replacement = [pscustomobject] @{ Bytes = $bytes }
        $replacement | Add-Member ScriptMethod ToArray { return ,$this.Bytes }
        $replacement | Add-Member ScriptMethod Dispose { throw 'PRIVATE_CANARY' }
        $parserFake.State.Output = $replacement
    }
    return @{ status = 'finished'; cleanup = $(if ($parserFake.Mode -ceq 'parent-cleanup') { 'incomplete' } else { 'complete' }) }
}.GetNewClosure()
try {
    $workspace = $parserRoot; $systemRoot = 'C:\Windows'; $isolatedPath = 'C:\Windows\System32'
    $setup = @{ Host = @{ Path = 'C:\Owned\pwsh.exe'; Hash = '0' * 64 }; Python = @{ Path = 'C:\Owned\python.exe'; Hash = '0' * 64 } }
    $run = @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = -1073740940; processMachine = '0xAA64' }
    foreach ($mode in @('clean', 'child-cleanup', 'parent-cleanup', 'cutoff', 'stream-cleanup')) {
        $parserFake.Mode = $mode
        $frequency = [Diagnostics.Stopwatch]::Frequency
        $deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 30 * $frequency
        $outcome = $null; $thrown = $false
        try { $outcome = Invoke-JstiStandaloneDiagnostic $setup $run @{ Id = 314 } 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency ([datetime]::UtcNow) ([datetime]::UtcNow) }
        catch { $thrown = $true }
        if ($mode -ceq 'cutoff') {
            # Actual pure retirement boundary uses an injected numeric clock;
            # no sleep, changed production clock or new wrapper seam.
            Remove-JstiStaleRefusalFacts $outcome $true 30 30
        }
        if ($mode -ceq 'clean') {
            Assert-That ($outcome.status -ceq 'invalid' -and $outcome.diagnostic.debugger.refusalFacts.reason -ceq 'ready-marker-count') 'parent-preserves-current-clean-facts'
        } elseif ($mode -ceq 'stream-cleanup') {
            Assert-That ($thrown -and $null -eq $outcome) 'stream-cleanup-cannot-return-facts'
        } else {
            Assert-That ((($outcome | ConvertTo-Json -Depth 8 -Compress) -notmatch 'refusalFacts') -and
                $run.exitCode -eq -1073740940) ("late-failure-retires-refusal-facts-original-failure-preserved-$mode")
        }
    }
} finally {
    Set-Item Function:Get-JstiDiagnosticIdentity -Value $parserIdentity
    Set-Item Function:New-JstiDiagnosticAdapter -Value $parserAdapter
    Set-Item Function:Invoke-JstiDiagnosticBootstrap -Value $parserBootstrap
    $workspace = $parserOldWorkspace; $systemRoot = $parserOldSystemRoot; $isolatedPath = $parserOldIsolatedPath
    [IO.Directory]::Delete($parserRoot, $true)
}

# The actual atomic publication owner refuses only expired new facts; legacy
# no-facts publication remains byte/behavior compatible. All files are owned.
$publicationRoot = Join-Path ([IO.Path]::GetTempPath()) ('jsti-parser-publication-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($publicationRoot)
$publicationNative = (Get-Item Function:Invoke-JstiNativeFailureDiagnostic).ScriptBlock
$publication = @{ Facts = $true; Called = 0; Value = $parserBaseline }
Set-Item Function:Invoke-JstiNativeFailureDiagnostic -Value {
    param($setup, $run, $executable, $hash, $deadline, $frequency)
    $publication.Called++
    $projection = ConvertTo-JstiDiagnosticProjection ($publication.Value | ConvertFrom-Json)
    if (-not $publication.Facts) { [void] $projection.debugger.Remove('refusalFacts') }
    return @{ status = 'invalid'; bootstrap = @{ cleanup = 'complete' }; diagnostic = $projection }
}.GetNewClosure()
try {
    foreach ($mode in @('fresh-facts', 'expired-facts', 'legacy-no-facts')) {
        $publication.Facts = $mode -cne 'legacy-no-facts'; $publication.Called = 0
        $path = Join-Path $publicationRoot 'owned-evidence.json'
        $original = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"architecture":"arm64","runs":[{"label":"ui-smoke-test","exitCode":3221226356}]}')
        [IO.File]::WriteAllBytes($path, $original)
        $frequency = [Diagnostics.Stopwatch]::Frequency
        # One-second original remaining makes the derived work cutoff already
        # expired without sleeping; fake late helper still supplies facts.
        $deadline = [Diagnostics.Stopwatch]::GetTimestamp() + $(if ($mode -ceq 'fresh-facts') { 30 } else { 1 }) * $frequency
        Update-JstiNativeFailureEvidence @{} $path 'C:\Owned\SpeakWindows.exe' ('0' * 64) $deadline $frequency
        Assert-That ($publication.Called -eq 1) 'publication-reached-fake-diagnostic-once'
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($mode -ceq 'expired-facts') {
            Assert-That ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($original)) 'expired-optional-replacement-preserves-original-bytes'
        } else {
            $value = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 16
            Assert-That ($value.runs[0].failureDiagnostic.status -ceq 'invalid' -and
                $value.runs[0].exitCode -eq 3221226356) 'fresh-and-legacy-publication-preserve-original-exit'
            if ($mode -ceq 'fresh-facts') {
                Assert-That ($value.runs[0].failureDiagnostic.diagnostic.debugger.refusalFacts.reason -ceq 'ready-marker-count') 'fresh-refusal-facts-published'
            }
        }
        Assert-That (@(Get-ChildItem -LiteralPath $publicationRoot).Count -eq 1) 'owned-publication-temp-cleaned'
    }
} finally {
    Set-Item Function:Invoke-JstiNativeFailureDiagnostic -Value $publicationNative
    [IO.Directory]::Delete($publicationRoot, $true)
}

Assert-That (-not ('JstiDiagnosticNative' -as [type])) 'pure-fakes-did-not-compile-or-load-native-type'
Write-Output 'Diagnostic bootstrap pure-fake checks passed.'
