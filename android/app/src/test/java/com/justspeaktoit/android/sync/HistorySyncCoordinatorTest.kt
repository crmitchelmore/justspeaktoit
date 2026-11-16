package com.justspeaktoit.android.sync

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HistorySyncCoordinatorTest {
    private fun entry(n: Int, updatedAtMs: Long = 10) = SyncableHistoryEntry(
        "00000000-0000-4000-8000-00000000000$n", 1, "text $n", null, "m", 1.0, 2, "android", updatedAtMs,
    )

    private class FakeStore(var pending: MutableList<SyncableHistoryEntry> = mutableListOf()) : HistorySyncLocalStore {
        var cursor: String? = null
        val received = mutableListOf<SyncableHistoryEntry>()
        val deleted = mutableListOf<String>()
        var persists = 0

        override suspend fun loadCursor() = cursor

        override suspend fun saveCursor(token: String) {
            cursor = token
        }

        override suspend fun pendingEntries() = pending.toList()

        override suspend fun didReceiveRemoteEntry(entry: SyncableHistoryEntry) {
            received += entry
            pending.removeAll { it.id == entry.id }
        }

        override suspend fun didDeleteRemoteEntry(id: String) {
            deleted += id
        }

        override suspend fun didAcknowledge(ids: Set<String>) {
            pending.removeAll { it.id in ids }
        }

        override suspend fun persistRemoteChanges() {
            persists += 1
        }
    }

    private class FakeTransport(
        val pages: MutableList<HistoryChangePage> = mutableListOf(),
        var upload: (List<SyncableHistoryEntry>) -> HistoryUploadResult = { batch ->
            HistoryUploadResult(batch.map { it.id }.toSet(), emptyList(), emptyMap())
        },
    ) : HistorySyncTransport {
        val requestedAfter = mutableListOf<String?>()

        override suspend fun fetchChanges(after: String?): HistoryChangePage {
            requestedAfter += after
            return pages.removeAt(0)
        }

        override suspend fun upload(entries: List<SyncableHistoryEntry>) = upload.invoke(entries)

        override suspend fun delete(id: String) = Unit
    }

    @Test
    fun testPass_appliesEveryPageAndSavesEachCursor() = runBlocking {
        val store = FakeStore().apply { cursor = "t0" }
        val transport = FakeTransport(
            mutableListOf(
                HistoryChangePage(listOf(HistoryRemoteChange.Changed(entry(1))), "t1", moreComing = true),
                HistoryChangePage(listOf(HistoryRemoteChange.Deleted(entry(2).id)), "t2", moreComing = false),
            ),
        )
        HistorySyncCoordinator(transport, store).runPass()
        assertEquals(listOf("t0", "t1"), transport.requestedAfter)
        assertEquals("t2", store.cursor)
        assertEquals(listOf(entry(1)), store.received)
        assertEquals(listOf(entry(2).id), store.deleted)
    }

    @Test
    fun testPass_rejectsAPageThatDoesNotAdvance() = runBlocking {
        val store = FakeStore().apply { cursor = "t0" }
        val transport = FakeTransport(mutableListOf(HistoryChangePage(emptyList(), "t0", moreComing = true)))
        try {
            HistorySyncCoordinator(transport, store).runPass()
            fail("expected InvalidChangePage")
        } catch (e: HistorySyncException.InvalidChangePage) {
            assertEquals("t0", store.cursor)
        }
    }

    @Test
    fun testPass_uploadsPendingEntriesAndAppliesNewerRemoteCopies() = runBlocking {
        val store = FakeStore(mutableListOf(entry(1), entry(2)))
        val newer = entry(2, updatedAtMs = 99)
        val transport = FakeTransport(mutableListOf(HistoryChangePage(emptyList(), "t1", false))) { batch ->
            HistoryUploadResult(batch.map { it.id }.toSet(), listOf(newer), emptyMap())
        }
        HistorySyncCoordinator(transport, store).runPass()
        assertTrue(store.pending.isEmpty())
        assertEquals(listOf(newer), store.received)
    }

    @Test
    fun testPass_reportsPartialUploadFailures() = runBlocking {
        val store = FakeStore(mutableListOf(entry(1), entry(2)))
        val transport = FakeTransport(mutableListOf(HistoryChangePage(emptyList(), "t1", false))) { batch ->
            HistoryUploadResult(setOf(batch[0].id), emptyList(), mapOf(batch[1].id to CloudKitException.Encoding()))
        }
        try {
            HistorySyncCoordinator(transport, store).runPass()
            fail("expected PartialUploadFailure")
        } catch (e: HistorySyncException.PartialUploadFailure) {
            assertEquals(1, e.count)
            assertEquals(listOf(entry(2)), store.pending)
        }
    }

    @Test
    fun testPass_stopsWhenNotAdmitted() = runBlocking {
        val store = FakeStore(mutableListOf(entry(1)))
        val transport = FakeTransport(mutableListOf(HistoryChangePage(emptyList(), "t1", false)))
        try {
            HistorySyncCoordinator(transport, store) { throw CloudKitException.SessionChanged() }.runPass()
            fail("expected SessionChanged")
        } catch (e: CloudKitException.SessionChanged) {
            assertTrue(transport.requestedAfter.isEmpty())
        }
    }
}
