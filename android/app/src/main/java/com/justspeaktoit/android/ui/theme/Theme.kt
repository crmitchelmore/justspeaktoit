package com.justspeaktoit.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

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

@Composable
fun JustSpeakTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}
