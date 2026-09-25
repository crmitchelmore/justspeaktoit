import Foundation

extension SharedMultipartUploadStaging {
    /// Snapshots multipart bytes with a bounded 1 MiB copy buffer. Creation,
    /// permissions, claims and failed-copy cleanup use the shared staging policy.
    func writeMultipart(
        sourceURL: URL,
        providerID: String,
        boundary: String,
        fields: [(name: String, value: String)],
        mimeType: String,
        fileField: String = "file",
        trailingFields: [(name: String, value: String)] = []
    ) throws -> URL {
        try Task.checkCancellation()
        let destination = try createUploadBodyFile(providerID: providerID)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try Self.write(fields: fields, boundary: boundary, to: output)
            let filename = sourceURL.lastPathComponent
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let header = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n"
                + "Content-Type: \(mimeType)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                guard !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            if trailingFields.isEmpty {
                try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            } else {
                try output.write(contentsOf: Data("\r\n".utf8))
                try Self.write(fields: trailingFields, boundary: boundary, to: output)
                try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            }
            return destination
        } catch {
            removeUploadBodyFile(at: destination)
            throw error
        }
    }

    private static func write(
        fields: [(name: String, value: String)], boundary: String, to output: FileHandle
    ) throws {
        for field in fields {
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
            try output.write(contentsOf: Data((header + field.value + "\r\n").utf8))
        }
    }
}
