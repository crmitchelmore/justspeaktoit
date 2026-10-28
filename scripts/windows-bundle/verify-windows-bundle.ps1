<#
.SYNOPSIS
Runs the Mac-built self-contained Windows bundle without any Swift installation.

.DESCRIPTION
Verifies the ZIP and every extracted file against the hashes recorded on the Mac,
isolates PATH to the Windows system directories, proves the runner cannot satisfy
the executable's runtime on its own (a copy without the bundled DLLs must fail to
start), then runs the production executable's self-test and native window smoke
test while sampling the process’s loaded module paths. Any module outside
%SystemRoot% and Microsoft's own Store packages (Media Foundation codec
extensions) must come from the bundle directory, and no bundled module may load
from anywhere else. Evidence is written even when a check fails, and
every failure is reported before the script exits non-zero. With
-LocalTranscriptionAudio it also transcribes that WAV on the CPU through the
bundled whisper.cpp runtime and requires its DLLs to load from the bundle.
Every run records the machine Windows reports for the process; an ARM64 bundle
must run as a native ARM64 process with no x64 emulation module loaded.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BundleDirectory,
    [Parameter(Mandatory = $true)] [string] $Workspace,
    [Parameter(Mandatory = $true)] [string] $ExpectedCommit,
    # Optional on-device check: a WAV the bundled whisper.cpp runtime must
    # transcribe, the phrase it must contain and a model cache folder.
    [string] $LocalTranscriptionAudio,
    [string] $LocalTranscriptionPhrase,
    [string] $LocalModelDirectory
)

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

function Get-JstiDiagnosticIdentity([string] $Path, [string[]] $Names) {
    if (-not [System.IO.Path]::IsPathFullyQualified($Path) -or
            [System.IO.Path]::GetFileName($Path).ToLowerInvariant() -cnotin $Names) { throw 'unavailable' }
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
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress))
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
    } finally { if ($null -ne $state) { $state.Output.Dispose() } }
    return $result
}

# Test-only import requires explicit inert mandatory arguments. Normal invocations
# execute the original verifier below unchanged; no environment switch is added.
if ($MyInvocation.InvocationName -eq '.' -and
        $BundleDirectory -ceq '__jsti_bootstrap_fake__' -and
        $Workspace -ceq '__jsti_bootstrap_fake__' -and
        $ExpectedCommit -ceq '__jsti_bootstrap_fake__') { return }

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BundleEnvironment.ps1')
. (Join-Path $PSScriptRoot 'BundleCLI.ps1')
$StatusDllNotFound = -1073741515  # NTSTATUS 0xC0000135 as a signed exit code
# Loaded only into emulated x64 or ARM64EC, and WOW64, processes.
$EmulationModules = @('xtajit.dll', 'xtajit64.dll', 'xtajit64se.dll', 'xtabase.dll', 'wow64.dll', 'wow64base.dll',
    'wow64con.dll', 'wow64cpu.dll', 'wow64win.dll', 'wowarmhw.dll')
# Named apart from the per-run $processMachine results: PowerShell variable names
# ignore case and functions see their caller's locals, so a shared name would
# hand Get-ProcessMachine the caller's $null instead of this type.
$MachineQuery = Add-Type -Namespace Jsti -Name ProcessMachine -PassThru -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetProcessInformation(System.IntPtr process, int informationClass, byte[] information, int size);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool IsWow64Process2(System.IntPtr process, out ushort processMachine, out ushort nativeMachine);
'@

# IMAGE_FILE_MACHINE value Windows reports for a process (ProcessMachineTypeInfo,
# Windows 11 and later), or $null when the query is unavailable.
function Get-ProcessMachine([System.Diagnostics.Process] $process) {
    $information = New-Object byte[] 8
    if (-not $script:MachineQuery::GetProcessInformation($process.Handle, 9, $information, 8)) { return $null }
    return [int][System.BitConverter]::ToUInt16($information, 0)
}

# Media Foundation can load codecs Microsoft ships as Store packages, such as
# Web Media Extensions, from %ProgramFiles%\WindowsApps. Only the package
# deployment service writes there, after checking the package signature, and
# 8wekyb3d8bbwe is Microsoft's publisher ID, so such a module is part of Windows
# rather than something the runner or a toolchain supplied.
$MicrosoftPackageRoot = Join-Path ([System.Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
function Test-MicrosoftPackageModule([string] $path) {
    if (-not $path.StartsWith("$MicrosoftPackageRoot\", [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $package = $path.Substring($MicrosoftPackageRoot.Length + 1).Split('\')[0]
    return $package -match '^Microsoft\.[A-Za-z0-9.]+_[0-9.]+_(x86|x64|arm|arm64|neutral)_[^_\\]*_8wekyb3d8bbwe$'
}

function Format-Machine($value) {
    if ($null -eq $value) { return $null }
    return '0x{0:X4}' -f [int]$value
}

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
$runnerProcessMachine = [uint16]0
$runnerNativeMachine = [uint16]0
[void] $MachineQuery::IsWow64Process2([System.Diagnostics.Process]::GetCurrentProcess().Handle,
    [ref] $runnerProcessMachine, [ref] $runnerNativeMachine)
$report = [ordered]@{
    schemaVersion = 1
    expectedCommit = $ExpectedCommit
    runner = [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        caption = (Get-CimInstance Win32_OperatingSystem).Caption
        architecture = $env:PROCESSOR_ARCHITECTURE
        nativeMachine = Format-Machine $runnerNativeMachine
    }
    bundleArchitecture = $null
    zip = $null
    isolation = $null
    negativeControl = $null
    resourceNegativeControl = $null
    runs = @()
    cliRuns = @()
    productionImages = $null
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
    # An ARM64 bundle proves native execution: its processes must be ARM64 on an ARM64 host.
    $report.bundleArchitecture = $manifest.bundle.architecture
    $expectedMachine = $null
    if ($manifest.bundle.architecture -eq 'aarch64') {
        $expectedMachine = 0xAA64
        if ($runnerNativeMachine -ne $expectedMachine) {
            throw "An ARM64 bundle needs an ARM64 runner; this one reports $(Format-Machine $runnerNativeMachine)."
        }
    } elseif ($manifest.bundle.architecture -ne 'x86_64') {
        throw "Unexpected bundle architecture $($manifest.bundle.architecture)."
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
    $roots = @('SpeakWindows.exe', 'speak.exe')
    foreach ($record in @($manifest.application.executables, $evidence.application.executables)) {
        if (@($record.PSObject.Properties).Count -ne 2) { throw 'Production evidence must name both executable roots.' }
        foreach ($root in $roots) {
            if ((Get-Sha256 (Join-Path $bundle $root)) -ne $record.$root) {
                throw "Production executable hash differs from its build receipt: $root"
            }
        }
    }
    $imageEvidence = Join-Path $evidenceDirectory 'production-images.json'
    Remove-Item -LiteralPath $imageEvidence -Force -ErrorAction SilentlyContinue
    $architecture = if ($manifest.bundle.architecture -eq 'aarch64') { 'arm64' } else { 'x64' }
    # Reuse the canonical PE reader; this is an image receipt, not short-process module sampling.
    & python -B (Join-Path $PSScriptRoot 'verify-native-execution.py') --architecture $architecture `
        --evidence $imageEvidence images (Join-Path $bundle 'SpeakWindows.exe') (Join-Path $bundle 'speak.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Production PE architecture verification failed.' }
    $report.productionImages = (Get-Content -LiteralPath $imageEvidence -Raw | ConvertFrom-Json).images
    if (@($report.productionImages | Where-Object { $_.dll -or -not $_.native }).Count -or
        @($report.productionImages | Where-Object { $_.name -eq 'speak.exe' -and $_.subsystem -eq 3 }).Count -ne 1) {
        throw 'Production roots must be native executables and speak.exe must be a console executable.'
    }
    if ($architecture -eq 'x64' -and $runnerNativeMachine -ne 0x8664) {
        throw 'Native x64 CLI verification requires an x64 host, not an emulated x64 process.'
    }

    # Optional preparation happens before original-run deadline capture. No
    # diagnostic target/job/debugger starts on this path or on a passing run.
    $diagnosticSetup = $null
    if ($architecture -ceq 'arm64') {
        try {
            $currentHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $pythonHost = (Get-Command python -CommandType Application -ErrorAction Stop).Source
            $hostIdentity = Get-JstiDiagnosticIdentity $currentHost @('pwsh.exe', 'powershell.exe')
            $pythonIdentity = Get-JstiDiagnosticIdentity $pythonHost @('python.exe', 'python3.exe')
            if (Initialize-JstiDiagnosticNative) { $diagnosticSetup = @{ Host = $hostIdentity; Python = $pythonIdentity } }
        } catch { }
    }

    # --- 3. Isolate the environment ----------------------------------------------
    $systemRoot = $env:SystemRoot
    $isolatedPath = "$systemRoot\System32;$systemRoot;$systemRoot\System32\Wbem;$systemRoot\System32\WindowsPowerShell\v1.0"
    $env:Path = $isolatedPath
    Clear-BundleToolchainEnvironment
    if (Get-Command swift.exe -ErrorAction SilentlyContinue) { throw 'A Swift toolchain is reachable on the isolated PATH.' }
    $bundled = @{}
    foreach ($property in $manifest.dependencies.bundled.PSObject.Properties) { $bundled[$property.Name] = $property.Value }
    $guiStaticModules = @(Get-BundleStaticModules $manifest.dependencies 'SpeakWindows.exe')
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

    # Fast help/version need no app, devices or credentials. Do not require or claim sampled modules.
    foreach ($argument in @('--help', '--version')) {
        try {
            $cli = Invoke-BundleCLIReadOnly -Executable (Join-Path $bundle 'speak.exe') -Argument $argument `
                -WorkingDirectory $emptyWorkingDirectory -IsolatedPath $isolatedPath
            $cli.label = 'cli-' + $argument.TrimStart('-')
            $cli.executableSHA256 = Get-Sha256 (Join-Path $bundle 'speak.exe')
            $report.cliRuns += $cli
            if (-not $cli.passed) { throw "speak.exe $argument failed: $($cli.failures -join '; ')" }
        } catch { $failures.Add($_.Exception.Message) }
    }

    # --- 5. Run the bundled GUI production executable and record loaded modules -------
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
        # Diagnostic-only QPC boundary; original stopwatch/timer stays unchanged.
        $diagnosticFrequency = [System.Diagnostics.Stopwatch]::Frequency
        $diagnosticDeadline = [System.Diagnostics.Stopwatch]::GetTimestamp() + ([long] $seconds * $diagnosticFrequency)
        $diagnosticStartedUTC = [datetime]::UtcNow
        $process = Start-Process @parameters
        $loaded = @{}
        $processMachine = $null
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            try {
                if ($null -eq $processMachine) { $processMachine = Get-ProcessMachine $process }
                $process.Refresh()
                foreach ($module in $process.Modules) { $loaded[$module.FileName.ToLowerInvariant()] = $module.FileName }
                $allStaticObserved = $true
                foreach ($name in $guiStaticModules) {
                    $expectedPath = (Join-Path $bundle $name).ToLowerInvariant()
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
        # The process object outlives the process, so a run too short to sample is still answered.
        if ($null -eq $processMachine) { $processMachine = Get-ProcessMachine $process }
        # Write-Host keeps the log text out of this function's return value.
        Get-Content -LiteralPath (Join-Path $evidenceDirectory "bundle-$label.log") | ForEach-Object { Write-Host $_ }
        Get-Content -LiteralPath (Join-Path $evidenceDirectory "bundle-$label-errors.log") | ForEach-Object { Write-Host $_ }
        $fromBundle = @(); $fromSystem = @(); $fromPackages = @(); $foreign = @()
        foreach ($path in ($loaded.Values | Sort-Object)) {
            if ($path.StartsWith("$bundle\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $path.Substring($bundle.Length + 1).Replace('\', '/')
                if (-not $expected.ContainsKey($relative.ToLowerInvariant())) { $foreign += $path } else { $fromBundle += $relative }
            } elseif ($path.StartsWith("$systemRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $fromSystem += $path
            } elseif (Test-MicrosoftPackageModule $path) {
                $fromPackages += $path
            } else {
                $foreign += $path
            }
        }
        $missing = @()
        foreach ($entry in $bundled.Values) {
            $static = $guiStaticModules -contains $entry.name
            $observed = @($fromBundle | Where-Object { $_ -ieq $entry.name }).Count -gt 0
            if ($static -and -not $observed) { $missing += $entry.name }
            foreach ($path in $fromSystem + $fromPackages + $foreign) {
                if ([System.IO.Path]::GetFileName($path) -ieq $entry.name) { $foreign += "$path (bundled module loaded from outside the bundle)" }
            }
        }
        $emulation = @($fromSystem + $fromPackages + $foreign | Where-Object {
            $EmulationModules -contains [System.IO.Path]::GetFileName($_).ToLowerInvariant() })
        $run = [ordered]@{
            label = $label
            arguments = $arguments
            exitCode = $process.ExitCode
            processMachine = Format-Machine $processMachine
            emulationModules = $emulation
            modulesFromBundle = $fromBundle
            modulesFromSystemRoot = $fromSystem
            modulesFromMicrosoftPackages = $fromPackages
            modulesFromElsewhere = $foreign
            staticallyImportedModulesNotObserved = $missing
        }
        $script:report.runs += $run
        # At most one optional attempt after the frozen original natural failure.
        # Timeout throws above and cannot reach this hook. Original verdict follows.
        if ($architecture -ceq 'arm64' -and $label -ceq 'ui-smoke' -and $arguments -ceq '--ui-smoke-test' -and
                ([long] $process.ExitCode -band 0xffffffffL) -in @(0xC0000005L, 0xC0000374L, 0xC0000409L)) {
            try {
                $image = @($report.productionImages | Where-Object { $_.name -ceq 'SpeakWindows.exe' })
                if ($image.Count -eq 1) {
                    $run.failureDiagnostic = Invoke-JstiStandaloneDiagnostic $diagnosticSetup $run $process `
                        (Join-Path $bundle 'SpeakWindows.exe') $image[0].sha256 $diagnosticDeadline `
                        $diagnosticFrequency $diagnosticStartedUTC ([datetime]::UtcNow)
                }
            } catch { $run.failureDiagnostic = @{ status = 'unavailable'; originalFailurePreserved = $true } }
        }
        if ($process.ExitCode -ne 0) { throw "$label failed with exit code $($process.ExitCode)." }
        if ($fromBundle.Count -lt 2) { throw "$label module evidence was not captured." }
        if ($foreign.Count) { throw "$label loaded modules from outside the bundle and Windows: $($foreign -join '; ')" }
        if ($missing.Count) { throw "$label did not load bundled modules from the bundle: $($missing -join ', ')" }
        if ($null -ne $expectedMachine) {
            if ($processMachine -ne $expectedMachine) {
                $observed = if ($null -eq $processMachine) { 'unknown' } else { Format-Machine $processMachine }
                throw "$label ran as machine $observed, not native $(Format-Machine $expectedMachine)."
            }
            if ($emulation.Count) { throw "$label loaded emulation modules: $($emulation -join '; ')" }
        }
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
    if ($LocalTranscriptionAudio) {
        try {
            # The runtime is loaded at run time, so the static-import check above
            # cannot see it: require whisper.dll, ggml and a CPU backend from the bundle.
            Remove-Item Env:JSTI_WHISPER_RUNTIME_DIRECTORY -ErrorAction SilentlyContinue
            $env:JSTI_LOCAL_MODEL_DIRECTORY = $LocalModelDirectory
            $env:JSTI_WHISPER_CPU_ONLY = '1'
            $audio = (Resolve-Path -LiteralPath $LocalTranscriptionAudio).Path
            $run = Invoke-Bundled "--local-transcription-self-test `"$audio`" --expect `"$LocalTranscriptionPhrase`"" 'local-transcription' 300
            if (-not (Select-String -LiteralPath (Join-Path $evidenceDirectory 'bundle-local-transcription.log') -Pattern 'Local transcription self-test passed' -Quiet)) {
                throw 'Bundled on-device transcription success marker missing.'
            }
            $runtimeModules = @('whisper.dll', 'ggml.dll', 'ggml-base.dll')
            $absent = @($runtimeModules | Where-Object { $name = $_; -not @($run.modulesFromBundle | Where-Object { $_ -ieq $name }).Count })
            # x64 ships ggml-cpu-<variant>.dll; ARM64 ships a single ggml-cpu.dll.
            if (-not @($run.modulesFromBundle | Where-Object { $_ -like 'ggml-cpu*.dll' }).Count) { $absent += 'a ggml-cpu backend' }
            if ($absent.Count) { throw "On-device transcription did not load $($absent -join ', ') from the bundle." }
            Write-Host "On-device transcription loaded $($run.modulesFromBundle.Count) modules from the bundle."
        } catch { $failures.Add($_.Exception.Message) }
    }
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
