package com.justspeaktoit.android.sendtomac

import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The encrypted channel failed: the Mac's handshake was invalid or a frame did not open. */
internal class TransportSecurityException(val kind: Kind) : Exception(kind.name) {
    enum class Kind {
        /** The Mac's key share was not valid. */
        MalformedHandshake,

        /** A frame failed authentication: wrong key, tampered, replayed or reordered. */
        UnauthenticatedFrame,
    }
}

/** The random secret a Mac issues when a phone pairs; later sessions are keyed with it, not the code. */
internal class DeviceCredential(val id: UUID, secret: ByteArray) {
    private val secretBytes = secret.copyOf()
    val secret: ByteArray get() = secretBytes.copyOf()

    /** The id's 16 bytes in RFC 4122 order, then the secret, as the Mac sends them. */
    fun wireBytes(): ByteArray = ByteBuffer.allocate(UUID_BYTES + secretBytes.size)
        .putLong(id.mostSignificantBits)
        .putLong(id.leastSignificantBits)
        .put(secretBytes)
        .array()

    override fun equals(other: Any?): Boolean =
        other is DeviceCredential && other.id == id && other.secretBytes.contentEquals(secretBytes)

    override fun hashCode(): Int = 31 * id.hashCode() + secretBytes.contentHashCode()

    companion object {
        private const val UUID_BYTES = 16

        fun fromWireBytes(bytes: ByteArray, protocol: SendToMacProtocol): DeviceCredential? {
            if (bytes.size != protocol.sizes.credentialId + protocol.sizes.credentialSecret) return null
            val buffer = ByteBuffer.wrap(bytes)
            val id = UUID(buffer.getLong(), buffer.getLong())
            return DeviceCredential(id, bytes.copyOfRange(protocol.sizes.credentialId, bytes.size))
        }
    }
}

/** What the phone proves in the handshake: the six-digit code at pairing, later the credential. */
internal sealed interface PairingSecret {
    class Code(val code: String) : PairingSecret

    class Credential(val credential: DeviceCredential) : PairingSecret
}

internal object TransportCrypto {
    private const val HMAC = "HmacSHA256"

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        parts.forEach(digest::update)
        return digest.digest()
    }

    /** HKDF-SHA256 (RFC 5869), as CryptoKit's `HKDF<SHA256>.deriveKey`. */
    fun hkdf(inputKeyMaterial: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance(HMAC).apply { init(SecretKeySpec(salt, HMAC)) }
        val pseudoRandomKey = extract.doFinal(inputKeyMaterial)
        val expand = Mac.getInstance(HMAC).apply { init(SecretKeySpec(pseudoRandomKey, HMAC)) }
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            expand.update(previous)
            expand.update(info)
            expand.update(counter.toByte())
            previous = expand.doFinal()
            val count = minOf(previous.size, length - written)
            previous.copyInto(output, written, 0, count)
            written += count
            counter++
        }
        return output
    }

    /** True when every byte is zero, checked without stopping early. */
    fun isAllZero(bytes: ByteArray): Boolean = bytes.fold(0) { bits, byte -> bits or byte.toInt() } == 0
}

/**
 * One direction of the sealed channel: ChaCha20-Poly1305 with the frame label as associated data
 * and the frame counter as the nonce, so frames open only in order and only once.
 */
internal class FrameCipher(key: ByteArray, private val protocol: SendToMacProtocol) {
    private val key = SecretKeySpec(key.copyOf(), "ChaCha20")
    private val associatedData = protocol.labels.frameAssociatedData.toByteArray(Charsets.UTF_8)

    var counter: Long = 0
        private set

    fun seal(plaintext: ByteArray): ByteArray {
        val cipher = newCipher()
        cipher.init(Cipher.ENCRYPT_MODE, key, IvParameterSpec(nonce()))
        cipher.updateAAD(associatedData)
        val frame = cipher.doFinal(plaintext)
        counter++
        return frame
    }

    fun open(frame: ByteArray): ByteArray {
        if (frame.size < protocol.sizes.tag) throw TransportSecurityException(TransportSecurityException.Kind.UnauthenticatedFrame)
        val plaintext = try {
            val cipher = newCipher()
            cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(nonce()))
            cipher.updateAAD(associatedData)
            cipher.doFinal(frame)
        } catch (_: GeneralSecurityException) {
            throw TransportSecurityException(TransportSecurityException.Kind.UnauthenticatedFrame)
        }
        counter++
        return plaintext
    }

    /** Four zero bytes, then the counter as a big-endian 64-bit integer. */
    private fun nonce(): ByteArray {
        if (counter == Long.MAX_VALUE) throw TransportSecurityException(TransportSecurityException.Kind.UnauthenticatedFrame)
        return ByteBuffer.allocate(protocol.sizes.nonce)
            .putLong(protocol.sizes.nonce - Long.SIZE_BYTES, counter)
            .array()
    }

    private fun newCipher(): Cipher {
        for (name in CIPHER_NAMES) {
            try {
                return Cipher.getInstance(name)
            } catch (_: GeneralSecurityException) {
                // Android's Conscrypt and the JVM name ChaCha20-Poly1305 differently.
            }
        }
        throw GeneralSecurityException("ChaCha20-Poly1305 is unavailable")
    }

    private companion object {
        val CIPHER_NAMES = listOf("ChaCha20/Poly1305/NoPadding", "ChaCha20-Poly1305")
    }
}

/** Both directions of an established session, from the phone's side. */
internal class SessionKeys(val outbound: FrameCipher, val inbound: FrameCipher)

/** The handshake state both ends share once each has the other's key share. */
internal class TransportKeySchedule private constructor(
    private val protocol: SendToMacProtocol,
    val sharedSecret: ByteArray,
    val transcriptHash: ByteArray,
) {
    /** The raw phone-to-Mac and Mac-to-phone keys. */
    fun directionKeys(preSharedKey: ByteArray): Pair<ByteArray, ByteArray> {
        val inputKeyMaterial = sharedSecret + preSharedKey
        fun key(info: String) = TransportCrypto.hkdf(
            inputKeyMaterial,
            transcriptHash,
            info.toByteArray(Charsets.UTF_8),
            protocol.sizes.key,
        )
        return key(protocol.labels.clientToServerInfo) to key(protocol.labels.serverToClientInfo)
    }

    /** The phone's ciphers: it seals with the phone-to-Mac key and opens with the other. */
    fun clientKeys(preSharedKey: ByteArray): SessionKeys {
        val (clientToServer, serverToClient) = directionKeys(preSharedKey)
        return SessionKeys(FrameCipher(clientToServer, protocol), FrameCipher(serverToClient, protocol))
    }

    companion object {
        fun derive(
            protocol: SendToMacProtocol,
            privateKey: ByteArray,
            peerPublicKey: ByteArray,
            clientFrame: ByteArray,
            serverFrame: ByteArray,
        ): TransportKeySchedule {
            val secret = X25519.sharedSecret(privateKey, peerPublicKey)
            // A low-order peer key yields an all-zero secret that an attacker can predict.
            if (TransportCrypto.isAllZero(secret)) {
                throw TransportSecurityException(TransportSecurityException.Kind.MalformedHandshake)
            }
            val transcript = MessageDigest.getInstance("SHA-256")
            transcript.update(protocol.labels.transcript.toByteArray(Charsets.UTF_8))
            for (frame in listOf(clientFrame, serverFrame)) {
                transcript.update(ByteBuffer.allocate(Int.SIZE_BYTES).putInt(frame.size).array())
                transcript.update(frame)
            }
            return TransportKeySchedule(protocol, secret, transcript.digest())
        }

        /** The key both devices hold before the handshake: from the code, or from the credential. */
        fun preSharedKey(protocol: SendToMacProtocol, secret: PairingSecret): ByteArray {
            val (material, salt) = when (secret) {
                is PairingSecret.Code -> secret.code.toByteArray(Charsets.UTF_8) to protocol.labels.pairingKeySalt
                is PairingSecret.Credential -> secret.credential.secret to protocol.labels.credentialKeySalt
            }
            return TransportCrypto.hkdf(
                material,
                salt.toByteArray(Charsets.UTF_8),
                protocol.labels.preSharedKeyInfo.toByteArray(Charsets.UTF_8),
                protocol.sizes.key,
            )
        }
    }
}

/** The phone's half of the handshake, from its key share to its sealed "client finished". */
internal class ClientHandshake(
    private val protocol: SendToMacProtocol,
    val secret: PairingSecret,
    private val privateKey: ByteArray = X25519.generatePrivateKey(),
) {
    val frame: ByteArray = PhoneMessages.keyShare(protocol.protocolVersion, X25519.publicKey(privateKey), secret)
        .toByteArray(Charsets.UTF_8)

    class Finished(val keys: SessionKeys, val frame: ByteArray)

    /** Derives the session from the Mac's key share and seals "client finished". */
    fun finish(serverFrame: ByteArray): Finished {
        val serverKey = MacMessages.keyShare(serverFrame, protocol)
            ?: throw TransportSecurityException(TransportSecurityException.Kind.MalformedHandshake)
        val schedule = TransportKeySchedule.derive(protocol, privateKey, serverKey, frame, serverFrame)
        val keys = schedule.clientKeys(TransportKeySchedule.preSharedKey(protocol, secret))
        val finished = keys.outbound.seal(protocol.labels.clientFinished.toByteArray(Charsets.UTF_8))
        return Finished(keys, finished)
    }

    /** Reads an opened "server finished": exactly the marker, or the marker and one credential. */
    fun credentialInServerFinished(opened: ByteArray): DeviceCredential? {
        val marker = protocol.labels.serverFinished.toByteArray(Charsets.UTF_8)
        if (opened.size < marker.size || !opened.copyOfRange(0, marker.size).contentEquals(marker)) {
            throw TransportSecurityException(TransportSecurityException.Kind.UnauthenticatedFrame)
        }
        if (opened.size == marker.size) return null
        return DeviceCredential.fromWireBytes(opened.copyOfRange(marker.size, opened.size), protocol)
            ?: throw TransportSecurityException(TransportSecurityException.Kind.UnauthenticatedFrame)
    }
}
