import Foundation
import SpeakCore

/// Desktop (Windows and Linux) side of "System resources in use" (issue #1473):
/// the same holds and wording as the macOS card, as plain values a native
/// toolkit can draw without knowing about `SystemResourceRegistry`.
package enum DesktopSystemResources {
    /// Standing listeners stay up through Release everything: stopping the
    /// hotkey would leave the user with no way to dictate. Matches macOS.
    package static let releaseEverythingKinds: Set<SystemResourceKind> = Set(SystemResourceKind.allCases)
        .subtracting([.hotKey, .accessibility])

    package struct Row: Equatable, Sendable {
        /// The hold's id, which the release event sends back.
        package let id: String
        package let kind: SystemResourceKind
        package let title: String
        package let reason: String
        /// "Microphone · for 12 s · Deepgram Nova-3".
        package let caption: String
        /// nil when the hold has no release button.
        package let releaseTitle: String?
        package let releasing: Bool
    }

    package struct Presentation: Equatable, Sendable {
        package let headline: String
        /// Shown above the rows only when the OS reports an unclaimed microphone.
        package let warning: String?
        /// Shown when there are no rows.
        package let empty: String
        package let rows: [Row]
        /// One line about what the OS reports, below the rows.
        package let microphone: String
        package let canReleaseEverything: Bool
    }

    package static let warningTitle = "Microphone open, but no feature claims it"
    package static let releaseEverythingTitle = "Release everything"
    package static let releaseEverythingHint = "Stops recordings, playback and listening. The hotkey keeps working."

    package static func presentation(
        holds: [SystemResourceHold], microphone: MicrophoneUseAttribution, osName: String, now: Date = Date()
    ) -> Presentation {
        // Release everything reaches only registered holds, so it cannot stop an
        // unclaimed capture and is never offered for one.
        let warning = microphone.isUnattributed
            ? "\(osName) reports that Just Speak to It is recording, yet nothing in the app says it is. "
                + "The app cannot stop a capture it does not track: quit and reopen it, "
                + "and please report this so it can be fixed."
            : nil
        return Presentation(
            headline: microphone.isUnattributed
                ? "Microphone open, not claimed by any feature" : SystemResourceSummary.headline(for: holds),
            warning: warning,
            empty: "Just Speak to It is not holding the microphone, audio, network connections "
                + "or anything else right now.",
            rows: holds.map { row($0, now: now) },
            microphone: microphoneSummary(microphone, osName: osName),
            canReleaseEverything: holds.contains { $0.isReleasable && releaseEverythingKinds.contains($0.kind) }
        )
    }

    package static func microphoneSummary(_ attribution: MicrophoneUseAttribution, osName: String) -> String {
        switch attribution {
        case .unknown: "\(osName) cannot report microphone use here."
        case .idle: "\(osName) reports the microphone closed."
        case .attributed: "\(osName) reports the microphone open, as listed above."
        case .unattributed: "\(osName) reports the microphone open."
        case .claimedButClosed: "\(osName) reports the microphone closed; the listed hold is paused."
        }
    }

    static func row(_ hold: SystemResourceHold, now: Date) -> Row {
        var parts = [hold.kind.displayName, SystemResourceSummary.duration(since: hold.since, now: now)]
        if let detail = hold.detail, !detail.isEmpty { parts.append(detail) }
        return Row(
            id: hold.id.uuidString, kind: hold.kind, title: hold.title, reason: hold.reason,
            caption: parts.joined(separator: " · "), releaseTitle: hold.releaseTitle, releasing: hold.isReleasing
        )
    }

    /// Releases one hold by the id a row carried. False when it is gone or not releasable.
    @discardableResult
    package static func release(
        _ id: String, registry: SystemResourceRegistry = .shared
    ) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return await registry.release(uuid)
    }

    @discardableResult
    package static func releaseEverything(registry: SystemResourceRegistry = .shared) async -> Int {
        await registry.releaseAll(kinds: releaseEverythingKinds)
    }
}

/// Polls the OS microphone signal and republishes the presentation, so
/// durations tick and an unclaimed microphone surfaces within the auditor's
/// grace. The probe returns nil where the OS cannot say.
package final class DesktopSystemResourcesMonitor: @unchecked Sendable {
    private let registry: SystemResourceRegistry
    private let osName: String
    private let probe: @Sendable () -> Bool?
    private let publish: @Sendable (DesktopSystemResources.Presentation) -> Void
    private let report: @Sendable (String) -> Void
    private let lock = NSLock()
    private var auditor = MicrophoneUseAuditor()
    private var attribution = MicrophoneUseAttribution.unknown
    private var last: DesktopSystemResources.Presentation?
    private var observation: SystemResourceObservation?
    private var poll: Task<Void, Never>?

    /// `report` receives one line per unclaimed-microphone episode, with the holds at that moment.
    package init(
        registry: SystemResourceRegistry = .shared, osName: String,
        probe: @escaping @Sendable () -> Bool?,
        publish: @escaping @Sendable (DesktopSystemResources.Presentation) -> Void,
        report: @escaping @Sendable (String) -> Void
    ) {
        self.registry = registry
        self.osName = osName
        self.probe = probe
        self.publish = publish
        self.report = report
    }

    deinit { stop() }

    package var microphone: MicrophoneUseAttribution { lock.withLock { attribution } }

    /// Observes the registry and samples every `interval`. Safe to call twice.
    package func start(interval: Duration = .seconds(2)) {
        let begin = lock.withLock { () -> Bool in
            guard poll == nil else { return false }
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: interval)
                }
            }
            return true
        }
        guard begin else { return }
        let observation = registry.observe { [weak self] _ in self?.sample(probing: false) }
        lock.withLock { self.observation = observation }
    }

    package func stop() {
        let (task, observation) = lock.withLock { () -> (Task<Void, Never>?, SystemResourceObservation?) in
            defer { poll = nil; self.observation = nil }
            return (poll, self.observation)
        }
        task?.cancel()
        observation?.cancel()
    }

    /// Registry changes republish without probing the OS; the timer probes.
    package func sample(probing: Bool = true, now: Date = Date()) {
        let reported = probing ? probe() : nil
        let holds = registry.holds
        let (presentation, line) = lock.withLock { () -> (DesktopSystemResources.Presentation?, String?) in
            var line: String?
            if probing {
                let result = auditor.observe(osReportsInput: reported, holds: holds, at: now)
                attribution = result.attribution
                if result.shouldReport {
                    line = "Microphone open with no registered owner. Holds: "
                        + SystemResourceSummary.diagnostics(for: holds, now: now)
                }
            }
            let next = DesktopSystemResources.presentation(
                holds: holds, microphone: attribution, osName: osName, now: now
            )
            guard next != last else { return (nil, line) }
            last = next
            return (next, line)
        }
        if let line { report(line) }
        if let presentation { publish(presentation) }
    }
}

/// Follows a native registration that reports its current name, or nil once
/// nothing is registered (the Windows dictation shortcut). One hold lasts while
/// something is registered; a changed combination updates its detail.
package final class DesktopRegistrationHold: @unchecked Sendable {
    private let lock = NSLock()
    private var token: SystemResourceToken?
    private var name: String?
    private let acquire: (String) -> SystemResourceToken

    package init(acquire: @escaping (String) -> SystemResourceToken) {
        self.acquire = acquire
    }

    package func update(_ next: String?) {
        let ended: SystemResourceToken? = lock.withLock {
            guard next != name else { return nil }
            name = next
            guard let next else {
                defer { token = nil }
                return token
            }
            if let token { token.update(detail: next) } else { token = acquire(next) }
            return nil
        }
        ended?.end()
    }
}
