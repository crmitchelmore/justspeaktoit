package com.justspeaktoit.android.telemetry

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class PostHogTransportTest {
    private val queued = mutableListOf<Runnable>()
    private val posted = mutableListOf<String>()
    private val payload = AnalyticsPayload(
        event = "app_active_daily",
        distinctId = "abc",
        properties = mapOf("platform" to "android", "analytics_schema_version" to 2),
        timestamp = Instant.parse("2026-07-01T10:00:00Z"),
    )

    private fun transport(key: String) = PostHogTransport(key, { queued += it }, { posted += it })

    @Test
    fun testBlankKey_neverQueuesOrPosts() {
        transport("").send(payload)

        assertTrue(queued.isEmpty())
        assertTrue(posted.isEmpty())
    }

    @Test
    fun testPurge_dropsQueuedSends() {
        val transport = transport("phc_test")
        transport.send(payload)
        transport.purge()
        queued.forEach(Runnable::run)

        assertTrue(posted.isEmpty())
    }

    @Test
    fun testEnvelope_matchesMacShape() {
        val transport = transport("phc_test")
        transport.send(payload)
        queued.forEach(Runnable::run)

        val body = JSONObject(posted.single())
        assertEquals("phc_test", body.getString("api_key"))
        assertEquals("app_active_daily", body.getString("event"))
        val properties = body.getJSONObject("properties")
        assertEquals("abc", properties.getString("distinct_id"))
        assertEquals(true, properties.getBoolean("\$geoip_disable"))
        assertEquals("just-speak-to-it", properties.getString("\$lib"))
        assertEquals("2026-07-01T10:00:00Z", properties.getString("timestamp"))
        assertEquals("android", properties.getString("platform"))
    }
}
