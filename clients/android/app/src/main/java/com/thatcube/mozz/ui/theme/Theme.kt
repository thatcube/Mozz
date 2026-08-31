package com.thatcube.mozz.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp

// Monochrome, per mozz-design-refs/REDESIGN-PLAN.md: identity comes from the
// logo shape, the typography and intentional whitespace — not from decorative
// colour. No brand-coloured glows, no brand-coloured surfaces.
//
// There is exactly one meaningful colour, the crimson from the Mozz logo, and it
// means "this is THE action". Using it anywhere else spends the only signal the
// palette has.

private val Crimson = Color(0xFFD6002B)
private val CrimsonDim = Color(0xFFB00023)

private val MozzDark = darkColorScheme(
    primary = Crimson,
    onPrimary = Color.White,
    background = Color(0xFF000000),
    onBackground = Color(0xFFF2F2F2),
    surface = Color(0xFF000000),
    onSurface = Color(0xFFF2F2F2),
    surfaceVariant = Color(0xFF141414),
    onSurfaceVariant = Color(0xFF9A9A9A),
    outline = Color(0xFF2A2A2A),
    outlineVariant = Color(0xFF1C1C1C),
    error = Crimson,
)

private val MozzLight = lightColorScheme(
    primary = CrimsonDim,
    onPrimary = Color.White,
    background = Color(0xFFFFFFFF),
    onBackground = Color(0xFF0A0A0A),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF0A0A0A),
    surfaceVariant = Color(0xFFF4F4F4),
    onSurfaceVariant = Color(0xFF6B6B6B),
    outline = Color(0xFFDCDCDC),
    outlineVariant = Color(0xFFEDEDED),
    error = CrimsonDim,
)

// Tighter tracking and heavier display weights than the Material defaults. The
// wordmark and the headings are doing the work colour is not allowed to do.
private val MozzTypography = Typography().let { base ->
    base.copy(
        displaySmall = base.displaySmall.copy(
            fontWeight = FontWeight.Bold,
            letterSpacing = (-1).sp,
        ),
        headlineMedium = base.headlineMedium.copy(
            fontWeight = FontWeight.SemiBold,
            letterSpacing = (-0.5).sp,
        ),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.Medium),
        labelLarge = base.labelLarge.copy(fontWeight = FontWeight.SemiBold),
    )
}

/** Centred, muted, small — the voice for anything explanatory. */
val quietBody: TextStyle
    @Composable get() = MaterialTheme.typography.bodyMedium.copy(
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        lineHeight = 22.sp,
    )

@Composable
fun MozzTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) MozzDark else MozzLight,
        typography = MozzTypography,
        content = content,
    )
}
