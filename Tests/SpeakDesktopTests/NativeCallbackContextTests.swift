import Foundation
import XCTest
@testable import SpeakDesktop

final class NativeCallbackContextTests: XCTestCase {
    private final class Target {}

    func testRegistrationRetainsValueUntilUnregisterThenCallbacksAreNoOps() {
        weak var weakTarget: Target?
        let context: NativeCallbackContext<Target> = {
            let target = Target()
            weakTarget = target
            return NativeCallbackContext(target)
        }()
        let pointer = context.pointer
        XCTAssertNotNil(weakTarget, "the native registration keeps its target alive")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(pointer) === weakTarget)
        XCTAssertNil(NativeCallbackContext<Target>.resolve(nil))

        context.unregister()
        XCTAssertNil(weakTarget, "unregistering releases the target")
        XCTAssertNil(NativeCallbackContext<Target>.resolve(pointer), "a late callback finds nothing")
        context.unregister()
        context.release()
        context.release()
    }

    func testReleaseFreesTheBoxOnce() {
        weak var weakBox: NativeCallbackContext<Target>?
        do {
            let context = NativeCallbackContext(Target())
            weakBox = context
            context.release()
        }
        XCTAssertNil(weakBox, "release balances the native retain")
    }

    func testScopedContextLivesOnlyForTheSynchronousCall() {
        weak var weakTarget: Target?
        weak var weakBox: NativeCallbackContext<Target>?
        let resolved: Bool = {
            let target = Target()
            weakTarget = target
            return NativeCallbackContext.withScoped(target) { pointer in
                weakBox = Unmanaged<NativeCallbackContext<Target>>.fromOpaque(pointer).takeUnretainedValue()
                return NativeCallbackContext<Target>.resolve(pointer) === target
            }
        }()
        XCTAssertTrue(resolved)
        XCTAssertNil(weakTarget)
        XCTAssertNil(weakBox)
    }

    /// A C callback that resolves its context as a `NativeCallbackContext` must
    /// get `pointer`, never a raw `Unmanaged` object: that reads a different
    /// layout and crashed the Windows self-test (#1473). Scans the desktop
    /// hosts, which the portable run cannot execute.
    func testNativeCallbacksNeverReceiveARawUnmanagedContext() throws {
        let sources = try ["Sources/SpeakWindows", "Sources/SpeakWindowsPlatform", "Sources/SpeakLinux",
                           "Sources/SpeakLinuxPlatform"].flatMap(swiftSources)
        let declaration = try NSRegularExpression(pattern: #"^(?:(?:private|fileprivate) )?func (\w+)\("#)
        var callbacks = Set<String>()
        for (_, lines) in sources {
            var current: String?
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if let match = declaration.firstMatch(in: line, range: range),
                   let name = Range(match.range(at: 1), in: line) {
                    current = String(line[name])
                } else if line.hasPrefix("}") || (!line.hasPrefix(" ") && !line.isEmpty) {
                    current = nil
                }
                if let current, line.contains("NativeCallbackContext<"), line.contains(".resolve(") {
                    callbacks.insert(current)
                }
            }
        }
        XCTAssertTrue(callbacks.contains("captureAudio"), "The callback scan no longer finds captureAudio.")
        var violations: [String] = []
        for (file, lines) in sources {
            for (index, line) in lines.enumerated() where line.contains("Unmanaged.pass") {
                let call = lines[max(0, index - 3)...min(lines.count - 1, index + 3)].joined(separator: "\n")
                for name in callbacks where call.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                    violations.append("\(file):\(index + 1) passes Unmanaged to \(name)")
                }
            }
        }
        XCTAssertEqual(violations, [], "Hand these callbacks NativeCallbackContext.pointer or withScoped.")
    }

    private func swiftSources(_ relativePath: String) throws -> [(String, [String])] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(relativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("\(relativePath) is not available where these tests run; the source checkout runs them.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            return ("\(relativePath)/\(file.lastPathComponent)", text.components(separatedBy: "\n"))
        }
    }

    func testSlotReplacesDetachesAndRejectsRefusedRegistrations() {
        let attached = AttachLog()
        let slot = NativeCallbackSlot<Target> { attached.record($0) }
        let first = Target()
        let second = Target()
        let registration = slot.begin(first)
        XCTAssertNotNil(registration)
        let pointer = registration?.pointer
        let replacement = slot.begin(second)
        XCTAssertNil(NativeCallbackContext<Target>.resolve(pointer), "replacing detaches the previous registration")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(replacement?.pointer) === second)
        if let registration { XCTAssertTrue(slot.end(registration), "a stale registration is already detached") }
        XCTAssertEqual(attached.calls, [true, false, true])

        attached.refuse = true
        XCTAssertEqual(replacement.map { slot.end($0) }, false, "a refused detach keeps the registration")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(replacement?.pointer) === second)
        attached.refuse = false
        if let replacement { XCTAssertTrue(slot.end(replacement)) }
        XCTAssertNil(NativeCallbackContext<Target>.resolve(replacement?.pointer))
        attached.refuse = true
        XCTAssertNil(slot.begin(first), "a refused attach registers nothing")
    }
}

private final class AttachLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var refuse = false
    var calls: [Bool] { lock.withLock { recorded } }

    func record(_ context: UnsafeMutableRawPointer?) -> Bool {
        lock.withLock { recorded.append(context != nil) }
        return !refuse
    }
}
