import Foundation

/// Reads the CPU slices a Mach-O file contains from its headers, so an
/// installer can confirm a downloaded executable is built for this Mac
/// before replacing anything (issue #775).
enum MachOArchitectures {
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatCigam: UInt32 = 0xBEBA_FECA
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let machCigam64: UInt32 = 0xCFFA_EDFE
    private static let machMagic32: UInt32 = 0xFEED_FACE
    private static let machCigam32: UInt32 = 0xCEFA_EDFE
    private static let cpuTypeIntel64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    enum ReadError: LocalizedError, Equatable {
        case notMachO

        var errorDescription: String? { "The downloaded file is not a macOS executable." }
    }

    static func architectures(of fileURL: URL) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        return try architectures(in: header)
    }

    /// Parses the leading bytes of a file: a thin Mach-O header, or a fat
    /// header followed by its architecture table.
    static func architectures(in header: Data) throws -> Set<String> {
        guard header.count >= 8 else { throw ReadError.notMachO }
        let magic = header.readUInt32(at: 0, bigEndian: true)
        switch magic {
        case fatMagic, fatCigam:
            let count = Int(header.readUInt32(at: 4, bigEndian: true))
            guard count > 0, count < 64 else { throw ReadError.notMachO }
            var archs: Set<String> = []
            for index in 0..<count {
                let offset = 8 + index * 20
                guard header.count >= offset + 4 else { throw ReadError.notMachO }
                archs.insert(name(forCPUType: header.readUInt32(at: offset, bigEndian: true)))
            }
            return archs
        case machMagic64, machMagic32:
            // The magic read as-is, so the file's fields are big-endian.
            return [name(forCPUType: header.readUInt32(at: 4, bigEndian: true))]
        case machCigam64, machCigam32:
            // Byte-swapped magic: a little-endian file (every modern Mac binary).
            return [name(forCPUType: header.readUInt32(at: 4, bigEndian: false))]
        default:
            throw ReadError.notMachO
        }
    }

    private static func name(forCPUType cpuType: UInt32) -> String {
        switch cpuType {
        case cpuTypeARM64: return "arm64"
        case cpuTypeIntel64: return "x86_64"
        default: return "cputype-\(cpuType)"
        }
    }
}

private extension Data {
    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32 {
        let bytes = self[startIndex + offset..<startIndex + offset + 4]
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return bigEndian ? value : value.byteSwapped
    }
}
