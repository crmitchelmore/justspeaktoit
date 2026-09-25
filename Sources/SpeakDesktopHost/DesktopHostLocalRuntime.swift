import Foundation
import SpeakCore
import SpeakDesktop

/// A loaded on-device speech runtime, shared by every recording once opened.
package protocol DesktopHostLocalRuntime: AnyObject, Sendable {
    /// Shown in Local models, e.g. "whisper.cpp 1.9.4; CPU".
    var description: String { get }
    /// Recognises with this runtime; cancelling the calling task aborts it.
    var recognizer: any DesktopLocalRecognizer { get }
    /// Frees the cached model after the current recognition, only if it was
    /// loaded from `modelFile` (which may already be deleted). A model loaded
    /// in its place stays cached. Returns whether that model was freed.
    @discardableResult
    func releaseModel(loadedFrom modelFile: URL) -> Bool
}

/// The controller's Local models state: running downloads, their progress and
/// the runtime once loaded.
package struct DesktopHostLocalModelsState<Runtime: DesktopHostLocalRuntime> {
    package var downloads: [String: Task<Void, Never>] = [:]
    package var progress: [String: Int64] = [:]
    package var runtime: Runtime?
    package var runtimeFailure: String?
    /// The models recordings and transcriptions use, and the downloads and
    /// removals that own model files.
    package var ownership = LocalModelOwnership()
    /// The model file last rehashed for the runtime to load; any other, or a
    /// changed one, is rehashed before recognition.
    package var loadVerification = LocalModelLoadVerification()
    /// Deletes removed models and frees the runtime's cache off the actor.
    package let teardown = LocalModelTeardown()
    /// Set once the window can show Local models; nothing is presented before.
    package var presenting = false
    /// Borrowed by the platform's presenter, for windows that need a native context.
    package var presenter: UnsafeMutableRawPointer?

    package init() {}
}

/// One model's row in Local models.
package struct DesktopHostLocalModelRow: Equatable, Sendable {
    package enum State: Equatable, Sendable {
        case notDownloaded
        /// Bytes are kept from an interrupted download; downloading resumes.
        case paused
        case downloading
        case downloaded
        /// Only a finished removal changes the row again.
        case removing
    }

    package let name: String
    package let detail: String
    package let about: String
    package let state: State

    package init(name: String, detail: String, about: String, state: State) {
        self.name = name
        self.detail = detail
        self.about = about
        self.state = state
    }
}

/// What a Local models row asks for.
package enum DesktopHostLocalModelAction: Sendable {
    /// Downloads, or resumes a paused download.
    case download
    case cancel
    case remove
}

/// A host that runs downloaded models on-device through a whisper.cpp-style
/// runtime. The shared controller owns downloads, verification, readiness,
/// removal and recognition; the platform supplies only native services.
package protocol DesktopHostLocalModelPlatform: DesktopHostPlatform
where LocalModelsState == DesktopHostLocalModelsState<LocalRuntime> {
    associatedtype LocalRuntime: DesktopHostLocalRuntime

    /// The downloaded-model backends this host runs.
    static var localModelHost: LocalModelHostSupport { get }
    /// The audited SHA-256 that verifies downloads.
    static var localModelDigests: LocalModelDigestProvider { get }
    /// Streams pinned artefacts. Defaults to URLSession.
    static var localModelTransport: any LocalModelDownloadTransport { get }
    /// Why this build cannot run on-device models at all (the runtime
    /// libraries are not installed beside it), or nil when they are.
    static var localRuntimeMissing: String? { get }
    /// Loads the process-wide runtime. Reads libraries, so it runs off the controller.
    static func openLocalRuntime(allowGPU: Bool) throws -> LocalRuntime
    /// The runtime line before it loads, e.g. "On-device with whisper.cpp
    /// 1.9.4 using the CPU. Audio stays on this PC."
    static func localRuntimeSummary(useGPU: Bool) -> String
    /// Where a downloaded model is chosen, completing "… downloaded and verified."
    static var localModelChoiceHint: String { get }
    /// Shows the rows and runtime line. `presenter` is what `configureLocalModels` was given.
    static func presentLocalModels(
        _ rows: [DesktopHostLocalModelRow], status: String, useGPU: Bool, presenter: UnsafeMutableRawPointer?
    )
}

// The DesktopHostPlatform on-device hooks, answered by the shared controller.
// These refine the unsupported defaults in DesktopHostLocalModels.swift.
package extension DesktopHostLocalModelPlatform {
    static var localModelTransport: any LocalModelDownloadTransport { LocalModelURLSessionTransport() }

    static func makeLocalModelsState() -> LocalModelsState { DesktopHostLocalModelsState() }

    static func localReadiness(_ model: String, controller: isolated DesktopHostController<Self>) -> String? {
        controller.localReadiness(model)
    }

    static func transcribeLocally(
        _ audio: URL, model: String, language: String?, controller: isolated DesktopHostController<Self>
    ) async throws -> TranscriptionResult {
        try await controller.transcribeLocally(audio, model: model, language: language)
    }

    static func beginLocalUse(_ model: String, controller: isolated DesktopHostController<Self>) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: localModelHost) else { return nil }
        controller.localModels.ownership.beginUse(spec.catalogueID)
        return spec.catalogueID
    }

    static func endLocalUse(_ held: String, controller: isolated DesktopHostController<Self>) {
        controller.localModels.ownership.endUse(held)
    }
}
