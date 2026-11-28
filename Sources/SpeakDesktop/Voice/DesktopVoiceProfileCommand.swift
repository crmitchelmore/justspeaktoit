import Foundation

/// The editor owns one session token until its native window closes.
public struct DesktopVoiceProfileCommand: Equatable, Sendable {
    public enum Operation: Int32, Sendable {
        case prepare, preview, transcribe, addClip, save, close, record, stopRecording
        case inspectDeletion, delete
    }

    public let session: UUID
    public let operation: Operation
    public let reference: String
    public let text: String
    public let name: String
    public let language: String

    init(source: Int32, text: String, record: String, path: String) throws {
        let fields = record.components(separatedBy: "\n")
        guard let operation = Operation(rawValue: source), let first = fields.first,
              let session = UUID(uuidString: first), text.utf8.count <= 65_536 else { throw Failure.malformed }
        if operation == .save {
            guard fields.count == 4, fields[1] == "consent-v1", !fields[2].isEmpty,
                  fields[2].count <= 120, !fields[3].isEmpty, fields[3].count <= 64 else { throw Failure.consent }
        } else if fields.count != 1 {
            throw Failure.malformed
        }
        self.operation = operation
        self.session = session
        self.name = operation == .save ? fields[2] : ""
        self.language = operation == .save ? fields[3] : ""
        self.reference = path
        self.text = text
    }

    private enum Failure: LocalizedError {
        case malformed, consent
        var errorDescription: String? {
            switch self {
            case .malformed: "The voice profile editor request was invalid."
            case .consent: "Enter a name and language and accept the voice consent statement before saving."
            }
        }
    }
}
