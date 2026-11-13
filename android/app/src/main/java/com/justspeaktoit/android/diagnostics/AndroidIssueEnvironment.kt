package com.justspeaktoit.android.diagnostics

import android.Manifest
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** Reads the device facts a report may include. Nothing here identifies the user or the device. */
object AndroidIssueEnvironment {
    fun current(context: Context): IssueEnvironment {
        val info = packageInfo(context)
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val microphone = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
        return IssueEnvironment(
            architecture = IssueEnvironment.architecture(Build.SUPPORTED_ABIS.firstOrNull()),
            // Release builds cannot tell Alpha from Play, so only debug builds name their channel.
            channel = if (debuggable) "development" else "unknown",
            appVersion = info?.versionName,
            appBuild = info?.longVersionCode?.toString(),
            osVersion = Build.VERSION.RELEASE,
            microphonePermission = if (microphone == PackageManager.PERMISSION_GRANTED) "available" else "denied",
        )
    }

    private fun packageInfo(context: Context): PackageInfo? = try {
        val manager = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            manager.getPackageInfo(context.packageName, 0)
        }
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }
}
