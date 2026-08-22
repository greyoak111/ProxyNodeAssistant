package com.proxynodeassistant.android.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Ink = Color(0xFF050A0E)
val Panel = Color(0xFF081219)
val PanelRaised = Color(0xFF0C1B24)
val GridLine = Color(0xFF1A3442)
val Cyan = Color(0xFF00D7F0)
val Mint = Color(0xFF5BF0C1)
val Amber = Color(0xFFFFC247)
val Critical = Color(0xFFFF5E73)
val TextPrimary = Color(0xFFE2F5FF)
val TextMuted = Color(0xFF83A6B8)

private val PnaColors = darkColorScheme(
    primary = Cyan,
    onPrimary = Ink,
    secondary = Mint,
    onSecondary = Ink,
    tertiary = Amber,
    background = Ink,
    onBackground = TextPrimary,
    surface = Panel,
    onSurface = TextPrimary,
    surfaceVariant = PanelRaised,
    onSurfaceVariant = TextMuted,
    outline = GridLine,
    error = Critical,
)

@Composable
fun PnaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = PnaColors, typography = Typography(), content = content)
}
