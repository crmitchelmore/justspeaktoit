package com.justspeaktoit.android.ondevice

/**
 * Whether this phone offers Gemini Nano, as Settings and the cleanup picker show it. It is checked only
 * when one of them opens or Gemini Nano is chosen, never at app start, so phones that never look at it
 * never bind to AICore.
 */
sealed interface GeminiNanoAvailability {
    data object Unchecked : GeminiNanoAvailability

    data object Checking : GeminiNanoAvailability

    data object Available : GeminiNanoAvailability

    /** Supported, but the model is still to download; choosing it starts the download. */
    data object Downloadable : GeminiNanoAvailability

    /** [totalBytes] is 0 until AICore says how large the download is. */
    data class Downloading(val downloadedBytes: Long, val totalBytes: Long) : GeminiNanoAvailability

    /** The download stopped; it can be retried. */
    data class DownloadFailed(val reason: GeminiNanoFailure) : GeminiNanoAvailability

    /** Not offered on this phone; [reason] explains why. */
    data class Unavailable(val reason: GeminiNanoFailure) : GeminiNanoAvailability

    /** Whether the picker lists Gemini Nano: the phone supports it, downloaded or not. */
    val offered: Boolean
        get() = this is Available || this is Downloadable || this is Downloading || this is DownloadFailed

    companion object {
        fun of(status: GeminiNanoStatus): GeminiNanoAvailability = when (status) {
            GeminiNanoStatus.Available -> Available
            GeminiNanoStatus.Downloadable -> Downloadable
            GeminiNanoStatus.Downloading -> Downloading(0, 0)
            GeminiNanoStatus.Unavailable -> Unavailable(GeminiNanoFailure.Unavailable)
        }

        /** The next state for a download update. */
        fun after(update: GeminiNanoDownload, current: GeminiNanoAvailability): GeminiNanoAvailability {
            val total = (current as? Downloading)?.totalBytes ?: 0
            return when (update) {
                is GeminiNanoDownload.Started -> Downloading(0, update.bytesToDownload)
                is GeminiNanoDownload.Progress -> Downloading(update.bytesDownloaded, total)
                GeminiNanoDownload.Completed -> Available
                is GeminiNanoDownload.Failed -> DownloadFailed(update.failure)
            }
        }
    }
}
