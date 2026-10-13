import Foundation
import SpeakCore

extension DesktopHostController {
    /// Admission is short; native file reads do not block the actor or UI loop.
    package func importVoiceText(
        path: String, requestID: String,
        read: @escaping @Sendable (URL) async throws -> String = { try await VoiceTextFileImport.read($0) },
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        guard !closed else { return }
        guard !path.isEmpty, !path.utf8.contains(0), !requestID.isEmpty, requestID.utf8.count <= 64 else {
            completion(.failure(VoiceTextFileImport.Failure.localFileRequired))
            return
        }
        guard voiceTextImportTask == nil else {
            completion(.failure(DesktopVoiceTextImportFailure.stillClosing))
            return
        }
        voiceTextImportRequestID = requestID
        activeOperations += 1
        voiceTextImportTask = Task {
            defer {
                self.voiceTextImportTask = nil
                self.voiceTextImportRequestID = nil
                self.finishOperation()
            }
            do {
                let text = try await read(URL(fileURLWithPath: path))
                try Task.checkCancellation()
                guard !self.closed else { return }
                completion(.success(try VoiceOutputSourceSnapshot(source: .textFile, text: text).text))
            } catch {
                guard !self.closed, !Task.isCancelled else { return }
                completion(.failure(error))
            }
        }
    }

    package func cancelVoiceTextImport(requestID: String) {
        guard voiceTextImportRequestID == requestID else { return }
        voiceTextImportTask?.cancel()
    }
}

private enum DesktopVoiceTextImportFailure: LocalizedError {
    case stillClosing

    var errorDescription: String? {
        "The previous text import is still closing. Choose the file again when it finishes."
    }
}
