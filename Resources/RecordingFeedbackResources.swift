import Foundation
import SpeakCore

public enum RecordingFeedbackResources {
    public static func url(
        for sound: RecordingFeedbackSound, profile: RecordingFeedbackProfile
    ) throws -> URL {
        let filename = profile.filename(for: sound)
        guard let directory = Bundle.module.url(forResource: "Sounds", withExtension: nil) else {
            throw RecordingFeedbackResourceError.missing("Sounds")
        }
        let url = directory.appendingPathComponent(filename)
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= 1_048_576 else {
            throw RecordingFeedbackResourceError.invalid(filename)
        }
        return url
    }
}

public enum RecordingFeedbackResourceError: LocalizedError {
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): return "Bundled recording sound is missing: \(name)."
        case .invalid(let name): return "Bundled recording sound is not a regular 1 MB-or-smaller file: \(name)."
        }
    }
}
