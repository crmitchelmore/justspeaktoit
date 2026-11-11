// windows-condition-lock-diagnostic.swift
//
// Standalone, Foundation-only probe for a hypothesized Windows-only
// swift-corelibs-foundation defect (pinned swift-6.2.3-RELEASE
// Sources/Foundation/NSLock.swift): `NSConditionLock.unlock(withCondition:)`
// sets its internal owner sentinel to `INVALID_HANDLE_VALUE` (non-nil) on
// Windows, while both `lock()`/`lock(whenCondition:)` acquisition loops
// treat "owner sentinel != nil" as "still held" -- so a SECOND acquisition
// attempt on the SAME `NSConditionLock` instance, after a first
// `unlock(withCondition:)`, is forced onto the lock's internal
// `_cond.wait(until:)` path even though nothing else holds it. On Windows
// that path converts the wait deadline to a 32-bit `DWORD` millisecond
// value (`timeoutFrom(date:)`); `Date.distantFuture` (used internally by
// the no-argument `lock()`/`lock(whenCondition:)` overloads) converts to a
// value far outside `DWORD`'s range and traps.
//
// This script does NOT touch production code and proves nothing about the
// real crash on its own -- it only observes, on whatever platform/toolchain
// runs it, what each described reuse sequence actually does. A diagnostic
// mismatch (unbounded mode happens not to trap in this run) is reported
// factually as "did not trap here", never promoted to "the hypothesis is
// false" or "healthy"; a bounded-mode `false` return is reported as exactly
// that -- a bounded reacquire that did not succeed in time -- never
// reinterpreted as a pass/fail verdict either way.
//
// Usage: swift windows-condition-lock-diagnostic.swift <finite|unbounded>
// Exits 0 if the described sequence completed without trapping (the mode's
// result is still reported factually either way); unknown/missing
// arguments exit nonzero with a usage message on stderr and perform no
// lock operations at all.

import Foundation

private func emit(_ message: String) {
    let line = "[windows-condition-lock-diagnostic] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

private func usageAndExit() -> Never {
    emit("usage: swift windows-condition-lock-diagnostic.swift <finite|unbounded>")
    exit(2)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let mode = arguments.first else {
    usageAndExit()
}

switch mode {
case "finite":
    // Reuse sequence identical to the former test gate's `entered` lock,
    // but reacquired with an EXPLICIT short finite deadline (never
    // `Date.distantFuture`), so this path is never expected to overflow the
    // Windows DWORD conversion regardless of outcome.
    emit("finite: creating NSConditionLock(condition: 0)")
    let lock = NSConditionLock(condition: 0)
    emit("finite: first lock()")
    lock.lock()
    emit("finite: unlock(withCondition: 1)")
    lock.unlock(withCondition: 1)
    let deadline = Date().addingTimeInterval(0.25)
    emit("finite: second lock(before: now+0.25s) -- about to reacquire")
    let acquired = lock.lock(before: deadline)
    // Reporting the raw boolean is the entire point: `false` is a bounded
    // reacquire that did not succeed within 0.25s (itself consistent with
    // the hypothesized reuse-after-unlock defect, since a SRWLock-backed
    // lock with no other owner would normally reacquire immediately); it is
    // never printed or treated as a healthy/passing result.
    emit("finite: second lock(before:) returned acquired=\(acquired)")
    if acquired {
        lock.unlock()
    }
    emit("finite: completed without trapping")
    exit(0)

case "unbounded":
    // Identical reuse sequence, but the second acquisition uses the
    // no-argument `lock()`, which internally calls
    // `lock(before: Date.distantFuture)` -- the path hypothesized to trap
    // on Windows. If this process exits here instead of reaching the final
    // "returned" marker below, the ABSENCE of that marker (and a non-zero/
    // signal-terminated exit observed by the caller) IS the diagnostic
    // signal; this script performs no crash handling of its own.
    emit("unbounded: creating NSConditionLock(condition: 0)")
    let lock = NSConditionLock(condition: 0)
    emit("unbounded: first lock()")
    lock.lock()
    emit("unbounded: unlock(withCondition: 1)")
    lock.unlock(withCondition: 1)
    emit("unbounded: about to call second lock() (suspected trap site)")
    lock.lock()
    // Reaching this line means the suspected trap did NOT occur in this
    // run; reported factually, not as confirmation the hypothesis is false.
    emit("unbounded: second lock() returned (did not trap in this run)")
    lock.unlock()
    emit("unbounded: completed without trapping")
    exit(0)

default:
    usageAndExit()
}
