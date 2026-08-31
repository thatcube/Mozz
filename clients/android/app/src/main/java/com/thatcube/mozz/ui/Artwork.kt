package com.thatcube.mozz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import coil3.SingletonImageLoader
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Track

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
    size: Int,
    modifier: Modifier = Modifier,
) {
    var url by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(serverId, artworkKey) {
        if (artworkKey == null) {
            url = null
            return@LaunchedEffect
        }
        val resolved = runCatching { server.artworkUrl(serverId, artworkKey, size) }.getOrNull()
        // Only ever replaced by something real. A server that fails to answer for
        // one track should not blank the cover that is already showing.
        if (resolved != null) url = resolved
    }

    Box(
        // A faint wash rather than an opaque surface: in the player this sits on
        // the artwork backdrop, and a solid placeholder reads as a black hole
        // punched in it.
        modifier = modifier.background(Color.White.copy(alpha = 0.06f)),
        contentAlignment = Alignment.Center,
    ) {
        val current = url
        if (current != null) {
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current)
                    .data(current)
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
suspend fun prefetchArtwork(server: MozzServer, context: android.content.Context, track: Track?, size: Int) {
    val key = track?.artworkKey ?: return
    runCatching {
        val url = server.artworkUrl(track.serverId, key, size) ?: return
        SingletonImageLoader.get(context).execute(
            ImageRequest.Builder(context).data(url).build()
        )
    }
}

/** Long enough to read as a dissolve, short enough not to feel slow. */
private const val ARTWORK_FADE_MS = 220
