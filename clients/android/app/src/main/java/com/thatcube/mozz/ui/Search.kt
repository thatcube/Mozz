package com.thatcube.mozz.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.Artist
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.SearchResults
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.ui.theme.mozzSurface
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject

/**
 * Search, over the catalogue on the device.
 *
 * Every keystroke queries the local FTS index rather than the server, which is
 * what keeps it instant and what makes it work with the network off — the same
 * arrangement as the iPhone, and the reason both feel the way they do. The
 * debounce below is not there to spare the server; it is there so a fast typist
 * does not see three result sets flicker past on the way to the one they meant.
 *
 * At rest the page shows what was searched for before, resolved live from the
 * catalogue rather than replayed from a snapshot, so a title that changed shows
 * its new name and anything pruned simply drops out.
 */
@Composable
fun SearchRoot(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    nav: Navigator,
    bottomReserve: Dp,
) {
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val recents = remember { RecentSearches(context) }

    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(SearchResults()) }
    var resolved by remember { mutableStateOf<List<RecentRow>>(emptyList()) }

    val trimmed = query.trim()

    LaunchedEffect(trimmed, account.serverId) {
        if (trimmed.isEmpty()) {
            results = SearchResults()
            return@LaunchedEffect
        }
        // Short enough to feel like it is keeping up, long enough that a word
        // typed at speed runs one query rather than seven.
        delay(DEBOUNCE_MS)
        results = runCatching { library.search(trimmed, account.serverId) }
            .getOrDefault(SearchResults())
    }

    // Re-resolved whenever the list changes or the query empties, so returning to
    // rest shows current rows rather than what they looked like when tapped.
    LaunchedEffect(recents.items, trimmed.isEmpty()) {
        if (trimmed.isNotEmpty()) return@LaunchedEffect
        resolved = recents.resolve(library)
    }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val inset = if (maxWidth >= WIDE_WINDOW) WIDE_INSET else 20.dp
        val cell = shelfCell(maxWidth)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)),
        ) {
            TabHeader("Search", inset = inset) {
                SettingsButton { nav.open(Route.Settings) }
            }
            SearchField(
                query = query,
                onQuery = { query = it },
                onClear = { query = "" },
                inset = inset,
            )
            Spacer(Modifier.height(8.dp))

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
            ) {
                if (trimmed.isEmpty()) {
                    if (resolved.isNotEmpty()) {
                        item {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = inset, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "Recently Searched",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    "Clear",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(6.dp))
                                        .clickable { recents.clear() }
                                        .padding(horizontal = 6.dp, vertical = 4.dp),
                                )
                            }
                        }
                        items(resolved, key = { it.key }) { row ->
                            when (row) {
                                is RecentRow.OfArtist -> ArtistRow(row.artist, server) {
                                    nav.open(Route.ArtistPage(row.artist))
                                }
                                is RecentRow.OfAlbum -> AlbumRow(row.album, server) {
                                    nav.open(Route.AlbumPage(row.album))
                                }
                                is RecentRow.OfTrack -> SongRow(
                                    row.track,
                                    server = server,
                                    onClick = { playback.play(listOf(row.track), 0) },
                                )
                            }
                        }
                    }
                    return@LazyColumn
                }

                if (results.artists.isNotEmpty()) {
                    item { ResultHeader("Artists", inset) }
                    items(results.artists, key = { "a-${it.serverId}-${it.remoteId}" }) { artist ->
                        ArtistRow(artist, server) {
                            recents.add(RecentKind.ARTIST, artist.serverId, artist.remoteId)
                            keyboard?.hide()
                            nav.open(Route.ArtistPage(artist))
                        }
                    }
                }
                if (results.albums.isNotEmpty()) {
                    item { ResultHeader("Albums", inset) }
                    items(results.albums, key = { "b-${it.serverId}-${it.remoteId}" }) { album ->
                        AlbumRow(album, server) {
                            recents.add(RecentKind.ALBUM, album.serverId, album.remoteId)
                            keyboard?.hide()
                            nav.open(Route.AlbumPage(album))
                        }
                    }
                }
                if (results.tracks.isNotEmpty()) {
                    item { ResultHeader("Songs", inset) }
                    items(results.tracks, key = { "t-${it.id}" }) { track ->
                        SongRow(
                            track,
                            server = server,
                            onClick = {
                                recents.add(RecentKind.TRACK, track.serverId, track.remoteId)
                                keyboard?.hide()
                                playback.play(results.tracks, results.tracks.indexOf(track))
                            },
                        )
                    }
                }
                if (results.artists.isEmpty() && results.albums.isEmpty() && results.tracks.isEmpty()) {
                    item {
                        EmptyState(
                            title = "No Results",
                            detail = "Nothing on this server matches “$trimmed”.",
                            icon = R.drawable.ic_search,
                        )
                    }
                }
            }
        }
    }
}

/** Long enough to collapse a word's keystrokes into one query. */
private const val DEBOUNCE_MS = 120L

@Composable
private fun SearchField(
    query: String,
    onQuery: (String) -> Unit,
    onClear: () -> Unit,
    inset: Dp,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = inset)
            .height(44.dp)
            .mozzSurface(RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(R.drawable.ic_search),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (query.isEmpty()) {
                Text(
                    "Artists, albums, songs",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            BasicTextField(
                value = query,
                onValueChange = onQuery,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(
                    color = MaterialTheme.colorScheme.onBackground,
                ),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (query.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Icon(
                painterResource(R.drawable.ic_close),
                contentDescription = "Clear",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(20.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onClear),
            )
        }
    }
}

@Composable
private fun ResultHeader(title: String, inset: Dp) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = inset, end = inset, top = 18.dp, bottom = 6.dp),
    )
}

/** An artist in a vertical list — round, because that is what round means here. */
@Composable
fun ArtistRow(artist: Artist, server: MozzServer, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            server = server,
            serverId = artist.serverId,
            artworkKey = artist.heroArtworkKey ?: artist.artworkKey,
            pixels = artworkPixels(52.dp),
            modifier = Modifier.size(52.dp).clip(CircleShape),
            shape = CircleShape,
        )
        Spacer(Modifier.width(14.dp))
        Text(
            artist.name,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

// MARK: - Recently searched

enum class RecentKind { ARTIST, ALBUM, TRACK }

/** One resolved row, re-read from the catalogue at display time. */
sealed interface RecentRow {
    val key: String

    data class OfArtist(val artist: Artist) : RecentRow {
        override val key get() = "r-artist-${artist.serverId}-${artist.remoteId}"
    }

    data class OfAlbum(val album: Album) : RecentRow {
        override val key get() = "r-album-${album.serverId}-${album.remoteId}"
    }

    data class OfTrack(val track: Track) : RecentRow {
        override val key get() = "r-track-${track.serverId}-${track.remoteId}"
    }
}

/**
 * What was searched for before.
 *
 * Stores a durable reference — kind, server, remote id — and never a snapshot of
 * the row, so the list re-reads from the catalogue every time it is shown. The
 * same rule `RecentSearchStore.swift` follows, for the same reason: a stored
 * title goes stale, and a stored row for something the server has since deleted
 * has to be noticed and removed. A reference that no longer resolves just
 * disappears.
 */
class RecentSearches(context: Context) {
    private val prefs = context.getSharedPreferences("mozz.settings", Context.MODE_PRIVATE)

    var items by mutableStateOf(read())
        private set

    fun add(kind: RecentKind, serverId: String, remoteId: String) {
        val entry = Triple(kind, serverId, remoteId)
        items = (listOf(entry) + items.filterNot { it == entry }).take(LIMIT)
        write()
    }

    fun clear() {
        items = emptyList()
        write()
    }

    suspend fun resolve(library: MozzLibrary): List<RecentRow> = items.mapNotNull { (kind, server, remote) ->
        runCatching {
            when (kind) {
                RecentKind.ARTIST -> library.artist(server, remote)?.let(RecentRow::OfArtist)
                RecentKind.ALBUM -> library.album(server, remote)?.let(RecentRow::OfAlbum)
                RecentKind.TRACK -> library.track(server, remote)?.let(RecentRow::OfTrack)
            }
        }.getOrNull()
    }

    private fun read(): List<Triple<RecentKind, String, String>> = runCatching {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        val array = JSONArray(raw)
        (0 until array.length()).mapNotNull { index ->
            val row = array.getJSONObject(index)
            val kind = RecentKind.entries.firstOrNull { it.name == row.getString("kind") }
                ?: return@mapNotNull null
            Triple(kind, row.getString("serverId"), row.getString("remoteId"))
        }
    }.getOrDefault(emptyList())

    private fun write() {
        val array = JSONArray()
        items.forEach { (kind, server, remote) ->
            array.put(
                JSONObject()
                    .put("kind", kind.name)
                    .put("serverId", server)
                    .put("remoteId", remote)
            )
        }
        prefs.edit().putString(KEY, array.toString()).apply()
    }

    private companion object {
        const val KEY = "mozz.recentSearches.v1"
        const val LIMIT = 20
    }
}
