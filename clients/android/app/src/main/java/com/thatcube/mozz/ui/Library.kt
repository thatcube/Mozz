package com.thatcube.mozz.ui

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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.Artist
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Playlist
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlayerController
import kotlinx.coroutines.flow.collectLatest

/**
 * The library tab: a menu of what is on this server, and a shelf of what arrived
 * most recently.
 *
 * Same list as the iPhone's Library, in the same order. Genres and Downloads are
 * absent because neither exists on Android yet — this menu says what is here
 * rather than listing places that would apologise when opened.
 */
@Composable
fun LibraryRoot(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    nav: Navigator,
    bottomReserve: Dp,
) {
    var recentlyAdded by remember { mutableStateOf<List<Album>>(emptyList()) }

    LaunchedEffect(account.serverId) {
        runCatching { library.recentlyAddedAlbums(account.serverId, limit = 20) }
            .getOrNull()?.let { recentlyAdded = it }
    }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val inset = if (maxWidth >= WIDE_WINDOW) WIDE_INSET else 20.dp
        val cell = shelfCell(maxWidth)

        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            item { TabHeader("Library", inset = inset) }
            item {
                Column {
                    CategoryRow("Songs", R.drawable.ic_music, inset) { nav.open(Route.AllSongs) }
                    RowDivider(start = inset + 40.dp, end = inset)
                    CategoryRow("Liked Songs", R.drawable.ic_heart, inset) { nav.open(Route.LikedSongs) }
                    RowDivider(start = inset + 40.dp, end = inset)
                    CategoryRow("Playlists", R.drawable.ic_playlist, inset) { nav.open(Route.AllPlaylists) }
                    RowDivider(start = inset + 40.dp, end = inset)
                    CategoryRow("Artists", R.drawable.ic_microphone, inset) { nav.open(Route.AllArtists) }
                    RowDivider(start = inset + 40.dp, end = inset)
                    CategoryRow("Albums", R.drawable.ic_disc, inset) { nav.open(Route.AllAlbums) }
                }
            }
            if (recentlyAdded.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(28.dp))
                    Shelf("Recently Added", inset = inset, onSeeAll = { nav.open(Route.AllAlbums) }) {
                        items(recentlyAdded, key = { "added-${it.serverId}-${it.remoteId}" }) { album ->
                            AlbumCell(album, server, cell) { nav.open(Route.AlbumPage(album)) }
                        }
                    }
                }
            }
        }
    }
}

/**
 * A pushed list page: a back control, a title, and the list.
 *
 * Deliberately plainer than a detail page. These are places you pass through on
 * the way to a record, and a hero on each one would make every route to an album
 * feel like three album pages in a row.
 */
@Composable
fun ListPage(
    title: String,
    onBack: () -> Unit,
    content: @Composable (inset: Dp, width: Dp) -> Unit,
) {
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)),
    ) {
        val inset = if (maxWidth >= WIDE_WINDOW) WIDE_INSET else 20.dp
        val width = maxWidth
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = inset - 12.dp, end = inset, top = 6.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .clickable(onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painterResource(R.drawable.ic_chevron_left),
                        contentDescription = "Back",
                        modifier = Modifier.size(22.dp),
                    )
                }
                Spacer(Modifier.width(4.dp))
                Text(title, style = MaterialTheme.typography.headlineMedium)
            }
            content(inset, width)
        }
    }
}

/**
 * A listing that arrives a page at a time.
 *
 * The catalogue can hold a hundred thousand songs, so these pages ask for a
 * window and fetch the next one as the end comes into view. [exhausted] is what
 * a null cursor means, kept so a finished list stops asking.
 */
@Stable
class Pager<T>(private val fetch: suspend (String?) -> Pair<List<T>, String?>) {
    var items by mutableStateOf<List<T>>(emptyList())
        private set
    var loading by mutableStateOf(false)
        private set

    private var cursor: String? = null
    private var exhausted = false

    suspend fun loadMore() {
        if (loading || exhausted) return
        loading = true
        val (rows, next) = runCatching { fetch(cursor) }.getOrElse { emptyList<T>() to null }
        items = items + rows
        cursor = next
        exhausted = next == null || rows.isEmpty()
        loading = false
    }
}

@Composable
fun SongsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    onBack: () -> Unit,
    bottomReserve: Dp,
) {
    val pager = remember(account.serverId) {
        Pager<Track> { cursor ->
            val page = library.tracks(account.serverId, cursor, limit = 100)
            (page.rows.orEmpty()) to page.nextCursor
        }
    }
    val listState = rememberLazyListState()
    LaunchedEffect(pager) { pager.loadMore() }
    LoadMoreWhenNearEnd(listState, pager) { pager.items.size }

    ListPage("Songs", onBack) { _, _ ->
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            itemsIndexed(pager.items, key = { _, t -> "song-${t.id}" }) { index, track ->
                SongRow(track, server = server, onClick = { playback.play(pager.items, index) })
            }
            if (pager.loading) item { LoadingRow() }
        }
    }
}

@Composable
fun AlbumsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    nav: Navigator,
    onBack: () -> Unit,
    bottomReserve: Dp,
) {
    val pager = remember(account.serverId) {
        Pager<Album> { cursor ->
            val page = library.albums(account.serverId, cursor, limit = 100)
            (page.rows.orEmpty()) to page.nextCursor
        }
    }
    LaunchedEffect(pager) { pager.loadMore() }

    ListPage("Albums", onBack) { inset, width ->
        val cell = cellWidth(width, ideal = 168.dp, gap = 16.dp, inset = inset)
        val gridState = rememberLazyGridState()
        LoadMoreWhenGridNearEnd(gridState, pager) { pager.items.size }
        LazyVerticalGrid(
            state = gridState,
            columns = GridCells.Fixed(cellColumns(width, ideal = 168.dp, gap = 16.dp, inset = inset)),
            contentPadding = PaddingValues(start = inset, end = inset, bottom = bottomReserve + 24.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(pager.items, key = { "album-${it.serverId}-${it.remoteId}" }) { album ->
                AlbumCell(album, server, cell) { nav.open(Route.AlbumPage(album)) }
            }
        }
    }
}

@Composable
fun ArtistsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    nav: Navigator,
    onBack: () -> Unit,
    bottomReserve: Dp,
) {
    val pager = remember(account.serverId) {
        Pager<Artist> { cursor ->
            val page = library.artists(account.serverId, cursor, limit = 100)
            (page.rows.orEmpty()) to page.nextCursor
        }
    }
    LaunchedEffect(pager) { pager.loadMore() }

    ListPage("Artists", onBack) { inset, width ->
        val cell = cellWidth(width, ideal = 148.dp, gap = 16.dp, inset = inset)
        val gridState = rememberLazyGridState()
        LoadMoreWhenGridNearEnd(gridState, pager) { pager.items.size }
        LazyVerticalGrid(
            state = gridState,
            columns = GridCells.Fixed(cellColumns(width, ideal = 148.dp, gap = 16.dp, inset = inset)),
            contentPadding = PaddingValues(start = inset, end = inset, bottom = bottomReserve + 24.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(pager.items, key = { "artist-${it.serverId}-${it.remoteId}" }) { artist ->
                ArtistCell(artist, server, cell) { nav.open(Route.ArtistPage(artist)) }
            }
        }
    }
}

@Composable
fun PlaylistsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    nav: Navigator,
    onBack: () -> Unit,
    bottomReserve: Dp,
) {
    var playlists by remember(account.serverId) { mutableStateOf<List<Playlist>>(emptyList()) }
    LaunchedEffect(account.serverId) {
        runCatching { library.playlists(account.serverId) }.getOrNull()?.let { playlists = it }
    }

    ListPage("Playlists", onBack) { inset, width ->
        val cell = cellWidth(width, ideal = 168.dp, gap = 16.dp, inset = inset)
        if (playlists.isEmpty()) {
            EmptyState(
                title = "No Playlists",
                detail = "Playlists made on this server show up here.",
                icon = R.drawable.ic_playlist,
            )
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(cellColumns(width, ideal = 168.dp, gap = 16.dp, inset = inset)),
                contentPadding = PaddingValues(start = inset, end = inset, bottom = bottomReserve + 24.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(playlists, key = { "playlist-${it.remoteId}" }) { playlist ->
                    PlaylistCell(playlist, server, cell) { nav.open(Route.PlaylistPage(playlist)) }
                }
            }
        }
    }
}

/** Fetch the next page once the end of this one is within a screen's reach. */
@Composable
private fun <T> LoadMoreWhenNearEnd(
    state: androidx.compose.foundation.lazy.LazyListState,
    pager: Pager<T>,
    total: () -> Int,
) {
    LaunchedEffect(state, pager) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collectLatest { last -> if (last >= total() - LOAD_AHEAD) pager.loadMore() }
    }
}

@Composable
private fun <T> LoadMoreWhenGridNearEnd(
    state: androidx.compose.foundation.lazy.grid.LazyGridState,
    pager: Pager<T>,
    total: () -> Int,
) {
    LaunchedEffect(state, pager) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collectLatest { last -> if (last >= total() - LOAD_AHEAD) pager.loadMore() }
    }
}

/** Rows of headroom to keep ahead of the scroll. */
private const val LOAD_AHEAD = 20

@Composable
private fun LoadingRow() {
    Box(
        modifier = Modifier.fillMaxWidth().height(64.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
    }
}
