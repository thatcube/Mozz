package com.thatcube.mozz.ui

import android.graphics.Bitmap
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.allowHardware
import coil3.toBitmap
import com.thatcube.mozz.R
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.ui.theme.LocalMozzBlackout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The page every album, artist, playlist and mix is shown on.
 *
 * One scaffold rather than four pages, for the same reason iOS has one
 * (`MediaDetailScaffold.swift`): the *style* of the hero is independent of what
 * the page is about, so a caller picks how its artwork is presented and
 * everything below — the colour the page settles into, the title block, the
 * Play/Shuffle row, the list — is identical everywhere.
 *
 * Two heroes:
 *
 *  * [HeroStyle.FULL_BLEED] — the artwork fills the top of the page and fades
 *    into a colour taken from it. For artists, whose art is a photograph and has
 *    no edges worth respecting.
 *  * [HeroStyle.CENTERED] — the artwork sits in a box on that same colour, so a
 *    square cover is shown whole. For albums and playlists, where the sleeve is
 *    the object.
 *
 * On a wide window both become a row: cover on the left, title and actions
 * beside it. That is not a different design, it is the same one rotated — a
 * 500dp banner across an unfolded display pushes the first song below the fold
 * and leaves the right two thirds of the screen empty.
 */
enum class HeroStyle { FULL_BLEED, CENTERED }

/**
 * The two tones a detail page is painted in.
 *
 * [hero] is the rich colour the artwork fades into; [deep] is the same hue kept
 * clearly tinted but dark enough that white song text stays legible. Sharing the
 * hue is what makes the image continue into the list instead of stopping at it.
 */
data class DetailColors(val hero: Color, val deep: Color)

/**
 * The page's colours, derived from its artwork.
 *
 * Mirrors `DominantColor.swift`: average the whole cover down to one pixel, then
 * push that colour into range — a little richer, and capped in brightness so
 * white text over it stays readable. The averaging is a scale-to-1x1, which is
 * the same thing iOS does by drawing into a one-pixel context.
 *
 * Falls back to a hue derived from [seed] when there is no artwork, so a server
 * that returns none still gets a page that looks deliberate rather than grey.
 */
@Composable
fun rememberDetailColors(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    seed: String,
): DetailColors {
    val context = LocalContext.current
    val fallback = remember(seed) { seedColors(seed) }
    var resolved by remember(serverId, artworkKey, seed) { mutableStateOf(fallback) }

    LaunchedEffect(serverId, artworkKey, seed) {
        val key = artworkKey ?: return@LaunchedEffect
        val average = runCatching {
            withContext(Dispatchers.IO) {
                val url = server.artworkUrl(serverId, key, PALETTE_PIXELS)
                    ?: return@withContext null
                val loader: ImageLoader = SingletonImageLoader.get(context)
                val request = ImageRequest.Builder(context)
                    .data(url)
                    // Hardware bitmaps cannot be read back pixel by pixel, and
                    // reading pixels is the whole point.
                    .allowHardware(false)
                    .build()
                loader.execute(request).image?.toBitmap()?.let(::averageColor)
            }
        }.getOrNull() ?: return@LaunchedEffect
        resolved = adjust(average)
    }

    // The colour eases in when it lands rather than cutting, because it arrives
    // after the page is already on screen.
    val hero by animateColorAsState(resolved.hero, tween(350), label = "detail-hero")
    val deep by animateColorAsState(resolved.deep, tween(350), label = "detail-deep")
    return DetailColors(hero, deep)
}

/** Small on purpose: this image is averaged, never shown. */
private const val PALETTE_PIXELS = 256

private fun averageColor(bitmap: Bitmap): Color {
    val one = Bitmap.createScaledBitmap(bitmap, 1, 1, true)
    val pixel = one.getPixel(0, 0)
    return Color(
        red = ((pixel shr 16) and 0xFF) / 255f,
        green = ((pixel shr 8) and 0xFF) / 255f,
        blue = (pixel and 0xFF) / 255f,
    )
}

/**
 * The hero/deep adjustment, rung for rung with `UIColor.mozzHeroAdjusted` and
 * `mozzDeepAdjusted` on iOS — the same album has to produce the same page on
 * both.
 */
private fun adjust(average: Color): DetailColors {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(average.toArgb(), hsv)
    val hero = android.graphics.Color.HSVToColor(
        floatArrayOf(hsv[0], minOf(1f, hsv[1] * 1.15f), minOf(hsv[2], 0.46f))
    )
    val deep = android.graphics.Color.HSVToColor(
        floatArrayOf(hsv[0], minOf(hsv[1], 0.6f), 0.18f)
    )
    return DetailColors(Color(hero), Color(deep))
}

/** Deterministic stand-in for a page with no artwork. */
private fun seedColors(seed: String): DetailColors {
    val hue = (kotlin.math.abs(seed.hashCode()) % 360).toFloat()
    return DetailColors(
        hero = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.5f, 0.42f))),
        deep = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.45f, 0.18f))),
    )
}

/**
 * A detail page.
 *
 * [content] is a `LazyListScope` rather than a composable slot: an album's songs
 * or an artist's shelves belong to the same scroll as the hero — a nested
 * scroller inside a header is the thing that makes a long playlist feel wrong —
 * and on a large library that list is long enough to need to be lazy.
 */
@Composable
fun MediaDetail(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    style: HeroStyle,
    /**
     * Whether the artwork is a person, and so drawn round.
     *
     * A property of the subject, not of the hero style. Deriving it from
     * `FULL_BLEED` was wrong in both directions: Liked Songs and the mixes are
     * full-bleed and are not people, and in Black every hero is framed, so the
     * style stops saying anything about shape at all.
     */
    circular: Boolean = false,
    title: String,
    subtitle: String? = null,
    meta: String? = null,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
    actions: @Composable () -> Unit,
    content: LazyListScope.() -> Unit,
) {
    // Black takes no colour from the artwork, and a full-bleed hero IS the
    // artwork bleeding into the page — so in Black the hero is always the framed
    // one and the page stays black behind it. See `LocalMozzBlackout`.
    val blackout = LocalMozzBlackout.current
    // Not merely overridden afterwards: in Black the palette is never derived at
    // all, so the cover is not decoded a second time to be averaged.
    val colors = if (blackout) DetailColors(Color.Black, Color.Black)
    else rememberDetailColors(server, serverId, artworkKey, seed = title)
    val heroStyle = if (blackout) HeroStyle.CENTERED else style
    val listState = rememberLazyListState()
    val density = LocalDensity.current
    var headerHeight by remember { mutableStateOf(0) }

    // Everything on this page sits on the extracted colour, which is
    // brightness-capped so that white reads over it at either end of the app's
    // light/dark setting. Stating it once here is what lets every row below be
    // an ordinary composable that knows nothing about where it is.
    CompositionLocalProvider(LocalContentColor provides Color.White) {
        Box(modifier = Modifier.fillMaxSize().background(colors.deep)) {
            // The seam. The hero's colour holds behind the header and through the
            // first rows, then eases into the page's settled tone — so the artwork
            // continues into the list rather than stopping at a line.
            //
            // Drawn UNDER the list and translated by the list's own scroll, rather
            // than being an item in it: as an item it would either take space the
            // rows need or have to be layered by them, and the first thing you
            // notice when a fade is a row is the edge where it ends.
            val fadePx = with(density) { CONTENT_FADE.roundToPx() }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(with(density) { (headerHeight + fadePx).toDp() })
                    .offset { IntOffset(0, -scrolledPast(listState)) }
                    .background(
                        Brush.verticalGradient(
                            0f to colors.hero,
                            (headerHeight.toFloat() / (headerHeight + fadePx)) to colors.hero,
                            1f to colors.deep,
                        )
                    )
            )

            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
            ) {
                item(key = "hero") {
                    Box(modifier = Modifier.onSizeChanged { headerHeight = it.height }) {
                        if (wide) {
                            WideHero(server, serverId, artworkKey, heroStyle, circular, title, subtitle, meta, colors, actions)
                        } else {
                            NarrowHero(server, serverId, artworkKey, heroStyle, circular, title, subtitle, meta, colors, actions)
                        }
                    }
                }
                content()
            }

            // Back stays below the status bar even though the artwork bleeds under
            // it — the button is chrome, and chrome that hides behind a notch is
            // just a button you cannot press.
            DetailBackButton(
                onBack,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(start = 8.dp, top = 4.dp),
            )
        }
    }
}

/** How far the page has scrolled, while the header is still the first item. */
private fun scrolledPast(state: LazyListState): Int =
    if (state.firstVisibleItemIndex == 0) state.firstVisibleItemScrollOffset else Int.MAX_VALUE / 2

@Composable
private fun NarrowHero(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    style: HeroStyle,
    circular: Boolean,
    title: String,
    subtitle: String?,
    meta: String?,
    colors: DetailColors,
    actions: @Composable () -> Unit,
) {
    when (style) {
        HeroStyle.FULL_BLEED -> BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val width = maxWidth
            val height = minOf(FULL_BLEED_HEIGHT, width * 1.3f)
            val heroPixels = artworkPixels(maxOf(width, height))
            Box(modifier = Modifier.fillMaxWidth().height(height)) {
                Artwork(
                    server = server,
                    serverId = serverId,
                    artworkKey = artworkKey,
                    pixels = heroPixels,
                    modifier = Modifier.fillMaxSize(),
                )
                // Keeps the title legible and lands the image on the page colour.
                Box(
                    modifier = Modifier.fillMaxSize().background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.45f to Color.Transparent,
                            0.78f to colors.hero.copy(alpha = 0.55f),
                            1f to colors.hero,
                        )
                    )
                )
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    TitleBlock(title, subtitle, meta, TextAlign.Center)
                    Spacer(Modifier.height(14.dp))
                    actions()
                }
            }
        }

        HeroStyle.CENTERED -> Column(
            modifier = Modifier
                .fillMaxWidth()
                // The cover is a square being shown whole, so unlike the
                // full-bleed hero it has no business under the status bar.
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top))
                .padding(horizontal = 16.dp)
                .padding(top = 52.dp, bottom = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Artwork(
                server = server,
                serverId = serverId,
                artworkKey = artworkKey,
                pixels = artworkPixels(CENTERED_ART),
                modifier = Modifier
                    .size(CENTERED_ART)
                    .shadow(18.dp, if (circular) CircleShape else RoundedCornerShape(14.dp))
                    .clip(if (circular) CircleShape else RoundedCornerShape(14.dp)),
                shape = if (circular) CircleShape else RoundedCornerShape(14.dp),
            )
            Spacer(Modifier.height(16.dp))
            TitleBlock(title, subtitle, meta, TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            actions()
        }
    }
}

/**
 * The same hero laid across a wide window: cover on the left, everything that
 * describes it on the right, both left-aligned.
 *
 * iOS has no equivalent because iOS has no wide player or wide library — this is
 * the arrangement every large-screen music app converged on, and the one an
 * unfolded display asks for.
 */
@Composable
private fun WideHero(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    style: HeroStyle,
    circular: Boolean,
    title: String,
    subtitle: String?,
    meta: String?,
    colors: DetailColors,
    actions: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        // A third of the window's width, within reason: small enough to leave the
        // titles room to breathe, large enough to still be the thing you look at.
        //
        // Bounded by the window's HEIGHT as well, which is the constraint that
        // actually bites on a landscape window: a wide window is usually a short
        // one, and sizing the cover off width alone filled the screen with it and
        // pushed the first shelf off the bottom. The height is read from the
        // configuration because this is inside a lazy list, where the incoming
        // height constraint is infinite.
        val window = LocalConfiguration.current.screenHeightDp.dp
        val side = minOf(maxWidth * 0.32f, window * 0.45f).coerceIn(180.dp, 340.dp)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top))
                .padding(horizontal = WIDE_INSET)
                .padding(top = 52.dp, bottom = 24.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Artwork(
                server = server,
                serverId = serverId,
                artworkKey = artworkKey,
                pixels = artworkPixels(side),
                modifier = Modifier
                    .size(side)
                    .shadow(20.dp, if (circular) CircleShape else RoundedCornerShape(14.dp))
                    .clip(if (circular) CircleShape else RoundedCornerShape(14.dp)),
                shape = if (circular) CircleShape else RoundedCornerShape(14.dp),
            )
            Spacer(Modifier.width(28.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.Bottom,
            ) {
                TitleBlock(title, subtitle, meta, TextAlign.Start)
                Spacer(Modifier.height(18.dp))
                // Held to the width the buttons are legible at rather than
                // stretched across the window: a Play button half a metre wide is
                // not easier to press, it is just further from the cover it plays.
                Box(modifier = Modifier.width(380.dp)) { actions() }
            }
        }
    }
}

@Composable
private fun TitleBlock(title: String, subtitle: String?, meta: String?, align: TextAlign) {
    Column(
        horizontalAlignment = if (align == TextAlign.Center) Alignment.CenterHorizontally else Alignment.Start,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            textAlign = align,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        if (subtitle != null) {
            Spacer(Modifier.height(4.dp))
            Text(
                subtitle,
                style = MaterialTheme.typography.titleMedium,
                color = Color.White.copy(alpha = 0.9f),
                textAlign = align,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (meta != null) {
            Spacer(Modifier.height(4.dp))
            Text(
                meta,
                style = MaterialTheme.typography.labelMedium,
                color = Color.White.copy(alpha = 0.7f),
                textAlign = align,
            )
        }
    }
}

/**
 * Play and Shuffle.
 *
 * White fill for Play and a white outline for Shuffle, because on this page the
 * background is whatever colour the album happens to be — the app's one crimson
 * would land on a red sleeve and vanish, and on a green one it would be the
 * loudest thing on screen.
 */
@Composable
fun DetailPlayActions(onPlay: () -> Unit, onShuffle: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        DetailActionButton(
            label = "Play",
            icon = R.drawable.ic_play,
            filled = true,
            onClick = onPlay,
            modifier = Modifier.weight(1f),
        )
        DetailActionButton(
            label = "Shuffle",
            icon = R.drawable.ic_shuffle,
            filled = false,
            onClick = onShuffle,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun DetailActionButton(
    label: String,
    icon: Int,
    filled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .height(48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (filled) Color.White else Color.White.copy(alpha = 0.16f))
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val tint = if (filled) Color.Black else Color.White
        Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = tint,
        )
    }
}

/** The floating back control the detail pages use in place of a top bar. */
@Composable
fun DetailBackButton(onBack: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.35f))
            .clickable(onClick = onBack),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(R.drawable.ic_chevron_left),
            contentDescription = "Back",
            tint = Color.White,
            modifier = Modifier.size(22.dp),
        )
    }
}

/** A section title inside a detail page's content. */
@Composable
fun DetailSectionHeader(title: String, trailing: (@Composable () -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 26.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke()
    }
}

/** iOS's `fullBleedHeight`. */
private val FULL_BLEED_HEIGHT = 500.dp

/** iOS's `centeredArtworkSize`. */
private val CENTERED_ART = 240.dp

/** How far the hero's colour takes to become the page's. iOS fades over 420pt. */
private val CONTENT_FADE = 420.dp

/** Wide windows get a wider margin, the way every other surface in the app does. */
val WIDE_INSET = 32.dp
