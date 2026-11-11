package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CloudException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

class CloudCaptureTest {
    @get:Rule val folder = TemporaryFolder()

    private val recorders = FakeRecorders()
    private val retirement = RecorderRetirement(Dispatchers.IO)
    private val capture by lazy { owner() }

    /** A new owner, as a recreated ViewModel builds, sharing this test's retirement lane. */
    private fun owner() = CloudCapture(recorders, folder.root, Dispatchers.IO, retirement)

    private fun start(): CloudCapture.Recording {
        assertTrue(capture.start(onLevel = {}, onLimitReached = {}, onCaptureFailed = {}))
        return checkNotNull(capture.current)
    }

    @Test
    fun testStart_ownsTheRecordingUntilItHasStopped() = runBlocking {
        val recording = start()
        assertTrue(capture.owns(recording))
        assertTrue(recording.file.exists())

        assertEquals(recorders.bytes, capture.stop(recording))
        assertFalse(capture.owns(recording))
        assertNull(capture.current)
        assertTrue("stop keeps the file for the upload", recording.file.exists())
    }

    @Test
    fun testFailedStart_ownsNothingAndDeletesTheFile() {
        recorders.opens = false
        assertFalse(capture.start(onLevel = {}, onLimitReached = {}, onCaptureFailed = {}))
        assertNull(capture.current)
        assertTrue(folder.root.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun testCallbacks_carryTheirOwnRecording() {
        val limited = AtomicReference<CloudCapture.Recording?>()
        val failed = AtomicReference<CloudCapture.Recording?>()
        capture.start(onLevel = {}, onLimitReached = limited::set, onCaptureFailed = failed::set)
        val recorder = recorders.last
        recorder.onLimitReached()
        recorder.onCaptureFailed()
        assertSame(capture.current, limited.get())
        assertSame(capture.current, failed.get())
    }

    @Test
    fun testDiscard_stopsDeletesAndReleases() = runBlocking {
        val recording = start()
        capture.discard(recording)
        assertEquals(1, recorders.last.stops)
        assertFalse(recording.file.exists())
        assertNull(capture.current)
    }

    @Test
    fun testClose_stopsAndDeletesAnOwnedRecordingOffTheCallingThread() {
        val recording = start()
        capture.close()
        assertNull(capture.current)
        ViewModelHarness.await(recorders.last.stopped)
        val end = System.currentTimeMillis() + ViewModelHarness.TIMEOUT_MS
        while (recording.file.exists() && System.currentTimeMillis() < end) Thread.sleep(5)
        assertFalse(recording.file.exists())
    }

    @Test
    fun testClose_withNothingOwned_doesNothing() {
        assertNull(capture.close())
        assertTrue(recorders.created.isEmpty())
    }

    @Test
    fun testClose_whileTheRecorderStopStalls_returnsAtOnceAndReleasesWhenItUnblocks() = runBlocking {
        val gate = CountDownLatch(1)
        recorders.stopGate = gate
        val recording = start()

        val teardown = checkNotNull(capture.close())
        assertNull("ownership ends immediately", capture.current)
        ViewModelHarness.await(recorders.last.stopEntered)
        assertTrue("the stalled stop keeps its file until it returns", recording.file.exists())
        assertFalse(teardown.isCompleted)

        gate.countDown()
        withTimeout(ViewModelHarness.TIMEOUT_MS) { teardown.join() }
        assertFalse(recording.file.exists())
    }

    @Test
    fun testRecreatedOwners_shareOneLane_andRefuseNewRecordingsWhileOrphansAreStalled() = runBlocking {
        val gate = CountDownLatch(1)
        recorders.stopGate = gate
        val owners = List(3) { owner() }
        val orphans = owners.take(2).map { owner ->
            assertTrue(owner.start(onLevel = {}, onLimitReached = {}, onCaptureFailed = {}))
            val recording = checkNotNull(owner.current)
            recording to checkNotNull(owner.close())
        }

        ViewModelHarness.await(recorders.created[0].stopEntered)
        Thread.sleep(50)
        assertEquals("one stalled stop holds the only lane thread", 0, recorders.created[1].stops)
        assertEquals(2, retirement.pendingOrphans)
        assertFalse("no microphone opens while two orphans wait", owners[2].start({}, {}, {}))
        assertEquals(2, recorders.created.size)
        assertNull(owners[2].current)

        gate.countDown()
        orphans.forEach { (recording, teardown) ->
            withTimeout(ViewModelHarness.TIMEOUT_MS) { teardown.join() }
            assertFalse("stopped, then deleted", recording.file.exists())
        }
        assertEquals(listOf(1, 1), recorders.created.map { it.stops })
        assertEquals(0, retirement.pendingOrphans)
        assertTrue("admission reopens once the orphans are released", owners[2].start({}, {}, {}))
    }

    @Test
    fun testClose_duringAnOwnersStop_joinsItWithoutASecondStopOrDelete() = runBlocking {
        val gate = CountDownLatch(1)
        recorders.stopGate = gate
        val recording = start()
        val stopping = async(Dispatchers.Default) { capture.stop(recording) }
        ViewModelHarness.await(recorders.last.stopEntered)

        val teardown = checkNotNull(capture.close())
        assertSame("close joins the stop under way", recording.stopped, teardown)
        assertEquals("the ownerless stop counts until it settles", 1, retirement.pendingOrphans)

        gate.countDown()
        assertEquals(recorders.bytes, withTimeout(ViewModelHarness.TIMEOUT_MS) { stopping.await() })
        teardown.join()
        assertEquals(1, recorders.last.stops)
        assertEquals(0, retirement.pendingOrphans)
        assertTrue("the stopping path still owns the file", recording.file.exists())
    }

    @Test
    fun testRecreatedOwners_eachClosingDuringAStalledStop_refuseNewRecordingsUntilTheStopsSettle() = runBlocking {
        val gate = CountDownLatch(1)
        recorders.stopGate = gate
        val owners = List(3) { owner() }
        val stops = owners.take(2).map { owner ->
            assertTrue(owner.start(onLevel = {}, onLimitReached = {}, onCaptureFailed = {}))
            val recording = checkNotNull(owner.current)
            val stopping = async(Dispatchers.Default) { owner.stop(recording) }
            ViewModelHarness.await(recorders.last.stopEntered)
            Triple(recording, stopping, checkNotNull(owner.close()))
        }

        assertEquals(2, retirement.pendingOrphans)
        assertFalse("no microphone opens while two ownerless stops stall", owners[2].start({}, {}, {}))
        assertEquals(2, recorders.created.size)

        gate.countDown()
        stops.forEach { (recording, stopping, teardown) ->
            assertEquals(recorders.bytes, withTimeout(ViewModelHarness.TIMEOUT_MS) { stopping.await() })
            teardown.join()
            assertTrue("the stopping path still owns the file", recording.file.exists())
        }
        assertEquals("each recorder stopped exactly once", listOf(1, 1), recorders.created.map { it.stops })
        assertEquals(0, retirement.pendingOrphans)
        assertTrue("admission reopens once the stops settle", owners[2].start({}, {}, {}))
    }

    @Test
    fun testStop_afterCloseClaimedTheRecording_waitsForTheOrphanStop() = runBlocking {
        val recording = start()
        val teardown = checkNotNull(capture.close())

        assertEquals(recorders.bytes, withTimeout(ViewModelHarness.TIMEOUT_MS) { capture.stop(recording) })
        teardown.join()
        assertEquals(1, recorders.last.stops)
        assertFalse(recording.file.exists())
    }

    @Test
    fun testCall_returnsTheResult() = runBlocking {
        assertEquals("ok", capture.call(1_000) { "ok" })
    }

    @Test
    fun testCall_cancellingTheCallerAbortsTheBlockedRequest() = runBlocking {
        val entered = CountDownLatch(1)
        val handle = AtomicReference<CallHandle>()
        val job = launch(Dispatchers.Default) {
            runCatching {
                capture.call(60_000) { call ->
                    handle.set(call)
                    entered.countDown()
                    while (!call.cancelled) Thread.sleep(5)
                    throw CloudException(DictationFailure.Network, "aborted")
                }
            }
        }
        ViewModelHarness.await(entered)
        job.cancel()
        job.join()
        assertTrue(handle.get().cancelled)
    }

    @Test
    fun testCall_pastTheDeadline_failsAsNetworkTimeoutEvenIfTheBlockIgnoresTheAbort() {
        val error = assertThrows(CloudException::class.java) {
            runBlocking {
                capture.call(20) { Thread.sleep(200) }
            }
        }
        assertEquals(DictationFailure.NetworkTimeout, error.failure)
    }

    @Test
    fun testCall_whenTheDeadlineAbortsTheRequest_failsAsNetworkTimeoutNotAsTheAbortError() {
        val error = assertThrows(CloudException::class.java) {
            runBlocking {
                capture.call(20) { call ->
                    while (!call.cancelled) Thread.sleep(5)
                    // What a disconnected HttpURLConnection reports.
                    throw CloudException(DictationFailure.Network, "Socket closed")
                }
            }
        }
        assertEquals(DictationFailure.NetworkTimeout, error.failure)
    }

    @Test
    fun testCall_blockFailureBeforeTheDeadline_isReportedAsIs() {
        val error = assertThrows(CloudException::class.java) {
            runBlocking { capture.call(1_000) { throw CloudException(DictationFailure.InvalidKey, "401") } }
        }
        assertEquals(DictationFailure.InvalidKey, error.failure)
    }

    @Test
    fun testBounded_usesTheCallersTimeoutFailure() {
        val error = assertThrows(CloudException::class.java) {
            runBlocking {
                capture.bounded(20, DictationFailure.Audio, abort = {}) {
                    Thread.sleep(200)
                }
            }
        }
        assertEquals(DictationFailure.Audio, error.failure)
    }
}
