package com.justspeaktoit.android.ui.theme

import android.os.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// The Mac app's brand palette (Color.brandAccent, brandAccentDeep, brandAccentWarm).
val BrandAccent = Color(0xFFFF6B3D)
val BrandAccentDeep = Color(0xFFE3522E)
val BrandAccentWarm = Color(0xFFFF9C4A)

private val LightColors = lightColorScheme(
    primary = Color(0xFFB83A17),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDBCF),
    onPrimaryContainer = Color(0xFF3A0B00),
    secondary = BrandAccentWarm,
    onSecondary = Color(0xFF2B1600),
)

private val DarkColors = darkColorScheme(
    primary = BrandAccent,
    onPrimary = Color(0xFF3A0B00),
    primaryContainer = Color(0xFF7A2A12),
    onPrimaryContainer = Color(0xFFFFDBCF),
    secondary = BrandAccentWarm,
    onSecondary = Color(0xFF2B1600),
)

/** Wallpaper (Material You) colour schemes exist from Android 12. */
val supportsDynamicColor: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/** [dark] is the resolved appearance (see `AppAppearance.isDark`), not the phone's setting. */
@Composable
fun JustSpeakTheme(dark: Boolean, dynamicColor: Boolean = false, content: @Composable () -> Unit) {
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        dark -> DarkColors
        else -> LightColors
    }
    MaterialTheme(colorScheme = colors, content = content)
}
