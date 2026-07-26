import Foundation

struct WAVFile {
    let samples: [Float]
    let durationSeconds: Double

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw WAVError.invalidContainer(url.path)
        }

        var offset = 12
        var format: (audioFormat: Int, channels: Int, sampleRate: Int, bitsPerSample: Int)?
        var sampleData: Data?
        while offset + 8 <= data.count {
            let identifier = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Self.littleEndianUInt32(data, offset: offset + 4)
            let chunkStart = offset + 8
            let chunkEnd = min(chunkStart + chunkSize, data.count)
            guard chunkStart <= chunkEnd else { break }
            if identifier == "fmt ", chunkSize >= 16 {
                format = (
                    audioFormat: Self.littleEndianUInt16(data, offset: chunkStart),
                    channels: Self.littleEndianUInt16(data, offset: chunkStart + 2),
                    sampleRate: Self.littleEndianUInt32(data, offset: chunkStart + 4),
                    bitsPerSample: Self.littleEndianUInt16(data, offset: chunkStart + 14)
                )
            } else if identifier == "data" {
                sampleData = data.subdata(in: chunkStart..<chunkEnd)
            }
            offset = chunkStart + chunkSize + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard let format, let sampleData else { throw WAVError.missingChunks(url.path) }
        guard format.audioFormat == 1,
              format.channels == 1,
              format.sampleRate == 16_000,
              format.bitsPerSample == 16 else {
            throw WAVError.unsupportedFormat(
                "\(url.path) must be 16 kHz, mono, 16-bit PCM WAV for an engine-neutral comparison"
            )
        }

        var decoded: [Float] = []
        decoded.reserveCapacity(sampleData.count / 2)
        var sampleOffset = 0
        while sampleOffset + 1 < sampleData.count {
            let raw = UInt16(sampleData[sampleOffset]) | UInt16(sampleData[sampleOffset + 1]) << 8
            decoded.append(Float(Int16(bitPattern: raw)) / 32_768)
            sampleOffset += 2
        }
        samples = decoded
        durationSeconds = Double(decoded.count) / 16_000
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> Int {
        guard offset + 1 < data.count else { return 0 }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> Int {
        guard offset + 3 < data.count else { return 0 }
        return Int(data[offset])
            | Int(data[offset + 1]) << 8
            | Int(data[offset + 2]) << 16
            | Int(data[offset + 3]) << 24
    }
}

enum WAVError: Error, LocalizedError {
    case invalidContainer(String)
    case missingChunks(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidContainer(let path): return "Not a RIFF/WAVE file: \(path)"
        case .missingChunks(let path): return "Missing fmt or data chunk: \(path)"
        case .unsupportedFormat(let message): return message
        }
    }
}
