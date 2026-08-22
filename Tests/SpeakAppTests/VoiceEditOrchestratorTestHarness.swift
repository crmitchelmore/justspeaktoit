import Foundation

@testable import SpeakApp

struct VoiceEditStubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Test double owning every orchestrator seam, so each test tweaks only what it needs.
@MainActor
final class VoiceEditOrchestratorHarness {
    var busy = false
    var reservationAvailable = true
    var llmConfigured = true
    var selection: VoiceEditOrchestrator.Selection? = .init(
        text: "The quick brown fox jumps over the lazy dog",
        source: .accessibility
    )
    var startError: Error?
    var instructionResult: Result<String, Error> = .success("make this shorter")
    var rewriteResult: Result<String, Error> = .success("Quick fox, lazy dog.")
    var replacementOutcome: VoiceEditOrchestrator.ReplacementOutcome = .replaced
    /// Suspends selection capture so tests can press the hotkey again mid-startup.
    var captureGate: (() async -> Void)?
    /// Suspends cancellation teardown so tests can observe the cancelling phase.
    var cancelGate: (() async -> Void)?

    private(set) var events: [VoiceEditOrchestrator.Event] = []
    private(set) var captureCount = 0
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var reserveCount = 0
    private(set) var releaseCount = 0
    private(set) var rewriteRequests: [(selection: String, instruction: String)] = []
    private(set) var appliedRewrites: [String] = []

    lazy var orchestrator = VoiceEditOrchestrator(
        dependencies: .init(
            isDictationBusy: { self.busy },
            reserveCapture: {
                self.reserveCount += 1
                return self.reservationAvailable
            },
            releaseCapture: { self.releaseCount += 1 },
            hasConfiguredLLM: { self.llmConfigured },
            captureSelection: {
                self.captureCount += 1
                await self.captureGate?()
                return self.selection
            },
            startListening: {
                self.startCount += 1
                if let error = self.startError { throw error }
            },
            finishListening: {
                self.finishCount += 1
                return try self.instructionResult.get()
            },
            cancelListening: {
                self.cancelCount += 1
                await self.cancelGate?()
            },
            rewrite: { selection, instruction in
                self.rewriteRequests.append((selection.text, instruction))
                return try self.rewriteResult.get()
            },
            applyReplacement: { _, rewrite in
                self.appliedRewrites.append(rewrite)
                return self.replacementOutcome
            },
            onEvent: { self.events.append($0) }
        )
    )
}

/// One-shot gate used to hold an orchestrator dependency at a suspension point.
@MainActor
final class VoiceEditTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
