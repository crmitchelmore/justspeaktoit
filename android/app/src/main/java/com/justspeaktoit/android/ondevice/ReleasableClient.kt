package com.justspeaktoit.android.ondevice

/**
 * A client that is created on first use and released exactly once. Each [use] holds a lease, so [close]
 * during a request releases the client only when the last lease ends rather than under the request.
 * After [close], [use] throws [ClosedException] and never creates a client.
 */
internal class ReleasableClient<T : Any>(
    private val create: () -> T,
    private val release: (T) -> Unit,
) {
    private val lock = Any()
    private var client: T? = null
    private var leases = 0
    private var closed = false

    suspend fun <R> use(block: suspend (T) -> R): R {
        val leased = acquire()
        try {
            return block(leased)
        } finally {
            endLease()
        }
    }

    /** Releases the client once no request holds it; safe to call repeatedly or before first use. */
    fun close() {
        val idle = synchronized(lock) {
            if (closed) return
            closed = true
            if (leases == 0) client.also { client = null } else null
        }
        idle?.let(release)
    }

    private fun acquire(): T =
        synchronized(lock) {
            if (closed) throw ClosedException()
            val leased = client ?: create().also { client = it }
            leases++
            leased
        }

    private fun endLease() {
        val last = synchronized(lock) {
            leases--
            if (closed && leases == 0) client.also { client = null } else null
        }
        last?.let(release)
    }

    class ClosedException : IllegalStateException("The client has been closed")
}
