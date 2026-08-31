package com.thatcube.mozz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.produceState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import coil3.compose.AsyncImage
import com.thatcube.mozz.core.MozzServer

/**
 * Album art for one artwork key.
 *
 * The URL is not built here. `artworkURL` is a core command because each server
 * addresses and sizes its thumbnails differently, and the token that authorises
 * the fetch belongs with the backend that issued it — so this asks, and Coil
 * loads whatever comes back.
 *
 * A missing key, a server with no thumbnail, or a failed load all land in the
 * same place: the empty square below. Album art is decoration on a list whose
 * text already says what the record is, so none of those is worth an error.
 */
@Composable
fun Artwork(
    server: MozzServer,
    serverId: String,
    artworkKey: String?,
    size: Int,
    modifier: Modifier = Modifier,
) {
    val url by produceState<String?>(initialValue = null, serverId, artworkKey, size) {
        value = artworkKey?.let { key ->
            runCatching { server.artworkUrl(serverId, key, size) }.getOrNull()
        }
    }

    Box(
        modifier = modifier.background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
