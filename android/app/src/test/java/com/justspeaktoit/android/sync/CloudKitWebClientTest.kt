package com.justspeaktoit.android.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.SocketTimeoutException

class CloudKitWebClientTest {
    private val config = CloudKitConfig("iCloud.com.justspeaktoit", "production", "api token")

    private class MemoryTokens(var token: String? = "web+token/1") : WebAuthTokenStore {
        override fun load() = token

        override fun save(token: String) {
            this.token = token
        }

        override fun clear() {
            token = null
        }
    }

    private class FakeHttp(vararg replies: () -> CloudKitHttpResponse) : CloudKitHttp {
        val queue = replies.toMutableList()
        val requests = mutableListOf<CloudKitHttpRequest>()

        override fun send(request: CloudKitHttpRequest): CloudKitHttpResponse {
            requests += request
            return queue.removeAt(0).invoke()
        }
    }

    private fun ok(body: JSONObject, headers: Map<String, List<String>> = emptyMap()) =
        { CloudKitHttpResponse(200, headers, body.toString()) }

    private fun client(http: CloudKitHttp, tokens: WebAuthTokenStore, sleeps: MutableList<Long> = mutableListOf()) =
        CloudKitWebClient(config, http, tokens, Dispatchers.Unconfined) { sleeps += it }

    @Test
    fun testRequest_carriesBothTokensPercentEncodedAndRotatesTheWebToken() = runBlocking {
        val tokens = MemoryTokens()
        val http = FakeHttp(
            ok(JSONObject().put("userRecordName", "_abc"), mapOf("x-apple-cloudkit-web-auth-token" to listOf("rotated"))),
            ok(JSONObject().put("userRecordName", "_abc")),
        )
        val client = client(http, tokens)
        assertEquals("_abc", client.currentUserRecordName())
        assertEquals(
            "https://api.apple-cloudkit.com/database/1/iCloud.com.justspeaktoit/production/public/users/caller" +
                "?ckAPIToken=api%20token&ckWebAuthToken=web%2Btoken%2F1",
            http.requests[0].url,
        )
        assertEquals("rotated", tokens.token)
        client.currentUserRecordName()
        assertTrue(http.requests[1].url.endsWith("ckWebAuthToken=rotated"))
    }

    @Test
    fun testAuthenticationRequired_clearsTheTokenAndEndsTheSession() = runBlocking {
        val tokens = MemoryTokens()
        val body = JSONObject().put("serverErrorCode", "AUTHENTICATION_REQUIRED").put("redirectURL", "https://idmsa.apple.com/x")
        val http = FakeHttp({ CloudKitHttpResponse(421, emptyMap(), body.toString()) })
        val client = client(http, tokens)
        val session = client.session()
        try {
            client.currentUserRecordName(session)
            fail("expected AuthenticationRequired")
        } catch (e: CloudKitException.AuthenticationRequired) {
            assertEquals("https://idmsa.apple.com/x", e.redirectUrl)
        }
        assertNull(tokens.token)
        try {
            client.currentUserRecordName(session)
            fail("expected SessionChanged")
        } catch (e: CloudKitException.SessionChanged) {
            assertEquals(1, http.requests.size)
        }
    }

    @Test
    fun testTransientFailures_areRetriedWithBackoff() = runBlocking {
        val sleeps = mutableListOf<Long>()
        val throttled = JSONObject().put("serverErrorCode", "THROTTLED").toString()
        val http = FakeHttp(
            { throw SocketTimeoutException() },
            { CloudKitHttpResponse(503, emptyMap(), "") },
            { CloudKitHttpResponse(429, emptyMap(), throttled) },
            ok(JSONObject().put("userRecordName", "_abc")),
        )
        assertEquals("_abc", client(http, MemoryTokens(), sleeps).currentUserRecordName())
        assertEquals(listOf(1_000L, 2_000L, 4_000L), sleeps)
    }

    @Test
    fun testRetries_stopAfterTheLastAttempt() = runBlocking {
        val http = FakeHttp(*Array(CloudKitWebClient.MAX_ATTEMPTS) { { CloudKitHttpResponse(503, emptyMap(), "") } })
        try {
            client(http, MemoryTokens()).currentUserRecordName()
            fail("expected InvalidResponse")
        } catch (e: CloudKitException.InvalidResponse) {
            assertEquals(CloudKitWebClient.MAX_ATTEMPTS, http.requests.size)
        }
    }

    @Test
    fun testUpload_createsAbsentRecordsAndAcknowledgesNewerRemoteOnes() = runBlocking {
        val absent = "00000000-0000-4000-8000-000000000001"
        val present = "00000000-0000-4000-8000-000000000002"
        fun field(value: Any, type: String) = JSONObject().put("value", value).put("type", type)
        val remote = JSONObject().put("recordName", present).put("recordType", HistorySchema.RECORD_TYPE)
            .put("recordChangeTag", "t").put(
                "fields",
                JSONObject().put("entryID", field(present, "STRING")).put("createdAt", field(1, "TIMESTAMP"))
                    .put("updatedAt", field(50, "TIMESTAMP")),
            )
        val http = FakeHttp(
            ok(
                JSONObject().put(
                    "records",
                    JSONArray().put(JSONObject().put("recordName", absent).put("serverErrorCode", "NOT_FOUND")).put(remote),
                ),
            ),
            ok(JSONObject().put("records", JSONArray().put(JSONObject().put("recordName", absent)))),
        )
        val client = client(http, MemoryTokens())
        val transport = CloudKitHistorySyncTransport(client, client.session())
        val local = { id: String -> SyncableHistoryEntry(id, 1, "x", null, "m", 0.0, 1, "android", 10) }
        val result = transport.upload(listOf(local(absent), local(present)))
        assertEquals(setOf(absent, present), result.acknowledgedIds)
        assertEquals(listOf(present), result.remoteEntries.map { it.id })
        assertTrue(result.failures.isEmpty())
        val operations = JSONObject(http.requests[1].body!!).getJSONArray("operations")
        assertEquals(1, operations.length())
        assertEquals("create", operations.getJSONObject(0).getString("operationType"))
        assertTrue(http.requests[1].url.contains("/private/records/modify?"))
    }
}
