package com.justspeaktoit.android.cloud

/** Audio another app shares for transcription, limited to formats every cloud model accepts. */
object SharedAudio {
    /** OpenAI and Groq reject uploads above 25 MB. */
    const val MAX_BYTES = 25L * 1024 * 1024

    data class Format(val extension: String, val mimeType: String)

    private val formats = mapOf(
        "audio/mpeg" to Format("mp3", "audio/mpeg"),
        "audio/mp3" to Format("mp3", "audio/mpeg"),
        "audio/mp4" to Format("m4a", "audio/mp4"),
        "audio/m4a" to Format("m4a", "audio/mp4"),
        "audio/x-m4a" to Format("m4a", "audio/mp4"),
        "audio/wav" to Format("wav", "audio/wav"),
        "audio/x-wav" to Format("wav", "audio/wav"),
        "audio/wave" to Format("wav", "audio/wav"),
        "audio/ogg" to Format("ogg", "audio/ogg"),
        "application/ogg" to Format("ogg", "audio/ogg"),
        "audio/opus" to Format("ogg", "audio/ogg"),
        "audio/webm" to Format("webm", "audio/webm"),
        "audio/flac" to Format("flac", "audio/flac"),
        "audio/x-flac" to Format("flac", "audio/flac"),
    )

    /** Returns null for formats the providers cannot read (for example AMR or raw AAC). */
    fun format(mimeType: String?): Format? =
        mimeType?.substringBefore(';')?.trim()?.lowercase()?.let(formats::get)
}
