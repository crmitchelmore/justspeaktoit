package com.justspeaktoit.android.sendtomac

import java.security.SecureRandom

/**
 * X25519 (RFC 7748) for the Send to Mac handshake, ported from TweetNaCl's `crypto_scalarmult`.
 *
 * The platform only offers X25519 from API 33 and the app supports API 29, so the Mac's
 * Curve25519 key agreement is computed here. It is constant time: the ladder swaps with masks,
 * never with branches on secret bits. `X25519Test` checks it against RFC 7748 and the Mac's
 * vectors in `send_to_mac_protocol.json`.
 */
internal object X25519 {
    const val KEY_BYTES = 32

    private const val LIMBS = 16
    private val basePoint = ByteArray(KEY_BYTES).also { it[0] = 9 }
    private val a24 = LongArray(LIMBS).also {
        it[0] = 0xDB41
        it[1] = 1
    }

    /** A new random private key. */
    fun generatePrivateKey(random: SecureRandom = SecureRandom()): ByteArray =
        ByteArray(KEY_BYTES).also(random::nextBytes)

    fun publicKey(privateKey: ByteArray): ByteArray = scalarMult(privateKey, basePoint)

    /** The shared secret of [privateKey] and the peer's [publicKey]. */
    fun sharedSecret(privateKey: ByteArray, publicKey: ByteArray): ByteArray = scalarMult(privateKey, publicKey)

    private fun scalarMult(scalar: ByteArray, point: ByteArray): ByteArray {
        require(scalar.size == KEY_BYTES) { "An X25519 private key has 32 bytes" }
        require(point.size == KEY_BYTES) { "An X25519 public key has 32 bytes" }
        val z = scalar.copyOf()
        z[31] = ((z[31].toInt() and 127) or 64).toByte()
        z[0] = (z[0].toInt() and 248).toByte()
        val x = unpack(point)
        val a = LongArray(LIMBS)
        val b = x.copyOf()
        val c = LongArray(LIMBS)
        val d = LongArray(LIMBS)
        val e = LongArray(LIMBS)
        val f = LongArray(LIMBS)
        a[0] = 1
        d[0] = 1
        for (i in 254 downTo 0) {
            val bit = ((z[i ushr 3].toInt() and 0xff) ushr (i and 7)) and 1
            swap(a, b, bit)
            swap(c, d, bit)
            add(e, a, c)
            sub(a, a, c)
            add(c, b, d)
            sub(b, b, d)
            mul(d, e, e)
            mul(f, a, a)
            mul(a, c, a)
            mul(c, b, e)
            add(e, a, c)
            sub(a, a, c)
            mul(b, a, a)
            sub(c, d, f)
            mul(a, c, a24)
            add(a, a, d)
            mul(c, c, a)
            mul(a, d, f)
            mul(d, b, x)
            mul(b, e, e)
            swap(a, b, bit)
            swap(c, d, bit)
        }
        invert(c, c)
        mul(a, a, c)
        return pack(a)
    }

    private fun carry(o: LongArray) {
        for (i in 0 until LIMBS) {
            o[i] += 1L shl 16
            val c = o[i] shr 16
            if (i < LIMBS - 1) o[i + 1] += c - 1 else o[0] += 38 * (c - 1)
            o[i] -= c shl 16
        }
    }

    /** Swaps [p] and [q] when [bit] is 1, without branching on it. */
    private fun swap(p: LongArray, q: LongArray, bit: Int) {
        val mask = (bit - 1L).inv()
        for (i in 0 until LIMBS) {
            val t = mask and (p[i] xor q[i])
            p[i] = p[i] xor t
            q[i] = q[i] xor t
        }
    }

    private fun pack(n: LongArray): ByteArray {
        val t = n.copyOf()
        val m = LongArray(LIMBS)
        carry(t)
        carry(t)
        carry(t)
        repeat(2) {
            m[0] = t[0] - 0xffed
            for (i in 1 until LIMBS - 1) {
                m[i] = t[i] - 0xffff - ((m[i - 1] shr 16) and 1)
                m[i - 1] = m[i - 1] and 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] shr 16) and 1)
            val borrow = ((m[15] shr 16) and 1).toInt()
            m[14] = m[14] and 0xffff
            swap(t, m, 1 - borrow)
        }
        val out = ByteArray(KEY_BYTES)
        for (i in 0 until LIMBS) {
            out[2 * i] = (t[i] and 0xff).toByte()
            out[2 * i + 1] = ((t[i] shr 8) and 0xff).toByte()
        }
        return out
    }

    private fun unpack(n: ByteArray): LongArray {
        val o = LongArray(LIMBS)
        for (i in 0 until LIMBS) {
            o[i] = (n[2 * i].toLong() and 0xff) + ((n[2 * i + 1].toLong() and 0xff) shl 8)
        }
        o[15] = o[15] and 0x7fff
        return o
    }

    private fun add(o: LongArray, a: LongArray, b: LongArray) {
        for (i in 0 until LIMBS) o[i] = a[i] + b[i]
    }

    private fun sub(o: LongArray, a: LongArray, b: LongArray) {
        for (i in 0 until LIMBS) o[i] = a[i] - b[i]
    }

    private fun mul(o: LongArray, a: LongArray, b: LongArray) {
        val t = LongArray(2 * LIMBS - 1)
        for (i in 0 until LIMBS) {
            for (j in 0 until LIMBS) t[i + j] += a[i] * b[j]
        }
        for (i in 0 until LIMBS - 1) t[i] += 38 * t[i + LIMBS]
        for (i in 0 until LIMBS) o[i] = t[i]
        carry(o)
        carry(o)
    }

    private fun invert(o: LongArray, input: LongArray) {
        val c = input.copyOf()
        for (step in 253 downTo 0) {
            mul(c, c, c)
            if (step != 2 && step != 4) mul(c, c, input)
        }
        c.copyInto(o)
    }
}
