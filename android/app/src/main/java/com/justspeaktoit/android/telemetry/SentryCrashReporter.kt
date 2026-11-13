package com.justspeaktoit.android.telemetry

import android.content.Context
import io.sentry.Sentry
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid
import java.io.File

/**
 * Sentry crash reporting on the EU project the iOS app uses. Started only by [CrashReportingGate]; the
 * manifest disables Sentry's auto-init provider. Reports carry the stack trace and device/OS context only:
 * no user, IP, request, screenshots, view hierarchy or sessions, and breadcrumbs are limited to lifecycle and
 * navigation, so no transcript, audio, prompt or key can be attached.
 */
class SentryCrashReporter(
    private val context: Context,
    private val release: String,
    private val environment: String,
) : CrashReporter {
    override fun start() {
        SentryAndroid.init(context.applicationContext) { options ->
            options.dsn = DSN
            options.release = release
            options.environment = environment
            options.isEnableAutoSessionTracking = false
            options.isAttachScreenshot = false
            options.isAttachViewHierarchy = false
            options.beforeSend = SentryOptions.BeforeSendCallback { event, _ ->
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
        if (Sentry.isEnabled()) Sentry.close()
        File(context.cacheDir, "sentry").deleteRecursively()
    }

    private companion object {
        // A DSN only permits sending events, so it is public by design; it is the one the iOS app ships.
        const val DSN = "https://0fe99ac203c91b80d4dfb0630ad7be7e@o4510682832240640.ingest.de.sentry.io/4510687487197264"
        val ALLOWED_BREADCRUMBS = setOf("app.lifecycle", "ui.lifecycle", "navigation")
    }
}
