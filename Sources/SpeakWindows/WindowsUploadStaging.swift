import Foundation
import SpeakCore
import CWindowsSupport

extension WindowsNative {
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        SharedMultipartUploadStaging(
            directory: directory,
            securityPolicy: .init(
                prepareDirectory: { url, _ in
                    try url.path.withCString { path in
                        try checked { jsti_private_directory_prepare(path, $0, $1) }
                    }
                },
                createFile: { url, _ in
                    try url.path.withCString { path in
                        try checked { jsti_private_file_create(path, $0, $1) }
                    }
                    return true
                }
            )
        )
    }

    static func validateImport(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WindowsNativeError(message: "Choose a regular audio file to import.")
        }
        guard let size = values.fileSize, size > 0, size <= 25_000_000 else {
            throw WindowsNativeError(message: "Choose a non-empty audio file no larger than 25 MB.")
        }
        guard ["wav", "mp3", "mp4", "m4a", "aac", "flac", "ogg", "opus", "webm"]
            .contains(source.pathExtension.lowercased()) else {
            throw WindowsNativeError(message: "Choose a WAV, MP3, MP4, M4A, AAC, FLAC, OGG, Opus or WebM audio file.")
        }
    }
}
