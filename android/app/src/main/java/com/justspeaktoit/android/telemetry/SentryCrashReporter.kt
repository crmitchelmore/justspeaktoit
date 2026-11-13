package com.justspeaktoit.android.telemetry

import android.content.Context
import io.sentry.IConnectionStatusProvider.ConnectionStatus
import io.sentry.Sentry
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid
import io.sentry.transport.ITransportGate
import java.io.File

/**
 * Sentry crash reporting on the EU project the iOS app uses. Started only by [CrashReportingGate]; the
 * manifest disables Sentry's auto-init provider. Reports carry the stack trace and device/OS context only:
 * no user, IP, request, screenshots, view hierarchy or sessions, and breadcrumbs are limited to lifecycle and
 * navigation, so no transcript, audio, prompt or key can be attached.
 *
 * Withdrawing consent closes the transport gate and drops new events before anything else, so the flush
 * [Sentry.close] performs can only write envelopes to the cache, which [stop] then deletes.
 */
class SentryCrashReporter(
    private val context: Context,
    private val release: String,
    private val environment: String,
) : CrashReporter {
    @Volatile private var reporting = false
    @Volatile private var cacheDir: File = File(context.cacheDir, "sentry")

    override fun start() {
        reporting = true
        SentryAndroid.init(context.applicationContext) { options ->
            options.dsn = DSN
            options.release = release
            options.environment = environment
            options.isEnableAutoSessionTracking = false
            options.isAttachScreenshot = false
            options.isAttachViewHierarchy = false
            options.cacheDirPath?.let { cacheDir = File(it) }
            // Replaces Sentry's Android gate, so it repeats that gate's connectivity check.
            options.transportGate = ITransportGate {
                reporting && options.connectionStatusProvider.connectionStatus != ConnectionStatus.DISCONNECTED
            }
            options.beforeSend = SentryOptions.BeforeSendCallback { event, _ ->
                if (!reporting) return@BeforeSendCallback null
                event.user = null
                event.request = null
                event.serverName = null
                event
            }
            options.beforeBreadcrumb = SentryOptions.BeforeBreadcrumbCallback { breadcrumb, _ ->
                breadcrumb.takeIf { it.category in ALLOWED_BREADCRUMBS }
            }
        }
    }

    override fun stop() {
        reporting = false
        cacheDir.deleteRecursively()
        if (Sentry.isEnabled()) Sentry.close()
        // Close's flush cannot pass the gate, so it caches what was still queued; delete that too.
        cacheDir.deleteRecursively()
    }

    private companion object {
        // A DSN only permits sending events, so it is public by design; it is the one the iOS app ships.
        const val DSN = "https://0fe99ac203c91b80d4dfb0630ad7be7e@o4510682832240640.ingest.de.sentry.io/4510687487197264"
        val ALLOWED_BREADCRUMBS = setOf("app.lifecycle", "ui.lifecycle", "navigation")
    }
}
