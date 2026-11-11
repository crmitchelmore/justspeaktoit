import Combine
import Foundation

/// One Settings presentation. Only its operation subscriptions are shared; its state and cancellation are local.
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

    struct Operation: Sendable {
        let configuration: Configuration
        let run: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) async throws -> Void
    }

    @available(macOS 26.0, iOS 26.0, *)
    public static let shared = AppleSpeechModelPreparation()

    @available(macOS 26.0, iOS 26.0, *)
    private static let operations = AppleSpeechPreparationOperations { try await resolveLiveModule($0) }

    /// Each Settings presentation has its own state but can share an explicitly requested installation.
    @available(macOS 26.0, iOS 26.0, *)
    public convenience init() {
        self.init(operations: Self.operations)
    }

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
                    for: [module.module.speechModule], onPreparing: { await onPreparing() },
                    inventoryTimeout: AppleSpeechDependencyWait.inventoryTimeout
                )
            }
        )
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var selection: Configuration?
    private var generation = UUID()
    private var activeTask: Task<Configuration, Error>?
    private let operations: AppleSpeechPreparationOperations

    init(resolve: @escaping AppleSpeechPreparationOperations.Resolve) {
        self.operations = AppleSpeechPreparationOperations(resolve: resolve)
    }

    init(operations: AppleSpeechPreparationOperations) {
        self.operations = operations
    }

    public func select(_ configuration: Configuration) {
        guard selection != configuration else { return }
        cancel()
        selection = configuration
    }

    /// Called only by the explicit Prepare button, never by selection or view appearance.
    public func prepare(_ configuration: Configuration) async {
        guard !Task.isCancelled else { return }
        select(configuration)
        cancel()
        let requestGeneration = generation
        state = .checking
        let operations = self.operations
        let task = Task {
            try await operations.prepare(configuration) { [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.state = .preparing
            }
        }
        activeTask = task
        defer { if generation == requestGeneration { activeTask = nil } }
        do {
            let resolved = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .ready(resolved)
        } catch {
            guard generation == requestGeneration else { return }
            state = error is CancellationError || Task.isCancelled ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Withdraw this presentation only. Other callers retain ownership of their preparation.
    public func cancel() {
        generation = UUID()
        activeTask?.cancel()
        activeTask = nil
        state = .idle
    }
}
