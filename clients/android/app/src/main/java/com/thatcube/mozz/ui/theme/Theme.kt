package com.thatcube.mozz.ui.theme

import android.app.Activity
import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

// Monochrome, per mozz-design-refs/REDESIGN-PLAN.md: identity comes from the
// logo shape, the typography and intentional whitespace — not from decorative
// colour. No brand-coloured glows, no brand-coloured surfaces.
//
// There is exactly one meaningful colour, the crimson from the Mozz logo, and it
// means "this is THE action". Using it anywhere else spends the only signal the
// palette has.

private val Crimson = Color(0xFFD6002B)
private val CrimsonDim = Color(0xFFB00023)

/**
 * Which of light and dark to use.
 *
 * Same three choices, same stored strings and the same key as the iPhone
 * (`mozz.appearance`), so someone who sets this on one device is not surprised
 * by the other.
 */
enum class MozzAppearance(val stored: String, val label: String) {
    SYSTEM("system", "System"),
    LIGHT("light", "Light"),
    DARK("dark", "Dark");

    companion object {
        val DEFAULT = SYSTEM
        fun from(stored: String?) = entries.firstOrNull { it.stored == stored } ?: DEFAULT
    }
}

/**
 * Which flavour of dark, whenever dark is in use.
 *
 * Dim is a neutral grey ladder; Black is true black, which on an OLED panel is
 * the display switching pixels off rather than painting them dark. Android has
 * only ever had the black one, which is why every surface in the app read as
 * one flat plane.
 */
enum class MozzDarkStyle(val stored: String, val label: String) {
    DIM("dim", "Dim"),
    BLACK("black", "Black");

    companion object {
        val DEFAULT = DIM
        fun from(stored: String?) = entries.firstOrNull { it.stored == stored } ?: DEFAULT
    }
}

/**
 * The choices someone has made about how the app looks.
 *
 * Held as Compose state over `SharedPreferences` so a change repaints the app on
 * the frame it is made, rather than on next launch — picking a theme and
 * watching nothing happen is the kind of thing that makes a setting feel broken.
 */
@Stable
class MozzSettings(context: Context) {
    private val prefs = context.getSharedPreferences("mozz.settings", Context.MODE_PRIVATE)

    private var appearanceState by mutableStateOf(
        MozzAppearance.from(prefs.getString(KEY_APPEARANCE, null))
    )
    private var darkStyleState by mutableStateOf(
        MozzDarkStyle.from(prefs.getString(KEY_DARK_STYLE, null))
    )

    /** Assigning repaints on this frame and persists for the next launch. */
    var appearance: MozzAppearance
        get() = appearanceState
        set(value) {
            appearanceState = value
            prefs.edit().putString(KEY_APPEARANCE, value.stored).apply()
        }

    var darkStyle: MozzDarkStyle
        get() = darkStyleState
        set(value) {
            darkStyleState = value
            prefs.edit().putString(KEY_DARK_STYLE, value.stored).apply()
        }

    private companion object {
        // The iPhone's UserDefaults keys, character for character.
        const val KEY_APPEARANCE = "mozz.appearance"
        const val KEY_DARK_STYLE = "mozz.darkStyle"
    }
}

/**
 * Reachable from anywhere that draws a control for these — which is the settings
 * screen, and nothing else so far.
 */
val LocalMozzSettings = compositionLocalOf<MozzSettings?> { null }

/**
 * Whether the Black dark style is in effect.
 *
 * Black is not a darker Dark. It is the mode where nothing takes its colour from
 * the artwork: every background in the app is black, and a cover is only ever
 * seen inside its own frame. Two places have to know — the player, whose backdrop
 * is otherwise a field sampled from the current cover, and the detail pages,
 * whose hero otherwise bleeds a colour taken from it across the whole page.
 *
 * The same rule, in the same words, is in `MediaDetailScaffold.swift` and
 * `NowPlayingMorph.swift`.
 */
val LocalMozzBlackout = staticCompositionLocalOf { false }

// The surface ladder, matching `Color.mozz*` on iOS tier for tier. In dark mode
// higher surfaces are LIGHTER (Material's rule: darkest is furthest away); in
// light mode the floor is a soft grey and content is white.
//
//              Dim        Black      Light
//  background  #1C1C1E    #000000    #F2F2F7   the page's floor
//  surface     #2C2C2E    #121212    #FFFFFF   cards, list rows, sheets

private val MozzDim = darkColorScheme(
    primary = Crimson,
    onPrimary = Color.White,
    background = Color(0xFF1C1C1E),
    onBackground = Color(0xFFF2F2F2),
    surface = Color(0xFF1C1C1E),
    onSurface = Color(0xFFF2F2F2),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFF9A9A9A),
    outline = Color(0xFF48484A),
    outlineVariant = Color(0xFF3A3A3C),
    error = Crimson,
)

private val MozzBlack = darkColorScheme(
    primary = Crimson,
    onPrimary = Color.White,
    background = Color(0xFF000000),
    onBackground = Color(0xFFF2F2F2),
    surface = Color(0xFF000000),
    onSurface = Color(0xFFF2F2F2),
    surfaceVariant = Color(0xFF141414),
    onSurfaceVariant = Color(0xFF9A9A9A),
    // Faint, but present. On a true-black page a #1C1C1C rule is not a hairline,
    // it is nothing — and separation is the only structure a page has once the
    // backgrounds all agree.
    outline = Color(0xFF3A3A3A),
    outlineVariant = Color(0xFF262626),
    error = Crimson,
)

private val MozzLight = lightColorScheme(
    primary = CrimsonDim,
    onPrimary = Color.White,
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF0A0A0A),
    surface = Color(0xFFF2F2F7),
    onSurface = Color(0xFF0A0A0A),
    surfaceVariant = Color(0xFFFFFFFF),
    onSurfaceVariant = Color(0xFF6B6B6B),
    outline = Color(0xFFDCDCDC),
    outlineVariant = Color(0xFFE6E6EB),
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
    settings: MozzSettings? = null,
    content: @Composable () -> Unit,
) {
    val appearance = settings?.appearance ?: MozzAppearance.DEFAULT
    val dark = when (appearance) {
        MozzAppearance.SYSTEM -> isSystemInDarkTheme()
        MozzAppearance.LIGHT -> false
        MozzAppearance.DARK -> true
    }
    val scheme = when {
        !dark -> MozzLight
        (settings?.darkStyle ?: MozzDarkStyle.DEFAULT) == MozzDarkStyle.BLACK -> MozzBlack
        else -> MozzDim
    }
    // The status bar's icons belong to the window, not to the palette, so they
    // do not follow a colour scheme on their own: choosing Light left white
    // icons on a white bar. Told here rather than in the activity because this
    // is the one place that knows which way the app went.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }

    val blackout = dark && (settings?.darkStyle ?: MozzDarkStyle.DEFAULT) == MozzDarkStyle.BLACK
    CompositionLocalProvider(LocalMozzBlackout provides blackout) {
        MaterialTheme(
            colorScheme = scheme,
            typography = MozzTypography,
            content = content,
        )
    }
}
