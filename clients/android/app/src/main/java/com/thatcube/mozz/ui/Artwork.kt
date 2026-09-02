package com.thatcube.mozz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import coil3.SingletonImageLoader
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.ui.theme.LocalMozzBlackout

/**
 * Album art for one artwork key.
 *
 * The URL is not built here. `artworkURL` is a core command because each server
 * addresses and sizes its thumbnails differently, and the token that authorises
 * the fetch belongs with the backend that issued it — so this asks, and Coil
 * loads whatever comes back.
 *
 * Two waits stack up behind every cover: resolving the URL through the core, and
 * then fetching the image. The previous cover is therefore held on screen until
 * the next one has actually arrived, rather than being cleared the moment the
 * track changes — clearing first is what produced a black square between songs,
 * because it made both waits visible instead of neither.
 */
@Composable
fun Artwork(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    /** Pixels to ask for — see [artworkPixels], which is how callers get one. */
    pixels: Int,
    modifier: Modifier = Modifier,
    /**
     * The shape the caller has clipped this to.
     *
     * Only used to draw the empty frame's hairline in Black, where the
     * placeholder wash is black like everything else and a coverless album
     * would otherwise be nothing at all. Pass the same shape as the `clip`:
     * a hairline drawn in a rounder shape than the clip has its corners eaten
     * by the clip, which is how a square cover ends up with four notches.
     */
    shape: Shape = RoundedCornerShape(6.dp),
) {
    val blackout = LocalMozzBlackout.current
    var url by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(serverId, artworkKey, pixels) {
        if (artworkKey == null) {
            url = null
            return@LaunchedEffect
        }
        val resolved = runCatching { server.artworkUrl(serverId, artworkKey, pixels) }.getOrNull()
        // Only ever replaced by something real. A server that fails to answer for
        // one track should not blank the cover that is already showing.
        if (resolved != null) url = resolved
    }

    Box(
        // A faint wash rather than an opaque surface: in the player this sits on
        // the artwork backdrop, and a solid placeholder reads as a black hole
        // punched in it. In Black the wash goes too — nothing is a lighter shade
        // of the page there — and a hairline marks the empty frame instead.
        modifier = modifier
            .background(if (blackout) Color.Transparent else Color.White.copy(alpha = 0.06f)),
        contentAlignment = Alignment.Center,
    ) {
        val current = url
        if (current == null && blackout) {
            // The empty frame, and only the empty frame. This used to be a
            // modifier on the Box, so it was drawn behind every cover as well —
            // invisible under an opaque one, but there all the same, and showing
            // through the crossfade and through art with transparency.
            //
            // Inset by its own width rather than sitting on the boundary. A
            // stroke drawn flush to the edge is a stroke the caller's clip
            // antialiases away at the corners, which is the whole reason these
            // looked notched.
            Spacer(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(HAIRLINE)
                    .border(HAIRLINE, MaterialTheme.colorScheme.outline, shape)
            )
        }
        if (current != null) {
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current)
                    .data(current)
                    // Decode at the size we asked the server for, rather than at
                    // whatever this box measures. The player's cover is laid out
                    // by the morph, so its measured size sweeps from a 48dp
                    // thumbnail to the full screen while it opens — letting Coil
                    // size the decode off that would sample the cover down to the
                    // dock and then scale that back up.
                    .size(pixels)
                    .crossfade(ARTWORK_FADE_MS)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/**
 * Warm the cache for a track that is about to play.
 *
 * The difference between a cover that appears and a cover that pops in is
 * entirely whether the fetch started before the track changed, which is why iOS
 * prefetches too. Failures are ignored on purpose: this is opportunistic.
 */
suspend fun prefetchArtwork(server: MozzServer, context: android.content.Context, track: Track?, pixels: Int) {
    val key = track?.artworkKey ?: return
    runCatching {
        val url = server.artworkUrl(track.serverId, key, pixels) ?: return
        SingletonImageLoader.get(context).execute(
            ImageRequest.Builder(context).data(url).build()
        )
    }
}

/** Long enough to read as a dissolve, short enough not to feel slow. */
private const val ARTWORK_FADE_MS = 220

/** The empty frame's line, and the distance it keeps from the clip. */
private val HAIRLINE = 1.dp

/**
 * How many pixels to ask a server for, given how many pixels a slot will draw.
 *
 * Mirrors `ArtworkResolution` in the Swift core, rung for rung, because a cover
 * fetched on the phone and the same cover fetched on the desktop should be the
 * same bytes — a shared ladder is what makes that true.
 *
 * Every artwork request used to carry a hand-picked constant, which is a guess
 * about a screen. The expanded player asked for 1024 pixels and drew them across
 * 1921 on a fold's inner display: a 1.9x upscale, and the reason big covers
 * looked soft there while the same covers looked fine in a list. The number a
 * slot needs is not a constant; it is the slot's own size times this display's
 * density.
 *
 * Asking for exactly that would be worse, though. Each distinct size is a
 * separate transcode on the server and a separate cache entry, so requests are
 * snapped UP to a rung: a whole device class shares one value, and no cover is
 * ever smaller than the box it fills.
 */
object ArtworkResolution {
    /** Roughly √2 apart. */
    private val RUNGS = intArrayOf(128, 192, 256, 384, 512, 768, 1024, 1536, 2048)

    /**
     * The smallest rung that covers [pixels], capped at the largest.
     *
     * The cap matters: a full-bleed hero on an unfolded display can measure past
     * 2700 physical pixels, and no music server holds cover art that big — asking
     * only makes the server upscale, which costs time and buys nothing.
     */
    fun rung(pixels: Int): Int = RUNGS.firstOrNull { it >= pixels } ?: RUNGS.last()
}

/** The rung for a slot drawn at [side] on this display. */
@Composable
fun artworkPixels(side: Dp): Int {
    val density = LocalDensity.current
    return ArtworkResolution.rung(with(density) { side.roundToPx() })
}
