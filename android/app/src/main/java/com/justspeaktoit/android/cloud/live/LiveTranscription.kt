package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.PersonalCorrections
import java.util.Locale

/** Creates a live session for a streaming [CloudModel]; each provider keeps its own protocol. */
object LiveTranscription {
    /**
     * [languageTag] is the session's BCP 47 language; providers take its primary language subtag.
     * [words] are personal vocabulary, sent the way each provider accepts it.
     */
    fun create(
        model: CloudModel,
        languageTag: String,
        words: List<String>,
        listener: LiveTranscriptListener,
        scheduler: LiveScheduler = ExecutorLiveScheduler(),
        sockets: LiveSocketFactory = OkHttpLiveSocketFactory(),
    ): LiveTranscriber {
        val route = requireNotNull(model.live) { "${model.catalogId} is not a live model" }
        val language = Locale.forLanguageTag(languageTag).language
            .takeIf { it.isNotEmpty() && route.languageField.isNotEmpty() }
        return when (model.provider) {
            CloudProvider.Deepgram -> DeepgramLiveSession(model, language, words, scheduler, sockets, listener)
            CloudProvider.AssemblyAI -> AssemblyAILiveSession(model, words, scheduler, sockets, listener)
            CloudProvider.OpenAI -> OpenAIRealtimeLiveSession(
                model,
                language,
                PersonalCorrections.vocabularyPrompt(words),
                scheduler,
                sockets,
                listener,
            )
            else -> throw IllegalArgumentException("${model.provider} has no live client")
        }
    }
}
