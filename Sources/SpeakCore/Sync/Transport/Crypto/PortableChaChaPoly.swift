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

    // swiftlint:disable:next identifier_name - RFC 8439 names the state and its indices s, a, b, c, d.
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

    /// `blocks` must be a whole number of 16-byte blocks. Names follow
    /// poly1305-donna: `rLimbs` is r, `rTimes5` is s and `acc` is h.
    static func authenticate(blocks: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(blocks.count % 16 == 0 && key.count == 32)
        let clamped: [UInt32] = [
            word(key, 0) & 0x3ff_ffff,
            (word(key, 3) >> 2) & 0x3ff_ff03,
            (word(key, 6) >> 4) & 0x3ff_c0ff,
            (word(key, 9) >> 6) & 0x3f0_3fff,
            (word(key, 12) >> 8) & 0x00f_ffff
        ]
        let rLimbs = clamped.map { UInt64($0) }
        let rTimes5 = clamped.map { UInt64($0 * 5) }
        var acc: [UInt32] = [0, 0, 0, 0, 0]
        var offset = 0
        while offset < blocks.count {
            acc[0] &+= word(blocks, offset) & mask
            acc[1] &+= (word(blocks, offset + 3) >> 2) & mask
            acc[2] &+= (word(blocks, offset + 6) >> 4) & mask
            acc[3] &+= (word(blocks, offset + 9) >> 6) & mask
            acc[4] &+= (word(blocks, offset + 12) >> 8) | (1 << 24)
            let wide = acc.map { UInt64($0) }
            var product: [UInt64] = (0..<5).map { limb in
                var total: UInt64 = 0
                for index in 0..<5 {
                    let other = limb - index
                    total += wide[index] * (other >= 0 ? rLimbs[other] : rTimes5[other + 5])
                }
                return total
            }
            var carry: UInt64 = 0
            for index in 0..<5 {
                product[index] += carry
                carry = product[index] >> 26
                acc[index] = UInt32(product[index] & UInt64(mask))
            }
            acc[0] &+= UInt32(carry) &* 5
            let carry0 = acc[0] >> 26
            acc[0] &= mask
            acc[1] &+= carry0
            offset += 16
        }
        return finish(acc, key: key)
    }

    private static func finish(_ input: [UInt32], key: [UInt8]) -> [UInt8] {
        var acc = input
        var carry = acc[1] >> 26; acc[1] &= mask
        acc[2] &+= carry; carry = acc[2] >> 26; acc[2] &= mask
        acc[3] &+= carry; carry = acc[3] >> 26; acc[3] &= mask
        acc[4] &+= carry; carry = acc[4] >> 26; acc[4] &= mask
        acc[0] &+= carry &* 5; carry = acc[0] >> 26; acc[0] &= mask
        acc[1] &+= carry

        // acc + -p, kept only when acc >= p, chosen without branching on secrets.
        var minusP: [UInt32] = [0, 0, 0, 0, 0]
        minusP[0] = acc[0] &+ 5; carry = minusP[0] >> 26; minusP[0] &= mask
        minusP[1] = acc[1] &+ carry; carry = minusP[1] >> 26; minusP[1] &= mask
        minusP[2] = acc[2] &+ carry; carry = minusP[2] >> 26; minusP[2] &= mask
        minusP[3] = acc[3] &+ carry; carry = minusP[3] >> 26; minusP[3] &= mask
        minusP[4] = acc[4] &+ carry &- (1 << 26)
        let select = (minusP[4] >> 31) &- 1
        for index in 0..<5 { acc[index] = (acc[index] & ~select) | (minusP[index] & select) }

        let words: [UInt32] = [
            acc[0] | (acc[1] << 26),
            (acc[1] >> 6) | (acc[2] << 20),
            (acc[2] >> 12) | (acc[3] << 14),
            (acc[3] >> 18) | (acc[4] << 8)
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
