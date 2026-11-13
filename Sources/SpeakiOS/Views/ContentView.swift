#if os(iOS)
import AVFoundation
import SpeakCore
import SwiftUI
import UIKit

public struct ContentView: View {
    @StateObject var recovery = CaptureRecoveryCoordinator.shared
    @State var showingRecoveryPrompt = false
    /// The interrupted capture the launch prompt is asking about.
    @State var recoveryPromptFinding: CaptureRecoveryFinding?
    /// The capture this screen started transcribing, so only its progress
    /// and outcome are shown here rather than one started in Capture Health.
    @State var recoveryInFlight: UUID?
    @State var recoveryFailure: CaptureRecoveryFinding?
    @State var recoveryFailureMessage = ""
    @StateObject var coordinator: TranscriberCoordinator
    @StateObject var handsFree: IOSHandsFreeDictationCoordinator
    @ObservedObject var settings = AppSettings.shared
    @State var showingError = false
    @State var issueReport: IOSIssueReportController?
    @State var issueErrorSnapshot = IOSIssueReporter.failedRequest()
    @State var errorMessage = ""
    @State var startFailureRecovery: CaptureStartFailureRecovery?
    /// Titles the error alert; start failures without a recovery still count.
    @State var errorIsStartFailure = false
    @State var recoveryDestination: CaptureStartFailureRecovery?
    /// The background session failure already alerted on, identified by its
    /// publication rather than its text, so the change observer and the
    /// on-appear read cannot show one failure twice — and two failures that
    /// happen to read identically are still shown separately.
    @State var presentedSessionError: UUID?
    @State var copied = false
    @State var showingPostProcessing = false
    @ObservedObject var historyRouter = DeepLinkRouter.shared
    @State var displayText = ""  // Text shown in UI (may be post-processed)
    @Namespace var controlsNamespace

    /// The headless Action Button / Siri / Shortcuts recorder. Observed so the
    /// app can surface the most recent background session as the current view and
    /// badge History when a recording landed while the app was away.
    @ObservedObject var backgroundService = TranscriptionRecordingService.shared
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var showHistoryBadge = false
    /// Guided first run and the progressive per-trigger cards. Every decision
    /// here comes from `CaptureOnboardingPolicy`; this layer only renders it.
    @ObservedObject var onboarding = CaptureOnboardingStore.shared
    @State var showingFirstRun = false
    @State var showingDiagnosticsConsent = false
    /// Recordings handed over by the Share extension (issue #1020). Drained on
    /// every foreground because that is the first moment the app has the keys,
    /// the batch client and the memory budget the extension does not.
    @ObservedObject var sharedImporter = SharedRecordingImporter.shared
    let captureHardware = CaptureHardwareProfile.current()
    /// Completion time of the background transcript we last surfaced, so we only
    /// surface a given session once and never clobber the user's in-app edits.
    @State var lastSurfacedAt: Date?

    public init() {
        let coordinator = TranscriberCoordinator(
            networkSnapshot: CaptureNetworkPathMonitor.liveSnapshotProvider(),
            localRecognitionCapability: AppleLegacyRecognitionCapabilityProbe.capability(for:)
        )
        _coordinator = StateObject(wrappedValue: coordinator)
        // Binds hands-free stop/cancel to the run its start acquired (#943): a
        // rejected or finished utterance cannot act on somebody else's recording.
        let handsFree = Self.makeHandsFree(coordinator: coordinator)
        _handsFree = StateObject(wrappedValue: handsFree)
        // A hands-free utterance presents through the coordinator's capture, so
        // it inherits the same proof gate rather than keeping a second one.
        handsFree.captureIsProven = { [weak coordinator] in coordinator?.isPresentingCapture ?? false }
        coordinator.onCapturePresentationChanged = { [weak handsFree] in
            handsFree?.refreshCapturePresentation()
        }
        coordinator.onCaptureDisruption = { [weak coordinator, weak handsFree] in
            if handsFree?.isArmed == true {
                await handsFree?.stopForCaptureDisruption(reason: coordinator?.captureDisruptionReason ?? .interrupted)
            } else {
                _ = await coordinator?.stop()
            }
        }
    }

    /// Builds the hands-free coordinator bound to one foreground capture
    /// handle, so its stop and cancel act only on the run its own start
    /// acquired (#943).
    @MainActor
    static func makeHandsFree(
        coordinator: TranscriberCoordinator
    ) -> IOSHandsFreeDictationCoordinator {
        let handsFreeCapture = ForegroundCaptureHandle()
        return IOSHandsFreeDictationCoordinator(
            audioSessionManager: coordinator.audioSessionManager,
            startCapture: { preRoll in
                // Earliest app-code observation of this utterance's start.
                let detectedAt = Date()
                let settings = AppSettings.shared
                guard HandsFreeDictationPolicy.supportsCapture(
                    modelID: settings.selectedModel,
                    isStreaming: settings.transcriptionMode == .streaming
                )
                else { return .rejected(.unsupportedConfiguration) }
                do {
                    try await coordinator.start(
                        preRollBuffers: preRoll, analyzerFallbackAllowed: false,
                        entry: StartupEntry(origin: .handsFree, observedAt: detectedAt), handle: handsFreeCapture
                    )
                    return .started
                } catch {
                    return .rejected(HandsFreeDictationMachine.Failure(error))
                }
            },
            stopCapture: { shouldRearm in
                _ = await coordinator.stop(handle: handsFreeCapture, rearmHandsFree: shouldRearm)
                if case .microphoneChanged? = coordinator.error as? iOSTranscriptionError { return .completed }
                return coordinator.error == nil ? .completed : .failed(.captureFailed)
            },
            cancelCapture: { coordinator.cancel(handle: handsFreeCapture) },
            // iOS has no silence-hold setting, so the shared policy value is
            // the only source. The macOS "silenceDuration" preference lives
            // in the Mac app's own defaults and never reaches this app.
            silenceDuration: { HandsFreeDictationPolicy.defaultSilenceHoldSeconds },
            captureIsSupported: {
                HandsFreeDictationPolicy.supportsCapture(
                    modelID: AppSettings.shared.selectedModel,
                    isStreaming: AppSettings.shared.transcriptionMode == .streaming
                )
            },
            liveActivitiesEnabled: { AppSettings.shared.liveActivitiesEnabled }
        )
    }

    public var body: some View {
        NavigationStack {
            sheets(observers(presentations(chrome(
                ZStack {
                    // Content layer - transcript display (base plane, no glass)
                    transcriptLayer

                    // Controls layer - floating glass controls
                    controlsLayer
                }
            ))))
        }
        .environment(\.appVisualDensity, settings.visualDensity)
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .controlSize(density.isCompact ? .small : .regular)
    }

    // MARK: - Computed Properties

    var density: AppVisualDensity {
        settings.visualDensity
    }

    var usesInlineDensityLayout: Bool {
        density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    var primaryControlSize: CGFloat {
        density.isCompact ? 48 : 64
    }

    var secondaryControlSize: CGFloat {
        density.isCompact ? 44 : 48
    }

    var primarySymbolSize: CGFloat {
        density.isCompact ? 20 : 28
    }

    var secondarySymbolSize: CGFloat {
        density.isCompact ? 16 : 20
    }

    var hasTextToShow: Bool {
        !currentText.isEmpty
    }

    var isAnyRecording: Bool {
        coordinator.isRunning || backgroundService.isRunning
    }

    var handsFreeStatusLabel: String {
        switch handsFree.state {
        case .off: return "Off"
        case .arming: return "Arming"
        case .armed: return "Armed"
        case .recording: return "Recording"
        case .finalising: return "Finalising"
        }
    }

    /// The primary control's symbol, visible title and accessibility label.
    var recordControl: ForegroundRecordControl {
        let phase: ForegroundRecordControl.Phase
        if coordinator.state == .starting {
            phase = .starting
        } else if coordinator.state == .stopping {
            phase = .stopping
        } else if isAnyRecording {
            phase = .recording
        } else {
            phase = .idle
        }
        return ForegroundRecordControl(
            phase: phase,
            handsFreeArmed: handsFree.isArmed,
            handsFreeEnabled: settings.handsFreeDictationActive
        )
    }

    var currentText: String {
        // A live background (Action Button) session takes precedence so opening
        // the app mid-recording shows it live.
        if backgroundService.isRunning {
            return backgroundService.partialText
        }
        return displayText.isEmpty ? coordinator.partialText : displayText
    }
}

#Preview {
    ContentView()
}
#endif
