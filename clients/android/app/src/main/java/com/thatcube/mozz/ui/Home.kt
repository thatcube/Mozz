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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.HomeMix
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Playlist
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.ui.theme.mozzSurface

/**
 * What someone sees when they open the app.
 *
 * The same shape as the iPhone's Home, section for section: the shortcuts the
 * core precomputed, then what was played recently, what arrived recently, and
 * the playlists on the server. Everything here is read from the mirrored
 * catalogue, so it is on screen before the network has been asked anything.
 *
 * The library itself is not here — it moved to its own tab, where iOS keeps it.
 * A home screen that is a list of every album is a file browser.
 */
@Composable
fun HomeRoot(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    nav: Navigator,
    bottomReserve: Dp,
) {
    val context = LocalContext.current
    var mixes by remember { mutableStateOf<List<HomeMix>>(emptyList()) }
    var recentlyPlayed by remember { mutableStateOf<List<Track>>(emptyList()) }
    var recentlyAdded by remember { mutableStateOf<List<Album>>(emptyList()) }
    var playlists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var likedCount by remember { mutableStateOf(0) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(account.serverId) {
        // Read everything first and assign once. The shelves are independent, and
        // filling them one await at a time makes the page assemble itself in
        // front of you.
        val played = runCatching { library.recentlyPlayedTracks(account.serverId, limit = 20) }.getOrNull()
        val added = runCatching { library.recentlyAddedAlbums(account.serverId, limit = 20) }.getOrNull()
        val lists = runCatching { library.playlists(account.serverId) }.getOrNull()
        val liked = runCatching { library.likedTracks(account.serverId) }.getOrNull()
        val sets = runCatching { library.homeMixes() }.getOrNull()

        if (played != null) recentlyPlayed = played
        if (added != null) recentlyAdded = added
        if (lists != null) playlists = lists
        if (liked != null) likedCount = liked.size
        if (sets != null) mixes = sets
        loaded = true

        // Then refresh the precomputed sets if they are stale, and re-read. This
        // runs after the page is already up, because generating is the expensive
        // part and nothing on screen is waiting for it.
        HomeMixSchedule.refreshIfStale(context, library, account.serverId, mixes)
        runCatching { library.homeMixes() }.getOrNull()?.let { mixes = it }
    }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val inset = if (maxWidth >= WIDE_WINDOW) WIDE_INSET else 20.dp
        val cell = shelfCell(maxWidth)
        // Two across on a phone, the way iOS lays these out, and more only when
        // there is genuinely room for another.
        val tileColumns = cellColumns(maxWidth, ideal = 170.dp, gap = 12.dp, inset = inset)
        val hasAnything = mixes.isNotEmpty() || recentlyPlayed.isNotEmpty() ||
            recentlyAdded.isNotEmpty() || playlists.isNotEmpty() || likedCount > 0

        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
            verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            item(key = "header") {
                TabHeader("Home", inset = inset) {
                    SettingsButton { nav.open(Route.Settings) }
                }
            }

            if (likedCount > 0 || mixes.isNotEmpty()) {
                item(key = "made-for-you") {
                    ShortcutGrid(
                        likedCount = likedCount,
                        mixes = mixes,
                        server = server,
                        serverId = account.serverId,
                        columns = tileColumns,
                        inset = inset,
                        onLiked = { nav.open(Route.LikedSongs) },
                        onMix = { nav.open(Route.MixPage(it)) },
                    )
                }
            }

            if (recentlyPlayed.isNotEmpty()) {
                item(key = "recently-played") {
                    Shelf("Recently Played", inset = inset) {
                        itemsIndexed(recentlyPlayed, key = { _, t -> "played-${t.id}" }) { index, track ->
                            TrackCell(track, server, cell) { playback.play(recentlyPlayed, index) }
                        }
                    }
                }
            }

            if (recentlyAdded.isNotEmpty()) {
                item(key = "recently-added") {
                    Shelf("Recently Added", inset = inset, onSeeAll = { nav.open(Route.AllAlbums) }) {
                        items(recentlyAdded, key = { "added-${it.serverId}-${it.remoteId}" }) { album ->
                            AlbumCell(album, server, cell) { nav.open(Route.AlbumPage(album)) }
                        }
                    }
                }
            }

            if (playlists.isNotEmpty()) {
                item(key = "playlists") {
                    Shelf("Your Playlists", inset = inset, onSeeAll = { nav.open(Route.AllPlaylists) }) {
                        items(playlists, key = { "playlist-${it.remoteId}" }) { playlist ->
                            PlaylistCell(playlist, server, cell) { nav.open(Route.PlaylistPage(playlist)) }
                        }
                    }
                }
            }

            if (loaded && !hasAnything) {
                item(key = "empty") {
                    EmptyState(
                        title = "Nothing Here Yet",
                        detail = "Play something, or refresh to pull your library across.",
                        icon = R.drawable.ic_home,
                    )
                }
            }
        }
    }
}

/** Past this, a window has room for wider margins and more columns. */
val WIDE_WINDOW = 700.dp

/**
 * The quick-access grid: Liked Songs, then every precomputed mix.
 *
 * Laid out by hand in rows rather than as a lazy grid, because the set is small
 * and bounded and a lazy grid nested in a lazy column is a measuring problem
 * with no upside.
 */
@Composable
private fun ShortcutGrid(
    likedCount: Int,
    mixes: List<HomeMix>,
    server: MozzServer,
    serverId: String,
    columns: Int,
    inset: Dp,
    onLiked: () -> Unit,
    onMix: (HomeMix) -> Unit,
) {
    val cells: List<ShortcutCell> =
        (if (likedCount > 0) listOf(ShortcutCell.Liked(likedCount)) else emptyList()) +
            mixes.map(ShortcutCell::Mix)

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = inset),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        cells.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { cell ->
                    Box(modifier = Modifier.weight(1f)) {
                        when (cell) {
                            is ShortcutCell.Liked -> ShortcutTile(
                                title = "Liked Songs",
                                subtitle = songCount(cell.count),
                                onClick = onLiked,
                            ) { LikedSquare() }
                            is ShortcutCell.Mix -> ShortcutTile(
                                title = cell.mix.title,
                                subtitle = cell.mix.subtitle ?: "Made for You",
                                onClick = { onMix(cell.mix) },
                            ) {
                                Artwork(
                                    server = server,
                                    serverId = serverId,
                                    artworkKey = cell.mix.artworkKey,
                                    pixels = artworkPixels(SHORTCUT_ART),
                                    modifier = Modifier.size(SHORTCUT_ART),
                                )
                            }
                        }
                    }
                }
                // Keeps the last row's tiles the same width as every other row's
                // instead of stretching one across the whole window.
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

private sealed interface ShortcutCell {
    data class Liked(val count: Int) : ShortcutCell
    data class Mix(val mix: HomeMix) : ShortcutCell
}

private val SHORTCUT_ART = 56.dp

@Composable
private fun ShortcutTile(
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
    leading: @Composable () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(SHORTCUT_ART)
            .mozzSurface(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading()
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!subtitle.isNullOrEmpty()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Liked Songs has no cover, so it gets a made one — the same red gradient and
 * white heart as iOS, which is the app's one colour used where it means
 * something.
 */
@Composable
fun LikedSquare(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(SHORTCUT_ART)
            .background(
                Brush.linearGradient(
                    listOf(Color(0xFFD64559), Color(0xFF801729)),
                    start = Offset.Zero,
                    end = Offset.Infinite,
                )
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(R.drawable.ic_heart_filled),
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(20.dp),
        )
    }
}

/** A song on a shelf: its album cover, its name, who made it. */
@Composable
fun TrackCell(track: Track, server: MozzServer, width: Dp, onClick: () -> Unit) {
    Column(modifier = Modifier.width(width).clickable(onClick = onClick)) {
        Artwork(
            server = server,
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            pixels = artworkPixels(width),
            modifier = Modifier.size(width).clip(RoundedCornerShape(8.dp)),
            shape = RoundedCornerShape(8.dp),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            track.title,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            track.artistName,
            style = MaterialTheme.typography.bodySmall,
            color = LocalContentColor.current.copy(alpha = 0.6f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * When to rebuild the precomputed mixes.
 *
 * The same two rules the iPhone follows, for the same reasons. Daily mixes are
 * gated on a stored timestamp rather than on the age of a set, because someone
 * whose library has just finished syncing has no sets at all — and gating on
 * "there are none" would re-run the generator every time Home appeared. Mozz
 * Weekly is gated on its own age, because there is exactly one of it.
 */
private object HomeMixSchedule {
    private const val PREFS = "mozz.home"
    private const val GENERATED_AT = "homeMixesGeneratedAt"
    private const val DAY_SECONDS = 24 * 60 * 60.0
    private const val WEEK_SECONDS = 7 * DAY_SECONDS
    private const val MOZZ_WEEKLY_ID = "mozz-weekly"

    suspend fun refreshIfStale(
        context: Context,
        library: MozzLibrary,
        serverId: String,
        mixes: List<HomeMix>,
    ) {
        val now = System.currentTimeMillis() / 1000.0
        val weekly = mixes.firstOrNull { it.id == MOZZ_WEEKLY_ID }
        if (weekly == null || now - weekly.generatedAt >= WEEK_SECONDS) {
            runCatching { library.generateMozzWeekly(serverId) }
        }

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val last = prefs.getLong(GENERATED_AT, 0L).toDouble()
        if (now - last >= DAY_SECONDS) {
            runCatching { library.generateHomeMixes(serverId) }
                .onSuccess { prefs.edit().putLong(GENERATED_AT, now.toLong()).apply() }
        }
    }
}
