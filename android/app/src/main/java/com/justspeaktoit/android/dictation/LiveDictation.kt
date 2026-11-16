package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.live.LiveOutcome
import com.justspeaktoit.android.cloud.live.LiveTranscriber
import com.justspeaktoit.android.cloud.live.LiveTranscriptListener
import com.justspeaktoit.android.cloud.live.LiveTranscription
import kotlinx.coroutines.CompletableDeferred

/** Creates the streaming client for a live model; tests substitute fake transports. */
internal fun interface LiveSessions {
    fun create(
        model: CloudModel,
        languageTag: String,
        words: List<String>,
        listener: LiveTranscriptListener,
    ): LiveTranscriber

    companion object {
        val Default = LiveSessions { model, languageTag, words, listener ->
            LiveTranscription.create(model, languageTag, words, listener)
        }
    }
}

/** One live session as the controller tracks it; [outcome] completes when the client ends. */
internal class LiveRun(val model: CloudModel) {
    lateinit var client: LiveTranscriber
    val outcome = CompletableDeferred<LiveOutcome>()
}
