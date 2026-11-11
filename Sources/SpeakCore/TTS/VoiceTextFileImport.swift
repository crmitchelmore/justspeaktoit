import Foundation

/// A local UTF-8 snapshot, never a live link to the chosen file.
public enum VoiceTextFileImport {
    public static let maximumBytes = VoiceOutputSourceSnapshot.maximumCharacters * 4 + 3

    public static func read(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        let worker = Task.detached { try readFile(url) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return try VoiceOutputSourceSnapshot(source: .textFile, text: text).text
    }

    private static func readFile(_ url: URL) throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw Failure.localFileRequired }
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw Failure.localFileRequired
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= maximumBytes else { throw Failure.tooLarge }
            }
            try Task.checkCancellation()
            return try decode(data)
        } catch let error as Failure {
            throw error
        } catch let error as VoiceOutputSourceSnapshot.Failure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreadable
        }
    }

    public enum Failure: LocalizedError {
        case localFileRequired, tooLarge, invalidUTF8, unreadable

        public var errorDescription: String? {
            switch self {
            case .localFileRequired: "Choose a local regular UTF-8 text file."
            case .tooLarge: "The text file exceeds the 100,000-character voice input limit."
            case .invalidUTF8: "The text file is not valid UTF-8. Save it as UTF-8 and try again."
            case .unreadable: "The text file could not be read. Check access and choose it again."
            }
        }
    }
}
