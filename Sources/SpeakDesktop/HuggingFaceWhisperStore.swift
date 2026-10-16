import Foundation
import SpeakCore

/// Device-local import metadata. It is separate from transferred Mac model
/// references: those contain no GGML digest and never acquire execution authority.
public struct HuggingFaceWhisperStore: Sendable {
    public static let maximumModels = 64
    public let directory: URL
    private let prepareDirectory: @Sendable (URL) throws -> Void

    public init(directory: URL, prepareDirectory: @escaping @Sendable (URL) throws -> Void) {
        self.directory = directory
        self.prepareDirectory = prepareDirectory
    }

    private var store: LocalModelMetadataStore<HuggingFaceWhisperModel> {
        .init(directory: directory, filename: "imported-whispercpp-models.json", prepareDirectory: prepareDirectory)
    }
    public var url: URL { store.url }
    public func load() throws -> [HuggingFaceWhisperModel] { try store.load() }
    public func save(_ models: [HuggingFaceWhisperModel]) throws { try store.save(models) }
}
