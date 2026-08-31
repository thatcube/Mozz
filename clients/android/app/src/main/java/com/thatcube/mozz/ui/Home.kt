package com.thatcube.mozz.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import com.thatcube.mozz.core.MozzServer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.core.Album
import com.thatcube.mozz.core.LibraryCounts
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlaybackState
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.ui.theme.quietBody
import kotlinx.coroutines.launch

/**
 * What someone sees once their catalogue is on the device.
 *
 * Built on the list/detail scaffold from the first screen rather than as a
 * single column to be widened later: on a fold, a phone layout stretched to the
 * inner display is the thing that looks wrong, and retrofitting two panes means
 * rewriting navigation. Folded, this is one pane and back goes back. Unfolded,
 * the album sits beside the list.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class, ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    onResync: () -> Unit,
    onSignOut: () -> Unit,
) {
    val playbackState by playback.state.collectAsStateWithLifecycle()
    var playerOpen by remember { mutableStateOf(false) }
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    val scope = rememberCoroutineScope()

    var liked by remember { mutableStateOf<List<Track>>(emptyList()) }
    var albums by remember { mutableStateOf<List<Album>>(emptyList()) }
    var counts by remember { mutableStateOf<LibraryCounts?>(null) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(account.serverId) {
        loading = true
        counts = library.counts(account.serverId)
        liked = library.likedTracks(account.serverId)
        albums = library.albums(account.serverId, limit = 200).rows.orEmpty()
        loading = false
    }

    // The player sits above everything, the now-playing bar included: it is a
    // full screen, not a pane, and a transport bar peeking out from under it
    // would be two sets of controls for one thing.
    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(account.serverName, style = MaterialTheme.typography.titleMedium) },
                    actions = {
                        TextButton(
                            onClick = onResync,
                            colors = ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        ) { Text("Refresh") }
                        TextButton(
                            onClick = onSignOut,
                            colors = ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        ) { Text("Sign out") }
                    },
                )
            },
            bottomBar = {
                NowPlayingBar(
                    state = playbackState,
                    onPlayPause = playback::togglePlayPause,
                    onNext = { playback.next() },
                    onOpen = { playerOpen = true },
                    server = server,
                )
            },
        ) { insets ->
            Box(modifier = Modifier.fillMaxSize().padding(insets)) {
                if (loading) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(strokeWidth = 2.dp)
                    }
                } else {
                    NavigableListDetailPaneScaffold(
                        navigator = navigator,
                        listPane = {
                            AnimatedPane {
                                LibraryList(
                                    liked = liked,
                                    albums = albums,
                                    albumTotal = counts?.albums ?: albums.size,
                                    server = server,
                                    onPlayLiked = { index -> playback.play(liked, index) },
                                    onOpenAlbum = { album ->
                                        scope.launch {
                                            navigator.navigateTo(
                                                ListDetailPaneScaffoldRole.Detail,
                                                album.groupKey.ifEmpty { album.remoteId },
                                            )
                                        }
                                    },
                                )
                            }
                        },
                        detailPane = {
                            AnimatedPane {
                                val key = navigator.currentDestination?.contentKey
                                val album = albums.firstOrNull {
                                    it.groupKey.ifEmpty { it.remoteId } == key
                                }
                                if (album == null) {
                                    EmptyDetail()
                                } else {
                                    AlbumDetail(account.serverId, album, library, playback)
                                }
                            }
                        },
                    )
                }
            }
        }

        PlayerSheet(
            visible = playerOpen,
            state = playbackState,
            server = server,
            library = library,
            playback = playback,
            onCollapse = { playerOpen = false },
        )
    }
}

@Composable
private fun LibraryList(
    liked: List<Track>,
    albums: List<Album>,
    albumTotal: Int,
    server: MozzServer,
    onPlayLiked: (Int) -> Unit,
    onOpenAlbum: (Album) -> Unit,
) {
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            SectionHeader("Liked Songs", "%,d".format(liked.size))
        }
        if (liked.isEmpty()) {
            item { Hint("Nothing liked on this server yet.") }
        }
        // Tapping a song plays from there through the rest of the list, which is
        // what every music player does and what "play my liked songs" means.
        itemsIndexed(liked.take(50), key = { _, track -> "liked-${track.id}" }) { index, track ->
            TrackRow(track, onClick = { onPlayLiked(index) })
        }

        item { SectionHeader("Albums", "%,d".format(albumTotal)) }
        items(albums, key = { "album-${it.id}" }) { album ->
            AlbumRow(album, server, onClick = { onOpenAlbum(album) })
        }
    }
}

@Composable
private fun SectionHeader(title: String, trailing: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.headlineMedium)
        Text(
            trailing,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
    )
}

@Composable
private fun TrackRow(track: Track, onClick: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                track.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(12.dp))
        Text(
            track.duration,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AlbumRow(album: Album, server: MozzServer, onClick: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
        Artwork(
            server = server,
            serverId = album.serverId,
            artworkKey = album.artworkKey,
            size = 160,
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
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}

@Composable
private fun EmptyDetail() {
    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Pick an album.", style = quietBody)
        }
    }
}

@Composable
private fun AlbumDetail(
    serverId: String,
    album: Album,
    library: MozzLibrary,
    playback: PlayerController,
) {
    var tracks by remember(album.id) { mutableStateOf<List<Track>>(emptyList()) }

    LaunchedEffect(album.id) {
        // Ask by group key when there is one: servers — Jellyfin especially —
        // split one album across several entities, and the remote id alone
        // returns a slice of it.
        tracks = library.albumTracks(
            serverId = serverId,
            remoteId = album.remoteId,
            groupKey = album.groupKey.ifEmpty { null },
        )
    }

    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Column(modifier = Modifier.padding(20.dp)) {
                Text(album.title, style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(4.dp))
                Text(
                    listOfNotNull(album.artistName, album.year?.toString()).joinToString(" · "),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        itemsIndexed(tracks, key = { _, track -> track.id }) { index, track ->
            TrackRow(track, onClick = { playback.play(tracks, index) })
        }
    }
}


/**
 * The bar that says what is playing.
 *
 * Absent entirely when nothing is, rather than present and empty: a permanent
 * dead strip along the bottom of a library is the sort of chrome that makes an
 * app feel heavier than it is.
 */
@Composable
private fun NowPlayingBar(
    state: PlaybackState,
    server: MozzServer,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
    onOpen: () -> Unit,
) {
    val track = state.track ?: return

    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Artwork(
                server = server,
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                size = 128,
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)),
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    track.title,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    track.artistName,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(12.dp))
            TextButton(
                onClick = onPlayPause,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.onSurface,
                ),
            ) {
                Text(if (state.isPlaying) "Pause" else "Play")
            }
            TextButton(
                onClick = onNext,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            ) { Text("Next") }
        }
    }
}
