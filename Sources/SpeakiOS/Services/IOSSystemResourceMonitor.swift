#if os(iOS)
import Combine
import SpeakCore
import SwiftUI

/// The iOS app's live view of ``SystemResourceRegistry`` (issue #1471). It also
/// registers holds for owners whose state is already published: the recording
/// service and the Live Activity.
@MainActor
public final class IOSSystemResourceMonitor: ObservableObject {
    public static let shared = IOSSystemResourceMonitor()

    @Published public private(set) var holds: [SystemResourceHold] = []

    private let registry: SystemResourceRegistry
    private var observation: SystemResourceObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var adapterHolds: [String: SystemResourceToken] = [:]
    private var started = false

    init(registry: SystemResourceRegistry = .shared) {
        self.registry = registry
        self.holds = registry.holds
        self.observation = registry.observe { [weak self] holds in
            Task { @MainActor [weak self] in self?.holds = holds }
        }
    }

    /// Starts the adapters. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        let recording = TranscriptionRecordingService.shared
        recording.$isRunning
            .removeDuplicates()
            .sink { [weak self, weak recording] running in
                self?.setHold("recording", active: running) { registry in
                    registry.acquire(
                        kind: .microphone, title: "Recording",
                        reason: "Recording the dictation you started.", owner: "TranscriptionRecordingService",
                        releaseTitle: "Cancel recording",
                        release: { await MainActor.run { recording?.cancelRecording() } }
                    )
                }
            }
            .store(in: &cancellables)
        let activities = TranscriptionActivityManager.shared
        let liveActivityReason = "Shows the dictation \(DeviceCopy.liveActivityPlacement)."
        activities.$currentActivity
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self, weak activities] active in
                self?.setHold("liveActivity", active: active) { registry in
                    registry.acquire(
                        kind: .liveActivity, title: "Live Activity",
                        reason: liveActivityReason,
                        owner: "TranscriptionActivityManager", releaseTitle: "End",
                        release: { await MainActor.run { activities?.endActivity() } }
                    )
                }
            }
            .store(in: &cancellables)
    }

    public var hasReleasableHolds: Bool { holds.contains(where: \.isReleasable) }

    public func release(_ hold: SystemResourceHold) async {
        await registry.release(hold.id)
    }

    public func releaseEverything() async {
        await registry.releaseAll()
    }

    private func setHold(_ key: String, active: Bool, make: (SystemResourceRegistry) -> SystemResourceToken) {
        if active {
            if adapterHolds[key] == nil { adapterHolds[key] = make(registry) }
        } else {
            adapterHolds.removeValue(forKey: key)?.end()
        }
    }
}

/// Rows for Settings › "System resources in use".
struct SystemResourcesStatusRows: View {
    @ObservedObject var monitor: IOSSystemResourceMonitor

    var body: some View {
        if monitor.holds.isEmpty {
            Text("Just Speak is not holding the microphone, audio, connections or anything else right now.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("systemResources.empty")
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.holds) { hold in
                        row(hold, now: context.date)
                    }
                }
            }
        }
        Button("Release Everything", role: .destructive) {
            Task { await monitor.releaseEverything() }
        }
        .disabled(!monitor.hasReleasableHolds)
        .accessibilityIdentifier("systemResources.releaseEverything")
    }

    private func row(_ hold: SystemResourceHold, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: hold.kind.systemImage)
                .foregroundStyle(hold.kind == .microphone ? Color.orange : Color.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hold.title).font(.body.weight(.medium))
                Text(hold.reason).font(.caption).foregroundStyle(.secondary)
                Text(
                    [hold.kind.displayName, SystemResourceSummary.duration(since: hold.since, now: now), hold.detail]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let title = hold.releaseTitle {
                Button(title) {
                    Task { await monitor.release(hold) }
                }
                .buttonStyle(.bordered)
                .disabled(hold.isReleasing)
                .accessibilityIdentifier("systemResources.release.\(hold.owner)")
            }
        }
        .accessibilityIdentifier("systemResources.hold.\(hold.owner)")
    }
}
#endif
