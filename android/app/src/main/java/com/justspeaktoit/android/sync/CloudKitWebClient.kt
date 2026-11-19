package com.justspeaktoit.android.sync

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL

/** One HTTP request to CloudKit Web Services. Its URL carries tokens, so it is never logged. */
data class CloudKitHttpRequest(val method: String, val url: String, val body: String?)

data class CloudKitHttpResponse(val status: Int, val headers: Map<String, List<String>>, val body: String)

/** Sends one request; production uses [UrlConnectionCloudKitHttp], tests a fake. */
fun interface CloudKitHttp {
    /** Throws [IOException] when the request does not complete. */
    fun send(request: CloudKitHttpRequest): CloudKitHttpResponse
}

/** Where the rotating CloudKit web auth token lives; production keeps it in the encrypted secret store. */
interface WebAuthTokenStore {
    fun load(): String?

    fun save(token: String)

    fun clear()
}

/**
 * A CloudKit Web Services client with the desktop client's rules (Sources/SpeakSync/
 * CloudKitWebServicesClient.swift): one request at a time, the web auth token rotated from every
 * response, transient failures retried with bounded backoff, and an expired or rejected session
 * cleared so the user is asked to sign in again.
 *
 * Each sign-in and sign-out starts a new session. An operation pinned to a session is only ever sent
 * in it, so a retry or a later step of a sync pass never crosses a sign-out or a sign-in.
 */
class CloudKitWebClient(
    private val config: CloudKitConfig,
    private val http: CloudKitHttp,
    private val tokens: WebAuthTokenStore,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val gate = Mutex()
    private var generation = 0L
    private var token: String? = null
    private var tokenLoaded = false

    suspend fun session(): Long = gate.withLock { generation }

    suspend fun hasWebAuthToken(): Boolean = gate.withLock { loadedToken() != null }

    suspend fun storeWebAuthToken(value: String) = gate.withLock {
        withContext(io) { tokens.save(value) }
        token = value
        tokenLoaded = true
        generation += 1
    }

    suspend fun signOut() = gate.withLock { rejectSession() }

    /** Throws [CloudKitException.SessionChanged] unless [session] is still the current one. */
    suspend fun requireCurrent(session: Long) = gate.withLock {
        if (session != generation) throw CloudKitException.SessionChanged()
    }

    suspend fun currentUserRecordName(session: Long? = null): String {
        val response = perform("GET", PUBLIC, "users/caller", null, session)
        val listed = response.optJSONArray("users")?.optJSONObject(0)?.opt("userRecordName") as? String
        val name = listed ?: response.opt("userRecordName") as? String
        if (name.isNullOrEmpty()) throw CloudKitException.InvalidResponse("The caller identity had no user record name.")
        return name
    }

    suspend fun createZone(zone: String, session: Long? = null) {
        val operation = JSONObject().put("operationType", "create")
            .put("zone", JSONObject().put("zoneID", CloudKitWire.zoneId(zone)))
        val response = perform("POST", PRIVATE, "zones/modify", JSONObject().put("operations", JSONArray().put(operation)), session)
        val zones = response.optJSONArray("zones") ?: return
        for (i in 0 until zones.length()) {
            val error = zones.optJSONObject(i)?.let(CloudKitWire::serverError) ?: continue
            if (error.code != CloudKitServerError.EXISTS) throw CloudKitException.Server(error)
        }
    }

    suspend fun fetchZoneChanges(zone: String, syncToken: String?, session: Long? = null): ZoneChanges {
        val request = JSONObject().put("zoneID", CloudKitWire.zoneId(zone))
        syncToken?.let { request.put("syncToken", it) }
        val response = perform("POST", PRIVATE, "changes/zone", JSONObject().put("zones", JSONArray().put(request)), session)
        val zones = response.optJSONArray("zones") ?: JSONArray()
        val results = (0 until zones.length()).mapNotNull { zones.optJSONObject(it) }
        val matching = results.firstOrNull { it.optJSONObject("zoneID")?.opt("zoneName") == zone }
            ?: results.singleOrNull()
            ?: throw CloudKitException.InvalidResponse("The change feed did not include the History zone.")
        CloudKitWire.serverError(matching)?.let { throw CloudKitException.Server(it) }
        return ZoneChanges(
            records = CloudKitWire.recordResults(matching.optJSONArray("records")),
            syncToken = matching.opt("syncToken") as? String,
            moreComing = matching.opt("moreComing") == true,
        )
    }

    suspend fun lookup(names: List<String>, zone: String, session: Long? = null): List<RecordResult> {
        val records = JSONArray()
        names.forEach { records.put(JSONObject().put("recordName", it)) }
        val body = JSONObject().put("records", records).put("zoneID", CloudKitWire.zoneId(zone))
        return CloudKitWire.recordResults(perform("POST", PRIVATE, "records/lookup", body, session).optJSONArray("records"))
    }

    suspend fun modify(operations: List<RecordOperation>, zone: String, session: Long? = null): List<RecordResult> {
        val encoded = JSONArray()
        operations.forEach { encoded.put(CloudKitWire.operation(it)) }
        val body = JSONObject().put("operations", encoded).put("zoneID", CloudKitWire.zoneId(zone))
            .put("atomic", false).put("desiredKeys", JSONArray())
        return CloudKitWire.recordResults(perform("POST", PRIVATE, "records/modify", body, session).optJSONArray("records"))
    }

    private suspend fun perform(
        method: String,
        database: String,
        operation: String,
        body: JSONObject?,
        session: Long?,
    ): JSONObject {
        val pinned = session ?: session()
        val payload = body?.toString()
        var attempt = 0
        while (true) {
            attempt += 1
            when (val outcome = exchange(method, database, operation, payload, pinned, attempt)) {
                is Outcome.Completed -> return outcome.body
                is Outcome.Retry -> {
                    if (attempt >= MAX_ATTEMPTS) throw outcome.failure
                    // Waits outside the gate, so a sign-out is never held up behind a backoff.
                    sleep(outcome.delayMs)
                }
            }
        }
    }

    private sealed interface Outcome {
        data class Completed(val body: JSONObject) : Outcome

        data class Retry(val delayMs: Long, val failure: CloudKitException) : Outcome
    }

    private suspend fun exchange(
        method: String,
        database: String,
        operation: String,
        payload: String?,
        session: Long,
        attempt: Int,
    ): Outcome = gate.withLock {
        // Checked under the gate: an operation's payload is only ever sent in the session it began in.
        if (session != generation) throw CloudKitException.SessionChanged()
        val request = CloudKitHttpRequest(method, url(database, operation, loadedToken()), payload)
        val response = try {
            withContext(io) { http.send(request) }
        } catch (e: SocketTimeoutException) {
            return@withLock Outcome.Retry(backoff(attempt), CloudKitException.Network(e))
        } catch (e: ConnectException) {
            return@withLock Outcome.Retry(backoff(attempt), CloudKitException.Network(e))
        } catch (e: SocketException) {
            return@withLock Outcome.Retry(backoff(attempt), CloudKitException.Network(e))
        } catch (e: IOException) {
            throw CloudKitException.Network(e)
        }
        rotateToken(response.headers)
        outcome(response, attempt)
    }

    private fun outcome(response: CloudKitHttpResponse, attempt: Int): Outcome {
        if (response.status in 200..299) {
            return try {
                Outcome.Completed(JSONObject(response.body))
            } catch (e: JSONException) {
                throw CloudKitException.InvalidResponse("CloudKit returned a response that was not JSON.")
            }
        }
        val error = CloudKitWire.serverError(response.body)
        if (response.status == 421 || error?.code == CloudKitServerError.AUTHENTICATION_REQUIRED) {
            rejectSession()
            throw CloudKitException.AuthenticationRequired(error?.redirectUrl)
        }
        if (response.status == 401 || error?.code == CloudKitServerError.AUTHENTICATION_FAILED) {
            rejectSession()
            throw CloudKitException.AuthenticationFailed()
        }
        if (error != null) {
            val delayMs = retryDelay(error, attempt) ?: throw CloudKitException.Server(error)
            return Outcome.Retry(delayMs, CloudKitException.Server(error))
        }
        val failure = CloudKitException.InvalidResponse("HTTP ${response.status}")
        if (response.status !in RETRYABLE_STATUSES) throw failure
        return Outcome.Retry(backoff(attempt), failure)
    }

    private fun retryDelay(error: CloudKitServerError, attempt: Int): Long? {
        val seconds = error.retryAfterSeconds
        if (seconds != null && seconds.isFinite() && seconds >= 0) {
            return if (seconds <= MAX_SERVER_DELAY_S) (seconds * 1000).toLong() else null
        }
        if (error.code != CloudKitServerError.THROTTLED && error.code != CloudKitServerError.TRY_AGAIN_LATER) return null
        return backoff(attempt)
    }

    private fun rotateToken(headers: Map<String, List<String>>) {
        val rotated = header(headers, ROTATED_TOKEN_HEADER) ?: header(headers, SESSION_HEADER)
        if (rotated.isNullOrEmpty() || rotated == token) return
        tokens.save(rotated)
        token = rotated
        tokenLoaded = true
    }

    private fun header(headers: Map<String, List<String>>, name: String): String? =
        headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()

    /** Called with the gate held. */
    private fun rejectSession() {
        tokens.clear()
        token = null
        tokenLoaded = true
        generation += 1
    }

    /** Called with the gate held. */
    private fun loadedToken(): String? {
        if (!tokenLoaded) {
            token = tokens.load()?.takeIf { it.isNotEmpty() }
            tokenLoaded = true
        }
        return token
    }

    private fun url(database: String, operation: String, webAuthToken: String?): String {
        val query = StringBuilder("ckAPIToken=").append(percentEncode(config.apiToken))
        webAuthToken?.let { query.append("&ckWebAuthToken=").append(percentEncode(it)) }
        return "${CloudKitConfig.BASE_URL}/database/1/${config.container}/${config.environment}/$database/$operation?$query"
    }

    companion object {
        const val MAX_ATTEMPTS = 4
        private const val INITIAL_BACKOFF_MS = 1_000L
        private const val MAX_BACKOFF_MS = 30_000L
        private const val MAX_SERVER_DELAY_S = 60.0
        private const val PRIVATE = "private"
        private const val PUBLIC = "public"
        private const val ROTATED_TOKEN_HEADER = "X-Apple-CloudKit-Web-Auth-Token"
        private const val SESSION_HEADER = "X-Apple-CloudKit-Session"
        private val RETRYABLE_STATUSES = setOf(502, 503, 504)

        fun backoff(attempt: Int): Long {
            var delayMs = INITIAL_BACKOFF_MS
            repeat((attempt - 1).coerceIn(0, 16)) { delayMs = (delayMs * 2).coerceAtMost(MAX_BACKOFF_MS) }
            return delayMs
        }

        /** Percent-encodes everything outside RFC 3986's unreserved characters. */
        fun percentEncode(value: String): String {
            val out = StringBuilder()
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                val ch = c.toChar()
                if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                    out.append(ch)
                } else {
                    out.append('%').append(HEX[c shr 4]).append(HEX[c and 0x0F])
                }
            }
            return out.toString()
        }

        private const val HEX = "0123456789ABCDEF"
    }
}

/** Production transport: HttpURLConnection with bounded timeouts and response size. */
class UrlConnectionCloudKitHttp(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 60_000,
) : CloudKitHttp {
    override fun send(request: CloudKitHttpRequest): CloudKitHttpResponse {
        val conn = URL(request.url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = request.method
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = readTimeoutMs
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("Accept", "application/json")
            if (request.body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "text/plain")
                conn.outputStream.use { it.write(request.body.toByteArray(Charsets.UTF_8)) }
            }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val body = stream?.use { input ->
                val bytes = input.readNBytesCompat(MAX_RESPONSE_BYTES + 1)
                if (bytes.size > MAX_RESPONSE_BYTES) throw IOException("CloudKit response too large")
                bytes.toString(Charsets.UTF_8)
            }.orEmpty()
            val headers = conn.headerFields.filterKeys { it != null }.mapKeys { it.key!! }
            return CloudKitHttpResponse(status, headers, body)
        } finally {
            conn.disconnect()
        }
    }

    private companion object {
        const val MAX_RESPONSE_BYTES = 16 * 1024 * 1024
    }
}

/** Reads up to [limit] bytes (InputStream.readNBytes needs API 33). */
internal fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    while (out.size() < limit) {
        val read = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (read < 0) break
        out.write(buffer, 0, read)
    }
    return out.toByteArray()
}
