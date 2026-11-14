import Foundation

// MARK: - Portable ChaCha20-Poly1305 (RFC 8439)
//
// Used only by the portable Send to Mac v2 receiver. Every frame's AEAD input
// (padded AAD, padded ciphertext and the two lengths) is a whole number of
// 16-byte blocks, so Poly1305 here only processes full blocks.

enum PortableChaChaPoly {
    static let keyByteCount = 32
    static let nonceByteCount = 12
    static let tagByteCount = 16

    /// Ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], authenticating aad: [UInt8]) -> [UInt8] {
        precondition(key.count == keyByteCount && nonce.count == nonceByteCount)
        let ciphertext = PortableChaCha20.xor(plaintext, key: key, nonce: nonce, counter: 1)
        return ciphertext + tag(ciphertext: ciphertext, key: key, nonce: nonce, aad: aad)
    }

    /// The plaintext, or nil when the tag does not authenticate the frame.
    static func open(_ frame: [UInt8], key: [UInt8], nonce: [UInt8], authenticating aad: [UInt8]) -> [UInt8]? {
        guard key.count == keyByteCount, nonce.count == nonceByteCount, frame.count >= tagByteCount else {
            return nil
        }
        let ciphertext = Array(frame.dropLast(tagByteCount))
        let expected = tag(ciphertext: ciphertext, key: key, nonce: nonce, aad: aad)
        var difference: UInt8 = 0
        for (left, right) in zip(expected, frame.suffix(tagByteCount)) { difference |= left ^ right }
        guard difference == 0 else { return nil }
        return PortableChaCha20.xor(ciphertext, key: key, nonce: nonce, counter: 1)
    }

    private static func tag(ciphertext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8] {
        let oneTimeKey = Array(PortableChaCha20.block(key: key, nonce: nonce, counter: 0).prefix(32))
        var message = aad + padding(aad.count) + ciphertext + padding(ciphertext.count)
        message += littleEndian(UInt64(aad.count)) + littleEndian(UInt64(ciphertext.count))
        return PortablePoly1305.authenticate(blocks: message, key: oneTimeKey)
    }

    private static func padding(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: (16 - count % 16) % 16)
    }

    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}

enum PortableChaCha20 {
    static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        var state: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        for index in 0..<8 { state.append(word(key, index * 4)) }
        state.append(counter)
        for index in 0..<3 { state.append(word(nonce, index * 4)) }
        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for index in 0..<16 {
            let value = working[index] &+ state[index]
            for shift in 0..<4 { output.append(UInt8(truncatingIfNeeded: value >> UInt32(shift * 8))) }
        }
        return output
    }

    static func xor(_ input: [UInt8], key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        var output = input
        var blockCounter = counter
        var offset = 0
        while offset < output.count {
            let stream = block(key: key, nonce: nonce, counter: blockCounter)
            for index in 0..<min(64, output.count - offset) { output[offset + index] ^= stream[index] }
            offset += 64
            blockCounter &+= 1
        }
        return output
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    // swiftlint:disable:next identifier_name
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotateLeft(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotateLeft(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotateLeft(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotateLeft(s[b] ^ s[c], 7)
    }
}

/// Poly1305 with 26-bit limbs (the public-domain poly1305-donna layout).
enum PortablePoly1305 {
    private static let mask: UInt32 = 0x3ff_ffff

    /// `blocks` must be a whole number of 16-byte blocks.
    static func authenticate(blocks: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(blocks.count % 16 == 0 && key.count == 32)
        let r0 = word(key, 0) & 0x3ff_ffff
        let r1 = (word(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (word(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (word(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (word(key, 12) >> 8) & 0x00f_ffff
        let s1 = UInt64(r1 * 5), s2 = UInt64(r2 * 5), s3 = UInt64(r3 * 5), s4 = UInt64(r4 * 5)
        let r = [UInt64(r0), UInt64(r1), UInt64(r2), UInt64(r3), UInt64(r4)]
        var h: [UInt32] = [0, 0, 0, 0, 0]
        var offset = 0
        while offset < blocks.count {
            h[0] &+= word(blocks, offset) & mask
            h[1] &+= (word(blocks, offset + 3) >> 2) & mask
            h[2] &+= (word(blocks, offset + 6) >> 4) & mask
            h[3] &+= (word(blocks, offset + 9) >> 6) & mask
            h[4] &+= (word(blocks, offset + 12) >> 8) | (1 << 24)
            let h64 = h.map { UInt64($0) }
            let d0 = h64[0] * r[0] + h64[1] * s4 + h64[2] * s3 + h64[3] * s2 + h64[4] * s1
            var d1 = h64[0] * r[1] + h64[1] * r[0] + h64[2] * s4 + h64[3] * s3 + h64[4] * s2
            var d2 = h64[0] * r[2] + h64[1] * r[1] + h64[2] * r[0] + h64[3] * s4 + h64[4] * s3
            var d3 = h64[0] * r[3] + h64[1] * r[2] + h64[2] * r[1] + h64[3] * r[0] + h64[4] * s4
            var d4 = h64[0] * r[4] + h64[1] * r[3] + h64[2] * r[2] + h64[3] * r[1] + h64[4] * r[0]
            var carry = d0 >> 26; h[0] = UInt32(d0 & UInt64(mask))
            d1 += carry; carry = d1 >> 26; h[1] = UInt32(d1 & UInt64(mask))
            d2 += carry; carry = d2 >> 26; h[2] = UInt32(d2 & UInt64(mask))
            d3 += carry; carry = d3 >> 26; h[3] = UInt32(d3 & UInt64(mask))
            d4 += carry; carry = d4 >> 26; h[4] = UInt32(d4 & UInt64(mask))
            h[0] &+= UInt32(carry) &* 5
            let carry0 = h[0] >> 26
            h[0] &= mask
            h[1] &+= carry0
            offset += 16
        }
        return finish(h, key: key)
    }

    private static func finish(_ input: [UInt32], key: [UInt8]) -> [UInt8] {
        var h = input
        var carry = h[1] >> 26; h[1] &= mask
        h[2] &+= carry; carry = h[2] >> 26; h[2] &= mask
        h[3] &+= carry; carry = h[3] >> 26; h[3] &= mask
        h[4] &+= carry; carry = h[4] >> 26; h[4] &= mask
        h[0] &+= carry &* 5; carry = h[0] >> 26; h[0] &= mask
        h[1] &+= carry

        // h + -p, kept only when h >= p, chosen without branching on secrets.
        var g: [UInt32] = [0, 0, 0, 0, 0]
        g[0] = h[0] &+ 5; carry = g[0] >> 26; g[0] &= mask
        g[1] = h[1] &+ carry; carry = g[1] >> 26; g[1] &= mask
        g[2] = h[2] &+ carry; carry = g[2] >> 26; g[2] &= mask
        g[3] = h[3] &+ carry; carry = g[3] >> 26; g[3] &= mask
        g[4] = h[4] &+ carry &- (1 << 26)
        let select = (g[4] >> 31) &- 1
        for index in 0..<5 { h[index] = (h[index] & ~select) | (g[index] & select) }

        let words: [UInt32] = [
            h[0] | (h[1] << 26),
            (h[1] >> 6) | (h[2] << 20),
            (h[2] >> 12) | (h[3] << 14),
            (h[3] >> 18) | (h[4] << 8)
        ]
        var tag: [UInt8] = []
        var sum: UInt64 = 0
        for index in 0..<4 {
            sum = UInt64(words[index]) + UInt64(word(key, 16 + index * 4)) + (sum >> 32)
            let value = UInt32(truncatingIfNeeded: sum)
            for shift in 0..<4 { tag.append(UInt8(truncatingIfNeeded: value >> UInt32(shift * 8))) }
        }
        return tag
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
