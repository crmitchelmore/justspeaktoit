import Foundation

// MARK: - Portable SHA-256, HMAC and HKDF
//
// The portable (Windows and Linux) build has no CryptoKit. These primitives
// implement FIPS 180-4 SHA-256, RFC 2104 HMAC and RFC 5869 HKDF in plain Swift
// for the Send to Mac v2 key schedule only. Known-answer tests pin them to the
// RFC vectors, and macOS tests check them byte for byte against CryptoKit.

/// Streaming SHA-256.
struct PortableSHA256 {
    static let digestByteCount = 32
    static let blockByteCount = 64

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2
    ]

    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    ]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0

    init() {}

    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var hasher = PortableSHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    mutating func update(_ bytes: [UInt8]) {
        byteCount &+= UInt64(bytes.count)
        pending.append(contentsOf: bytes)
        var offset = 0
        while pending.count - offset >= Self.blockByteCount {
            compress(pending, at: offset)
            offset += Self.blockByteCount
        }
        pending.removeFirst(offset)
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = byteCount &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % Self.blockByteCount != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var offset = 0
        while offset < tail.count {
            compress(tail, at: offset)
            offset += Self.blockByteCount
        }
        pending = []
        var digest: [UInt8] = []
        digest.reserveCapacity(Self.digestByteCount)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private mutating func compress(_ block: [UInt8], at offset: Int) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = offset + index * 4
            schedule[index] = UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let early = schedule[index - 15]
            let late = schedule[index - 2]
            let sigma0 = Self.rotateRight(early, 7) ^ Self.rotateRight(early, 18) ^ (early >> 3)
            let sigma1 = Self.rotateRight(late, 17) ^ Self.rotateRight(late, 19) ^ (late >> 10)
            schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
        }
        var work = state
        for index in 0..<64 {
            let sum1 = Self.rotateRight(work[4], 6) ^ Self.rotateRight(work[4], 11) ^ Self.rotateRight(work[4], 25)
            let choose = (work[4] & work[5]) ^ (~work[4] & work[6])
            let temp1 = work[7] &+ sum1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let sum0 = Self.rotateRight(work[0], 2) ^ Self.rotateRight(work[0], 13) ^ Self.rotateRight(work[0], 22)
            let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
            let temp2 = sum0 &+ majority
            work[7] = work[6]
            work[6] = work[5]
            work[5] = work[4]
            work[4] = work[3] &+ temp1
            work[3] = work[2]
            work[2] = work[1]
            work[1] = work[0]
            work[0] = temp1 &+ temp2
        }
        for index in 0..<8 { state[index] = state[index] &+ work[index] }
    }
}

/// HMAC-SHA256 (RFC 2104).
enum PortableHMACSHA256 {
    static func authenticationCode(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key.count > PortableSHA256.blockByteCount ? PortableSHA256.hash(key) : key
        block += [UInt8](repeating: 0, count: PortableSHA256.blockByteCount - block.count)
        var inner = PortableSHA256()
        inner.update(block.map { $0 ^ 0x36 })
        inner.update(message)
        var outer = PortableSHA256()
        outer.update(block.map { $0 ^ 0x5c })
        outer.update(inner.finalize())
        return outer.finalize()
    }
}

/// HKDF-SHA256 (RFC 5869).
enum PortableHKDF {
    static func deriveKey(inputKeyMaterial: [UInt8], salt: [UInt8], info: [UInt8], outputByteCount: Int) -> [UInt8] {
        let extractSalt = salt.isEmpty ? [UInt8](repeating: 0, count: PortableSHA256.digestByteCount) : salt
        let pseudoRandomKey = PortableHMACSHA256.authenticationCode(key: extractSalt, message: inputKeyMaterial)
        var output: [UInt8] = []
        var previous: [UInt8] = []
        var counter: UInt8 = 1
        while output.count < outputByteCount {
            previous = PortableHMACSHA256.authenticationCode(key: pseudoRandomKey, message: previous + info + [counter])
            output += previous
            counter &+= 1
        }
        return Array(output.prefix(outputByteCount))
    }
}
