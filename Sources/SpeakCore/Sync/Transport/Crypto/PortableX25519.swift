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

    private static func scalarMultiply(_ scalar: [UInt8], _ point: [UInt8]) -> [UInt8] {
        var clamped = scalar
        clamped[31] = (scalar[31] & 127) | 64
        clamped[0] &= 248
        let x = unpack(point)
        var a = zero(), b = x, c = zero(), d = zero()
        a[0] = 1
        d[0] = 1
        let constant: Field = [0xDB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        for bitIndex in stride(from: 254, through: 0, by: -1) {
            let bit = Int64((clamped[bitIndex >> 3] >> UInt8(bitIndex & 7)) & 1)
            select(&a, &b, bit)
            select(&c, &d, bit)
            var e = add(a, c)
            a = subtract(a, c)
            c = add(b, d)
            b = subtract(b, d)
            d = square(e)
            let f = square(a)
            a = multiply(c, a)
            c = multiply(b, e)
            e = add(a, c)
            a = subtract(a, c)
            b = square(a)
            c = subtract(d, f)
            a = multiply(c, constant)
            a = add(a, d)
            c = multiply(c, a)
            a = multiply(d, f)
            d = multiply(b, x)
            b = square(e)
            select(&a, &b, bit)
            select(&c, &d, bit)
        }
        return pack(multiply(a, invert(c)))
    }

    private static func zero() -> Field { Field(repeating: 0, count: 16) }

    private static func carry(_ o: inout Field) {
        o.withUnsafeMutableBufferPointer { buffer in
            guard let o = buffer.baseAddress else { return }
            var index = 0
            while index < 16 {
                o[index] &+= 1 << 16
                let c = o[index] >> 16
                if index < 15 {
                    o[index + 1] &+= c &- 1
                } else {
                    o[0] &+= 38 &* (c &- 1)
                }
                o[index] &-= c << 16
                index += 1
            }
        }
    }

    /// Swaps `p` and `q` when `bit` is 1, without branching on it.
    private static func select(_ p: inout Field, _ q: inout Field, _ bit: Int64) {
        let mask = ~(bit &- 1)
        p.withUnsafeMutableBufferPointer { p in
            q.withUnsafeMutableBufferPointer { q in
                guard let p = p.baseAddress, let q = q.baseAddress else { return }
                var index = 0
                while index < 16 {
                    let t = mask & (p[index] ^ q[index])
                    p[index] ^= t
                    q[index] ^= t
                    index += 1
                }
            }
        }
    }

    private static func pack(_ n: Field) -> [UInt8] {
        var t = n
        carry(&t)
        carry(&t)
        carry(&t)
        var m = zero()
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for index in 1..<15 {
                m[index] = t[index] - 0xffff - ((m[index - 1] >> 16) & 1)
                m[index - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            select(&t, &m, 1 - borrow)
        }
        var output = [UInt8](repeating: 0, count: keyByteCount)
        for index in 0..<16 {
            output[2 * index] = UInt8(truncatingIfNeeded: t[index])
            output[2 * index + 1] = UInt8(truncatingIfNeeded: t[index] >> 8)
        }
        return output
    }

    private static func unpack(_ n: [UInt8]) -> Field {
        var o = zero()
        for index in 0..<16 { o[index] = Int64(n[2 * index]) + (Int64(n[2 * index + 1]) << 8) }
        o[15] &= 0x7fff
        return o
    }

    private static func add(_ a: Field, _ b: Field) -> Field {
        var o = a
        for index in 0..<16 { o[index] &+= b[index] }
        return o
    }

    private static func subtract(_ a: Field, _ b: Field) -> Field {
        var o = a
        for index in 0..<16 { o[index] &-= b[index] }
        return o
    }

    // Hot path of the ladder: unchecked pointer arithmetic keeps unoptimised
    // (debug and test) builds fast enough for a handshake per connection.
    private static func multiply(_ a: Field, _ b: Field) -> Field {
        var o = zero()
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                o.withUnsafeMutableBufferPointer { o in
                    guard let a = a.baseAddress, let b = b.baseAddress, let o = o.baseAddress else { return }
                    var t = (Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                             Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                             Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0),
                             Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
                    withUnsafeMutableBytes(of: &t) { raw in
                        guard let t = raw.baseAddress?.assumingMemoryBound(to: Int64.self) else { return }
                        var i = 0
                        while i < 16 {
                            let ai = a[i]
                            var j = 0
                            while j < 16 {
                                t[i + j] &+= ai &* b[j]
                                j += 1
                            }
                            i += 1
                        }
                        i = 0
                        while i < 15 {
                            o[i] = t[i] &+ 38 &* t[i + 16]
                            i += 1
                        }
                        o[15] = t[15]
                    }
                }
            }
        }
        carry(&o)
        carry(&o)
        return o
    }

    private static func square(_ a: Field) -> Field { multiply(a, a) }

    private static func invert(_ input: Field) -> Field {
        var c = input
        for exponent in stride(from: 253, through: 0, by: -1) {
            c = square(c)
            if exponent != 2 && exponent != 4 { c = multiply(c, input) }
        }
        return c
    }
}
