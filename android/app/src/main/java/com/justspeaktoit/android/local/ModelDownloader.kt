package com.justspeaktoit.android.local

import android.annotation.SuppressLint
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URISyntaxException
import java.net.URL
import java.security.MessageDigest

/** Where downloaded models live: `<dir>/<filename>`, and `<filename>.part` while downloading. */
class WhisperModelStore(val dir: File) {
    fun file(model: WhisperModel) = File(dir, model.filename)

    fun partial(model: WhisperModel) = File(dir, model.filename + ".part")

    /**
     * A model is installed once its verified file is in place. Its SHA-256 is checked before it is moved
     * there, so later uses check only the size; a file damaged since fails to load and shows an error.
     */
    fun isInstalled(model: WhisperModel): Boolean = file(model).let { it.isFile && it.length() == model.bytes }

    fun partialBytes(model: WhisperModel): Long = partial(model).takeIf { it.isFile }?.length() ?: 0L

    /** Removes the model and any partial download. */
    fun remove(model: WhisperModel) {
        file(model).delete()
        partial(model).delete()
    }
}

/** Why a download stopped. A partial download is kept for every reason except a bad checksum or size. */
enum class DownloadFailure { Network, Http, HostNotAllowed, SizeMismatch, ChecksumMismatch, Storage, Cancelled }

/** One HTTP response, with redirects left for [ModelDownloader] to check. */
class ModelResponse(
    val status: Int,
    val location: String?,
    val body: InputStream?,
    private val onClose: () -> Unit = {},
) : Closeable {
    override fun close() {
        try {
            body?.close()
        } finally {
            onClose()
        }
    }
}

/** Opens a model URL from a byte offset, without following redirects. Faked in tests. */
fun interface ModelSource {
    @Throws(IOException::class)
    fun open(url: String, offset: Long): ModelResponse
}

/**
 * Downloads a pinned model into a [WhisperModelStore], resuming a partial download with an HTTP range
 * request. Every hop, redirects included, must be HTTPS to a host the pin allows; the finished file
 * must match the pinned size and SHA-256 before it is moved into place.
 */
class ModelDownloader(
    private val source: ModelSource = HttpModelSource(),
    private val usableSpace: (File) -> Long = ::fileUsableSpace,
) {
    /**
     * Blocks until the model is installed or the download stops; returns null on success. [progress]
     * receives the bytes on disk; [cancelled] is polled between reads.
     */
    fun download(
        model: WhisperModel,
        store: WhisperModelStore,
        progress: (Long) -> Unit = {},
        cancelled: () -> Boolean = { false },
    ): DownloadFailure? {
        if (store.isInstalled(model)) return null
        if (!store.dir.isDirectory && !store.dir.mkdirs()) return DownloadFailure.Storage
        val part = store.partial(model)
        if (store.partialBytes(model) > model.bytes) part.delete()
        if (usableSpace(store.dir) < model.bytes - store.partialBytes(model)) return DownloadFailure.Storage
        var retriedFromStart = false
        while (true) {
            val offset = store.partialBytes(model)
            val fetched = if (offset == model.bytes) Fetched.Complete else fetch(model, part, offset, progress, cancelled)
            when (fetched) {
                Fetched.Complete -> return install(model, store, part)
                is Fetched.Failed -> return fetched.failure
                Fetched.RangeRejected -> {
                    if (retriedFromStart) return DownloadFailure.Http
                    retriedFromStart = true
                    part.delete()
                }
            }
        }
    }

    private fun fetch(
        model: WhisperModel,
        part: File,
        offset: Long,
        progress: (Long) -> Unit,
        cancelled: () -> Boolean,
    ): Fetched {
        val response = try {
            resolve(model, offset)
        } catch (e: IOException) {
            return Fetched.Failed(DownloadFailure.Network)
        } catch (e: RedirectRejected) {
            return Fetched.Failed(e.failure)
        }
        val failure = response.use {
            when (response.status) {
                HttpURLConnection.HTTP_PARTIAL -> if (offset > 0) {
                    copy(response, part, offset, model.bytes, progress, cancelled)
                } else {
                    DownloadFailure.Http
                }
                // The server ignored the range, so the body starts again from the first byte.
                HttpURLConnection.HTTP_OK -> copy(response, part, 0L, model.bytes, progress, cancelled)
                RANGE_NOT_SATISFIABLE -> return Fetched.RangeRejected
                else -> DownloadFailure.Http
            }
        }
        return if (failure == null) Fetched.Complete else Fetched.Failed(failure)
    }

    private fun resolve(model: WhisperModel, offset: Long): ModelResponse {
        var url = model.url
        repeat(MAX_REDIRECTS + 1) {
            val uri = try {
                URI(url)
            } catch (e: URISyntaxException) {
                throw RedirectRejected(DownloadFailure.HostNotAllowed)
            }
            if (uri.scheme != "https" || !model.allowsHost(uri.host.orEmpty())) {
                throw RedirectRejected(DownloadFailure.HostNotAllowed)
            }
            val response = source.open(url, offset)
            if (response.status !in REDIRECTS) return response
            val location = response.location
            response.close()
            url = try {
                uri.resolve(location ?: throw RedirectRejected(DownloadFailure.Http)).toString()
            } catch (e: IllegalArgumentException) {
                throw RedirectRejected(DownloadFailure.HostNotAllowed)
            }
        }
        throw RedirectRejected(DownloadFailure.Http)
    }

    private fun copy(
        response: ModelResponse,
        part: File,
        offset: Long,
        expected: Long,
        progress: (Long) -> Unit,
        cancelled: () -> Boolean,
    ): DownloadFailure? {
        val body = response.body ?: return DownloadFailure.Http
        var written = offset
        try {
            FileOutputStream(part, offset > 0).use { out ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    if (cancelled()) return DownloadFailure.Cancelled
                    val read = body.read(buffer)
                    if (read < 0) break
                    if (written + read > expected) {
                        part.delete()
                        return DownloadFailure.SizeMismatch
                    }
                    out.write(buffer, 0, read)
                    written += read
                    progress(written)
                }
            }
        } catch (e: IOException) {
            return if (part.parentFile?.let(usableSpace) == 0L) DownloadFailure.Storage else DownloadFailure.Network
        }
        // A short body is a dropped connection: keep the partial file so the next attempt resumes it.
        return if (written < expected) DownloadFailure.Network else null
    }

    private fun install(model: WhisperModel, store: WhisperModelStore, part: File): DownloadFailure? {
        if (part.length() != model.bytes) {
            part.delete()
            return DownloadFailure.SizeMismatch
        }
        val digest = try {
            sha256(part)
        } catch (e: IOException) {
            return DownloadFailure.Storage
        }
        if (digest != model.sha256) {
            part.delete()
            return DownloadFailure.ChecksumMismatch
        }
        val target = store.file(model)
        target.delete()
        return if (part.renameTo(target)) null else DownloadFailure.Storage
    }

    private sealed interface Fetched {
        data object Complete : Fetched
        data object RangeRejected : Fetched
        data class Failed(val failure: DownloadFailure) : Fetched
    }

    private class RedirectRejected(val failure: DownloadFailure) : Exception()

    companion object {
        private const val MAX_REDIRECTS = 5
        private const val BUFFER_BYTES = 64 * 1024
        private const val RANGE_NOT_SATISFIABLE = 416
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

// getAllocatableBytes counts cache the system frees only through allocateBytes, which a
// plain stream copy cannot use, so usableSpace is the space this write can really fill.
@SuppressLint("UsableSpace")
private fun fileUsableSpace(file: File): Long = file.usableSpace

/** Production [ModelSource]: one HTTPS request per hop, with redirects returned rather than followed. */
class HttpModelSource : ModelSource {
    override fun open(url: String, offset: Long): ModelResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.setRequestProperty("Accept-Encoding", "identity")
        if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
        return try {
            val status = connection.responseCode
            val body = if (status == HttpURLConnection.HTTP_OK || status == HttpURLConnection.HTTP_PARTIAL) {
                connection.inputStream
            } else {
                null
            }
            ModelResponse(status, connection.getHeaderField("Location"), body, connection::disconnect)
        } catch (e: IOException) {
            connection.disconnect()
            throw e
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 15_000
        const val READ_TIMEOUT_MS = 30_000
    }
}
