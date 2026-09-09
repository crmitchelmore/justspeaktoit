import Combine
import Foundation

/// Foreground Settings preparation. Only in-flight work is shared; capture always checks inventory again.
@MainActor
public final class AppleSpeechModelPreparation: ObservableObject {
    public struct Configuration: Hashable, Sendable {
        public let modelID: String
        public let localeIdentifier: String

        public init(modelID: String, localeIdentifier: String) {
            self.modelID = modelID
            self.localeIdentifier = localeIdentifier
        }
    }

    public enum State: Equatable {
        case idle
        case checking
        case preparing
        case ready(Configuration)
        case failed(String)
    }

    struct Operation {
        let configuration: Configuration
        let run: @MainActor (@escaping @MainActor @Sendable () -> Void) async throws -> Void
    }

    private struct Pending {
        let task: Task<Void, Error>
        var isPreparing = false
    }

    @available(macOS 26.0, iOS 26.0, *)
    public static let shared = AppleSpeechModelPreparation(resolve: resolveLiveModule)

    @available(macOS 26.0, iOS 26.0, *)
    private static func resolveLiveModule(_ selection: Configuration) async throws -> Operation {
        let module = try await AppleSpeechAnalyzerTranscriber.resolveModule(
            engine: AppleSpeechAnalyzerEngine(modelID: selection.modelID),
            localeIdentifier: selection.localeIdentifier,
            progressive: true
        )
        return Operation(
            configuration: Configuration(modelID: module.engine.modelID, localeIdentifier: module.localeIdentifier),
            run: { onPreparing in
                try await AppleSpeechAnalyzerTranscriber.ensureAssets(
                    for: [module.module.speechModule], onPreparing: { await onPreparing() }
                )
            }
        )
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var selection: Configuration?
    private var generation = UUID()
    private var activeConfiguration: Configuration?
    private var pending: [Configuration: Pending] = [:]
    private let resolve: @MainActor (Configuration) async throws -> Operation

    init(resolve: @escaping @MainActor (Configuration) async throws -> Operation) {
        self.resolve = resolve
    }

    /// Selection changes invalidate presentation, including a late completion for a previous locale.
    public func select(_ configuration: Configuration) {
        guard selection != configuration else { return }
        generation = UUID()
        selection = configuration
        activeConfiguration = nil
        state = .idle
    }

    /// Called only by the explicit Prepare button, never by selection or view appearance.
    public func prepare(_ configuration: Configuration) async {
        guard !Task.isCancelled else { return }
        select(configuration)
        generation = UUID()
        let requestGeneration = generation
        state = .checking
        do {
            let operation = try await resolve(configuration)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            let key = operation.configuration
            activeConfiguration = key
            let task: Task<Void, Error>
            if let existing = pending[key] {
                task = existing.task
                state = existing.isPreparing ? .preparing : .checking
            } else {
                task = Task {
                    // Remove before publishing completion so a retry rechecks authoritative inventory.
                    defer { self.pending[key] = nil }
                    try Task.checkCancellation()
                    try await operation.run {
                        self.pending[key]?.isPreparing = true
                        if self.activeConfiguration == key { self.state = .preparing }
                    }
                    try Task.checkCancellation()
                }
                pending[key] = Pending(task: task)
            }
            try await task.value
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .ready(key)
        } catch {
            guard generation == requestGeneration else { return }
            state = error is CancellationError || Task.isCancelled ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Leaving foreground Settings withdraws app work; no background completion is promised.
    public func cancel() {
        generation = UUID()
        activeConfiguration = nil
        for entry in pending.values { entry.task.cancel() }
        state = .idle
    }
}
