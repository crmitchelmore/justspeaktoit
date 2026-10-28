# Pure fakes ONLY. Dot-source returns before imports, Add-Type or verifier work.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'verify-windows-bundle.ps1') `
    -BundleDirectory '__jsti_bootstrap_fake__' -Workspace '__jsti_bootstrap_fake__' `
    -ExpectedCommit '__jsti_bootstrap_fake__'

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

Assert-That (-not ('JstiDiagnosticNative' -as [type])) 'pure-fakes-did-not-compile-or-load-native-type'
Write-Output 'Diagnostic bootstrap pure-fake checks passed.'
