package com.justspeaktoit.android.ondevice

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Candidate
import com.google.mlkit.genai.prompt.Feature
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map

/**
 * [GeminiNanoModel] over the ML Kit GenAI Prompt API (`com.google.mlkit:genai-prompt`). The client is
 * created on first use, so phones that never choose Gemini Nano never bind to AICore, and [close]
 * releases it once no request is using it.
 */
internal class MlKitGeminiNano : GeminiNanoModel {
    private val client = ReleasableClient<GenerativeModel>(create = Generation::getClient, release = { it.close() })

    override suspend fun status(): GeminiNanoStatus =
        try {
            statusFor(client.use { it.checkStatus() })
        } catch (e: CancellationException) {
            throw e
        } catch (e: GenAiException) {
            // checkStatus reports a missing AICore or feature (NOT_SUPPORTED, AICORE_INCOMPATIBLE) by throwing.
            if (failureFor(e.errorCode) == GeminiNanoFailure.NeedsSystemUpdate) {
                throw GeminiNanoException(GeminiNanoFailure.NeedsSystemUpdate, e)
            }
            GeminiNanoStatus.Unavailable
        } catch (e: RuntimeException) {
            // A phone without AICore can fail to bind with a platform exception; a closed client lands here too.
            GeminiNanoStatus.Unavailable
        }

    override suspend fun supportsSystemInstruction(): Boolean =
        call { Feature.SYSTEM_PROMPT in it.getAvailableFeatures() }

    override suspend fun countTokens(request: GeminiNanoRequest): Int =
        call { it.countTokens(request.toMlKit()).totalTokens }

    override suspend fun generate(request: GeminiNanoRequest): GeminiNanoReply =
        call {
            val candidate = it.generateContent(request.toMlKit()).candidates.firstOrNull()
            GeminiNanoReply(candidate?.text, candidate?.finishReason == Candidate.FinishReason.MAX_TOKENS)
        }

    override fun download(): Flow<GeminiNanoDownload> =
        flow { client.use { emitAll(it.download()) } }
            .map { status ->
                when (status) {
                    is DownloadStatus.DownloadStarted -> GeminiNanoDownload.Started(status.bytesToDownload)
                    is DownloadStatus.DownloadProgress -> GeminiNanoDownload.Progress(status.totalBytesDownloaded)
                    is DownloadStatus.DownloadCompleted -> GeminiNanoDownload.Completed
                    is DownloadStatus.DownloadFailed -> GeminiNanoDownload.Failed(failureFor(status.e.errorCode))
                }
            }
            .catch { error ->
                if (error is CancellationException) throw error
                val failure = (error as? GenAiException)?.let { failureFor(it.errorCode) } ?: GeminiNanoFailure.Failed
                emit(GeminiNanoDownload.Failed(failure))
            }

    override fun close() = client.close()

    private suspend fun <T> call(block: suspend (GenerativeModel) -> T): T =
        try {
            client.use(block)
        } catch (e: CancellationException) {
            throw e
        } catch (e: GenAiException) {
            throw GeminiNanoException(failureFor(e.errorCode), e)
        } catch (e: RuntimeException) {
            // AICore can also fail with a platform exception (a lost binding); keep the transcript.
            throw GeminiNanoException(GeminiNanoFailure.Failed, e)
        }

    private fun GeminiNanoRequest.toMlKit(): GenerateContentRequest {
        val build: GenerateContentRequest.Builder.() -> Unit = { temperature = CLEANUP_TEMPERATURE }
        val instruction = systemInstruction
        return if (instruction == null) {
            generateContentRequest(TextPart(text), build)
        } else {
            generateContentRequest(SystemInstruction(instruction), TextPart(text), build)
        }
    }

    companion object {
        /** Cleanup should repeat the speaker's words, not improvise. */
        private const val CLEANUP_TEMPERATURE = 0.2f

        fun statusFor(featureStatus: Int): GeminiNanoStatus =
            when (featureStatus) {
                FeatureStatus.AVAILABLE -> GeminiNanoStatus.Available
                FeatureStatus.DOWNLOADABLE -> GeminiNanoStatus.Downloadable
                FeatureStatus.DOWNLOADING -> GeminiNanoStatus.Downloading
                else -> GeminiNanoStatus.Unavailable
            }

        /** What the user is told for an ML Kit `GenAiException.ErrorCode`. */
        fun failureFor(errorCode: Int): GeminiNanoFailure =
            when (errorCode) {
                GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> GeminiNanoFailure.NotInForeground
                GenAiException.ErrorCode.BUSY -> GeminiNanoFailure.Busy
                GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> GeminiNanoFailure.QuotaExceeded
                GenAiException.ErrorCode.REQUEST_TOO_LARGE -> GeminiNanoFailure.TooLong
                GenAiException.ErrorCode.NOT_AVAILABLE,
                GenAiException.ErrorCode.NOT_SUPPORTED,
                -> GeminiNanoFailure.Unavailable
                GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
                GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
                -> GeminiNanoFailure.NeedsSystemUpdate
                GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> GeminiNanoFailure.NotEnoughStorage
                else -> GeminiNanoFailure.Failed
            }
    }
}
