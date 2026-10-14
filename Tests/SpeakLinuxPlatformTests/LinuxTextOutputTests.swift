import Foundation
import XCTest
import SpeakLinuxPlatform

final class LinuxTextOutputOptionsTests: XCTestCase {
    func testDefaultsPasteAndRestore() {
        let options = LinuxTextOutputOptions()
        XCTAssertEqual(options.method, .paste)
        XCTAssertTrue(options.restoreClipboard)
    }

    func testUnknownOrMissingKeysKeepDefaults() throws {
        let decoded = try JSONDecoder().decode(
            LinuxTextOutputOptions.self, from: Data(#"{"method":"telepathy"}"#.utf8)
        )
        XCTAssertEqual(decoded, LinuxTextOutputOptions())
        let empty = try JSONDecoder().decode(LinuxTextOutputOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, LinuxTextOutputOptions())
    }

    func testRoundTrip() throws {
        let options = LinuxTextOutputOptions(method: .clipboardOnly, restoreClipboard: false)
        let decoded = try JSONDecoder().decode(LinuxTextOutputOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
    }

    func testWaylandStatusRetainsButDoesNotPromiseTheX11RestorationPreference() throws {
        for restore in [false, true] {
            let options = LinuxTextOutputOptions(restoreClipboard: restore)
            let status = options.savedStatus(canRestoreClipboard: false)
            XCTAssertTrue(status.contains("focused at delivery"), status)
            XCTAssertTrue(status.contains("keeps the transcript on the clipboard"), status)
            XCTAssertTrue(status.contains("preference is retained"), status)
            XCTAssertFalse(status.contains("is restored"), status)
            let decoded = try JSONDecoder().decode(LinuxTextOutputOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.restoreClipboard, restore)
        }
        XCTAssertTrue(LinuxTextOutputOptions().savedStatus(canRestoreClipboard: true).contains("still owns"))
    }
}

final class LinuxOutputPlanTests: XCTestCase {
    private let x11 = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"])
    private let wayland = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0"])

    func testClipboardOnlyNeedsNoTarget() {
        let plan = LinuxOutputPlan.make(
            options: .init(method: .clipboardOnly), target: nil, session: wayland, portalAvailable: false
        )
        XCTAssertEqual(plan, .copy(reason: nil))
    }

    func testPasteWithoutTargetHasNoAutomaticOutput() {
        // Record in the app's own window: nothing to paste into.
        XCTAssertNil(LinuxOutputPlan.make(options: .init(), target: nil, session: x11, portalAvailable: true))
    }

    func testX11WindowPastesWithShiftForTerminals() {
        let editor = LinuxInsertionTarget(kind: .x11Window(42), windowClass: "gedit")
        let terminal = LinuxInsertionTarget(kind: .x11Window(7), windowClass: "Gnome-terminal")
        XCTAssertEqual(
            LinuxOutputPlan.make(options: .init(), target: editor, session: x11, portalAvailable: false),
            .x11Paste(window: 42, shift: false, restoreClipboard: true)
        )
        XCTAssertEqual(
            LinuxOutputPlan.make(
                options: .init(restoreClipboard: false), target: terminal, session: x11, portalAvailable: false
            ),
            .x11Paste(window: 7, shift: true, restoreClipboard: false)
        )
    }

    func testX11TargetInWaylandSessionOnlyCopies() {
        let target = LinuxInsertionTarget(kind: .x11Window(42))
        guard case .copy(let reason) = LinuxOutputPlan.make(
            options: .init(), target: target, session: wayland, portalAvailable: true
        ) else { return XCTFail("expected a copy") }
        XCTAssertNotNil(reason)
    }

    func testWaylandUsesThePortalOnlyWhenAvailable() {
        let target = LinuxInsertionTarget(kind: .focusedApplication)
        XCTAssertEqual(
            LinuxOutputPlan.make(options: .init(), target: target, session: wayland, portalAvailable: true),
            .portalPaste(shift: false)
        )
        guard case .copy(let reason)? = LinuxOutputPlan.make(
            options: .init(), target: target, session: wayland, portalAvailable: false
        ) else { return XCTFail("expected a copy") }
        XCTAssertNotNil(reason)
    }
}

/// Records every native effect in order.
final class RecordingNative: LinuxOutputNative, @unchecked Sendable {
    let lock = NSLock()
    var clipboard: String?
    var ownership: UInt64 = 0
    var clipboardReads = 0
    var readFails = false
    var restoreFails = false
    var log: [String] = []
    var focusStays = true
    var ownWindow = false
    var portalFails = false
    var sharedClipboard = true
    /// Simulates the user copying something during the restore delay.
    var copyDuringDelay: String?
    var duringDelay: (() -> Void)?

    func record(_ entry: String) { lock.withLock { log.append(entry) } }

    func readClipboard() throws -> String? {
        try lock.withLock {
            clipboardReads += 1
            if readFails { throw LinuxNativeError(message: "Synthetic clipboard read failure.") }
            return clipboard
        }
    }
    func writeClipboard(_ text: String) throws {
        lock.withLock {
            clipboard = text
            ownership += 1
            log.append("write:\(text)")
        }
    }
    func writeOwnedClipboard(_ text: String) throws -> UInt64 {
        lock.withLock {
            clipboard = text
            ownership += 1
            log.append("write:\(text)")
            return ownership
        }
    }
    func restoreClipboard(_ text: String, ownership expected: UInt64) throws -> Bool {
        try lock.withLock {
            if restoreFails { throw LinuxNativeError(message: "Synthetic clipboard restore failure.") }
            guard ownership == expected else { return false }
            clipboard = text
            ownership += 1
            log.append("write:\(text)")
            return true
        }
    }
    func x11Paste(window: UInt64, shift: Bool) throws -> Bool {
        record("x11:\(window):\(shift)")
        return focusStays
    }
    func prepareRemoteDesktop() throws -> Bool {
        record("portal-start")
        if portalFails { throw LinuxNativeError(message: "Permission was declined in the desktop dialog.") }
        return sharedClipboard
    }
    func remotePaste(text: String?, shift: Bool) throws {
        lock.withLock {
            if let text {
                clipboard = text
                ownership += 1
            }
            log.append("portal-paste:\(text ?? "<clipboard>"):\(shift)")
        }
    }
    func ownWindowFocused() -> Bool { ownWindow }
    func notify(title: String, body: String) { record("notify:\(title)") }
    func sleep(milliseconds: Int) {
        record("sleep")
        if let copy = copyDuringDelay {
            lock.withLock {
                clipboard = copy
                ownership += 1
            }
        }
        duringDelay?()
    }
}

final class LinuxOutputJobTests: XCTestCase {
    func testX11PasteRestoresThePreviousClipboard() {
        let native = RecordingNative()
        native.clipboard = "previous"
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.log, ["write:dictated", "x11:9:false", "sleep", "write:previous"])
        XCTAssertEqual(native.clipboard, "previous")
        XCTAssertTrue(status.contains("restored"), status)
    }

    func testRestoreNeverOverwritesANewerCopy() {
        let native = RecordingNative()
        native.clipboard = "previous"
        native.copyDuringDelay = "user copied this"
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        _ = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "user copied this")
        XCTAssertFalse(native.log.contains("write:previous"))
    }

    func testRestoreNeverOverwritesANewerIdenticalTextCopy() {
        let native = RecordingNative()
        native.clipboard = "previous"
        native.copyDuringDelay = "dictated"
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "dictated")
        XCTAssertFalse(native.log.contains("write:previous"))
        XCTAssertEqual(native.clipboardReads, 1)
        XCTAssertFalse(status.contains("was restored"), status)
    }

    func testCancellationDuringDelayDoesNotRestore() {
        let native = RecordingNative()
        native.clipboard = "previous"
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        native.duringDelay = { job.cancel() }
        _ = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "dictated")
        XCTAssertFalse(native.log.contains("write:previous"))
    }

    func testReadFailureStillPastesButExplicitlyReportsLostRestoration() {
        let native = RecordingNative()
        native.readFails = true
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.log, ["write:dictated", "x11:9:false"])
        XCTAssertTrue(status.contains("Synthetic clipboard read failure"), status)
    }

    func testRestoreFailureIsReportedWithoutClaimingSuccess() {
        let native = RecordingNative()
        native.clipboard = "previous"
        native.restoreFails = true
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "dictated")
        XCTAssertTrue(status.contains("Synthetic clipboard restore failure"), status)
        XCTAssertFalse(status.contains("was restored"), status)
    }

    func testDisabledRestorationDoesNotReadOrDelay() {
        let native = RecordingNative()
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: false), native: native)
        _ = job.perform("dictated")
        XCTAssertEqual(native.clipboardReads, 0)
        XCTAssertEqual(native.log, ["write:dictated", "x11:9:false"])
    }

    func testChangedFocusLeavesTheTranscriptOnTheClipboard() {
        let native = RecordingNative()
        native.clipboard = "previous"
        native.focusStays = false
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: true, restoreClipboard: true), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "dictated")
        XCTAssertTrue(status.contains("focused window changed"), status)
        XCTAssertTrue(native.log.contains("notify:Transcript copied"))
    }

    func testCancelledJobDoesNothing() {
        let native = RecordingNative()
        let job = LinuxOutputJob(plan: .x11Paste(window: 9, shift: false, restoreClipboard: true), native: native)
        job.cancel()
        _ = job.perform("dictated")
        XCTAssertTrue(native.log.isEmpty)
    }

    func testPortalPasteOffersTheSelectionThroughTheSession() {
        let native = RecordingNative()
        let job = LinuxOutputJob(plan: .portalPaste(shift: false), native: native)
        _ = job.perform("dictated")
        XCTAssertEqual(native.log, ["portal-start", "portal-paste:dictated:false"])
    }

    func testPortalRoutesNeverReadDelayOrRestoreRegardlessOfStoredPreference() throws {
        let session = LinuxDesktopSession(environment: [
            "XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0", "DISPLAY": ":0"
        ])
        XCTAssertFalse(session.canUseX11Injection)
        for restore in [false, true] {
            for shared in [false, true] {
                let options = LinuxTextOutputOptions(restoreClipboard: restore)
                let decoded = try JSONDecoder().decode(
                    LinuxTextOutputOptions.self, from: JSONEncoder().encode(options)
                )
                let plan = try XCTUnwrap(LinuxOutputPlan.make(
                    options: decoded, target: .init(kind: .focusedApplication),
                    session: session, portalAvailable: true
                ))
                XCTAssertEqual(plan, .portalPaste(shift: false))
                let native = RecordingNative()
                native.clipboard = "previous"
                native.sharedClipboard = shared
                let status = LinuxOutputJob(plan: plan, native: native).perform("dictated")
                XCTAssertEqual(native.clipboardReads, 0)
                XCTAssertEqual(native.clipboard, "dictated")
                XCTAssertFalse(native.log.contains("sleep"))
                XCTAssertFalse(native.log.contains("write:previous"))
                XCTAssertTrue(status.contains("stays on the clipboard"), status)
                XCTAssertEqual(decoded.restoreClipboard, restore)
            }
        }
    }

    func testPortalWithoutSharedClipboardUsesTheAppClipboard() {
        let native = RecordingNative()
        native.sharedClipboard = false
        let job = LinuxOutputJob(plan: .portalPaste(shift: false), native: native)
        _ = job.perform("dictated")
        XCTAssertEqual(native.log, ["portal-start", "write:dictated", "portal-paste:<clipboard>:false"])
    }

    func testDeclinedPortalFallsBackToCopy() {
        let native = RecordingNative()
        native.portalFails = true
        let job = LinuxOutputJob(plan: .portalPaste(shift: false), native: native)
        let status = job.perform("dictated")
        XCTAssertEqual(native.clipboard, "dictated")
        XCTAssertTrue(status.contains("Permission was declined"), status)
    }

    func testPortalNeverPastesIntoTheAppItself() {
        let native = RecordingNative()
        native.ownWindow = true
        let job = LinuxOutputJob(plan: .portalPaste(shift: false), native: native)
        _ = job.perform("dictated")
        XCTAssertFalse(native.log.contains("portal-start"))
        XCTAssertEqual(native.clipboard, "dictated")
    }
}

final class LinuxDesktopSessionTests: XCTestCase {
    func testSessionTypeWins() {
        let session = LinuxDesktopSession(environment: [
            "XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0",
            "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"
        ])
        XCTAssertEqual(session.displayServer, .wayland)
        XCTAssertTrue(session.isGNOME)
        XCTAssertFalse(session.canUseX11Injection)
    }

    func testDisplayWithoutSessionTypeIsX11() {
        let session = LinuxDesktopSession(environment: ["DISPLAY": ":99"])
        XCTAssertEqual(session.displayServer, .x11)
        XCTAssertTrue(session.canUseX11Injection)
    }

    func testWlrootsAdviceNamesTheToggleCommand() {
        let session = LinuxDesktopSession(environment: [
            "XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w", "XDG_CURRENT_DESKTOP": "sway"
        ])
        XCTAssertTrue(session.isWlroots)
        XCTAssertTrue(session.shortcutAdvice(command: "justspeaktoit").contains("justspeaktoit --toggle"))
    }

    func testFlatpakDetection() {
        XCTAssertTrue(LinuxDesktopSession(environment: ["FLATPAK_ID": "com.justspeaktoit.JustSpeakToIt"]).isFlatpak)
        XCTAssertFalse(LinuxDesktopSession(environment: [:]).isFlatpak)
    }

    func testDataDirectoryFollowsXDG() {
        XCTAssertEqual(
            LinuxFiles.dataDirectory(environment: ["XDG_DATA_HOME": "/data", "HOME": "/home/u"]).path,
            "/data/JustSpeakToIt"
        )
        XCTAssertEqual(
            LinuxFiles.dataDirectory(environment: ["HOME": "/home/u"]).path, "/home/u/.local/share/JustSpeakToIt"
        )
    }

    func testTerminalClasses() {
        XCTAssertTrue(LinuxTerminals.isTerminal(windowClass: "kitty"))
        XCTAssertTrue(LinuxTerminals.isTerminal(windowClass: "Konsole"))
        XCTAssertFalse(LinuxTerminals.isTerminal(windowClass: "firefox"))
    }
}

final class LinuxPrivateFilesTests: XCTestCase {
    func testPrivateFolderAndFileModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("a/b")
        try LinuxFiles.preparePrivateDirectory(folder)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        let file = folder.appendingPathComponent("body")
        try LinuxFiles.createPrivateFile(file)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertThrowsError(try LinuxFiles.createPrivateFile(file))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try LinuxFiles.preparePrivateDirectory(link))
    }
}
