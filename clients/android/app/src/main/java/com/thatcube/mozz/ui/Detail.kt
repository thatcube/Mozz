package com.thatcube.mozz.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.Artist
import com.thatcube.mozz.core.HomeMix
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Playlist
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlayerController

/**
 * An album: the sleeve whole, then its songs by number.
 *
 * The cover is shown centred rather than bled to the edges because an album
 * sleeve is a square object with a border the designer chose, and cropping it to
 * fill a phone throws that away.
 */
@Composable
fun AlbumDetailPage(
    album: Album,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    var tracks by remember(album.remoteId) { mutableStateOf<List<Track>>(emptyList()) }
    var loaded by remember(album.remoteId) { mutableStateOf(false) }

    LaunchedEffect(album.remoteId, album.groupKey) {
        // Ask by group key when there is one: servers — Jellyfin especially —
        // split one album across several entities, and the remote id alone
        // returns a slice of it.
        tracks = runCatching {
            library.albumTracks(
                serverId = album.serverId,
                remoteId = album.remoteId,
                groupKey = album.groupKey.ifEmpty { null },
            )
        }.getOrDefault(emptyList())
        loaded = true
    }

    MediaDetail(
        server = server,
        serverId = album.serverId,
        artworkKey = album.artworkKey,
        style = HeroStyle.CENTERED,
        title = album.title,
        subtitle = album.artistName,
        meta = albumMeta(album, tracks, loaded),
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
        actions = {
            DetailPlayActions(
                onPlay = { playback.play(tracks, 0) },
                onShuffle = { playback.play(tracks.shuffled(), 0) },
            )
        },
    ) {
        itemsIndexed(tracks, key = { _, t -> "track-${t.id}" }) { index, track ->
            SongRow(
                track = track,
                index = track.trackNumber ?: (index + 1),
                onClick = { playback.play(tracks, index) },
            )
        }
    }
}

/** "2021 · 12 songs · 48 min", minus whatever is not known yet. */
private fun albumMeta(album: Album, tracks: List<Track>, loaded: Boolean): String? {
    if (!loaded) return album.year?.toString()
    val parts = buildList {
        album.year?.let { add(it.toString()) }
        add(songCount(tracks.size))
        longDuration(tracks.sumOf { it.durationSeconds }).takeIf { it.isNotEmpty() }?.let(::add)
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/**
 * An artist: their picture across the top, then the shape of their catalogue.
 *
 * Full-bleed rather than a centred square, because artist art is a photograph —
 * it has no edge that means anything, and letting it fill the top is what makes
 * this page feel like a person rather than another record.
 */
@Composable
fun ArtistDetailPage(
    artist: Artist,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    nav: Navigator,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    var songs by remember(artist.remoteId) { mutableStateOf<List<Track>>(emptyList()) }
    var albums by remember(artist.remoteId) { mutableStateOf<List<Album>>(emptyList()) }
    var appearsOn by remember(artist.remoteId) { mutableStateOf<List<Album>>(emptyList()) }
    var loaded by remember(artist.remoteId) { mutableStateOf(false) }

    LaunchedEffect(artist.remoteId) {
        albums = runCatching { library.artistAlbums(artist.serverId, artist.remoteId) }
            .getOrDefault(emptyList())
        songs = runCatching { library.artistTopTracks(artist.serverId, artist.remoteId) }
            .getOrDefault(emptyList())
        appearsOn = runCatching { library.artistAppearsOn(artist.serverId, artist.remoteId) }
            .getOrDefault(emptyList())
        loaded = true
    }

    val fullAlbums = albums.filter { !AlbumRelease.isSingleOrEp(it.trackCount) }
    val singles = albums.filter { AlbumRelease.isSingleOrEp(it.trackCount) }
    val latest = AlbumRelease.newest(albums)
    val topSongs = songs.take(TOP_SONGS)

    MediaDetail(
        server = server,
        serverId = artist.serverId,
        artworkKey = artist.heroArtworkKey ?: artist.artworkKey,
        style = HeroStyle.FULL_BLEED,
        title = artist.name,
        meta = if (loaded && albums.isNotEmpty()) albumCount(albums.size) else null,
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
        actions = {
            DetailPlayActions(
                onPlay = { playback.play(songs, 0) },
                onShuffle = { playback.play(songs.shuffled(), 0) },
            )
        },
    ) {
        if (latest != null) {
            albumShelf("Latest Release", listOf(latest), server, nav)
        }
        if (topSongs.isNotEmpty()) {
            item(key = "top-songs-header") {
                DetailSectionHeader("Top Songs")
            }
            itemsIndexed(topSongs, key = { _, t -> "top-${t.id}" }) { index, track ->
                SongRow(
                    track = track,
                    server = server,
                    // The album, not the artist: every row on this page is by
                    // the same person, and repeating their name five times says
                    // nothing about the songs.
                    subtitle = track.albumTitle,
                    onClick = { playback.play(songs, index) },
                )
            }
        }
        if (fullAlbums.isNotEmpty()) albumShelf("Albums", fullAlbums, server, nav)
        if (singles.isNotEmpty()) albumShelf("Singles & EPs", singles, server, nav)
        if (appearsOn.isNotEmpty()) albumShelf("Appears On", appearsOn, server, nav)

        if (loaded && albums.isEmpty() && songs.isEmpty() && appearsOn.isEmpty()) {
            item(key = "empty") {
                EmptyState(
                    title = "Nothing Here Yet",
                    detail = "Nothing by this artist has synced across.",
                    icon = R.drawable.ic_microphone,
                )
            }
        }
    }
}

/** iOS shows five before offering the rest. */
private const val TOP_SONGS = 5

private fun LazyListScope.albumShelf(
    title: String,
    albums: List<Album>,
    server: MozzServer,
    nav: Navigator,
) {
    item(key = "shelf-$title") {
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val cell = shelfCell(maxWidth)
            Column {
                Spacer(Modifier.height(14.dp))
                Shelf(title, inset = 16.dp) {
                    items(albums, key = { "${title}-${it.serverId}-${it.remoteId}" }) { album ->
                        AlbumCell(album, server, cell) { nav.open(Route.AlbumPage(album)) }
                    }
                }
            }
        }
    }
}

/**
 * A playlist: whatever cover the server gave it, then the songs in the order
 * someone put them in.
 */
@Composable
fun PlaylistDetailPage(
    playlist: Playlist,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    var tracks by remember(playlist.remoteId) { mutableStateOf<List<Track>>(emptyList()) }
    var loaded by remember(playlist.remoteId) { mutableStateOf(false) }

    LaunchedEffect(playlist.remoteId) {
        tracks = runCatching { library.playlistTracks(playlist.serverId, playlist.remoteId) }
            .getOrDefault(emptyList())
        loaded = true
    }

    MediaDetail(
        server = server,
        serverId = playlist.serverId,
        artworkKey = playlist.artworkKey,
        style = HeroStyle.CENTERED,
        title = playlist.title,
        subtitle = "Playlist",
        meta = if (tracks.isEmpty()) playlist.trackCount?.let(::songCount)
        else "${songCount(tracks.size)} · ${longDuration(tracks.sumOf { it.durationSeconds })}",
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
        actions = {
            DetailPlayActions(
                onPlay = { playback.play(tracks, 0) },
                onShuffle = { playback.play(tracks.shuffled(), 0) },
            )
        },
    ) {
        if (loaded && tracks.isEmpty()) {
            item(key = "empty") {
                EmptyState(
                    title = "Empty Playlist",
                    detail = "Nothing has been added to this one yet.",
                    icon = R.drawable.ic_playlist,
                )
            }
        }
        itemsIndexed(tracks, key = { _, t -> "pl-${t.id}" }) { index, track ->
            SongRow(track, server = server, onClick = { playback.play(tracks, index) })
        }
    }
}

/**
 * Liked Songs and the precomputed mixes, which are the two collections with no
 * cover of their own.
 *
 * Both borrow one from a track inside them, so the page still blooms with a
 * colour that belongs to the music rather than falling back to a hue derived
 * from the title.
 */
@Composable
fun LikedSongsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    var tracks by remember(account.serverId) { mutableStateOf<List<Track>>(emptyList()) }
    var loaded by remember(account.serverId) { mutableStateOf(false) }

    LaunchedEffect(account.serverId) {
        tracks = runCatching { library.likedTracks(account.serverId) }.getOrDefault(emptyList())
        loaded = true
    }

    CollectionDetail(
        title = "Liked Songs",
        subtitle = null,
        tracks = tracks,
        loaded = loaded,
        emptyTitle = "No Liked Songs",
        emptyDetail = "Tap the heart on a song to add it here.",
        emptyIcon = R.drawable.ic_heart,
        server = server,
        serverId = account.serverId,
        playback = playback,
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
    )
}

@Composable
fun MixDetailPage(
    mix: HomeMix,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    var tracks by remember(mix.id) { mutableStateOf<List<Track>>(emptyList()) }
    var loaded by remember(mix.id) { mutableStateOf(false) }

    LaunchedEffect(mix.id) {
        tracks = runCatching { library.mixTracks(mix.id) }.getOrDefault(emptyList())
        loaded = true
    }

    CollectionDetail(
        title = mix.title,
        subtitle = mix.subtitle ?: "Made for You",
        tracks = tracks,
        loaded = loaded,
        emptyTitle = "Nothing Here Yet",
        emptyDetail = "This mix is built from what you play — give it a little history to work with.",
        emptyIcon = R.drawable.ic_music,
        server = server,
        serverId = tracks.firstOrNull()?.serverId ?: "",
        artworkKey = mix.artworkKey,
        playback = playback,
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
    )
}

/** The shared body of any track collection that has no cover of its own. */
@Composable
private fun CollectionDetail(
    title: String,
    subtitle: String?,
    tracks: List<Track>,
    loaded: Boolean,
    emptyTitle: String,
    emptyDetail: String,
    emptyIcon: Int,
    server: MozzServer,
    serverId: String,
    artworkKey: String? = null,
    playback: PlayerController,
    wide: Boolean,
    bottomReserve: Dp,
    onBack: () -> Unit,
) {
    // Borrowed from the first track that has one, and held there. Re-picking as
    // the list changes would repaint the whole page under someone reading it.
    val borrowed = remember(tracks.firstOrNull()?.id) {
        artworkKey ?: tracks.firstOrNull { it.artworkKey != null }?.artworkKey
    }
    val heroServerId = serverId.ifEmpty { tracks.firstOrNull()?.serverId.orEmpty() }

    MediaDetail(
        server = server,
        serverId = heroServerId,
        artworkKey = borrowed,
        style = HeroStyle.FULL_BLEED,
        title = title,
        subtitle = subtitle,
        meta = tracks.takeIf { it.isNotEmpty() }?.let { songCount(it.size) },
        wide = wide,
        bottomReserve = bottomReserve,
        onBack = onBack,
        actions = {
            DetailPlayActions(
                onPlay = { playback.play(tracks, 0) },
                onShuffle = { playback.play(tracks.shuffled(), 0) },
            )
        },
    ) {
        if (loaded && tracks.isEmpty()) {
            item(key = "empty") { EmptyState(emptyTitle, emptyDetail, emptyIcon) }
        }
        itemsIndexed(tracks, key = { _, t -> "c-${t.id}" }) { index, track ->
            SongRow(track, server = server, onClick = { playback.play(tracks, index) })
        }
    }
}

/**
 * Which releases are singles, and which one is newest.
 *
 * Mirrors `AlbumReleaseClassifier` and `LatestRelease` in the Swift core. The
 * rule has to be the same on every client: an artist whose newest record differs
 * between the phone and the desktop is a bug nobody could explain.
 */
object AlbumRelease {
    /**
     * Three tracks or fewer is a single or an EP. An unknown count counts as a
     * full album on purpose — incomplete server metadata should leave a record in
     * Albums rather than hide it among the singles.
     */
    fun isSingleOrEp(trackCount: Int?): Boolean = (trackCount ?: 99) <= 3

    /**
     * Newest by year, then by when the library first saw it, then by title.
     *
     * A release with no year sorts below every release that has one: absent a
     * year we do not know that it is new, and promoting an undated record to
     * "Latest Release" would be a confident lie. The tie-breakers are what keep
     * an artist whose whole discography arrived without years in a stable — and
     * identical — order on every client.
     */
    fun newest(albums: List<Album>): Album? = albums.reduceOrNull { best, next ->
        if (isNewer(next, best)) next else best
    }

    private fun isNewer(a: Album, b: Album): Boolean {
        if (a.year != b.year) {
            val left = a.year
            val right = b.year
            if (left != null && right != null) return left > right
            if (left != null) return true
            if (right != null) return false
        }
        if (a.addedAt != b.addedAt) {
            val left = a.addedAt
            val right = b.addedAt
            if (left != null && right != null) return left > right
            if (left != null) return true
            if (right != null) return false
        }
        return a.title.compareTo(b.title, ignoreCase = true) < 0
    }
}

/** "1 album" / "12 albums". */
private fun albumCount(count: Int): String = if (count == 1) "1 album" else "%,d albums".format(count)

/** "48 min" / "1 hr 12 min" — the shape a collection's length is read in. */
fun longDuration(seconds: Double): String {
    if (seconds <= 0 || seconds.isNaN()) return ""
    val total = seconds.toLong()
    val hours = total / 3600
    val minutes = (total % 3600 + 30) / 60
    return when {
        hours >= 1 && minutes > 0 -> "$hours hr $minutes min"
        hours >= 1 -> "$hours hr"
        else -> "$minutes min"
    }
}
