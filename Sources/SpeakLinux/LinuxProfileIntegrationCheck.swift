import Foundation
import SpeakCore
import SpeakDesktopHost
import SpeakLinuxPlatform

/// Actual X11 identity and canonical matching, driven by two owned windows in
/// linux-profile-identity-checks.py. No controller, settings, audio or provider.
enum LinuxProfileIntegrationCheck {
    private struct Fixture: Decodable {
        let version: Int
        let display: String
        let signalDirectory: String
        let targets: [Target]
    }

    private struct Target: Decodable {
        let window: UInt64
        let processID: Int32
        let executable: String
    }

    static func run() throws {
        let path = try LinuxIntegrationChecks.environment("JSTI_PROFILE_TEST_FIXTURE")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try LinuxIntegrationChecks.require(
            fixture.version == 1 && fixture.targets.count == 2
                && fixture.display == ProcessInfo.processInfo.environment["DISPLAY"], "invalid profile fixture"
        )
        let targets = fixture.targets
        try LinuxIntegrationChecks.require(
            targets[0].window != targets[1].window && targets[0].processID != targets[1].processID
                && targets[0].executable != targets[1].executable
                && targets.allSatisfy {
                    $0.window > 0 && $0.processID > 0
                        && DictationProfileMatcher.isFullLinuxExecutablePath($0.executable)
                }, "profile fixture must own two distinct executable identities"
        )
        let signals = URL(fileURLWithPath: fixture.signalDirectory, isDirectory: true)
        try Data().write(to: signals.appendingPathComponent("ready"), options: .withoutOverwriting)
        var first: LinuxInsertionTarget?
        for (phase, index) in [0, 1, 0].enumerated() {
            try waitFor(signals.appendingPathComponent("phase-\(phase)"))
            let target = try capture(targets[index])
            try checkMatching(target, paths: targets.map(\.executable), selected: index)
            if phase == 0 { first = target }
            if let first, phase > 0 {
                try LinuxIntegrationChecks.require(
                    try LinuxX11.targetIsFront(first) == (phase == 2),
                    "the earlier target did not become stale and recover with actual focus"
                )
                try LinuxIntegrationChecks.require(
                    first.executablePath == targets[0].executable, "switching changed the captured identity"
                )
            }
            try Data().write(to: signals.appendingPathComponent("ack-\(phase)"), options: .withoutOverwriting)
            print("X11 profiles phase \(phase): actual window/PID/executable, exact matching and order passed.")
        }
        print("X11 profiles: A-B-A identities, foreign matcher exclusion, case sensitivity, "
            + "priority and stale target passed.")
    }

    private static func capture(_ expected: Target) throws -> LinuxInsertionTarget {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let target = try LinuxX11.captureTargetChecked(), target.kind == .x11Window(expected.window) {
                try LinuxIntegrationChecks.require(
                    target.processID == expected.processID && target.executablePath == expected.executable
                        && target.processIdentity != nil, "the actual /proc identity did not match the owned window"
                )
                return target
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw DesktopHostError(message: "Integration check: the owned profile target never became active.")
    }

    private static func waitFor(_ file: URL) throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard ContinuousClock.now < deadline else {
                throw DesktopHostError(message: "Integration check: profile phase was not signalled.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func checkMatching(_ target: LinuxInsertionTarget, paths: [String], selected: Int) throws {
        let foreign = DictationProfile(name: "Foreign only", matchers: [
            .bundleID(paths[selected]), .windowsExecutablePath(paths[selected])
        ])
        let first = DictationProfile(name: "First A", matchers: [.init(kind: .linuxExecutablePath, value: paths[0])])
        let second = DictationProfile(name: "Second A", matchers: [.init(kind: .linuxExecutablePath, value: paths[0])])
        let other = DictationProfile(name: "B", matchers: [.init(kind: .linuxExecutablePath, value: paths[1])])
        func match(_ profiles: [DictationProfile], _ path: String?) -> UUID? {
            LinuxHostPlatform.matchProfile(profiles, executablePath: path)?.id
        }
        let ordered = [foreign, first, second, other]
        try LinuxIntegrationChecks.require(
            match(ordered, target.executablePath) == (selected == 0 ? first.id : other.id),
            "the current executable did not select its first matching Linux profile"
        )
        try LinuxIntegrationChecks.require(
            match([foreign, second, first, other], target.executablePath) == (selected == 0 ? second.id : other.id),
            "reordering matching profiles did not preserve user priority"
        )
        let basename = URL(fileURLWithPath: paths[selected]).lastPathComponent
        let differentCase = URL(fileURLWithPath: paths[selected]).deletingLastPathComponent()
            .appendingPathComponent(basename.lowercased()).path
        try LinuxIntegrationChecks.require(
            differentCase != paths[selected] && match(ordered, differentCase) == nil
                && match(ordered, basename) == nil && match(ordered, target.windowClass) == nil
                && match(ordered, nil) == nil && match([foreign], target.executablePath) == nil,
            "a case variant, basename, WM_CLASS or foreign matcher substituted for the exact executable"
        )
    }
}
