package com.justspeaktoit.android.ondevice

import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.justspeaktoit.android.cloud.CleanupPolicy
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GeminiNanoCleanupTest {
    private class FakeModel(
        var status: GeminiNanoStatus = GeminiNanoStatus.Available,
        var systemInstruction: Boolean = true,
        var tokens: Int = 100,
        var reply: GeminiNanoReply = GeminiNanoReply(" Hello, world. ", truncated = false),
        var failure: GeminiNanoFailure? = null,
        val onCount: () -> Unit = {},
    ) : GeminiNanoModel {
        val calls = mutableListOf<String>()
        val generated = mutableListOf<GeminiNanoRequest>()

        override suspend fun status(): GeminiNanoStatus {
            calls += "status"
            return status
        }

        override suspend fun supportsSystemInstruction(): Boolean = systemInstruction

        override suspend fun countTokens(request: GeminiNanoRequest): Int {
            calls += "count"
            onCount()
            return tokens
        }

        override suspend fun generate(request: GeminiNanoRequest): GeminiNanoReply {
            calls += "generate"
            generated += request
            failure?.let { throw GeminiNanoException(it) }
            return reply
        }

        override fun download(): Flow<GeminiNanoDownload> = emptyFlow()

        override fun close() = Unit
    }

    private fun clean(model: FakeModel, transcript: String = "hello world", isTopApp: () -> Boolean = { true }) =
        runBlocking { GeminiNanoCleanup(model, isTopApp, inputTokenLimit = 4_000).clean(transcript, "Clean it.") }

    @Test
    fun testClean_sendsTheInstructionAndTheTranscriptDataSeparately() {
        val model = FakeModel()

        assertEquals(GeminiNanoResult.Cleaned("Hello, world."), clean(model))
        assertEquals(
            listOf(GeminiNanoRequest("Clean it.", CleanupPolicy.userMessage("hello world"))),
            model.generated,
        )
    }

    @Test
    fun testClean_putsTheInstructionAheadOfTheDataWithoutSystemInstructionSupport() {
        val model = FakeModel(systemInstruction = false)

        clean(model)

        val request = model.generated.single()
        assertNull(request.systemInstruction)
        assertEquals("Clean it.\n\n" + CleanupPolicy.userMessage("hello world"), request.text)
    }

    @Test
    fun testClean_skipsAnEmptyTranscriptWithoutCallingTheModel() {
        val model = FakeModel()

        assertEquals(GeminiNanoResult.Skipped, clean(model, transcript = "  \n"))
        assertTrue(model.calls.isEmpty())
    }

    @Test
    fun testClean_failsInTheBackgroundWithoutCallingTheModel() {
        val model = FakeModel()

        assertEquals(GeminiNanoResult.Failed(GeminiNanoFailure.NotInForeground), clean(model) { false })
        assertTrue(model.calls.isEmpty())
    }

    @Test
    fun testClean_checksTheForegroundAgainBeforeGenerating() {
        var inFront = true
        val model = FakeModel(onCount = { inFront = false })

        assertEquals(GeminiNanoResult.Failed(GeminiNanoFailure.NotInForeground), clean(model) { inFront })
        assertFalse("generate" in model.calls)
    }

    @Test
    fun testClean_keepsTheTranscriptOverTheInputTokenLimit() {
        val model = FakeModel(tokens = 4_001)

        assertEquals(GeminiNanoResult.Failed(GeminiNanoFailure.TooLong), clean(model))
        assertFalse("generate" in model.calls)
        assertEquals(GeminiNanoResult.Cleaned("Hello, world."), clean(FakeModel(tokens = 4_000)))
    }

    @Test
    fun testClean_failsUntilTheModelIsDownloadedAndWhereItIsUnavailable() {
        assertEquals(
            GeminiNanoResult.Failed(GeminiNanoFailure.NotDownloaded),
            clean(FakeModel(status = GeminiNanoStatus.Downloadable)),
        )
        assertEquals(
            GeminiNanoResult.Failed(GeminiNanoFailure.NotDownloaded),
            clean(FakeModel(status = GeminiNanoStatus.Downloading)),
        )
        val unavailable = FakeModel(status = GeminiNanoStatus.Unavailable)
        assertEquals(GeminiNanoResult.Failed(GeminiNanoFailure.Unavailable), clean(unavailable))
        assertEquals(listOf("status"), unavailable.calls)
    }

    @Test
    fun testClean_reportsAICoreRefusalsAsVisibleFailures() {
        listOf(
            GeminiNanoFailure.NotInForeground,
            GeminiNanoFailure.Busy,
            GeminiNanoFailure.QuotaExceeded,
        ).forEach { failure ->
            assertEquals(GeminiNanoResult.Failed(failure), clean(FakeModel(failure = failure)))
        }
    }

    @Test
    fun testClean_keepsTheTranscriptForACutShortOrEmptyReply() {
        assertEquals(
            GeminiNanoResult.Failed(GeminiNanoFailure.TooLong),
            clean(FakeModel(reply = GeminiNanoReply("Hello", truncated = true))),
        )
        assertEquals(
            GeminiNanoResult.Failed(GeminiNanoFailure.NoReply),
            clean(FakeModel(reply = GeminiNanoReply(" ", truncated = false))),
        )
        assertEquals(
            GeminiNanoResult.Failed(GeminiNanoFailure.NoReply),
            clean(FakeModel(reply = GeminiNanoReply(null, truncated = false))),
        )
    }

    @Test
    fun testFailureFor_mapsMlKitErrorCodes() {
        mapOf(
            GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED to GeminiNanoFailure.NotInForeground,
            GenAiException.ErrorCode.BUSY to GeminiNanoFailure.Busy,
            GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED to GeminiNanoFailure.QuotaExceeded,
            GenAiException.ErrorCode.REQUEST_TOO_LARGE to GeminiNanoFailure.TooLong,
            GenAiException.ErrorCode.NOT_AVAILABLE to GeminiNanoFailure.Unavailable,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE to GeminiNanoFailure.NeedsSystemUpdate,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE to GeminiNanoFailure.NotEnoughStorage,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR to GeminiNanoFailure.Failed,
        ).forEach { (code, failure) -> assertEquals("$code", failure, MlKitGeminiNano.failureFor(code)) }
    }

    @Test
    fun testStatusFor_mapsMlKitFeatureStatus() {
        assertEquals(GeminiNanoStatus.Available, MlKitGeminiNano.statusFor(FeatureStatus.AVAILABLE))
        assertEquals(GeminiNanoStatus.Downloadable, MlKitGeminiNano.statusFor(FeatureStatus.DOWNLOADABLE))
        assertEquals(GeminiNanoStatus.Downloading, MlKitGeminiNano.statusFor(FeatureStatus.DOWNLOADING))
        assertEquals(GeminiNanoStatus.Unavailable, MlKitGeminiNano.statusFor(FeatureStatus.UNAVAILABLE))
    }

    @Test
    fun testAvailability_followsADownloadAndOffersOnlySupportedPhones() {
        var state = GeminiNanoAvailability.of(GeminiNanoStatus.Downloadable)
        assertTrue(state.offered)
        state = GeminiNanoAvailability.after(GeminiNanoDownload.Started(1_000), state)
        state = GeminiNanoAvailability.after(GeminiNanoDownload.Progress(250), state)
        assertEquals(GeminiNanoAvailability.Downloading(250, 1_000), state)
        assertEquals(
            GeminiNanoAvailability.DownloadFailed(GeminiNanoFailure.NotEnoughStorage),
            GeminiNanoAvailability.after(GeminiNanoDownload.Failed(GeminiNanoFailure.NotEnoughStorage), state),
        )
        assertEquals(GeminiNanoAvailability.Available, GeminiNanoAvailability.after(GeminiNanoDownload.Completed, state))
        assertFalse(GeminiNanoAvailability.of(GeminiNanoStatus.Unavailable).offered)
        assertFalse(GeminiNanoAvailability.Checking.offered)
    }
}
