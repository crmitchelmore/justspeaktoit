package com.justspeaktoit.android.sync

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URISyntaxException
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Locale

/** The request line and header fields of one loopback request (desktop `DesktopLoopbackRequestHead`). */
data class LoopbackRequestHead(val method: String, val target: String, val fields: List<Pair<String, String>> = emptyList()) {
    fun values(name: String): List<String> = fields.filter { it.first.equals(name, ignoreCase = true) }.map { it.second }

    companion object {
        /** Null when [request] is not an HTTP request head. */
        fun parse(request: ByteArray): LoopbackRequestHead? {
            val text = String(request, Charsets.ISO_8859_1).substringBefore("\r\n\r\n")
            val lines = text.split("\r\n")
            val requestLine = lines.first().split(" ")
            if (requestLine.size != 3 || requestLine[0].isEmpty() || requestLine[1].isEmpty() ||
                !requestLine[2].startsWith("HTTP/")
            ) {
                return null
            }
            val fields = mutableListOf<Pair<String, String>>()
            for (line in lines.drop(1)) {
                val colon = line.indexOf(':')
                if (colon < 0) return null
                val name = line.substring(0, colon)
                if (name.isEmpty() || name.any { it == ' ' || it == '\t' }) return null
                fields += name to line.substring(colon + 1).trim(' ', '\t')
            }
            return LoopbackRequestHead(requestLine[0], requestLine[1], fields)
        }
    }
}

sealed interface CallbackDecision {
    data class Accept(val webAuthToken: String) : CallbackDecision

    data object NotFound : CallbackDecision

    data class Refuse(val reason: CallbackRefusal) : CallbackDecision
}

enum class CallbackRefusal { Method, Host, NotTopLevelNavigation, UntrustedInitiator }

class CloudKitSignInTimeoutException : Exception("iCloud sign-in did not finish in time.")

/**
 * The loopback half of iCloud web sign-in, ported from `DesktopCloudSyncSignIn`. Apple redirects the
 * browser to [CALLBACK_URL], the address registered on the API token for every non-Apple platform,
 * and this keeps the `ckWebAuthToken` from that request alone.
 *
 * Unlike Windows, Android cannot tell which app opened a loopback connection, so the browser
 * checks below are the only defence against another app on the device delivering its own token.
 */
object CloudKitSignIn {
    const val CALLBACK_HOST = "127.0.0.1"
    const val CALLBACK_PORT = 47_823
    const val CALLBACK_PATH = "/cloudkit-sign-in"
    const val CALLBACK_URL = "http://$CALLBACK_HOST:$CALLBACK_PORT$CALLBACK_PATH"
    const val WINDOW_MS = 10L * 60 * 1000
    private const val READ_TIMEOUT_MS = 5_000
    private const val ACCEPT_SLICE_MS = 1_000
    private const val MAX_REQUEST_BYTES = 1 shl 20

    /** The `ckWebAuthToken` of a request to the callback path, percent-decoded; `+` stays `+`. */
    fun webAuthToken(target: String): String? {
        if (target.any { it.code <= 0x20 || it.code >= 0x7F || it in "\"<>\\^`{|}" }) return null
        val beforeFragment = target.substringBefore('#')
        val path = percentDecode(beforeFragment.substringBefore('?')) ?: return null
        if (path != CALLBACK_PATH) return null
        if (!beforeFragment.contains('?')) return null
        for (item in beforeFragment.substringAfter('?').split('&')) {
            val name = percentDecode(item.substringBefore('=')) ?: return null
            if (name != "ckWebAuthToken") continue
            if (!item.contains('=')) return null
            return percentDecode(item.substringAfter('='))?.takeIf { it.isNotEmpty() }
        }
        return null
    }

    fun isTrustedSignInUrl(text: String): Boolean {
        val uri = try {
            URI(text)
        } catch (e: URISyntaxException) {
            return false
        }
        if (uri.scheme?.lowercase(Locale.ROOT) != "https") return false
        val host = uri.host?.lowercase(Locale.ROOT) ?: return false
        return listOf("apple.com", "icloud.com").any { host == it || host.endsWith(".$it") }
    }

    fun evaluateCallback(head: LoopbackRequestHead?): CallbackDecision {
        val token = head?.let { webAuthToken(it.target) } ?: return CallbackDecision.NotFound
        if (head.method != "GET") return CallbackDecision.Refuse(CallbackRefusal.Method)
        val hosts = head.values("Host")
        if (hosts.size != 1 || !isCallbackHost(hosts[0])) return CallbackDecision.Refuse(CallbackRefusal.Host)
        if (!isTopLevelNavigation(head)) return CallbackDecision.Refuse(CallbackRefusal.NotTopLevelNavigation)
        val initiators = head.values("Origin") + head.values("Referer")
        if (!initiators.all(::isTrustedSignInUrl)) return CallbackDecision.Refuse(CallbackRefusal.UntrustedInitiator)
        return CallbackDecision.Accept(token)
    }

    fun callbackPage(title: String, message: String, status: Int = 200): ByteArray {
        val body = "<!doctype html><meta charset=\"utf-8\"><title>$title</title><p>$message</p>"
        val reason = mapOf(200 to "OK", 403 to "Forbidden", 404 to "Not Found")[status] ?: "Error"
        val head = "HTTP/1.1 $status $reason\r\n" +
            "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
            "Content-Length: ${body.toByteArray(Charsets.UTF_8).size}\r\nConnection: close\r\n\r\n"
        return (head + body).toByteArray(Charsets.UTF_8)
    }

    fun response(decision: CallbackDecision): ByteArray = when (decision) {
        is CallbackDecision.Accept -> callbackPage(
            "Signed in",
            "You are signed in to iCloud. You can close this tab and return to Just Speak to It.",
        )
        CallbackDecision.NotFound -> callbackPage("Not found", "This address only completes iCloud sign-in.", 404)
        is CallbackDecision.Refuse -> callbackPage(
            "Not signed in",
            "This request could not be confirmed as your browser returning from Apple's sign-in, " +
                "so it was not used. Return to Just Speak to It and sign in again.",
            403,
        )
    }

    /** Binds the callback address; the caller opens the sign-in page only once this succeeds. */
    fun bind(): ServerSocket = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress(InetAddress.getByName(CALLBACK_HOST), CALLBACK_PORT), 8)
    }

    /**
     * Answers requests on [server] until one carries an acceptable token, then closes it. Throws
     * [CloudKitSignInTimeoutException] after [windowMs]; cancellation stops it within a second.
     */
    suspend fun awaitCallback(
        server: ServerSocket,
        io: CoroutineDispatcher,
        windowMs: Long = WINDOW_MS,
        now: () -> Long = System::currentTimeMillis,
    ): String = withContext(io) {
        server.use {
            val deadline = now() + windowMs
            while (true) {
                ensureActive()
                val remaining = deadline - now()
                if (remaining <= 0) break
                server.soTimeout = minOf(remaining, ACCEPT_SLICE_MS.toLong()).toInt().coerceAtLeast(1)
                val socket = try {
                    server.accept()
                } catch (e: SocketTimeoutException) {
                    continue
                }
                val token = socket.use(::answer)
                if (token != null) return@withContext token
            }
            throw CloudKitSignInTimeoutException()
        }
    }

    private fun answer(socket: Socket): String? {
        val decision = try {
            socket.soTimeout = READ_TIMEOUT_MS
            evaluateCallback(readHead(socket)?.let(LoopbackRequestHead::parse))
        } catch (e: IOException) {
            return null
        }
        try {
            socket.getOutputStream().apply {
                write(response(decision))
                flush()
            }
        } catch (e: IOException) {
            // Android can freeze the app while the browser is in front, so the browser may have given
            // up on the page by the time it is answered; the token it sent is still good.
        }
        return (decision as? CallbackDecision.Accept)?.webAuthToken
    }

    private fun readHead(socket: Socket): ByteArray? {
        val input = socket.getInputStream()
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (bytes.size() < MAX_REQUEST_BYTES) {
            val read = input.read(buffer)
            if (read < 0) break
            bytes.write(buffer, 0, read)
            if (bytes.toString(Charsets.ISO_8859_1.name()).contains("\r\n\r\n")) break
        }
        return bytes.toByteArray().takeIf { it.isNotEmpty() }
    }

    private fun isCallbackHost(value: String): Boolean {
        val parts = value.split(":", limit = 2)
        if (parts[0] != CALLBACK_HOST) return false
        return parts.size == 1 || parts[1].toIntOrNull()?.takeIf { parts[1].all(Char::isDigit) }?.let { it in 0..65_535 } == true
    }

    private fun isTopLevelNavigation(head: LoopbackRequestHead): Boolean {
        if (head.fields.none { it.first.lowercase(Locale.ROOT).startsWith("sec-fetch-") }) return true
        fun only(name: String, allowed: Set<String>, required: Boolean): Boolean {
            val values = head.values(name).map { it.lowercase(Locale.ROOT) }
            if (values.isEmpty()) return !required
            return values.all { it in allowed }
        }
        return only("Sec-Fetch-Mode", setOf("navigate"), required = true) &&
            only("Sec-Fetch-Dest", setOf("document"), required = false) &&
            only("Sec-Fetch-Site", setOf("cross-site", "none"), required = false)
    }

    /** Strict percent-decoding as URLComponents does it: a bad escape or invalid UTF-8 is null. */
    private fun percentDecode(text: String): String? {
        val out = ByteArrayOutputStream()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '%') {
                val hex = text.substring(i + 1, minOf(i + 3, text.length))
                if (hex.length != 2 || !hex.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return null
                out.write(hex.toInt(16))
                i += 3
            } else {
                out.write(c.code)
                i += 1
            }
        }
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
        } catch (e: CharacterCodingException) {
            null
        }
    }
}
