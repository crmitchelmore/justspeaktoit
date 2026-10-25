#if os(iOS)
import AppIntents
import SpeakCore

/// Opt-in through Settings > Focus. Defaults also represent native deactivation.
public struct DictationFocusFilter: SetFocusFilterIntent {
    public static var title: LocalizedStringResource = "Capture Overrides"
    public static var description = IntentDescription(
        "Choose destination, model or language for Action Button, Siri and Shortcuts captures."
    )

    @Parameter(title: "Destination")
    public var destination: CaptureDestinationAppEnum?

    @Parameter(title: "Model", optionsProvider: CaptureModelOptionsProvider())
    public var model: String?

    @Parameter(title: "Language", optionsProvider: CaptureLanguageOptionsProvider())
    public var language: String?

    public init() {}

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Capture overrides", subtitle: "Action Button, Siri and Shortcuts")
    }

    var captureOverride: FocusCaptureOverride {
        FocusCaptureOverride(destinationID: destination?.rawValue, modelID: model, languageIdentifier: language)
    }

    public func perform() async throws -> some IntentResult {
        // All-default reset needs no model, credentials or microphone permission.
        try FocusCaptureOverrideStore.live().write(captureOverride)
        return .result()
    }
}

@MainActor
enum FocusCaptureReconciliation {
    static func reconcile(
        store: FocusCaptureOverrideStore,
        explicit: CaptureRunParameters,
        current: () async throws -> FocusCaptureOverride
    ) async throws -> FocusCaptureOverride {
        let before = try store.snapshot()
        // A never-configured capture has no new dependency on a native Focus lookup.
        guard before.hasBeenConfigured else { return .none }
        let native: FocusCaptureOverride
        do {
            native = try await current()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve diagnostic state; a concurrent perform/reset is authoritative.
            let latest = try store.snapshot()
            if latest.override.affects(explicit) { throw FocusCaptureOverrideStore.Failure.nativeLookup }
            return latest.override
        }
        return try store.write(native, ifGeneration: before.generation, compare: true).override
    }

    static func live(explicit: CaptureRunParameters) async throws -> FocusCaptureOverride {
        try await reconcile(store: .live(), explicit: explicit) {
            try await FocusNativeLookup().read { try await DictationFocusFilter.current.captureOverride }
        }
    }
}

/// Bounds native lookup without letting a late result mutate the store.
@MainActor
private final class FocusNativeLookup {
    private var continuation: CheckedContinuation<FocusCaptureOverride, Error>?
    private var lookup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func read(
        _ current: @escaping @MainActor () async throws -> FocusCaptureOverride
    ) async throws -> FocusCaptureOverride {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.lookup = Task {
                    do { self.finish(.success(try await current())) } catch { self.finish(.failure(error)) }
                }
                self.deadline = Task {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self.finish(.failure(FocusCaptureOverrideStore.Failure.nativeLookup))
                }
                if Task.isCancelled { self.finish(.failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<FocusCaptureOverride, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.lookup?.cancel()
        self.deadline?.cancel()
        self.lookup = nil
        self.deadline = nil
        continuation.resume(with: result)
    }
}

/// Shared only by the two attempts of one foreground-continuation request.
@MainActor
final class CaptureConfigurationRequest {
    var configuration: EffectiveCaptureConfiguration?
}
#endif
