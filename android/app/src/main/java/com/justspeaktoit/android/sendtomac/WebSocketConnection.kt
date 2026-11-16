package com.justspeaktoit.android.sendtomac

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale

/** One whole message at a time over the Mac's connection. */
internal interface FrameTransport : Closeable {
    /** Sends one binary message. */
    fun send(frame: ByteArray)

    /**
     * The next whole message. Throws [java.net.SocketTimeoutException] after [timeoutMs], which
     * leaves the connection unusable, and [WebSocketClosedException] once the Mac has closed it.
     */
    fun receive(timeoutMs: Int): ByteArray

    /** The largest message either side may send; it rises once the Mac has authenticated the phone. */
    var maximumMessageBytes: Int
}

/** The Mac closed the connection, or it ended before a whole message arrived. */
internal class WebSocketClosedException(message: String) : IOException(message)

/** The Mac broke the WebSocket protocol. */
internal class WebSocketProtocolException(message: String) : IOException(message)

/**
 * A minimal RFC 6455 client over a plain TCP socket: the Mac's `NWProtocolWebSocket` listener
 * (`SpeakTransportWire`) is the only peer, so there is no TLS, extension or subprotocol to
 * negotiate. Data goes out as masked binary messages; pings are answered and fragments joined.
 */
internal class WebSocketConnection private constructor(
    private val socket: Socket,
    private val input: InputStream,
    private val output: OutputStream,
    private val random: SecureRandom,
    override var maximumMessageBytes: Int,
) : FrameTransport {
    override fun send(frame: ByteArray) = writeFrame(OPCODE_BINARY, frame)

    override fun receive(timeoutMs: Int): ByteArray {
        socket.soTimeout = timeoutMs.coerceAtLeast(1)
        val message = ByteArrayOutputStream()
        var messageOpcode = -1
        while (true) {
            val header = readExactly(2)
            val fin = header[0].toInt() and 0x80 != 0
            if (header[0].toInt() and 0x70 != 0) throw WebSocketProtocolException("Unexpected extension bits")
            val opcode = header[0].toInt() and 0x0F
            if (header[1].toInt() and 0x80 != 0) throw WebSocketProtocolException("The server masked a frame")
            val length = payloadLength(header[1].toInt() and 0x7F)
            if (opcode >= OPCODE_CLOSE) {
                if (!fin || length > MAX_CONTROL_PAYLOAD) throw WebSocketProtocolException("Invalid control frame")
                val payload = readExactly(length.toInt())
                when (opcode) {
                    OPCODE_CLOSE -> {
                        runCatching { writeFrame(OPCODE_CLOSE, payload.copyOf(minOf(payload.size, 2))) }
                        throw WebSocketClosedException("The Mac closed the connection")
                    }
                    OPCODE_PING -> writeFrame(OPCODE_PONG, payload)
                    OPCODE_PONG -> Unit
                    else -> throw WebSocketProtocolException("Unknown control frame")
                }
                continue
            }
            if (opcode == OPCODE_CONTINUATION) {
                if (messageOpcode < 0) throw WebSocketProtocolException("Continuation without a message")
            } else {
                if (messageOpcode >= 0) throw WebSocketProtocolException("Interleaved message")
                if (opcode != OPCODE_TEXT && opcode != OPCODE_BINARY) {
                    throw WebSocketProtocolException("Unsupported frame")
                }
                messageOpcode = opcode
            }
            if (message.size() + length > maximumMessageBytes) {
                throw WebSocketProtocolException("Message above the $maximumMessageBytes byte limit")
            }
            message.write(readExactly(length.toInt()))
            if (fin) {
                // Network.framework reports an empty message as the connection ending.
                if (message.size() == 0) throw WebSocketClosedException("The Mac sent an empty message")
                return message.toByteArray()
            }
        }
    }

    override fun close() {
        runCatching { writeFrame(OPCODE_CLOSE, byteArrayOf(0x03, 0xE8.toByte())) }
        runCatching { socket.close() }
    }

    @Synchronized
    private fun writeFrame(opcode: Int, payload: ByteArray) {
        val frame = ByteArrayOutputStream(payload.size + MAX_HEADER_BYTES)
        frame.write(0x80 or opcode)
        when {
            payload.size < LENGTH_16_MARKER -> frame.write(0x80 or payload.size)
            payload.size <= 0xFFFF -> {
                frame.write(0x80 or LENGTH_16_MARKER)
                frame.write(payload.size ushr 8)
                frame.write(payload.size and 0xFF)
            }
            else -> {
                frame.write(0x80 or LENGTH_64_MARKER)
                val length = payload.size.toLong()
                for (shift in 56 downTo 0 step 8) frame.write(((length ushr shift) and 0xFF).toInt())
            }
        }
        val mask = ByteArray(MASK_BYTES).also(random::nextBytes)
        frame.write(mask)
        for (index in payload.indices) frame.write(payload[index].toInt() xor mask[index % MASK_BYTES].toInt())
        output.write(frame.toByteArray())
        output.flush()
    }

    private fun payloadLength(marker: Int): Long = when (marker) {
        LENGTH_16_MARKER -> readExactly(2).fold(0L) { acc, byte -> (acc shl 8) or (byte.toLong() and 0xFF) }
        LENGTH_64_MARKER -> readExactly(8).fold(0L) { acc, byte -> (acc shl 8) or (byte.toLong() and 0xFF) }
            .also { if (it < 0) throw WebSocketProtocolException("Invalid frame length") }
        else -> marker.toLong()
    }

    private fun readExactly(count: Int): ByteArray = readExactly(input, count)

    companion object {
        private const val OPCODE_CONTINUATION = 0x0
        private const val OPCODE_TEXT = 0x1
        private const val OPCODE_BINARY = 0x2
        private const val OPCODE_CLOSE = 0x8
        private const val OPCODE_PING = 0x9
        private const val OPCODE_PONG = 0xA
        private const val LENGTH_16_MARKER = 126
        private const val LENGTH_64_MARKER = 127
        private const val MAX_CONTROL_PAYLOAD = 125L
        private const val MAX_HEADER_BYTES = 14
        private const val MASK_BYTES = 4
        private const val KEY_BYTES = 16
        private const val MAX_RESPONSE_HEADER_BYTES = 8 * 1024
        private const val ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        /**
         * Connects to the Mac at [address]:[port] and completes the WebSocket upgrade on [path]
         * within [timeoutMs].
         */
        fun open(
            address: InetAddress,
            port: Int,
            path: String,
            timeoutMs: Int,
            maximumMessageBytes: Int,
            random: SecureRandom = SecureRandom(),
        ): WebSocketConnection {
            val socket = Socket()
            try {
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(address, port), timeoutMs.coerceAtLeast(1))
                socket.soTimeout = timeoutMs.coerceAtLeast(1)
                val input = BufferedInputStream(socket.getInputStream())
                val output = socket.getOutputStream()
                val key = Base64.getEncoder().encodeToString(ByteArray(KEY_BYTES).also(random::nextBytes))
                output.write(upgradeRequest(hostHeader(address, port), path, key).toByteArray(Charsets.US_ASCII))
                output.flush()
                checkUpgradeResponse(readResponseHead(input), key)
                return WebSocketConnection(socket, input, output, random, maximumMessageBytes)
            } catch (error: IOException) {
                runCatching { socket.close() }
                throw error
            }
        }

        fun upgradeRequest(host: String, path: String, key: String): String =
            "GET $path HTTP/1.1\r\n" +
                "Host: $host\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                "Sec-WebSocket-Key: $key\r\n" +
                "Sec-WebSocket-Version: 13\r\n" +
                "\r\n"

        fun acceptValue(key: String): String = Base64.getEncoder().encodeToString(
            MessageDigest.getInstance("SHA-1").digest((key + ACCEPT_GUID).toByteArray(Charsets.US_ASCII)),
        )

        /** Throws unless [head] switches protocols and proves the server read [key]. */
        fun checkUpgradeResponse(head: String, key: String) {
            val lines = head.split("\r\n")
            val status = lines.firstOrNull().orEmpty().split(' ')
            if (status.size < 2 || !status[0].startsWith("HTTP/1.") || status[1] != "101") {
                throw WebSocketProtocolException("The Mac refused the WebSocket upgrade")
            }
            val headers = lines.drop(1).mapNotNull { line ->
                val colon = line.indexOf(':')
                if (colon <= 0) null else line.substring(0, colon).trim().lowercase(Locale.ROOT) to line.substring(colon + 1).trim()
            }.toMap()
            if (!headers["upgrade"].equals("websocket", ignoreCase = true)) {
                throw WebSocketProtocolException("The Mac did not upgrade to WebSocket")
            }
            if (headers["sec-websocket-accept"] != acceptValue(key)) {
                throw WebSocketProtocolException("The Mac's WebSocket accept key is wrong")
            }
        }

        private fun hostHeader(address: InetAddress, port: Int): String {
            val host = address.hostAddress.orEmpty().substringBefore('%')
            return if (address is Inet6Address) "[$host]:$port" else "$host:$port"
        }

        private fun readResponseHead(input: InputStream): String {
            val head = ByteArrayOutputStream()
            var matched = 0
            val terminator = "\r\n\r\n"
            while (matched < terminator.length) {
                val byte = input.read()
                if (byte < 0) throw WebSocketClosedException("The Mac closed the connection during the upgrade")
                head.write(byte)
                if (head.size() > MAX_RESPONSE_HEADER_BYTES) throw WebSocketProtocolException("Upgrade response too long")
                matched = when {
                    byte == terminator[matched].code -> matched + 1
                    byte == '\r'.code -> 1
                    else -> 0
                }
            }
            return head.toString(Charsets.US_ASCII.name()).removeSuffix(terminator)
        }

        private fun readExactly(input: InputStream, count: Int): ByteArray {
            val buffer = ByteArray(count)
            var read = 0
            while (read < count) {
                val n = input.read(buffer, read, count - read)
                if (n < 0) throw if (read == 0 && count > 0) WebSocketClosedException("The connection closed") else EOFException()
                read += n
            }
            return buffer
        }
    }
}
