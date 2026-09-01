package com.thatcube.mozz.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.Artist
import com.thatcube.mozz.core.HomeMix
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Playlist
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlayerController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Everywhere a tab can go.
 *
 * The same set iOS routes through `AppRoute`, and for the same reason: pushes
 * carry a *value*, not a view, so the stack can be inspected, popped to its root
 * and — later — restored from a deep link or a widget.
 */
sealed interface Route {
    data class AlbumPage(val album: Album) : Route
    data class ArtistPage(val artist: Artist) : Route
    data class PlaylistPage(val playlist: Playlist) : Route
    data class MixPage(val mix: HomeMix) : Route
    data object LikedSongs : Route
    data object AllSongs : Route
    data object AllArtists : Route
    data object AllAlbums : Route
    data object AllPlaylists : Route
    data object AllGenres : Route
    data class GenrePage(val genre: String) : Route

    /** An artist's full ranked song list, behind "See All". */
    data class ArtistSongs(val artist: Artist) : Route

    data object Settings : Route
    data object SettingsAppearance : Route

    /**
     * A settings page that exists in the map before it exists in code. Carries
     * its own text so one destination covers every one of them.
     */
    data class SettingsSoon(val title: String, val promise: String) : Route
}

/**
 * One tab's history.
 *
 * A tab per stack rather than one stack for the app, because switching tabs and
 * coming back to where you were is the behaviour every phone app has, and losing
 * your place is the thing people notice.
 */
@Stable
class BrowseStack {
    var entries by mutableStateOf<List<Route>>(emptyList())
        private set

    val current: Route? get() = entries.lastOrNull()
    val isEmpty: Boolean get() = entries.isEmpty()

    fun push(route: Route) { entries = entries + route }
    fun pop() { entries = entries.dropLast(1) }
    fun popToRoot() { entries = emptyList() }
}

/**
 * How a page asks to go somewhere.
 *
 * [openArtist] takes a remote id rather than an artist because that is all a
 * song or an album knows about who made it — the record itself is fetched on the
 * way, so tapping an artist's name anywhere in the app lands on the same page.
 */
@Stable
class Navigator(
    private val stack: BrowseStack,
    private val library: MozzLibrary,
    private val scope: CoroutineScope,
) {
    fun open(route: Route) = stack.push(route)
    fun back() = stack.pop()

    fun openArtist(serverId: String, remoteId: String?) {
        val id = remoteId ?: return
        scope.launch {
            runCatching { library.artist(serverId, id) }.getOrNull()?.let { stack.push(Route.ArtistPage(it)) }
        }
    }

    fun openAlbum(serverId: String, remoteId: String?) {
        val id = remoteId ?: return
        scope.launch {
            runCatching { library.album(serverId, id) }.getOrNull()?.let { stack.push(Route.AlbumPage(it)) }
        }
    }
}

// MARK: - Rows

/**
 * A song, as it appears in a list.
 *
 * Given a server it carries its cover; inside an album it does not, because
 * forty copies of one sleeve is noise rather than information. [index] shows a
 * track number in its place, which is what an album wants there.
 */
@Composable
fun SongRow(
    track: Track,
    server: MozzServer? = null,
    index: Int? = null,
    /** Replaces the artist on the second line — the album, on an artist's page. */
    subtitle: String? = null,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (server != null) {
            Artwork(
                server = server,
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                pixels = artworkPixels(44.dp),
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)),
            )
            Spacer(Modifier.width(14.dp))
        } else if (index != null) {
            Text(
                "$index",
                style = MaterialTheme.typography.bodyMedium,
                color = LocalContentColor.current.copy(alpha = 0.5f),
                modifier = Modifier.width(28.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // Only where it tells you something. Inside an album every row has
            // the same artist and the same album name, so a second line there is
            // the album's own title repeated once per song.
            if (server != null) {
                Spacer(Modifier.height(2.dp))
                Text(
                    subtitle ?: track.artistName,
                    style = MaterialTheme.typography.bodySmall,
                    color = LocalContentColor.current.copy(alpha = 0.6f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(
            track.duration,
            style = MaterialTheme.typography.labelMedium,
            color = LocalContentColor.current.copy(alpha = 0.6f),
        )
        // Ambient rather than passed: every list in the app wants the same menu,
        // and threading it through album, playlist, search, artist and songs
        // would be five places to forget it. Absent — in a preview, or the
        // player's own queue rows — the row simply has no overflow.
        LocalTrackActions.current?.let { TrackMenu(track, it) }
    }
}

/**
 * What a row can do besides play.
 *
 * A bundle rather than six parameters, because every list in the app wants the
 * same set and threading them individually through album, playlist, search and
 * artist pages would be six places to forget one.
 */
/** Where a row finds [TrackActions]. Null means "this list has no menu". */
val LocalTrackActions = staticCompositionLocalOf<TrackActions?> { null }

@Stable
class TrackActions(
    private val library: MozzLibrary,
    private val playback: PlayerController,
    private val nav: Navigator,
    private val scope: CoroutineScope,
) {
    fun playNext(track: Track) = playback.playNext(track)
    fun addToQueue(track: Track) = playback.addToQueue(track)
    fun goToArtist(track: Track) = nav.openArtist(track.serverId, track.artistRemoteId)
    fun goToAlbum(track: Track) = nav.openAlbum(track.serverId, track.albumRemoteId)

    fun setLiked(track: Track, liked: Boolean) {
        scope.launch {
            runCatching { library.setLiked(track.serverId, track.remoteId, liked, playback.deviceId) }
        }
    }

    fun suppressTrack(track: Track) {
        scope.launch { runCatching { library.suppressTrack(track.serverId, track.remoteId) } }
    }

    fun suppressArtist(track: Track) {
        val artist = track.artistRemoteId ?: return
        scope.launch { runCatching { library.suppressArtist(track.serverId, artist) } }
    }
}

/**
 * The per-row overflow.
 *
 * Same actions as the iPhone's, in the same order, minus the two it has that
 * Android has no machinery for yet: downloads, and starting a station.
 */
@Composable
private fun TrackMenu(track: Track, actions: TrackActions) {
    var open by remember { mutableStateOf(false) }
    // Held locally so the row reflects the tap immediately; the write goes to the
    // database first and the server after, so there is nothing to wait for.
    var liked by remember(track.id) { mutableStateOf(track.isLiked) }

    Box {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(percent = 50))
                .clickable { open = true },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painterResource(R.drawable.ic_more_vert),
                contentDescription = "More actions",
                tint = LocalContentColor.current.copy(alpha = 0.6f),
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(if (liked) "Unlike" else "Like") },
                leadingIcon = {
                    Icon(
                        painterResource(
                            if (liked) R.drawable.ic_heart_filled else R.drawable.ic_heart
                        ),
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                    )
                },
                onClick = {
                    liked = !liked
                    actions.setLiked(track, liked)
                    open = false
                },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Play Next") },
                onClick = { actions.playNext(track); open = false },
            )
            DropdownMenuItem(
                text = { Text("Add to Queue") },
                onClick = { actions.addToQueue(track); open = false },
            )
            if (track.artistRemoteId != null) {
                DropdownMenuItem(
                    text = { Text("Go to Artist") },
                    onClick = { actions.goToArtist(track); open = false },
                )
            }
            if (track.albumRemoteId != null) {
                DropdownMenuItem(
                    text = { Text("Go to Album") },
                    onClick = { actions.goToAlbum(track); open = false },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Don't recommend this track") },
                onClick = { actions.suppressTrack(track); open = false },
            )
            if (track.artistRemoteId != null) {
                DropdownMenuItem(
                    text = { Text("Don't recommend this artist") },
                    onClick = { actions.suppressArtist(track); open = false },
                )
            }
        }
    }
}

/** An album in a vertical list. */
@Composable
fun AlbumRow(album: Album, server: MozzServer, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            server = server,
            serverId = album.serverId,
            artworkKey = album.artworkKey,
            pixels = artworkPixels(52.dp),
            modifier = Modifier.size(52.dp).clip(RoundedCornerShape(6.dp)),
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                album.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                listOfNotNull(album.artistName, album.year?.toString()).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = LocalContentColor.current.copy(alpha = 0.6f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** An album as a cover with its name under it — the unit every shelf and grid uses. */
@Composable
fun AlbumCell(album: Album, server: MozzServer, width: Dp, onClick: () -> Unit) {
    Column(
        modifier = Modifier.width(width).clickable(onClick = onClick),
    ) {
        Artwork(
            server = server,
            serverId = album.serverId,
            artworkKey = album.artworkKey,
            pixels = artworkPixels(width),
            modifier = Modifier.size(width).clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            album.title,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            album.year?.toString() ?: album.artistName,
            style = MaterialTheme.typography.bodySmall,
            color = LocalContentColor.current.copy(alpha = 0.6f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** An artist, round — the shape every music app uses to mean "a person". */
@Composable
fun ArtistCell(artist: Artist, server: MozzServer, width: Dp, onClick: () -> Unit) {
    Column(
        modifier = Modifier.width(width).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Artwork(
            server = server,
            serverId = artist.serverId,
            artworkKey = artist.heroArtworkKey ?: artist.artworkKey,
            pixels = artworkPixels(width),
            modifier = Modifier.size(width).clip(CircleShape),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            artist.name,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A playlist, as a cover with a song count. */
@Composable
fun PlaylistCell(playlist: Playlist, server: MozzServer, width: Dp, onClick: () -> Unit) {
    Column(
        modifier = Modifier.width(width).clickable(onClick = onClick),
    ) {
        Artwork(
            server = server,
            serverId = playlist.serverId,
            artworkKey = playlist.artworkKey,
            pixels = artworkPixels(width),
            modifier = Modifier.size(width).clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            playlist.title,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            songCount(playlist.trackCount),
            style = MaterialTheme.typography.bodySmall,
            color = LocalContentColor.current.copy(alpha = 0.6f),
            maxLines = 1,
        )
    }
}

/** "1 song" / "24 songs" / nothing at all. Used wherever a count is shown. */
fun songCount(count: Int?): String = when (count) {
    null -> ""
    1 -> "1 song"
    else -> "%,d songs".format(count)
}

/**
 * A horizontal shelf.
 *
 * Shelves scroll sideways on every screen size rather than reflowing into a
 * grid: a shelf is a *sample* of something larger, and a grid of five albums
 * with a gap where the sixth would be reads as a page that failed to load.
 */
@Composable
fun Shelf(
    title: String,
    onSeeAll: (() -> Unit)? = null,
    inset: Dp = 20.dp,
    content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = inset),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            if (onSeeAll != null) {
                Text(
                    "See All",
                    style = MaterialTheme.typography.labelLarge,
                    color = LocalContentColor.current.copy(alpha = 0.7f),
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(onClick = onSeeAll)
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = inset),
            content = content,
        )
    }
}

/**
 * A tab's title, and the one control that belongs beside it.
 *
 * Large and flush left, sitting straight under the status bar, in the same place
 * on every tab — the same arrangement iOS gets from `TightHeader`.
 */
@Composable
fun TabHeader(
    title: String,
    inset: Dp = 20.dp,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = inset, end = inset - 8.dp, top = 8.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.displaySmall,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke()
    }
}

/** A library category — an icon, a name, and a chevron that promises a page. */
@Composable
fun CategoryRow(title: String, icon: Int, inset: Dp = 20.dp, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = inset, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(16.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
        Icon(
            painterResource(R.drawable.ic_chevron_right),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** Nothing to show, said in a way that does not read as a failure. */
@Composable
fun EmptyState(title: String, detail: String, icon: Int) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 40.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = LocalContentColor.current.copy(alpha = 0.4f),
            modifier = Modifier.size(34.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            detail,
            style = MaterialTheme.typography.bodyMedium,
            color = LocalContentColor.current.copy(alpha = 0.6f),
            modifier = Modifier.fillMaxWidth(),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

/**
 * How wide one cell should be, given the window.
 *
 * Grids and shelves size their cells to the space rather than counting columns:
 * a fixed three-across looks considered on a phone and absurd on an unfolded
 * display, and a fixed cell width leaves a ragged margin. This picks the column
 * count that lands the cell closest to [ideal].
 */
fun cellWidth(available: Dp, ideal: Dp, gap: Dp, inset: Dp): Dp {
    val usable = available - inset * 2
    if (usable <= ideal) return usable.coerceAtLeast(80.dp)
    val columns = ((usable + gap) / (ideal + gap)).toInt().coerceAtLeast(1)
    return (usable - gap * (columns - 1)) / columns
}

/**
 * How wide a shelf's cells are.
 *
 * A fixed size rather than the window divided into columns, and deliberately not
 * a whole number across: the half cell showing at the right edge is the only
 * thing that tells you the row scrolls. Dividing evenly — which is right for a
 * grid — makes a shelf look like a grid that ran out of items.
 */
fun shelfCell(available: Dp): Dp = if (available >= WIDE_WINDOW) 176.dp else 150.dp

/** Cells per row for [cellWidth]'s answer. */
fun cellColumns(available: Dp, ideal: Dp, gap: Dp, inset: Dp): Int {
    val usable = available - inset * 2
    if (usable <= ideal) return 1
    return ((usable + gap) / (ideal + gap)).toInt().coerceAtLeast(1)
}

/**
 * A thin rule between category rows.
 *
 * Indented past the icons so the rules line up with the text rather than cutting
 * the icon column in half, and stopped at the same margin the rows keep on the
 * right — a rule that runs off the edge of the screen reads as the page having
 * been cropped.
 */
@Composable
fun RowDivider(start: Dp, end: Dp) {
    androidx.compose.material3.HorizontalDivider(
        color = MaterialTheme.colorScheme.outlineVariant,
        modifier = Modifier.padding(start = start, end = end),
    )
}
