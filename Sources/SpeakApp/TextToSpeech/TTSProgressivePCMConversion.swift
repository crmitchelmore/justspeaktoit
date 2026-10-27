import Foundation

/// The native mixer uses standard Float32 mono buffers. The provider/decoder
/// contract stays little-endian signed PCM16; frame identity is unchanged.
enum TTSProgressivePCMConversion {
    static func samples(from bytes: Data) -> [Float]? {
        guard !bytes.isEmpty, bytes.count % MemoryLayout<Int16>.size == 0 else { return nil }
        return bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var samples: [Float] = []
            samples.reserveCapacity(bytes.count / MemoryLayout<Int16>.size)
            for offset in stride(from: 0, to: bytes.count, by: MemoryLayout<Int16>.size) {
                let bits = source.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                let sample = Int16(bitPattern: UInt16(littleEndian: bits))
                samples.append(Float(sample) / 32_768)
            }
            return samples
        }
    }
}
