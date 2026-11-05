# Definitions only. Importing this file starts no native code or process.
# Private control flow for optional diagnostics; adapters are explicit and owned. Adapter operations must use the SAME QPC tick basis,
# respect the supplied absolute deadlines, and return only owned handles. A
# Resource-creation exceptions must clean up handles not returned to this owner.
function Invoke-JstiDiagnosticBootstrap {
    param([hashtable] $Adapter, $Request, [long] $DeadlineTicks, [long] $Frequency)
    $receipt = [ordered]@{ status = 'skipped'; streamBytes = 0; resumed = $false; cleanup = 'notStarted' }
    $job = $null; $child = $null; $pipes = $null; $assigned = $false
    $cleanupOK = $true
    $acquiring = $false
    $closedEarly = [System.Collections.Generic.HashSet[object]]::new()
    try {
        foreach ($operation in @('Now', 'CreateJob', 'CreatePipes', 'CreateSuspended', 'Assign', 'Resume',
                'ReadChunk', 'TerminateJob', 'TerminateProcess', 'Wait', 'JobEmpty', 'Close')) {
            if ($Adapter[$operation] -isnot [scriptblock]) { return $receipt }
        }
        # Reject invalid/future-unbounded arithmetic before acquiring resources.
        if ($Frequency -le 0 -or $Frequency -gt 1000000000) { return $receipt }
        $now = [long] (& $Adapter.Now)
        if ($now -lt 0 -or $now -gt ([long]::MaxValue - (30 * $Frequency)) -or $DeadlineTicks -le $now -or
                ($DeadlineTicks - $now) -gt (30 * $Frequency)) { return $receipt }
        $cleanupReserve = 2 * $Frequency
        if (($DeadlineTicks - $now) -lt (7 * $Frequency)) { return $receipt }
        $runDeadline = $DeadlineTicks - $cleanupReserve
        $receipt.status = 'failed'
        # Adapter must enforce kill-on-last-close and NONINHERITANCE on this job.
        $acquiring = $true
        $job = & $Adapter.CreateJob $true $false
        if ($null -eq $job) { throw 'unavailable' }
        $acquiring = $false
        $receipt.cleanup = 'incomplete'
        $acquiring = $true
        $pipes = & $Adapter.CreatePipes
        if ($null -eq $pipes) { throw 'unavailable' }
        $handles = @($pipes.StdinRead, $pipes.StdinWrite, $pipes.StdoutRead, $pipes.StdoutWrite, $pipes.StderrRead, $pipes.StderrWrite)
        $identities = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($handle in $handles) { if ($null -ne $handle) { [void] $identities.Add($handle) } }
        if (@($handles | Where-Object { $null -eq $_ }).Count -ne 0 -or
                $identities.Count -ne 6 -or $identities.Contains($job)) {
            throw 'unavailable'
        }
        $acquiring = $false
        if ([long] (& $Adapter.Now) -ge $runDeadline) { $receipt.status = 'deadline'; return $receipt }
        # Explicit allowlist: stdin pipe reader and output writers ONLY.
        $inherited = @($pipes.StdinRead, $pipes.StdoutWrite, $pipes.StderrWrite)
        $acquiring = $true
        $child = & $Adapter.CreateSuspended $Request $inherited $job $pipes $DeadlineTicks $Frequency
        if ($null -eq $child -or $null -eq $child.Process -or $null -eq $child.Thread) { throw 'unavailable' }
        $acquiring = $false
        # Native CreateSuspended atomically applies JOB_LIST; Assign verifies it.
        $assignment = & $Adapter.Assign $job $child.Process
        if ($assignment -isnot [bool]) { throw 'unavailable' }
        $assigned = $assignment
        if (-not $assigned) { throw 'unavailable' }
        if ([long] (& $Adapter.Now) -ge $runDeadline) { $receipt.status = 'deadline'; return $receipt }
        # EOF stdin and no parent-held output writers before first instruction.
        # Track wrapper identity, never a recycled raw HANDLE value.
        foreach ($writer in @($pipes.StdinWrite, $pipes.StdoutWrite, $pipes.StderrWrite)) {
            if (-not (& $Adapter.Close $writer)) { throw 'unavailable' }
            [void] $closedEarly.Add($writer)
        }
        if ([long] (& $Adapter.Now) -ge $runDeadline) { $receipt.status = 'deadline'; return $receipt }
        $resumed = & $Adapter.Resume $child.Thread
        if ($resumed -isnot [bool] -or -not $resumed) { throw 'unavailable' }
        $receipt.resumed = $true
        # One adapter read covers both nonblocking pipe readers, bounded by the
        # requested bytes and deadline. The prerequisite discards ALL raw bytes.
        for ($sample = 0; $sample -lt 4096; $sample++) {
            if ([long] (& $Adapter.Now) -ge $runDeadline) { $receipt.status = 'deadline'; return $receipt }
            $remaining = 65536 - $receipt.streamBytes
            if ($remaining -le 0) { $receipt.status = 'streamLimit'; return $receipt }
            $maximum = [Math]::Min(4096, $remaining)
            $chunk = & $Adapter.ReadChunk $child.Process @($pipes.StdoutRead, $pipes.StderrRead) $maximum $runDeadline
            if ($null -eq $chunk -or $chunk.Bytes -isnot [byte[]] -or $chunk.Bytes.Length -gt $maximum -or
                    $chunk.Exited -isnot [bool]) {
                throw 'unavailable'
            }
            $receipt.streamBytes += $chunk.Bytes.Length
            if ($chunk.Exited -ceq $true) { $receipt.status = 'finished'; return $receipt }
        }
        $receipt.status = 'sampleLimit'
    } catch {
        # No exception text, native values, request, stream, or handle identities.
        $receipt.status = 'failed'
    } finally {
        # A factory may have failed after acquiring an unreturned resource.
        # Clean all known ownership but never certify that unknown cleanup.
        if ($acquiring) { $cleanupOK = $false }
        if ($null -ne $job -and ($assigned -or $acquiring)) {
            try { if (-not (& $Adapter.TerminateJob $job)) { $cleanupOK = $false } }
            catch { $cleanupOK = $false }
        }
        if ($null -ne $child -and $null -ne $child.Process) {
            if (-not $assigned) {
                try { if (-not (& $Adapter.TerminateProcess $child.Process)) { $cleanupOK = $false } }
                catch { $cleanupOK = $false }
            }
            try { if (-not (& $Adapter.Wait $child.Process $DeadlineTicks)) { $cleanupOK = $false } }
            catch { $cleanupOK = $false }
        }
        if ($null -ne $job) {
            try { if (-not (& $Adapter.JobEmpty $job $DeadlineTicks)) { $cleanupOK = $false } }
            catch { $cleanupOK = $false }
        }
        $owned = @()
        if ($null -ne $child) { $owned += @($child.Thread, $child.Process) }
        if ($null -ne $pipes) { $owned += @($pipes.StdinRead, $pipes.StdinWrite, $pipes.StdoutRead, $pipes.StdoutWrite, $pipes.StderrRead, $pipes.StderrWrite) }
        if ($null -ne $job) { $owned += $job }
        $seen = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($handle in $owned) {
            if ($null -eq $handle -or -not $seen.Add($handle) -or $closedEarly.Contains($handle)) { continue }
            try { if (-not (& $Adapter.Close $handle)) { $cleanupOK = $false } }
            catch { $cleanupOK = $false }
        }
        if ($acquiring -or $null -ne $job -or $null -ne $child -or $null -ne $pipes) {
            $receipt.cleanup = if ($cleanupOK) { 'complete' } else { 'incomplete' }
        }
    }
    return $receipt
}

# Prepared before original-run deadline capture. Merely loading this type has no
# native side effects; actual Win32 calls occur only in the failure-only adapter.
function Initialize-JstiDiagnosticNative {
    try {
        if (-not ('JstiDiagnosticNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class JstiDiagnosticNative {
    // No static initializer or native call occurs while compiling/loading this type.
    public sealed class Owned : SafeHandleZeroOrMinusOneIsInvalid {
        static long next; readonly long identity; bool succeeded = true;
        public Owned(IntPtr value) : base(true) { identity = Interlocked.Increment(ref next); SetHandle(value); }
        protected override bool ReleaseHandle() { succeeded = CloseHandle(handle); return succeeded; }
        public bool CloseChecked() { Dispose(); return succeeded; }
        public IntPtr Raw { get { if (IsClosed || IsInvalid) throw new InvalidOperationException(); return DangerousGetHandle(); } }
        public override string ToString() { return "owned-" + identity; }
    }
    public sealed class Pipes { public Owned StdinRead, StdinWrite, StdoutRead, StdoutWrite, StderrRead, StderrWrite; }
    public sealed class Child { public Owned Process, Thread; }
    public sealed class Chunk { public byte[] Bytes, Stdout; public bool Exited; }
    [StructLayout(LayoutKind.Sequential)] struct SA { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential)] struct SI {
        public uint cb; public IntPtr reserved, desktop, title;
        public uint x,y,xSize,ySize,xChars,yChars,fill,flags; public ushort show, reserved2;
        public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct SIX { public SI Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public long ProcessTime, JobTime; public uint Flags; public UIntPtr Min, Max; public uint Active;
        public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public Limits Basic; public IO Counters; public UIntPtr a,b,c,d; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr sa, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetHandleInformation(IntPtr h, out uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr h, int info, ref Extended data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr h, int info, IntPtr data, uint size, IntPtr result);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SA sa, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSA, IntPtr threadSA, bool inherit, uint flags, IntPtr environment, string directory, ref SIX si, out PI pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr process, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool PeekNamedPipe(IntPtr pipe, IntPtr buffer, uint length, IntPtr read, out uint available, IntPtr left);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadFile(IntPtr pipe, byte[] bytes, uint length, out uint read, IntPtr overlapped);
    static void Require(bool value) { if (!value) throw new InvalidOperationException(); }
    public static Owned NewJob() {
        IntPtr raw=CreateJobObjectW(IntPtr.Zero,null); Owned job=null; bool transferred=false;
        try {
            Require(raw!=IntPtr.Zero); job=new Owned(raw); raw=IntPtr.Zero;
            Require(SetHandleInformation(job.Raw, 1, 0)); uint flags;
            Require(GetHandleInformation(job.Raw, out flags) && (flags & 1) == 0);
            // ONLY KILL_ON_JOB_CLOSE: no breakaway/silent-breakaway permission.
            Extended limits = new Extended(); limits.Basic.Flags = 0x2000;
            Require(SetInformationJobObject(job.Raw, 9, ref limits, (uint)Marshal.SizeOf<Extended>()));
            transferred=true; return job;
        } finally { if(!transferred) { if(job!=null) job.Dispose(); if(raw!=IntPtr.Zero) CloseHandle(raw); } }
    }
    static void Pipe(out Owned read, out Owned write, bool childReads) {
        SA sa=new SA { Length=Marshal.SizeOf<SA>(), Inherit=true }; IntPtr r=IntPtr.Zero,w=IntPtr.Zero;
        read=null; write=null; bool transferred=false;
        try {
            Require(CreatePipe(out r,out w,ref sa,0));
            read=new Owned(r); r=IntPtr.Zero;
            write=new Owned(w); w=IntPtr.Zero;
            Require(SetHandleInformation((childReads ? write : read).Raw,1,0)); transferred=true;
        } finally {
            if(!transferred) { if(read!=null) read.Dispose(); if(write!=null) write.Dispose();
                if(r!=IntPtr.Zero) CloseHandle(r); if(w!=IntPtr.Zero) CloseHandle(w); }
        }
    }
    public static Pipes NewPipes() {
        Pipes p = new Pipes();
        try { Pipe(out p.StdinRead,out p.StdinWrite,true); Pipe(out p.StdoutRead,out p.StdoutWrite,false); Pipe(out p.StderrRead,out p.StderrWrite,false); return p; }
        catch { foreach (Owned h in new[]{p.StdinRead,p.StdinWrite,p.StdoutRead,p.StdoutWrite,p.StderrRead,p.StderrWrite}) if(h!=null) h.Dispose(); throw; }
    }
    static string Quote(string value) {
        StringBuilder b=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) { if(c=='\\') {slashes++;continue;} if(c=='"') b.Append('\\',slashes*2+1); else b.Append('\\',slashes); b.Append(c); slashes=0; }
        b.Append('\\',slashes*2); return b.Append('"').ToString();
    }
    public static Child Start(string application, string[] arguments, string directory, string environment, Owned job, Pipes pipes, long deadline, long frequency) {
        IntPtr list=IntPtr.Zero, inherit=IntPtr.Zero, jobs=IntPtr.Zero, env=IntPtr.Zero; bool initialized=false, transferred=false; PI pi=new PI(); Owned processOwner=null, threadOwner=null;
        try {
            IntPtr size=IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref size);
            Require(size.ToInt64()>0 && size.ToInt64()<=4096); list=Marshal.AllocHGlobal(size);
            Require(InitializeProcThreadAttributeList(list,2,0,ref size)); initialized=true;
            Owned[] children={pipes.StdinRead,pipes.StdoutWrite,pipes.StderrWrite}; inherit=Marshal.AllocHGlobal(IntPtr.Size*3);
            for(int i=0;i<3;i++) { Require(!Object.ReferenceEquals(children[i],job)); Marshal.WriteIntPtr(inherit,i*IntPtr.Size,children[i].Raw); }
            jobs=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs,job.Raw);
            Require(UpdateProcThreadAttribute(list,0,new IntPtr(0x20002),inherit,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero));
            // Atomic job membership at creation: unsupported/nested-job failure has NO fallback.
            Require(UpdateProcThreadAttribute(list,0,new IntPtr(0x2000D),jobs,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero));
            SIX si=new SIX(); si.Startup.cb=(uint)Marshal.SizeOf<SIX>(); si.Startup.flags=0x100;
            si.Startup.stdin=pipes.StdinRead.Raw; si.Startup.stdout=pipes.StdoutWrite.Raw; si.Startup.stderr=pipes.StderrWrite.Raw; si.Attributes=list;
            StringBuilder command=new StringBuilder(Quote(application)); foreach(string arg in arguments) command.Append(' ').Append(Quote(arg));
            env=Marshal.StringToHGlobalUni(environment);
            Require(CreateProcessW(application,command,IntPtr.Zero,IntPtr.Zero,true,0x08080404,env,directory,ref si,out pi));
            // Each raw handle transfers ONCE; no raw finally-close may overlap a wrapper finalizer.
            processOwner=new Owned(pi.Process); pi.Process=IntPtr.Zero;
            threadOwner=new Owned(pi.Thread); pi.Thread=IntPtr.Zero;
            Child child=new Child { Process=processOwner, Thread=threadOwner }; transferred=true; return child;
        } finally {
            if(!transferred) {
                IntPtr ownedProcess=processOwner!=null ? processOwner.Raw : pi.Process;
                if(ownedProcess!=IntPtr.Zero) { TerminateProcess(ownedProcess,1); long ticks=deadline-System.Diagnostics.Stopwatch.GetTimestamp(); WaitForSingleObject(ownedProcess,(uint)Math.Max(0,Math.Min(2000,ticks*1000/frequency))); }
                if(processOwner!=null) processOwner.Dispose(); else if(pi.Process!=IntPtr.Zero) CloseHandle(pi.Process);
                if(threadOwner!=null) threadOwner.Dispose(); else if(pi.Thread!=IntPtr.Zero) CloseHandle(pi.Thread);
            }
            GC.KeepAlive(job); GC.KeepAlive(pipes);
            if(initialized) DeleteProcThreadAttributeList(list);
            foreach(IntPtr block in new[]{list,inherit,jobs,env}) if(block!=IntPtr.Zero) Marshal.FreeHGlobal(block);
        }
    }
    public static bool Verify(Owned job, Owned process) { bool inside; return IsProcessInJob(process.Raw,job.Raw,out inside) && inside; }
    public static bool Resume(Owned thread) { return ResumeThread(thread.Raw)==1; }
    public static bool StopJob(Owned job) { return TerminateJobObject(job.Raw,1); }
    public static bool StopProcess(Owned process) { return TerminateProcess(process.Raw,1); }
    public static bool Wait(Owned process,long deadline,long frequency) {
        long remaining=deadline-System.Diagnostics.Stopwatch.GetTimestamp(); uint ms=(uint)Math.Max(0,Math.Min(2000,remaining*1000/frequency));
        return WaitForSingleObject(process.Raw,ms)==0;
    }
    static uint Available(Owned pipe) {
        uint count; if(PeekNamedPipe(pipe.Raw,IntPtr.Zero,0,IntPtr.Zero,out count,IntPtr.Zero)) return count;
        if(Marshal.GetLastWin32Error()==109) return 0; throw new InvalidOperationException();
    }
    static byte[] Read(Owned pipe,int maximum) {
        uint length=Math.Min((uint)maximum,Available(pipe)); if(length==0) return new byte[0];
        byte[] bytes=new byte[length]; uint read; Require(ReadFile(pipe.Raw,bytes,length,out read,IntPtr.Zero));
        if(read!=length) Array.Resize(ref bytes,(int)read); return bytes;
    }
    public static Chunk ReadChunk(Owned process,Pipes pipes,int maximum,long deadline,long frequency) {
        byte[] output=Read(pipes.StdoutRead,maximum), error=Read(pipes.StderrRead,maximum-output.Length);
        byte[] combined=new byte[output.Length+error.Length]; output.CopyTo(combined,0);error.CopyTo(combined,output.Length);
        uint wait=WaitForSingleObject(process.Raw,0); Require(wait==0 || wait==258);
        bool drained=wait==0 && Available(pipes.StdoutRead)==0 && Available(pipes.StderrRead)==0;
        if(combined.Length==0 && !drained) { long ticks=deadline-System.Diagnostics.Stopwatch.GetTimestamp(); uint ms=(uint)Math.Max(0,Math.Min(5,ticks*1000/frequency)); if(ms>0) { uint poll=WaitForSingleObject(process.Raw,ms); Require(poll==0 || poll==258); } }
        return new Chunk { Bytes=combined, Stdout=output, Exited=drained };
    }
    public static bool Empty(Owned job,long deadline) {
        IntPtr buffer=Marshal.AllocHGlobal(48);
        try { do { Require(QueryInformationJobObject(job.Raw,1,buffer,48,IntPtr.Zero)); if(Marshal.ReadInt32(buffer,40)==0) return true;
                if(System.Diagnostics.Stopwatch.GetTimestamp()>=deadline) return false; Thread.Sleep(1); } while(true); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}

'@ -ErrorAction Stop
        }
        return $true
    } catch { return $false }
}

function New-JstiDiagnosticAdapter([long] $Frequency, [hashtable] $State) {
    return @{
        Now = { [System.Diagnostics.Stopwatch]::GetTimestamp() }
        CreateJob = { param($kill, $inherit)
            if ($kill -cne $true -or $inherit -cne $false) { throw 'unavailable' }
            [JstiDiagnosticNative]::NewJob()
        }
        CreatePipes = { $State.Pipes = [JstiDiagnosticNative]::NewPipes(); return $State.Pipes }.GetNewClosure()
        CreateSuspended = { param($request, $inherited, $job, $pipes, $deadline, $frequency)
            $expected = @($pipes.StdinRead, $pipes.StdoutWrite, $pipes.StderrWrite)
            if ($inherited.Count -ne 3) { throw 'unavailable' }
            for ($index = 0; $index -lt 3; $index++) {
                if (-not [object]::ReferenceEquals($inherited[$index], $expected[$index])) { throw 'unavailable' }
            }
            [JstiDiagnosticNative]::Start($request.Application, $request.Arguments, $request.Directory,
                $request.Environment, $job, $pipes, $deadline, $frequency)
        }
        Assign = { param($job, $process) [JstiDiagnosticNative]::Verify($job, $process) }
        Resume = { param($thread) [JstiDiagnosticNative]::Resume($thread) }
        ReadChunk = { param($process, $readers, $maximum, $deadline)
            $chunk = [JstiDiagnosticNative]::ReadChunk($process, $State.Pipes, $maximum, $deadline, $Frequency)
            if ($State.Output.Length + $chunk.Stdout.Length -gt 8192) { throw 'unavailable' }
            $State.Output.Write($chunk.Stdout, 0, $chunk.Stdout.Length)
            return $chunk
        }.GetNewClosure()
        TerminateJob = { param($job) [JstiDiagnosticNative]::StopJob($job) }
        TerminateProcess = { param($process) [JstiDiagnosticNative]::StopProcess($process) }
        Wait = { param($process, $deadline) [JstiDiagnosticNative]::Wait($process, $deadline, $Frequency) }.GetNewClosure()
        JobEmpty = { param($job, $deadline) [JstiDiagnosticNative]::Empty($job, $deadline) }
        Close = { param($handle) $handle.CloseChecked() }
    }
}

function Assert-JstiDiagnosticAncestors([string] $Path) {
    # Called only after normalized absolute Windows-drive admission. Inspect
    # every parent including the drive root, without following a reparse link.
    $parent = $Path.Substring(0, $Path.LastIndexOf('\'))
    for ($depth = 0; $depth -lt 64; $depth++) {
        if ($parent.Length -eq 2) { $parent += '\' }
        $item = Get-Item -LiteralPath $parent -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'unavailable'
        }
        if ($parent.Length -eq 3) { return }
        $parent = $parent.Substring(0, $parent.LastIndexOf('\'))
    }
    throw 'unavailable'
}

function Get-JstiDiagnosticIdentity([string] $Path, [string[]] $Names, [switch] $FrameworkPath) {
    $qualified = if ($FrameworkPath) {
        $Path.Length -le 4096 -and $Path -cmatch '^[A-Za-z]:\\' -and $Path.Substring(2).IndexOf(':') -lt 0 -and
            [System.IO.Path]::GetFullPath($Path) -ceq $Path
    } else { [System.IO.Path]::IsPathFullyQualified($Path) }
    if (-not $qualified -or
            [System.IO.Path]::GetFileName($Path).ToLowerInvariant() -cnotin $Names) { throw 'unavailable' }
    if ($FrameworkPath) { Assert-JstiDiagnosticAncestors $Path }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
            $item.Length -lt 256 -or $item.Length -gt 16777216) { throw 'unavailable' }
    $stream = $null; $hasher = $null; $reader = $null
    try {
        $stream = [System.IO.File]::Open($item.FullName, 'Open', 'Read', 'Read')
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $reader = [System.IO.BinaryReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'unavailable' }
        $stream.Position = 0x3C; $offset = $reader.ReadUInt32()
        if ($offset -gt 1048576 -or $offset + 24 -gt $stream.Length) { throw 'unavailable' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -notin @(0x8664, 0xAA64)) { throw 'unavailable' }
        $stream.Position = $offset + 22
        if ($reader.ReadUInt16() -band 0x2000) { throw 'unavailable' }
        $stream.Position = 0
        $hash = [System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        return @{ Path = $item.FullName; Hash = $hash }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $hasher) { $hasher.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# Strictly reproject: no request, arbitrary JSON string, raw stderr, path, timestamp,
# address or unknown field from the optional child enters the bundle receipt.
function ConvertTo-JstiDiagnosticProjection($Value) {
    $statuses = @('unavailable', 'deadline', 'observed', 'no-reproduction', 'invalid', 'truncated')
    $modules = @('app', 'ntdll', 'kernel32', 'kernelbase', 'ucrtbase', 'swiftCore', 'swift_Concurrency', 'swiftDispatch', 'unknown')
    if (($Value.schema -isnot [int] -and $Value.schema -isnot [long]) -or $Value.schema -ne 1 -or $Value.status -isnot [string] -or $Value.status -cnotin $statuses) { throw 'unavailable' }
    $safe = [ordered]@{ schema = 1; status = $Value.status }
    if ($Value.cleanup -is [string] -and $Value.cleanup -cin @('clean', 'failed', 'not-started')) { $safe.cleanup = $Value.cleanup }
    if ($null -ne $Value.applicationError) {
        $event = $Value.applicationError
        if ($event.status -isnot [string] -or
                $event.status -cnotin @('observed', 'no-match', 'ambiguous', 'timeout', 'unavailable', 'invalid')) { throw 'unavailable' }
        $safe.applicationError = [ordered]@{ status = $event.status }
        if ($event.status -ceq 'observed') {
            if ($event.module -isnot [string] -or $event.module -cnotin $modules -or
                    $event.version -isnot [string] -or $event.version -cnotmatch '^[0-9]{1,10}(\.[0-9]{1,10}){0,3}\z' -or
                    $event.exceptionCode -isnot [string] -or $event.exceptionCode -cnotmatch '^0x[0-9a-f]{8}\z' -or
                    $event.faultOffset -isnot [string] -or $event.faultOffset -cnotmatch '^0x[0-9a-f]{1,16}\z') { throw 'unavailable' }
            foreach ($name in @('module', 'version', 'exceptionCode', 'faultOffset')) { $safe.applicationError[$name] = $event.$name }
        }
    }
    if ($null -ne $Value.debugger) {
        $debugger = $Value.debugger
        if ($debugger.status -isnot [string] -or $debugger.status -cnotin $statuses) { throw 'unavailable' }
        $safe.debugger = [ordered]@{ status = $debugger.status }
        $debuggerNames = if ($debugger -is [System.Collections.IDictionary]) { @($debugger.Keys) } else { @($debugger.PSObject.Properties.Name) }
        if ($debuggerNames -contains 'preparationFacts') {
            if ($debuggerNames -cnotcontains 'preparationFacts' -or $debugger.status -cne 'unavailable' -or
                    $Value.status -cne 'unavailable' -or $null -ne $debugger.exceptionCode -or
                    @($debugger.frames).Count -ne 0 -or $debuggerNames -contains 'refusalFacts') { throw 'unavailable' }
            $facts = $debugger.preparationFacts
            $names = if ($facts -is [System.Collections.IDictionary]) { @($facts.Keys) } else { @($facts.PSObject.Properties.Name) }
            $phases = @('app-identity', 'host-identity', 'scratch-setup', 'event-query', 'event-project',
                'cdb-identity', 'identity-recheck', 'runtime-layout', 'runtime-source', 'runtime-copy',
                'runtime-recheck', 'cdb-runner', 'debugger-project')
            if ($names.Count -ne 2 -or $names -cnotcontains 'lastPhase' -or $names -cnotcontains 'errorCategory' -or
                    $facts.lastPhase -isnot [string] -or $facts.lastPhase -cnotin $phases -or
                    $facts.errorCategory -isnot [string] -or
                    $facts.errorCategory -cnotin @('validation', 'filesystem', 'unexpected', 'returned-unavailable')) { throw 'unavailable' }
            $early = $facts.lastPhase -cin @('app-identity', 'host-identity', 'scratch-setup')
            $cleanup = if ($early) { $Value.cleanup -ceq 'not-started' -and $Value.applicationError.status -ceq 'unavailable' }
                       else { $Value.cleanup -ceq 'clean' }
            if (-not $cleanup -or
                    ($facts.errorCategory -ceq 'returned-unavailable' -and
                    ($facts.lastPhase -cne 'cdb-runner' -or $Value.cleanup -cne 'clean'))) { throw 'unavailable' }
            $safe.debugger.preparationFacts = [ordered]@{ lastPhase = $facts.lastPhase; errorCategory = $facts.errorCategory }
        }
        if ($debuggerNames -contains 'refusalFacts') {
            if ($debuggerNames -cnotcontains 'refusalFacts' -or $debugger.status -cne 'invalid' -or
                    $Value.status -cne 'invalid' -or $Value.cleanup -cne 'clean' -or
                    $null -ne $debugger.exceptionCode -or @($debugger.frames).Count -ne 0) { throw 'unavailable' }
            $facts = $debugger.refusalFacts
            $factNames = if ($facts -is [System.Collections.IDictionary]) { @($facts.Keys) } else { @($facts.PSObject.Properties.Name) }
            $required = @('reason', 'completionClass', 'counts')
            if ($factNames.Count -ne 3 -and ($factNames.Count -ne 4 -or $factNames -cnotcontains 'processFacts')) { throw 'unavailable' }
            foreach ($name in $required) { if ($factNames -cnotcontains $name) { throw 'unavailable' } }
            $reasons = @('ready-marker-count', 'fault-boundary', 'fault-code-order', 'section-boundary',
                'ip-count', 'module-range', 'stack-row-order', 'stack-row-count', 'frame-range', 'frame-count')
            if ($facts.reason -isnot [string] -or $facts.reason -cnotin $reasons -or
                    $facts.completionClass -isnot [string] -or $facts.completionClass -cnotin @('zero', 'nonzero', 'unknown')) { throw 'unavailable' }
            $counts = $facts.counts
            $countNames = if ($counts -is [System.Collections.IDictionary]) { @($counts.Keys) } else { @($counts.PSObject.Properties.Name) }
            $requiredCounts = @('ready', 'fault', 'end', 'modules', 'stack', 'ip', 'moduleRanges', 'stackRows')
            if ($countNames.Count -ne 8) { throw 'unavailable' }
            $safeCounts = [ordered]@{}
            foreach ($name in $requiredCounts) {
                if ($countNames -cnotcontains $name -or
                        ($counts.$name -isnot [int] -and $counts.$name -isnot [long]) -or
                        $counts.$name -lt 0 -or $counts.$name -gt 17) { throw 'unavailable' }
                $safeCounts[$name] = $counts.$name
            }
            $safe.debugger.refusalFacts = [ordered]@{ reason = $facts.reason
                completionClass = $facts.completionClass; counts = $safeCounts }
            if ($factNames -ccontains 'processFacts') {
                $process = $facts.processFacts
                $processNames = if ($process -is [System.Collections.IDictionary]) { @($process.Keys) } else { @($process.PSObject.Properties.Name) }
                if ($processNames.Count -ne 2 -or $processNames -cnotcontains 'exitStatusClass' -or
                        $processNames -cnotcontains 'outputClass' -or $facts.reason -cne 'ready-marker-count' -or
                        $safeCounts.ready -ne 0 -or $process.exitStatusClass -isnot [string] -or
                        $process.exitStatusClass -cnotin @('zero', 'dllNotFoundStatus', 'invalidImageFormatStatus',
                            'entryPointNotFoundStatus', 'otherNonzero') -or
                        $process.outputClass -isnot [string] -or $process.outputClass -cnotin @('empty', 'nonempty')) { throw 'unavailable' }
                if ($process.outputClass -ceq 'empty') {
                    foreach ($name in $requiredCounts) {
                        if ($safeCounts[$name] -ne 0) { throw 'unavailable' }
                    }
                }
                $expectedCompletion = if ($process.exitStatusClass -ceq 'zero') { 'zero' } else { 'nonzero' }
                if ($facts.completionClass -cne $expectedCompletion) { throw 'unavailable' }
                $safe.debugger.refusalFacts.processFacts = [ordered]@{
                    exitStatusClass = $process.exitStatusClass; outputClass = $process.outputClass }
            }
        }
        if ($null -ne $debugger.exceptionCode) {
            if ($debugger.exceptionCode -isnot [string] -or
                    $debugger.exceptionCode -cnotin @('0xc0000005', '0xc0000374', '0xc0000409')) { throw 'unavailable' }
            $safe.debugger.exceptionCode = $debugger.exceptionCode
        }
        $frames = @($debugger.frames)
        if ($null -eq $debugger.frames) { $frames = @() }
        if ($frames.Count -gt 16) { throw 'unavailable' }
        $safe.debugger.frames = @()
        foreach ($frame in $frames) {
            if (($frame.index -isnot [int] -and $frame.index -isnot [long]) -or
                    $frame.index -ne $safe.debugger.frames.Count -or $frame.index -gt 15 -or
                    $frame.module -isnot [string] -or $frame.module -cnotin $modules) { throw 'unavailable' }
            $entry = [ordered]@{ index = $frame.index; module = $frame.module }
            if ($null -ne $frame.rva) {
                if ($frame.rva -isnot [string] -or $frame.rva -cnotmatch '^0x[0-9a-f]{1,16}\z') { throw 'unavailable' }
                $entry.rva = $frame.rva
            }
            $safe.debugger.frames += $entry
        }
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount(($safe | ConvertTo-Json -Depth 8 -Compress)) -gt 8192) { throw 'unavailable' }
    return $safe
}

function ConvertTo-JstiPackagedEventProjection($Value) {
    $names = @($Value.PSObject.Properties.Name)
    if ($names.Count -ne 4 -or @($names | Where-Object {
            $_ -cnotin @('schema', 'status', 'cleanup', 'applicationError') }).Count -ne 0) { throw 'unavailable' }
    if ($Value.cleanup -isnot [string] -or $Value.cleanup -cnotin @('clean', 'failed', 'not-started') -or
            $null -eq $Value.applicationError) { throw 'unavailable' }
    $eventNames = @($Value.applicationError.PSObject.Properties.Name)
    $expected = if ($Value.applicationError.status -ceq 'observed') {
        @('status', 'module', 'version', 'exceptionCode', 'faultOffset')
    } else { @('status') }
    if ($eventNames.Count -ne $expected.Count -or
            @($eventNames | Where-Object { $_ -cnotin $expected }).Count -ne 0) { throw 'unavailable' }
    $safe = ConvertTo-JstiDiagnosticProjection $Value
    if ($safe.status -ceq 'observed' -and
            ($safe.cleanup -cne 'clean' -or $safe.applicationError.status -cne 'observed')) { throw 'unavailable' }
    if ($safe.applicationError.status -ceq 'observed' -and
            ($safe.cleanup -cne 'clean' -or $safe.status -cne 'observed')) { throw 'unavailable' }
    return $safe
}

function New-JstiPackagedEventSetup([string] $Python) {
    try {
        $fixedHost = $env:SystemRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
        $currentHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($currentHost -ine $fixedHost) { return $null }
        $hostIdentity = Get-JstiDiagnosticIdentity $fixedHost @('powershell.exe') -FrameworkPath
        $pythonIdentity = Get-JstiDiagnosticIdentity $Python @('python.exe', 'python3.exe') -FrameworkPath
        if (Initialize-JstiDiagnosticNative) { return @{ Host = $hostIdentity; Python = $pythonIdentity } }
    } catch { }
    return $null
}

function Invoke-JstiPackagedEventDiagnostic($Setup, $Run, $Context, [string] $Executable,
        [string] $ExpectedSHA256, [string] $ExpectedPackageFullName,
        [scriptblock] $Timestamp = { [System.Diagnostics.Stopwatch]::GetTimestamp() }) {
    $result = [ordered]@{ status = 'unavailable'; originalFailurePreserved = $true }
    $state = $null; $private = $null; $bootstrap = $null
    try {
        if ($null -eq $Setup -or $Run.label -cne 'base-ui-smoke-test' -or
                $Run.arguments -cne '--ui-smoke-test' -or $Run.identityError -or
                [string]::IsNullOrWhiteSpace($ExpectedPackageFullName) -or
                $Run.packageFullName -cne $ExpectedPackageFullName -or $Run.modules.passed -isnot [bool] -or
                -not $Run.modules.passed -or
                $Run.exitCode -isnot [int] -or
                $Run.exitCode -notin @(-1073741819, -1073740940, -1073740791)) { return $result }
        $keys = @($Context.Keys)
        if ($keys.Count -ne 7 -or @($keys | Where-Object { $_ -cnotin @('originalPid', 'startedUTC', 'endedUTC',
                'startedTicks', 'endedTicks', 'originalDeadlineTicks', 'frequency') }).Count -ne 0) { return $result }
        $frequency = [System.Diagnostics.Stopwatch]::Frequency
        if ($Context.frequency -isnot [long] -or $Context.frequency -ne $frequency -or $frequency -gt 1000000000 -or
                $Context.originalPid -isnot [int] -or $Context.originalPid -le 0 -or
                $Context.startedTicks -isnot [long] -or $Context.endedTicks -isnot [long] -or
                $Context.originalDeadlineTicks -isnot [long] -or $Context.startedTicks -le 0 -or
                $Context.startedTicks -gt ([long]::MaxValue - 60 * $frequency) -or
                $Context.originalDeadlineTicks -ne ($Context.startedTicks + 60 * $frequency) -or
                $Context.endedTicks -lt $Context.startedTicks -or $Context.endedTicks -gt $Context.originalDeadlineTicks -or
                $Context.startedUTC -isnot [datetime] -or $Context.endedUTC -isnot [datetime] -or
                $Context.startedUTC.Kind -ne [DateTimeKind]::Utc -or $Context.endedUTC.Kind -ne [DateTimeKind]::Utc -or
                ($Context.endedUTC - $Context.startedUTC).TotalSeconds -lt 0 -or
                ($Context.endedUTC - $Context.startedUTC).TotalSeconds -gt 60 -or
                $ExpectedSHA256 -cnotmatch '^[0-9a-f]{64}\z' -or
                $Executable -cnotmatch '^[A-Za-z]:\\(?:[^\\]+\\)*SpeakWindows[.]exe\z') { return $result }
        $now = [long] (& $Timestamp)
        if ($now -lt $Context.endedTicks -or $now -gt ([long]::MaxValue - 10 * $frequency)) { return $result }
        $cutoff = [Math]::Min($Context.originalDeadlineTicks, $now + 10 * $frequency)
        if ($cutoff - $now -lt 9 * $frequency) { $result.status = 'deadline'; return $result }
        $fixedHost = $env:SystemRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
        if ($Setup.Host.Path -ine $fixedHost) { return $result }
        $hostNow = Get-JstiDiagnosticIdentity $Setup.Host.Path @('powershell.exe') -FrameworkPath
        $pythonNow = Get-JstiDiagnosticIdentity $Setup.Python.Path @('python.exe', 'python3.exe') -FrameworkPath
        if ($hostNow.Hash -cne $Setup.Host.Hash -or $pythonNow.Hash -cne $Setup.Python.Hash) { return $result }
        $request = [ordered]@{
            schema = 1; architecture = 'arm64'; label = 'base-ui-smoke-test'; exitCode = $Run.exitCode
            originalPid = $Context.originalPid; parentPid = $PID
            startedUTC = $Context.startedUTC.ToString('o'); endedUTC = $Context.endedUTC.ToString('o')
            executable = $Executable; expectedSHA256 = $ExpectedSHA256
            powershell = $Setup.Host.Path; powershellSHA256 = $Setup.Host.Hash
            startedTicks = $Context.startedTicks; endedTicks = $Context.endedTicks
            originalDeadlineTicks = $Context.originalDeadlineTicks; deadlineTicks = $cutoff - 2 * $frequency
            frequency = $frequency
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress))
        if ($bytes.Length -gt 8192) { return $result }
        $encoded = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $private = Join-Path $workspace ('packaged-event-' + [guid]::NewGuid().ToString('N'))
        [void] [System.IO.Directory]::CreateDirectory($private)
        $environment = [ordered]@{
            SystemRoot = $systemRoot; WINDIR = $systemRoot; PATH = $isolatedPath
            TEMP = $private; TMP = $private; USERPROFILE = $private; HOME = $private
            APPDATA = $private; LOCALAPPDATA = $private
            DOTNET_CLI_TELEMETRY_OPTOUT = '1'; POWERSHELL_TELEMETRY_OPTOUT = '1'
        }
        $block = ''
        foreach ($key in @($environment.Keys | Sort-Object)) { $block += "$key=$($environment[$key])" + [char]0 }
        $block += [char]0
        $launch = @{ Application = $Setup.Python.Path; Directory = $private; Environment = $block
            Arguments = [string[]] @('-I', '-B', (Join-Path $PSScriptRoot 'verify-native-execution.py'),
                'packaged-application-error', '--request', $encoded) }
        $state = @{ Output = [System.IO.MemoryStream]::new(); Pipes = $null }
        $adapter = New-JstiDiagnosticAdapter $frequency $state
        $bootstrap = Invoke-JstiDiagnosticBootstrap $adapter $launch $cutoff $frequency
        $result.bootstrap = $bootstrap
        if ($bootstrap.status -cne 'finished' -or $bootstrap.cleanup -cne 'complete') { return $result }
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        # PS5.1 supports this bounded response; no -Depth or System.Text.Json.
        $value = $utf8.GetString($state.Output.ToArray()) | ConvertFrom-Json -ErrorAction Stop
        $result.applicationErrorEvidence = ConvertTo-JstiPackagedEventProjection $value
        $result.status = if ($result.applicationErrorEvidence.cleanup -ceq 'failed') {
            'unavailable'
        } else { $result.applicationErrorEvidence.status }
    } catch { $result.status = 'unavailable' }
    finally {
        if ($null -ne $state) { try { $state.Output.Dispose() } catch { $result.status = 'unavailable' } }
        if ($private -and $null -ne $bootstrap -and $bootstrap.cleanup -ceq 'complete') {
            try { [System.IO.Directory]::Delete($private, $true) } catch { $result.status = 'unavailable' }
        }
        if ($result.status -ceq 'observed') {
            try { if ([long] (& $Timestamp) -ge $cutoff) { $result.status = 'deadline' } }
            catch { $result.status = 'unavailable' }
        }
        if ($result.status -cne 'observed' -and $result.Contains('applicationErrorEvidence') -and
                ($result.applicationErrorEvidence.status -ceq 'observed' -or
                 $result.applicationErrorEvidence.applicationError.status -ceq 'observed')) {
            [void] $result.Remove('applicationErrorEvidence')
        }
    }
    return $result
}

# Pure retirement boundary; clock acquisition stays with the owning caller.
function Remove-JstiStaleRefusalFacts($Result, [bool] $StreamsClosed, [long] $CurrentTicks, [long] $WorkCutoff) {
    if ($null -ne $Result.diagnostic -and $null -ne $Result.diagnostic.debugger) {
        if (-not $StreamsClosed -or $Result.bootstrap.cleanup -cne 'complete' -or
                $Result.diagnostic.cleanup -cne 'clean' -or $CurrentTicks -ge $WorkCutoff) {
            [void] $Result.diagnostic.debugger.Remove('refusalFacts')
        }
        $early = $Result.diagnostic.debugger.preparationFacts.lastPhase -cin @('app-identity', 'host-identity', 'scratch-setup')
        $cleanup = if ($early) { $Result.diagnostic.cleanup -ceq 'not-started' -and
            $Result.diagnostic.applicationError.status -ceq 'unavailable' } else { $Result.diagnostic.cleanup -ceq 'clean' }
        if (-not $StreamsClosed -or $Result.bootstrap.cleanup -cne 'complete' -or -not $cleanup -or
                $CurrentTicks -ge $WorkCutoff) {
            [void] $Result.diagnostic.debugger.Remove('preparationFacts')
        }
    }
}

# Internal request-only locator projection. No runtime path enters a receipt.
function ConvertTo-JstiDiagnosticRuntimeModules($Rows) {
    $rowsArray = @($Rows)
    if ($null -eq $Rows -or $rowsArray.Count -ne 14) { throw 'unavailable' }
    $safe = @(); $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $parent = $null; $total = 0L
    foreach ($row in $rowsArray) {
        $keys = if ($row -is [Collections.IDictionary]) { @($row.Keys) } else { @($row.PSObject.Properties.Name) }
        if ($keys.Count -ne 4 -or @($keys | Where-Object { $_ -cnotin @('name', 'path', 'bytes', 'sha256') }).Count -ne 0 -or
                $row.name -isnot [string] -or $row.name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*\.dll\z' -or
                -not $names.Add($row.name) -or $row.path -isnot [string] -or $row.path.Length -gt 4096 -or
                $row.path -cnotmatch '^[A-Za-z]:\\' -or $row.path -cmatch '[\x00-\x1f";/]' -or
                $row.path.Substring(2).Contains(':') -or $row.path -cmatch '(^|\\)\.{1,2}(\\|$)' -or
                $row.path.Split('\')[-1] -cne $row.name -or
                ($row.bytes -isnot [int] -and $row.bytes -isnot [long]) -or $row.bytes -le 0 -or $row.bytes -gt 67108864 -or
                $row.sha256 -isnot [string] -or $row.sha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'unavailable' }
        $currentParent = $row.path.Substring(0, $row.path.LastIndexOf('\'))
        if ($null -ne $parent -and $currentParent -ine $parent) { throw 'unavailable' }
        $parent = $currentParent; $total += $row.bytes
        if ($total -gt 67108864) { throw 'unavailable' }
        $safe += [ordered]@{ name = $row.name; path = $row.path; bytes = $row.bytes; sha256 = $row.sha256 }
    }
    return ,$safe
}

function Invoke-JstiStandaloneDiagnostic($Setup, $Run, $Process, [string] $Executable, [string] $ExpectedSHA256,
        [long] $DeadlineTicks, [long] $Frequency, [datetime] $StartedUTC, [datetime] $EndedUTC) {
    $result = [ordered]@{ status = 'unavailable'; originalFailurePreserved = $true }
    $state = $null
    try {
        if ($null -eq $Setup -or $Run.label -cne 'ui-smoke' -or $Run.arguments -cne '--ui-smoke-test' -or
                $Run.processMachine -cne '0xAA64' -or
                [uint32]([long] $Run.exitCode -band 0xffffffffL) -notin @(0xC0000005L, 0xC0000374L, 0xC0000409L)) { return $result }
        if ($DeadlineTicks - [System.Diagnostics.Stopwatch]::GetTimestamp() -lt 7 * $Frequency) {
            $result.status = 'deadline'; return $result
        }
        # Re-admit the captured absolute hosts, never search the isolated PATH.
        $hostNow = Get-JstiDiagnosticIdentity $Setup.Host.Path @('pwsh.exe', 'powershell.exe')
        $pythonNow = Get-JstiDiagnosticIdentity $Setup.Python.Path @('python.exe', 'python3.exe')
        if ($hostNow.Hash -cne $Setup.Host.Hash -or $pythonNow.Hash -cne $Setup.Python.Hash) { return $result }
        $request = [ordered]@{
            schema = 1; architecture = 'arm64'; label = 'ui-smoke'; arguments = @('--ui-smoke-test')
            exitCode = [int] $Run.exitCode; originalPid = $Process.Id
            startedUTC = $StartedUTC.ToUniversalTime().ToString('o'); endedUTC = $EndedUTC.ToUniversalTime().ToString('o')
            executable = $Executable; expectedSHA256 = $ExpectedSHA256
            powershell = $Setup.Host.Path; powershellSHA256 = $Setup.Host.Hash
            # Derived bridge work cutoff; Python reserves its own2s inside it.
            parentPid = $PID; deadlineTicks = $DeadlineTicks - (2 * $Frequency); frequency = $Frequency
        }
        $runKeys = if ($Run -is [Collections.IDictionary]) { @($Run.Keys) } else { @($Run.PSObject.Properties.Name) }
        if ($runKeys -contains 'runtimeModules') {
            if ($runKeys -cnotcontains 'runtimeModules') { return $result }
            $request.runtimeModules = ConvertTo-JstiDiagnosticRuntimeModules $Run.runtimeModules
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 4 -Compress))
        if ($bytes.Length -gt 8192) { return $result }
        $encoded = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $private = Join-Path $workspace ('failure-diagnostic-' + [guid]::NewGuid().ToString('N'))
        [void] [System.IO.Directory]::CreateDirectory($private)
        # No inherited debugger/provider/toolchain configuration or personal profile.
        $environment = [ordered]@{
            SystemRoot = $systemRoot; WINDIR = $systemRoot; PATH = $isolatedPath
            TEMP = $private; TMP = $private; USERPROFILE = $private
            APPDATA = $private; LOCALAPPDATA = $private
            DOTNET_CLI_TELEMETRY_OPTOUT = '1'; POWERSHELL_TELEMETRY_OPTOUT = '1'
        }
        $block = ''
        foreach ($key in @($environment.Keys | Sort-Object)) { $block += "$key=$($environment[$key])" + [char]0 }
        $block += [char]0
        $launch = @{
            Application = $Setup.Python.Path; Directory = $private; Environment = $block
            Arguments = [string[]] @('-I', '-B', (Join-Path $PSScriptRoot 'verify-native-execution.py'),
                'standalone-diagnostic', '--request', $encoded)
        }
        $state = @{ Output = [System.IO.MemoryStream]::new(); Pipes = $null }
        $adapter = New-JstiDiagnosticAdapter $Frequency $state
        $bootstrap = Invoke-JstiDiagnosticBootstrap $adapter $launch $DeadlineTicks $Frequency
        $result.bootstrap = $bootstrap
        if ($bootstrap.status -cne 'finished' -or $bootstrap.cleanup -cne 'complete') { return $result }
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $value = $utf8.GetString($state.Output.ToArray()) | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        $result.diagnostic = ConvertTo-JstiDiagnosticProjection $value
        $result.status = if ($result.diagnostic.cleanup -ceq 'failed') { 'unavailable' } else { $result.diagnostic.status }
    } catch {
        # Optional evidence cannot replace the original abnormal-exit throw.
        $result.status = 'unavailable'
    } finally {
        $streamsClosed = $false
        try {
            if ($null -ne $state) { $state.Output.Dispose() }
            $streamsClosed = $true
        } finally {
            # Retire only optional facts; original statuses/verdicts are untouched.
            try {
                Remove-JstiStaleRefusalFacts $result $streamsClosed ([System.Diagnostics.Stopwatch]::GetTimestamp()) ($DeadlineTicks - 2 * $Frequency)
            } catch {
                if ($null -ne $result.diagnostic -and $null -ne $result.diagnostic.debugger) {
                    [void] $result.diagnostic.debugger.Remove('refusalFacts')
                    [void] $result.diagnostic.debugger.Remove('preparationFacts')
                }
            }
        }
    }
    return $result
}

# Adapt only the exact native workflow's owned failure receipt. The original
# record, process verdict and shared deadline are never rewritten here.
function Invoke-JstiNativeFailureDiagnostic($Setup, $Run, [string] $Executable, [string] $ExpectedSHA256,
        [long] $DeadlineTicks, [long] $Frequency) {
    $unavailable = [ordered]@{ status = 'unavailable'; originalFailurePreserved = $true }
    try {
        if ($null -eq $Setup -or $null -eq $Run -or $Run.label -cne 'ui-smoke-test' -or
                @($Run.arguments).Count -ne 1 -or $Run.arguments[0] -cne '--ui-smoke-test' -or
                $Run.timedOut -isnot [bool] -or $Run.timedOut -or $Run.processMachine -cne 'arm64' -or
                $Run.nativeMachine -cne 'arm64' -or @($Run.failures).Count -eq 0 -or
                $Run.executable.architecture -cne 'arm64' -or $Run.executable.native -isnot [bool] -or
                -not $Run.executable.native -or $Run.executable.dll -isnot [bool] -or $Run.executable.dll -or
                $Run.executable.name -cne 'SpeakWindows.exe' -or
                $Run.executable.path -cne $Executable -or $ExpectedSHA256 -cnotmatch '^[0-9a-f]{64}\z' -or
                $Run.executable.sha256 -cne $ExpectedSHA256) { return $unavailable }
        if (($Run.exitCode -isnot [int] -and $Run.exitCode -isnot [long]) -or
                $Run.exitCode -lt -2147483648L -or $Run.exitCode -gt 4294967295L) { return $unavailable }
        $unsigned = [long] $Run.exitCode -band 0xffffffffL
        if ($unsigned -notin @(0xC0000005L, 0xC0000374L, 0xC0000409L)) { return $unavailable }
        $signed = [int] ($unsigned - 4294967296L)
        $context = $Run.diagnosticOwnerContext
        $keys = if ($context -is [System.Collections.IDictionary]) { @($context.Keys) }
                else { @($context.PSObject.Properties.Name) }
        $required = @('schema', 'originalPid', 'startedUTC', 'endedUTC', 'deadlineTicks', 'frequency', 'exitCode')
        if ($keys.Count -ne $required.Count -or
                @(Compare-Object $keys $required -CaseSensitive).Count -ne 0) { return $unavailable }
        foreach ($key in @('schema', 'originalPid', 'deadlineTicks', 'frequency', 'exitCode')) {
            if ($context.$key -isnot [int] -and $context.$key -isnot [long]) { return $unavailable }
        }
        if ($context.schema -ne 1 -or $context.originalPid -le 0 -or $context.originalPid -gt 4294967295L -or
                $context.exitCode -ne $signed -or $context.deadlineTicks -ne $DeadlineTicks -or
                $context.frequency -ne $Frequency -or $Frequency -le 0 -or $Frequency -gt 1000000000L -or
                $Frequency -ne [System.Diagnostics.Stopwatch]::Frequency) { return $unavailable }
        $moments = @()
        foreach ($key in @('startedUTC', 'endedUTC')) {
            $text = $context.$key
            if ($text -isnot [string] -or $text.Length -gt 40 -or
                    $text -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|\+00:00)\z') { return $unavailable }
            $moment = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref] $moment) -or
                    $moment.Offset -ne [timespan]::Zero) { return $unavailable }
            $moments += $moment
        }
        if (($moments[1] - $moments[0]).TotalSeconds -lt 0 -or
                ($moments[1] - $moments[0]).TotalSeconds -gt 30) { return $unavailable }
        $adapted = @{ label = 'ui-smoke'; arguments = '--ui-smoke-test'; exitCode = $signed; processMachine = '0xAA64' }
        $runtime = @()
        $nativeKeys = if ($Run -is [Collections.IDictionary]) { @($Run.Keys) } else { @($Run.PSObject.Properties.Name) }
        if ($nativeKeys -contains 'modulesOutsideSystemRoot') {
            if ($nativeKeys -cnotcontains 'modulesOutsideSystemRoot' -or $null -eq $Run.modulesOutsideSystemRoot) { return $unavailable }
            foreach ($module in @($Run.modulesOutsideSystemRoot)) {
                if ($null -eq $module) { return $unavailable }
                if ($module.path -ceq $Executable) { continue }
                if ($module.dll -isnot [bool] -or -not $module.dll -or $module.native -isnot [bool] -or
                        -not $module.native -or $module.architecture -cne 'arm64') { return $unavailable }
                $runtime += [ordered]@{ name = $module.name; path = $module.path; bytes = $module.bytes; sha256 = $module.sha256 }
            }
        }
        if ($runtime.Count -gt 0) { $adapted.runtimeModules = ConvertTo-JstiDiagnosticRuntimeModules $runtime }
        return Invoke-JstiStandaloneDiagnostic $Setup $adapted @{ Id = $context.originalPid } `
            $Executable $ExpectedSHA256 $DeadlineTicks $Frequency $moments[0].UtcDateTime $moments[1].UtcDateTime
    } catch { return $unavailable }
}
# Preserve JSON scalar types exactly; ConvertFrom-Json otherwise converts UTC
# strings to DateTime on supported PowerShell versions. No date inference here.
function ConvertFrom-JstiEvidenceElement($Element, [int] $Depth = 0) {
    if ($Depth -gt 24) { throw 'unavailable' }
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($value.Count -ge 256 -or $value.ContainsKey($property.Name)) { throw 'unavailable' }
                $value.Add($property.Name, (ConvertFrom-JstiEvidenceElement $property.Value ($Depth + 1)))
            }
            return $value
        }
        'Array' {
            $value = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                if ($value.Count -ge 1024) { throw 'unavailable' }
                $value.Add((ConvertFrom-JstiEvidenceElement $item ($Depth + 1)))
            }
            return ,($value.ToArray())
        }
        'String' { return $Element.GetString() }
        'Number' {
            $integer = [long] 0
            if ($Element.TryGetInt64([ref] $integer)) { return $integer }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'unavailable' }
    }
}

function Read-JstiNativeEvidence([string] $Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
            $item.Length -le 0 -or $item.Length -gt 1048576) { throw 'unavailable' }
    $stream = $null; $reader = $null
    try {
        $stream = [System.IO.File]::Open($item.FullName, 'Open', 'Read', 'Read')
        $reader = [System.IO.BinaryReader]::new($stream)
        $bytes = $reader.ReadBytes(1048577)
        if ($bytes.Length -ne $item.Length -or $bytes.Length -gt 1048576) { throw 'unavailable' }
        return ,$bytes
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

# Called by the existing workflow host after the original Python run returns.
# Optional evidence never changes its recorded failures or the caller's exit.
function Update-JstiNativeFailureEvidence($Setup, [string] $EvidencePath, [string] $Executable,
        [string] $ExpectedSHA256, [long] $DeadlineTicks, [long] $Frequency) {
    $document = $null; $temporary = $null
    try {
        if ($Frequency -le 0 -or $DeadlineTicks -le [System.Diagnostics.Stopwatch]::GetTimestamp()) { return }
        $bytes = Read-JstiNativeEvidence $EvidencePath
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $document = [System.Text.Json.JsonDocument]::Parse($utf8.GetString($bytes))
        $evidence = ConvertFrom-JstiEvidenceElement $document.RootElement
        if ($evidence.schemaVersion -ne 1 -or $evidence.architecture -cne 'arm64') { return }
        $runs = @($evidence.runs | Where-Object { $_.label -ceq 'ui-smoke-test' })
        if ($runs.Count -ne 1) { return }
        $run = $runs[0]
        $run['failureDiagnostic'] = Invoke-JstiNativeFailureDiagnostic $Setup $run $Executable `
            $ExpectedSHA256 $DeadlineTicks $Frequency
        $payload = $utf8.GetBytes(($evidence | ConvertTo-Json -Depth 32 -Compress))
        if ($payload.Length -gt 1048576) { return }
        $temporary = $EvidencePath + '.diagnostic-' + [guid]::NewGuid().ToString('N') + '.tmp'
        $output = [System.IO.File]::Open($temporary, 'CreateNew', 'Write', 'None')
        try { $output.Write($payload, 0, $payload.Length) } finally { $output.Dispose() }
        # Do not overwrite evidence changed by another owner while the optional
        # bridge was running. Both reads are capped and refuse reparse files.
        if ([Convert]::ToBase64String((Read-JstiNativeEvidence $EvidencePath)) -cne
                [Convert]::ToBase64String($bytes)) { return }
        # Last finite sample before atomic replacement: facts known expired
        # here are never published. Clock sampling and Move are not atomic.
        if (($null -ne $run.failureDiagnostic.diagnostic.debugger.refusalFacts -or
                $null -ne $run.failureDiagnostic.diagnostic.debugger.preparationFacts) -and
                [System.Diagnostics.Stopwatch]::GetTimestamp() -ge ($DeadlineTicks - 2 * $Frequency)) { return }
        [System.IO.File]::Move($temporary, $EvidencePath, $true)
        $temporary = $null
    } catch {
        # No original receipt or original nonzero result is replaced on failure.
    } finally {
        if ($null -ne $document) { $document.Dispose() }
        if ($null -ne $temporary) { try { [System.IO.File]::Delete($temporary) } catch { } }
    }
}
