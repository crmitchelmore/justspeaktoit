package com.justspeaktoit.android.local

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.InputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.coroutines.CoroutineContext

class LocalModelManagerTest {
    @get:Rule val folder = TemporaryFolder()

    private val content = ByteArray(2_000) { (it % 13).toByte() }
    private val tiny = pinnedModel("local/whisperkit/tiny", content)
    private val turbo = pinnedModel("local/whisperkit/large-v3-turbo", content, minimumDeviceMemoryBytes = 8L shl 30)
    private val source = FakeModelSource(content)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val store by lazy { ModelStore(folder.newFolder("models")) }
    private var onWifi = true
    private val gateChecks = CopyOnWriteArrayList<Boolean>()

    private fun manager(memory: Long = 4L shl 30, scope: CoroutineScope = this.scope) = LocalModelManager(
        catalog = listOf(tiny, turbo),
        store = store,
        downloader = ModelDownloader(source) { Long.MAX_VALUE },
        totalMemoryBytes = memory,
        network = NetworkGate { mobile ->
            gateChecks += mobile
            onWifi || mobile
        },
        scope = scope,
        io = Dispatchers.IO,
    )

    private fun LocalModelManager<*>.awaitState(id: String, predicate: (ModelInstallState) -> Boolean) = runBlocking {
        withTimeout(TIMEOUT_MS) { models.first { items -> items.any { it.model.catalogId == id && predicate(it.state) } } }
    }

    @After
    fun tearDown() = scope.cancel()

    @Test
    fun testRefresh_offersOnlyModelsThatFitThisPhone() {
        val manager = manager()
        runBlocking { manager.refresh().join() }
        assertEquals(listOf(tiny.catalogId), manager.models.value.map { it.model.catalogId })
        assertEquals(ModelInstallState.NotDownloaded(), manager.models.value.single().state)

        val roomy = manager(memory = 16L shl 30)
        runBlocking { roomy.refresh().join() }
        assertEquals(listOf(tiny.catalogId, turbo.catalogId), roomy.models.value.map { it.model.catalogId })
    }

    @Test
    fun testDownload_waitsForWifiUnlessMobileDataIsAllowed() {
        onWifi = false
        val manager = manager()
        runBlocking { manager.refresh().join() }

        manager.download(tiny.catalogId, allowMobileData = false)
        assertEquals(ModelInstallState.WaitingForWifi, manager.models.value.single().state)
        assertTrue("nothing is fetched on mobile data", source.requests.isEmpty())

        manager.download(tiny.catalogId, allowMobileData = true)
        manager.awaitState(tiny.catalogId) { it == ModelInstallState.Installed }
        assertEquals(listOf(false, true), gateChecks.toList())
        assertTrue(manager.isInstalled(tiny.catalogId))
        assertEquals(store.file(tiny), manager.installedFile(tiny.catalogId))
    }

    @Test
    fun testRemove_deletesTheModelSoItMustBeDownloadedAgain() {
        val manager = manager()
        runBlocking { manager.refresh().join() }
        manager.download(tiny.catalogId, allowMobileData = false)
        manager.awaitState(tiny.catalogId) { it == ModelInstallState.Installed }

        runBlocking { manager.remove(tiny.catalogId)?.join() }

        assertFalse(store.file(tiny).exists())
        assertEquals(ModelInstallState.NotDownloaded(), manager.models.value.single().state)
        assertNull(manager.installedFile(tiny.catalogId))
    }

    @Test
    fun testFailedDownload_reportsItsReasonAndKeepsWhatArrived() {
        source.respond = { ModelResponse(200, null, content.inputStream(0, 500)) }
        val manager = manager()
        runBlocking { manager.refresh().join() }

        manager.download(tiny.catalogId, allowMobileData = false)

        manager.awaitState(tiny.catalogId) { it == ModelInstallState.Failed(DownloadFailure.Network, 500) }
        assertFalse(manager.isInstalled(tiny.catalogId))
    }

    @Test
    fun testCancel_duringABlockedRead_staysCancelledWhenTheReadCompletes() {
        val reading = CountDownLatch(1)
        val release = CountDownLatch(1)
        // The first read returns 500 bytes; the second blocks until released, then returns the rest,
        // which completes the file and would cross the progress threshold.
        source.respond = {
            ModelResponse(
                200,
                null,
                object : InputStream() {
                    private var position = 0

                    override fun read(): Int = throw UnsupportedOperationException()

                    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                        if (position == content.size) return -1
                        if (position > 0) {
                            reading.countDown()
                            release.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
                        }
                        val count = minOf(length, if (position == 0) 500 else content.size - position)
                        content.copyInto(buffer, offset, position, position + count)
                        position += count
                        return count
                    }
                },
            )
        }
        val manager = manager()
        runBlocking { manager.refresh().join() }

        manager.download(tiny.catalogId, allowMobileData = false)
        assertTrue(reading.await(TIMEOUT_MS, TimeUnit.MILLISECONDS))
        manager.cancel(tiny.catalogId)
        assertEquals(ModelInstallState.NotDownloaded(500), manager.models.value.single().state)
        release.countDown()

        manager.awaitState(tiny.catalogId) { it == ModelInstallState.NotDownloaded(content.size.toLong()) }
        assertFalse(manager.isInstalled(tiny.catalogId))
    }

    /** The first request's second read blocks until [release]; later requests are served normally. */
    private fun blockFirstRead(reading: CountDownLatch, release: CountDownLatch) {
        var first = true
        source.respond = { request ->
            if (!first) {
                source.serve(request)
            } else {
                first = false
                ModelResponse(200, null, BlockingStream(reading, release))
            }
        }
    }

    private inner class BlockingStream(
        private val reading: CountDownLatch,
        private val release: CountDownLatch,
    ) : InputStream() {
        private var position = 0

        override fun read(): Int = throw UnsupportedOperationException()

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (position == content.size) return -1
            if (position > 0) {
                reading.countDown()
                release.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
            }
            val count = minOf(length, if (position == 0) 500 else content.size - position)
            content.copyInto(buffer, offset, position, position + count)
            position += count
            return count
        }
    }

    @Test
    fun testRemove_duringABlockedRead_neverDeletesADownloadStartedAfterIt() {
        val reading = CountDownLatch(1)
        val release = CountDownLatch(1)
        blockFirstRead(reading, release)
        val manager = manager()
        runBlocking { manager.refresh().join() }
        manager.download(tiny.catalogId, allowMobileData = false)
        assertTrue(reading.await(TIMEOUT_MS, TimeUnit.MILLISECONDS))

        val removal = manager.remove(tiny.catalogId)
        manager.download(tiny.catalogId, allowMobileData = false)
        Thread.sleep(QUIET_MS)
        assertEquals("the new download waits for the removal", 1, source.requests.size)
        release.countDown()

        manager.awaitState(tiny.catalogId) { it == ModelInstallState.Installed }
        runBlocking { removal?.join() }
        assertTrue(manager.isInstalled(tiny.catalogId))
        assertEquals(ModelInstallState.Installed, manager.models.value.single().state)
    }

    /** Runs coroutines on [Dispatchers.Default], except that it holds every dispatch while [holding]. */
    private class HoldingDispatcher : CoroutineDispatcher() {
        private val held = mutableListOf<Pair<CoroutineContext, Runnable>>()
        private var holding = false

        fun hold() = synchronized(held) { holding = true }

        fun resume() {
            val queued = synchronized(held) {
                holding = false
                held.toList().also { held.clear() }
            }
            queued.forEach { (context, block) -> Dispatchers.Default.dispatch(context, block) }
        }

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            synchronized(held) {
                if (holding) {
                    held += context to block
                    return
                }
            }
            Dispatchers.Default.dispatch(context, block)
        }
    }

    @Test
    fun testCancelledQueuedResume_stillMakesTheNextResumeWaitForTheBlockedRead() {
        val reading = CountDownLatch(1)
        val release = CountDownLatch(1)
        blockFirstRead(reading, release)
        val dispatcher = HoldingDispatcher()
        val manager = manager(scope = CoroutineScope(scope.coroutineContext + dispatcher))
        runBlocking { manager.refresh().join() }
        manager.download(tiny.catalogId, allowMobileData = false)
        assertTrue(reading.await(TIMEOUT_MS, TimeUnit.MILLISECONDS))
        manager.cancel(tiny.catalogId)

        // Queued behind the blocked read and cancelled before its coroutine has started.
        dispatcher.hold()
        manager.download(tiny.catalogId, allowMobileData = false)
        manager.cancel(tiny.catalogId)
        manager.download(tiny.catalogId, allowMobileData = false)
        dispatcher.resume()
        Thread.sleep(QUIET_MS)
        assertEquals("no resume writes while the first read is still blocked", 1, source.requests.size)
        release.countDown()

        manager.awaitState(tiny.catalogId) { it == ModelInstallState.Installed }
        assertTrue(manager.isInstalled(tiny.catalogId))
    }

    @Test
    fun testDownloadedModel_staysOfferedOnAPhoneWithTooLittleMemory_soItCanBeRemoved() {
        store.dir.mkdirs()
        store.file(turbo).writeBytes(content)
        val manager = manager(memory = 1L shl 30)
        runBlocking { manager.refresh().join() }
        val item = manager.models.value.single { it.model.catalogId == turbo.catalogId }
        assertEquals(ModelInstallState.Installed, item.state)
    }

    private companion object {
        const val TIMEOUT_MS = 10_000L
        const val QUIET_MS = 300L
    }
}
