package com.justspeaktoit.android.sendtomac

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Where a Mac's Send to Mac listener can be reached. */
internal data class ResolvedMac(val addresses: List<InetAddress>, val port: Int)

/**
 * Browses for Macs advertising Send to Mac over DNS-SD with [NsdManager], under the service type
 * from `send_to_mac_protocol.json`, as iOS browses with Bonjour.
 */
internal class MacDiscovery(context: Context, private val serviceType: String) {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.DiscoveryListener? = null

    /**
     * Starts browsing. [onChange] gets the advertised Mac names whenever they change and [onFailure]
     * runs if browsing cannot start; both run on an NSD thread.
     */
    @Synchronized
    fun start(onChange: (List<String>) -> Unit, onFailure: () -> Unit) {
        if (listener != null) return
        val names = sortedSetOf<String>(String.CASE_INSENSITIVE_ORDER)
        val next = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val list = synchronized(names) {
                    names.add(serviceName(serviceInfo))
                    names.toList()
                }
                onChange(list)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val list = synchronized(names) {
                    names.remove(serviceName(serviceInfo))
                    names.toList()
                }
                onChange(list)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                clear(this)
                onFailure()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        listener = next
        try {
            nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, next)
        } catch (_: IllegalArgumentException) {
            listener = null
            onFailure()
        }
    }

    @Synchronized
    fun stop() {
        val current = listener ?: return
        listener = null
        runCatching { nsd.stopServiceDiscovery(current) }
    }

    @Synchronized
    private fun clear(failed: NsdManager.DiscoveryListener) {
        if (listener === failed) listener = null
    }

    /**
     * Finds the Mac advertised as [macName] and resolves its addresses within [timeoutMs].
     * Blocks; throws [IOException] when it is not found in time.
     */
    fun resolve(macName: String, timeoutMs: Long): ResolvedMac {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        fun remainingMs() = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
        val service = find(macName, remainingMs())
        return resolve(service, remainingMs())
    }

    private fun find(macName: String, timeoutMs: Long): NsdServiceInfo {
        val found = AtomicReference<NsdServiceInfo?>()
        val latch = CountDownLatch(1)
        val browse = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceName(serviceInfo) == macName && found.compareAndSet(null, serviceInfo)) latch.countDown()
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = latch.countDown()

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        try {
            nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, browse)
        } catch (error: IllegalArgumentException) {
            throw IOException("Couldn't browse for $macName", error)
        }
        try {
            latch.await(timeoutMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("Interrupted", error)
        } finally {
            runCatching { nsd.stopServiceDiscovery(browse) }
        }
        return found.get() ?: throw IOException("$macName is not advertising Send to Mac")
    }

    private fun resolve(service: NsdServiceInfo, timeoutMs: Long): ResolvedMac =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resolveWithCallback(service, timeoutMs)
        } else {
            resolveLegacy(service, timeoutMs)
        }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun resolveWithCallback(service: NsdServiceInfo, timeoutMs: Long): ResolvedMac {
        val result = AtomicReference<ResolvedMac?>()
        val latch = CountDownLatch(1)
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) = latch.countDown()

            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                val addresses = serviceInfo.hostAddresses
                if (addresses.isNotEmpty() && result.compareAndSet(null, ResolvedMac(addresses, serviceInfo.port))) {
                    latch.countDown()
                }
            }

            override fun onServiceLost() = Unit

            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        nsd.registerServiceInfoCallback(service, DIRECT, callback)
        try {
            await(latch, timeoutMs)
        } finally {
            runCatching { nsd.unregisterServiceInfoCallback(callback) }
        }
        return result.get() ?: throw IOException("Couldn't resolve ${service.serviceName}")
    }

    @Suppress("DEPRECATION") // resolveService and host are the only resolver below API 34.
    private fun resolveLegacy(service: NsdServiceInfo, timeoutMs: Long): ResolvedMac {
        val result = AtomicReference<ResolvedMac?>()
        val latch = CountDownLatch(1)
        nsd.resolveService(
            service,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = latch.countDown()

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    serviceInfo.host?.let { result.set(ResolvedMac(listOf(it), serviceInfo.port)) }
                    latch.countDown()
                }
            },
        )
        await(latch, timeoutMs)
        return result.get() ?: throw IOException("Couldn't resolve ${service.serviceName}")
    }

    private fun await(latch: CountDownLatch, timeoutMs: Long) {
        try {
            latch.await(timeoutMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("Interrupted", error)
        }
    }

    companion object {
        private val DIRECT = Executor { it.run() }

        private fun serviceName(info: NsdServiceInfo): String = unescapeServiceName(info.serviceName.orEmpty())

        /**
         * A DNS-SD instance name as the Mac advertises it. Some Android versions report names with
         * DNS escapes (`\032` for a space, `\.` for a dot); iOS shows and stores the plain name.
         */
        fun unescapeServiceName(name: String): String {
            if ('\\' !in name) return name
            val out = StringBuilder()
            val bytes = java.io.ByteArrayOutputStream()
            fun flush() {
                if (bytes.size() > 0) {
                    out.append(String(bytes.toByteArray(), Charsets.UTF_8))
                    bytes.reset()
                }
            }
            var index = 0
            while (index < name.length) {
                val char = name[index]
                val decimal = name.length >= index + 4 && (1..3).all { name[index + it] in '0'..'9' }
                when {
                    char == '\\' && decimal -> {
                        bytes.write(name.substring(index + 1, index + 4).toInt() and 0xFF)
                        index += 4
                    }
                    char == '\\' && index + 1 < name.length -> {
                        flush()
                        out.append(name[index + 1])
                        index += 2
                    }
                    else -> {
                        flush()
                        out.append(char)
                        index++
                    }
                }
            }
            flush()
            return out.toString()
        }

        /** IPv4 first: a link-local IPv6 address without its scope cannot be dialled. */
        fun dialOrder(addresses: List<InetAddress>): List<InetAddress> =
            addresses.sortedBy { if (it is Inet4Address) 0 else 1 }
    }
}
