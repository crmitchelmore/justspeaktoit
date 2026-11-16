package com.justspeaktoit.android.sendtomac

import java.io.IOException
import java.net.SocketTimeoutException
import java.time.Instant
import java.util.UUID

/** Why pairing or a send failed. The view model turns each into the copy iOS shows. */
sealed class SendToMacFailure(message: String) : Exception(message) {
    /** The code is not six digits. */
    data object InvalidCode : SendToMacFailure("Enter the six-digit code shown on the Mac.")

    /** The Mac could not be found or reached within the connect timeout. */
    data class Unreachable(val macName: String) : SendToMacFailure("Couldn't reach $macName")

    /** The Mac refused, with its own reason (wrong code, revoked credential, version, lockout). */
    data class Rejected(val reason: String) : SendToMacFailure(reason)

    /** The Mac's handshake did not follow the protocol. */
    data object MalformedHandshake : SendToMacFailure("The peer sent an invalid encryption handshake")

    /** A frame did not open with this session's key. */
    data object UnauthenticatedFrame :
        SendToMacFailure("Received a message that was not sealed with this session's key")

    data object UnexpectedResponse : SendToMacFailure("The Mac sent an unexpected response")

    /** The Mac runs another release train (an Alpha Mac). */
    data object ReleaseTrainMismatch : SendToMacFailure("Connect to a Mac running the same release train")

    data object MissingSessionToken :
        SendToMacFailure("The Mac accepted the pairing code without issuing a session token")

    /** The Mac accepted the code but is too old to issue a device credential. */
    data object NoCredentialIssued : SendToMacFailure("Update Just Speak to It on the Mac, then pair again.")

    data object AcknowledgementTimedOut : SendToMacFailure("The Mac did not confirm it received the transcript.")

    data object ConnectionLost :
        SendToMacFailure("The connection to the Mac was lost before it confirmed the transcript.")

    data object NotPaired : SendToMacFailure("Pair with a Mac in Settings first.")

    data object NothingToSend : SendToMacFailure("There is no transcript to send.")

    /** The transcript does not fit in one session frame. */
    data object TranscriptTooLarge : SendToMacFailure("The transcript is too long to send to the Mac.")
}

/**
 * The phone's side of Send to Mac, as SpeakCore's `MacConnection` and `SendToMacSender` run it on
 * iOS. Each call opens one connection, runs the encrypted handshake, authenticates and closes.
 *
 * Pairing presents the six-digit code once and returns the device credential the Mac issues;
 * every send presents only that credential, so a revoked credential fails instead of falling
 * back to the code (#1643). Calls block: run them off the main thread.
 */
internal class SendToMacClient(
    private val protocol: SendToMacProtocol,
    private val deviceName: () -> String,
    private val deviceId: () -> String,
    private val connectTimeoutMs: Long = CONNECT_TIMEOUT_MS,
    private val acknowledgementTimeoutMs: Long = ACKNOWLEDGEMENT_TIMEOUT_MS,
    private val clock: () -> Instant = Instant::now,
    private val monotonicMs: () -> Long = { System.nanoTime() / NANOS_PER_MILLI },
    private val privateKey: () -> ByteArray = { X25519.generatePrivateKey() },
) {
    /**
     * Opens a connection to the Mac within the given milliseconds, applying the given message size
     * limit. Throws [IOException] when it cannot.
     */
    fun interface Connector {
        fun open(timeoutMs: Int, maximumMessageBytes: Int): FrameTransport
    }

    /** Pairs with [macName] using [code] and returns the credential it issued. */
    fun pair(macName: String, code: String, connector: Connector): DeviceCredential {
        val digits = normalizedPairingCode(code) ?: throw SendToMacFailure.InvalidCode
        val session = connect(macName, PairingSecret.Code(digits), connector)
        session.transport.close()
        return session.issued ?: throw SendToMacFailure.NoCredentialIssued
    }

    /**
     * Delivers [text] to [macName] as one finished session and returns once the Mac has
     * acknowledged it.
     */
    fun send(
        macName: String,
        credential: DeviceCredential,
        text: String,
        model: String,
        durationSeconds: Double,
        connector: Connector,
        sessionId: UUID = UUID.randomUUID(),
    ) {
        val session = connect(macName, PairingSecret.Credential(credential), connector)
        session.transport.use { session.deliver(text, model, durationSeconds, PhoneMessages.uuid(sessionId)) }
    }

    private fun connect(macName: String, secret: PairingSecret, connector: Connector): Session {
        val deadline = monotonicMs() + connectTimeoutMs
        fun remaining(): Int {
            val left = deadline - monotonicMs()
            if (left <= 0) throw SendToMacFailure.Unreachable(macName)
            return left.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }

        val transport = try {
            connector.open(remaining(), protocol.handshakeFrameLimitBytes)
        } catch (_: IOException) {
            throw SendToMacFailure.Unreachable(macName)
        }
        try {
            val handshake = ClientHandshake(protocol, secret, privateKey())
            transport.send(handshake.frame)
            val reply = transport.receive(remaining())
            if (MacMessages.keyShare(reply, protocol) == null) {
                throw rejection(reply) ?: SendToMacFailure.MalformedHandshake
            }
            val finished = try {
                handshake.finish(reply)
            } catch (error: TransportSecurityException) {
                throw error.asFailure()
            }
            transport.send(finished.frame)

            val confirmation = transport.receive(remaining())
            val opened = try {
                finished.keys.inbound.open(confirmation)
            } catch (_: TransportSecurityException) {
                // The Mac could not open our frame, so it answered in plaintext. Only a refusal is
                // read from such a frame; never a success.
                throw rejection(confirmation) ?: SendToMacFailure.UnauthenticatedFrame
            }
            val issued = try {
                handshake.credentialInServerFinished(opened)
            } catch (error: TransportSecurityException) {
                throw error.asFailure()
            }
            // Only a code-based handshake may receive a credential.
            if (issued != null && secret is PairingSecret.Credential) throw SendToMacFailure.UnauthenticatedFrame

            val session = Session(transport, finished.keys, issued)
            session.authenticate(secret, ::remaining)
            return session
        } catch (error: SendToMacFailure) {
            transport.close()
            throw error
        } catch (_: IOException) {
            transport.close()
            throw SendToMacFailure.Unreachable(macName)
        }
    }

    private fun rejection(frame: ByteArray): SendToMacFailure? =
        MacMessages.rejection(frame)?.let { SendToMacFailure.Rejected(it) }

    private inner class Session(
        val transport: FrameTransport,
        private val keys: SessionKeys,
        val issued: DeviceCredential?,
    ) {
        private var frameLimit = protocol.handshakeFrameLimitBytes

        fun authenticate(secret: PairingSecret, remaining: () -> Int) {
            val train = SendToMacProtocol.RELEASE_TRAIN
            sendSealed(PhoneMessages.hello(protocol.protocolVersion, deviceName(), deviceId(), train))
            val code = (secret as? PairingSecret.Code)?.code.orEmpty()
            sendSealed(PhoneMessages.authenticate(code, clock()))
            val message = receiveSealed(remaining())
            when {
                message is MacMessage.AuthResult && message.success -> {
                    val macTrain = message.releaseTrain
                    if (macTrain != null && macTrain != train) {
                        throw SendToMacFailure.ReleaseTrainMismatch
                    }
                    if (message.sessionToken == null) throw SendToMacFailure.MissingSessionToken
                    // The Mac raises its own ceiling at the same point.
                    frameLimit = protocol.sessionFrameLimitBytes
                    transport.maximumMessageBytes = frameLimit
                }
                message is MacMessage.AuthResult ->
                    throw SendToMacFailure.Rejected(message.errorMessage ?: MacMessages.AUTHENTICATION_FAILED)
                message is MacMessage.Error -> throw SendToMacFailure.Rejected(message.message)
                else -> throw SendToMacFailure.UnexpectedResponse
            }
        }

        fun deliver(text: String, model: String, durationSeconds: Double, sessionId: String) {
            try {
                sendSealed(PhoneMessages.sessionStart(sessionId, model))
                sendSealed(PhoneMessages.transcriptChunk(sessionId, SEQUENCE_NUMBER, text, true, clock()))
            } catch (_: IOException) {
                throw SendToMacFailure.ConnectionLost
            }
            awaitAcknowledgement()
            val end = PhoneMessages.sessionEnd(sessionId, text, durationSeconds, PhoneMessages.wordCount(text))
            // The Mac already has the transcript; a lost session end changes nothing it shows.
            runCatching { sendSealed(end) }
        }

        private fun awaitAcknowledgement() {
            val deadline = monotonicMs() + acknowledgementTimeoutMs
            while (true) {
                val left = deadline - monotonicMs()
                if (left <= 0) throw SendToMacFailure.AcknowledgementTimedOut
                val message = try {
                    receiveSealed(left.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                } catch (_: SocketTimeoutException) {
                    throw SendToMacFailure.AcknowledgementTimedOut
                } catch (_: IOException) {
                    throw SendToMacFailure.ConnectionLost
                } catch (_: SendToMacFailure) {
                    throw SendToMacFailure.ConnectionLost
                }
                when {
                    message is MacMessage.Ack && message.sequenceNumber == SEQUENCE_NUMBER -> return
                    message is MacMessage.Ping -> try {
                        sendSealed(PhoneMessages.PONG)
                    } catch (_: IOException) {
                        throw SendToMacFailure.ConnectionLost
                    }
                    message is MacMessage.Error -> throw SendToMacFailure.ConnectionLost
                }
            }
        }

        private fun sendSealed(json: String) {
            val frame = keys.outbound.seal(json.toByteArray(Charsets.UTF_8))
            if (frame.size > frameLimit) throw SendToMacFailure.TranscriptTooLarge
            transport.send(frame)
        }

        /** The next sealed message; null when it opened but is not one the Mac could send. */
        private fun receiveSealed(timeoutMs: Int): MacMessage? {
            val frame = transport.receive(timeoutMs)
            val opened = try {
                keys.inbound.open(frame)
            } catch (_: TransportSecurityException) {
                throw SendToMacFailure.UnauthenticatedFrame
            }
            return MacMessages.parse(opened)
        }
    }

    private fun TransportSecurityException.asFailure(): SendToMacFailure = when (kind) {
        TransportSecurityException.Kind.MalformedHandshake -> SendToMacFailure.MalformedHandshake
        TransportSecurityException.Kind.UnauthenticatedFrame -> SendToMacFailure.UnauthenticatedFrame
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
        const val ACKNOWLEDGEMENT_TIMEOUT_MS = 5_000L
        private const val SEQUENCE_NUMBER = 1
        private const val CODE_DIGITS = 6
        private const val NANOS_PER_MILLI = 1_000_000L

        /** The code with whitespace removed, or null unless it is six ASCII digits. */
        fun normalizedPairingCode(code: String): String? {
            val digits = code.filterNot { it.isWhitespace() }
            return digits.takeIf { it.length == CODE_DIGITS && it.all { char -> char in '0'..'9' } }
        }
    }
}
