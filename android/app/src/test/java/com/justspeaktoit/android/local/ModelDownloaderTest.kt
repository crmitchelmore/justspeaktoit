package com.justspeaktoit.android.local

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream

class ModelDownloaderTest {
    @get:Rule val folder = TemporaryFolder()

    private val content = ByteArray(1_000) { (it * 7 % 256).toByte() }
    private val model = pinnedModel(content = content)
    private val source = FakeModelSource(content)
    private val store by lazy { WhisperModelStore(folder.newFolder("models")) }

    private fun download(cancelled: () -> Boolean = { false }, space: Long = Long.MAX_VALUE): DownloadFailure? =
        ModelDownloader(source) { space }.download(model, store, cancelled = cancelled)

    private fun writePartial(bytes: Int) = store.partial(model).writeBytes(content.copyOf(bytes))

    @Test
    fun testFreshDownload_isVerifiedAndMovedIntoPlace() {
        val progress = mutableListOf<Long>()
        assertNull(ModelDownloader(source) { Long.MAX_VALUE }.download(model, store, progress = { progress += it }))
        assertArrayEquals(content, store.file(model).readBytes())
        assertFalse(store.partial(model).exists())
        assertTrue(store.isInstalled(model))
        assertEquals(model.bytes, progress.last())
        assertEquals(listOf(FakeModelSource.Request(model.url, 0)), source.requests.toList())
    }

    @Test
    fun testPartialDownload_resumesFromItsLastByte() {
        writePartial(400)
        assertNull(download())
        assertEquals(listOf(400L), source.requests.map { it.offset })
        assertArrayEquals(content, store.file(model).readBytes())
    }

    @Test
    fun testServerThatIgnoresTheRange_restartsTheFileFromItsFirstByte() {
        writePartial(400)
        source.respond = { ModelResponse(200, null, ByteArrayInputStream(content)) }
        assertNull(download())
        assertArrayEquals(content, store.file(model).readBytes())
    }

    @Test
    fun testRejectedRange_retriesOnceFromTheStart() {
        writePartial(400)
        source.respond = { if (it.offset > 0) ModelResponse(416, null, null) else source.serve(it) }
        assertNull(download())
        assertEquals(listOf(400L, 0L), source.requests.map { it.offset })
        assertTrue(store.isInstalled(model))
    }

    @Test
    fun testRedirects_areFollowedOnlyToAllowedHttpsHosts() {
        val cdn = "https://cdn-lfs.hf.co/repos/model.bin"
        source.respond = { if (it.url == model.url) ModelResponse(302, cdn, null) else source.serve(it) }
        assertNull(download())
        assertEquals(listOf(model.url, cdn), source.requests.map { it.url })

        for (target in listOf("https://evil.example/model.bin", "http://cdn-lfs.hf.co/model.bin")) {
            val other = WhisperModelStore(folder.newFolder())
            source.requests.clear()
            source.respond = { if (it.url == model.url) ModelResponse(302, target, null) else source.serve(it) }
            assertEquals(
                target,
                DownloadFailure.HostNotAllowed,
                ModelDownloader(source) { Long.MAX_VALUE }.download(model, other),
            )
            assertEquals("the untrusted host is never contacted", listOf(model.url), source.requests.map { it.url })
            assertFalse(other.isInstalled(model))
        }
    }

    @Test
    fun testWrongBytes_failTheChecksumAndAreDeleted() {
        val tampered = content.copyOf().also { it[10] = (it[10] + 1).toByte() }
        source.respond = { ModelResponse(200, null, ByteArrayInputStream(tampered)) }
        assertEquals(DownloadFailure.ChecksumMismatch, download())
        assertFalse(store.file(model).exists())
        assertFalse(store.partial(model).exists())
    }

    @Test
    fun testLongerBody_failsTheSizeCheck() {
        source.respond = { ModelResponse(200, null, ByteArrayInputStream(content + byteArrayOf(1))) }
        assertEquals(DownloadFailure.SizeMismatch, download())
        assertFalse(store.isInstalled(model))
        assertEquals(0L, store.partialBytes(model))
    }

    @Test
    fun testDroppedConnection_keepsThePartialFileForTheNextAttempt() {
        source.respond = { ModelResponse(200, null, ByteArrayInputStream(content, 0, 300)) }
        assertEquals(DownloadFailure.Network, download())
        assertEquals(300L, store.partialBytes(model))

        source.respond = source::serve
        assertNull(download())
        assertEquals(300L, source.requests.last().offset)
        assertTrue(store.isInstalled(model))
    }

    @Test
    fun testOfflineCancelledOrFullDisk_eachStopWithItsReason() {
        assertEquals(
            DownloadFailure.Network,
            ModelDownloader(FakeModelSource.failing()) { Long.MAX_VALUE }.download(model, store),
        )
        assertEquals(DownloadFailure.Cancelled, download(cancelled = { true }))
        assertEquals(DownloadFailure.Storage, download(space = model.bytes - 1))
        source.respond = { ModelResponse(404, null, null) }
        assertEquals(DownloadFailure.Http, download())
        assertFalse(store.isInstalled(model))
    }
}
