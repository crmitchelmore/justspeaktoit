import Foundation

// MARK: - Portable X25519 (RFC 7748)
//
// A constant-time Montgomery ladder over 16-bit limbs, following the
// public-domain TweetNaCl field arithmetic. It runs once per Send to Mac
// connection in the portable receiver, so clarity wins over speed.

enum PortableX25519 {
    static let keyByteCount = 32

    private typealias Field = [Int64]

    /// 32 random bytes from the system CSPRNG; clamped when used.
    static func generatePrivateKey() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<keyByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    static func publicKey(privateKey: [UInt8]) -> [UInt8] {
        var basePoint = [UInt8](repeating: 0, count: keyByteCount)
        basePoint[0] = 9
        return scalarMultiply(privateKey, basePoint)
    }

    /// The shared secret, or nil for a malformed key. Callers still reject an
    /// all-zero result, which a low-order peer key produces.
    static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == keyByteCount, peerPublicKey.count == keyByteCount else { return nil }
        return scalarMultiply(privateKey, peerPublicKey)
    }

    // The ladder registers follow TweetNaCl's a–f: regA/regC hold x2/z2 and
    // regB/regD hold x3/z3 of RFC 7748's Montgomery ladder.
    private static func scalarMultiply(_ scalar: [UInt8], _ point: [UInt8]) -> [UInt8] {
        var clamped = scalar
        clamped[31] = (scalar[31] & 127) | 64
        clamped[0] &= 248
        let pointU = unpack(point)
        var regA = zero(), regB = pointU, regC = zero(), regD = zero()
        regA[0] = 1
        regD[0] = 1
        let constant: Field = [0xDB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        for bitIndex in stride(from: 254, through: 0, by: -1) {
            let bit = Int64((clamped[bitIndex >> 3] >> UInt8(bitIndex & 7)) & 1)
            select(&regA, &regB, bit)
            select(&regC, &regD, bit)
            var regE = add(regA, regC)
            regA = subtract(regA, regC)
            regC = add(regB, regD)
            regB = subtract(regB, regD)
            regD = square(regE)
            let regF = square(regA)
            regA = multiply(regC, regA)
            regC = multiply(regB, regE)
            regE = add(regA, regC)
            regA = subtract(regA, regC)
            regB = square(regA)
            regC = subtract(regD, regF)
            regA = multiply(regC, constant)
            regA = add(regA, regD)
            regC = multiply(regC, regA)
            regA = multiply(regD, regF)
            regD = multiply(regB, pointU)
            regB = square(regE)
            select(&regA, &regB, bit)
            select(&regC, &regD, bit)
        }
        return pack(multiply(regA, invert(regC)))
    }

    private static func zero() -> Field { Field(repeating: 0, count: 16) }

    private static func carry(_ field: inout Field) {
        field.withUnsafeMutableBufferPointer { buffer in
            guard let limbs = buffer.baseAddress else { return }
            var index = 0
            while index < 16 {
                limbs[index] &+= 1 << 16
                let overflow = limbs[index] >> 16
                if index < 15 {
                    limbs[index + 1] &+= overflow &- 1
                } else {
                    limbs[0] &+= 38 &* (overflow &- 1)
                }
                limbs[index] &-= overflow << 16
                index += 1
            }
        }
    }

    /// Swaps `first` and `second` when `bit` is 1, without branching on it.
    private static func select(_ first: inout Field, _ second: inout Field, _ bit: Int64) {
        let mask = ~(bit &- 1)
        first.withUnsafeMutableBufferPointer { firstBuffer in
            second.withUnsafeMutableBufferPointer { secondBuffer in
                guard let lhs = firstBuffer.baseAddress, let rhs = secondBuffer.baseAddress else { return }
                var index = 0
                while index < 16 {
                    let difference = mask & (lhs[index] ^ rhs[index])
                    lhs[index] ^= difference
                    rhs[index] ^= difference
                    index += 1
                }
            }
        }
    }

    private static func pack(_ input: Field) -> [UInt8] {
        var value = input
        carry(&value)
        carry(&value)
        carry(&value)
        var reduced = zero()
        for _ in 0..<2 {
            reduced[0] = value[0] - 0xffed
            for index in 1..<15 {
                reduced[index] = value[index] - 0xffff - ((reduced[index - 1] >> 16) & 1)
                reduced[index - 1] &= 0xffff
            }
            reduced[15] = value[15] - 0x7fff - ((reduced[14] >> 16) & 1)
            let borrow = (reduced[15] >> 16) & 1
            reduced[14] &= 0xffff
            select(&value, &reduced, 1 - borrow)
        }
        var output = [UInt8](repeating: 0, count: keyByteCount)
        for index in 0..<16 {
            output[2 * index] = UInt8(truncatingIfNeeded: value[index])
            output[2 * index + 1] = UInt8(truncatingIfNeeded: value[index] >> 8)
        }
        return output
    }

    private static func unpack(_ bytes: [UInt8]) -> Field {
        var field = zero()
        for index in 0..<16 { field[index] = Int64(bytes[2 * index]) + (Int64(bytes[2 * index + 1]) << 8) }
        field[15] &= 0x7fff
        return field
    }

    private static func add(_ lhs: Field, _ rhs: Field) -> Field {
        var sum = lhs
        for index in 0..<16 { sum[index] &+= rhs[index] }
        return sum
    }

    private static func subtract(_ lhs: Field, _ rhs: Field) -> Field {
        var difference = lhs
        for index in 0..<16 { difference[index] &-= rhs[index] }
        return difference
    }

    // Hot path of the ladder: unchecked pointer arithmetic keeps unoptimised
    // (debug and test) builds fast enough for a handshake per connection.
    private static func multiply(_ lhs: Field, _ rhs: Field) -> Field {
        var product = zero()
        lhs.withUnsafeBufferPointer { lhsBuffer in
            rhs.withUnsafeBufferPointer { rhsBuffer in
                product.withUnsafeMutableBufferPointer { productBuffer in
                    guard let left = lhsBuffer.baseAddress, let right = rhsBuffer.baseAddress,
                          let out = productBuffer.baseAddress else { return }
                    var wide = (Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                                Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                                Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                                Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
                    withUnsafeMutableBytes(of: &wide) { raw in
                        guard let terms = raw.baseAddress?.assumingMemoryBound(to: Int64.self) else { return }
                        var row = 0
                        while row < 16 {
                            let leftLimb = left[row]
                            var column = 0
                            while column < 16 {
                                terms[row + column] &+= leftLimb &* right[column]
                                column += 1
                            }
                            row += 1
                        }
                        row = 0
                        while row < 15 {
                            out[row] = terms[row] &+ 38 &* terms[row + 16]
                            row += 1
                        }
                        out[15] = terms[15]
                    }
                }
            }
        }
        carry(&product)
        carry(&product)
        return product
    }

    private static func square(_ value: Field) -> Field { multiply(value, value) }

    private static func invert(_ input: Field) -> Field {
        var result = input
        for exponent in stride(from: 253, through: 0, by: -1) {
            result = square(result)
            if exponent != 2 && exponent != 4 { result = multiply(result, input) }
        }
        return result
    }
}
