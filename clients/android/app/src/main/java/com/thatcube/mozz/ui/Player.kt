package com.thatcube.mozz.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.Lyrics
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlaybackState
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.playback.RepeatMode
import com.thatcube.mozz.ui.theme.quietBody
import kotlinx.coroutines.delay

/**
 * The player's own foreground colours.
 *
 * Fixed rather than taken from the colour scheme, because the player's ground is
 * the artwork wash — always dark, whatever the system theme is doing — so
 * scheme colours would be legible in dark mode and invisible in light.
 */
private val PlayerForeground = Color(0xFFF6F6F6)
private val PlayerForegroundMuted = Color(0xB3F6F6F6)

/** What is showing beside (or instead of) the artwork. Mirrors iOS's `PlayerPanel`. */
enum class PlayerPanel { QUEUE, LYRICS }

/**
 * The player.
 *
 * The layout answers a question iOS does not: what to do when there is more room
 * than one column. On a phone — and on the Fold's cover screen — the queue and
 * the lyrics *replace* the artwork, which is what iOS does and what the space
 * allows. Given a second column's worth of width, they sit beside the player
 * instead, so what is playing and what is coming next are both simply there.
 *
 * The rest is deliberately iOS's behaviour rather than a new invention, because
 * the two apps should feel like one product: the same panels, the same 5-second
 * idle takeover that lets the words have the screen, the same rule that any
 * touch brings the chrome back.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun PlayerScreen(
    state: PlaybackState,
    server: MozzServer,
    library: MozzLibrary,
    playback: PlayerController,
    onCollapse: () -> Unit,
) {
    val track = state.track ?: return
    // The same question the library's list/detail scaffold asks, answered the
    // same way. Width alone was wrong: half-folded, the hinge splits the library
    // into two panes while the width class still reads as a phone, so the player
    // stayed one column on a screen that was visibly showing two.
    val wide = calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())
        .maxHorizontalPartitions > 1

    // Wide layouts open onto the queue, because an empty second column is worse
    // than a useful one. Narrow layouts open onto the artwork, because there the
    // panel costs you the record sleeve.
    var panel by remember(wide) { mutableStateOf(if (wide) PlayerPanel.QUEUE else null) }

    // Bumped by any touch in the lyrics, which restarts the idle countdown.
    var interactions by remember { mutableIntStateOf(0) }
    var immersive by remember { mutableStateOf(false) }

    // The idle takeover: after a few seconds of being left alone with the lyrics
    // showing, the chrome drifts away. Armed only while audio is actually
    // running — a stopped player with no controls is a dead end — and torn down
    // the moment anything else happens.
    LaunchedEffect(wide, panel, state.isPlaying, interactions) {
        // Clearing first is the whole fix: a touch bumps `interactions`, which
        // restarts this effect, and without this line the chrome never came back
        // — it just re-armed the countdown and left you staring at lyrics with
        // no way out.
        immersive = false
        // Nothing to take over in a two-pane layout: the lyrics already have a
        // column of their own, and hiding the transport there would buy nothing.
        if (wide || panel != PlayerPanel.LYRICS || !state.isPlaying) return@LaunchedEffect
        delay(IMMERSIVE_DELAY_MS)
        immersive = true
    }

    // Warm the next cover while the current one is still playing. Holding the
    // previous artwork stops the black square; this is what stops the wait.
    val context = LocalContext.current
    LaunchedEffect(state.indexInQueue, state.queue.size) {
        prefetchArtwork(server, context, state.queue.getOrNull(state.indexInQueue + 1), 1024)
    }

    BackHandler {
        when {
            immersive -> immersive = false
            panel != null && !wide -> panel = null
            else -> onCollapse()
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        PlayerBackground(
            server = server,
            library = library,
            serverId = track.serverId,
            artworkKey = track.artworkKey,
        )

        // The backdrop is always a dark wash of the artwork, whatever the system
        // theme is, so the player's content colour is fixed rather than taken
        // from the scheme. Dropping the Surface that used to provide it is what
        // turned the title black on a navy background.
        CompositionLocalProvider(
            LocalContentColor provides PlayerForeground,
            LocalTextSelectionColors provides LocalTextSelectionColors.current,
        ) {
        Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
            AnimatedVisibility(
                visible = !immersive,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onCollapse) {
                        Icon(
                            painterResource(R.drawable.ic_chevron_down),
                            contentDescription = "Close the player",
                            tint = PlayerForegroundMuted,
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    if (wide) {
                        PanelTabs(panel) { panel = it }
                    }
                }
            }

            if (wide) {
                Row(
                    modifier = Modifier.fillMaxSize().padding(start = 32.dp, end = 24.dp, bottom = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f).widthIn(max = 620.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Artwork(
                            server = server,
                            serverId = track.serverId,
                            artworkKey = track.artworkKey,
                            size = 1024,
                            modifier = Modifier
                                .sizeIn(maxWidth = 520.dp, maxHeight = 520.dp)
                                .fillMaxWidth()
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(12.dp)),
                        )
                        Spacer(Modifier.height(28.dp))
                        Chrome(state, playback, centred = true)
                    }
                    Spacer(Modifier.width(32.dp))
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        Panel(
                            panel = panel ?: PlayerPanel.QUEUE,
                            state = state,
                            playback = playback,
                            library = library,
                            onInteraction = { interactions++ },
                        )
                    }
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // The panel takes the artwork's place rather than pushing it
                    // off-screen, so the transport never moves under the user's
                    // thumb when they open the queue.
                    Box(
                        modifier = Modifier.fillMaxWidth().weight(1f),
                        contentAlignment = Alignment.Center,
                    ) {
                        Crossfade(targetState = panel, label = "player-panel") { showing ->
                            if (showing == null) {
                                Artwork(
                                    server = server,
                                    serverId = track.serverId,
                                    artworkKey = track.artworkKey,
                                    size = 1024,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .aspectRatio(1f)
                                        .clip(RoundedCornerShape(12.dp)),
                                )
                            } else {
                                Panel(
                                    panel = showing,
                                    state = state,
                                    playback = playback,
                                    library = library,
                                    onInteraction = { interactions++ },
                                )
                            }
                        }
                    }

                    AnimatedVisibility(
                        visible = !immersive,
                        enter = fadeIn(spring()) + expandVertically(spring()),
                        exit = fadeOut(spring()) + shrinkVertically(spring()),
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Spacer(Modifier.height(24.dp))
                            Chrome(state, playback, centred = true)
                            Spacer(Modifier.height(12.dp))
                            PanelTabs(panel) { panel = it }
                            Spacer(Modifier.height(12.dp))
                        }
                    }
                }
            }
        }
        }
    }
}

/** Titles, scrubber and transport — everything that is not the artwork or a panel. */
@Composable
private fun Chrome(state: PlaybackState, playback: PlayerController, centred: Boolean) {
    Column(modifier = Modifier.fillMaxWidth()) {
        TrackTitles(state, centred)
        Spacer(Modifier.height(20.dp))
        Scrubber(state, playback)
        Spacer(Modifier.height(12.dp))
        Transport(state, playback)
    }
}

/**
 * Which panel is showing, if any.
 *
 * Selecting the panel you are already on closes it, which is how the artwork
 * comes back on a narrow screen without a separate "show artwork" control.
 */
@Composable
private fun PanelTabs(current: PlayerPanel?, onSelect: (PlayerPanel?) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PlayerPanel.entries.forEach { panel ->
            val selected = current == panel
            Surface(
                color = if (selected) PlayerForeground.copy(alpha = 0.18f) else Color.Transparent,
                shape = RoundedCornerShape(percent = 50),
                modifier = Modifier.clickable { onSelect(if (selected) null else panel) },
            ) {
                Text(
                    when (panel) {
                        PlayerPanel.QUEUE -> "Up next"
                        PlayerPanel.LYRICS -> "Lyrics"
                    },
                    style = MaterialTheme.typography.labelLarge,
                    color = if (selected) PlayerForeground else PlayerForegroundMuted,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun Panel(
    panel: PlayerPanel,
    state: PlaybackState,
    playback: PlayerController,
    library: MozzLibrary,
    onInteraction: () -> Unit,
) {
    when (panel) {
        PlayerPanel.QUEUE -> QueuePane(state, playback)
        PlayerPanel.LYRICS -> LyricsPane(state, library, onInteraction)
    }
}

@Composable
private fun QueuePane(state: PlaybackState, playback: PlayerController) {
    val listState = rememberLazyListState()

    // Follow the music: when the track changes, put what is playing at the top
    // rather than leaving the user scrolled to a song that finished ten minutes
    // ago.
    LaunchedEffect(state.indexInQueue) {
        if (state.indexInQueue in state.queue.indices) {
            listState.animateScrollToItem(state.indexInQueue)
        }
    }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 8.dp),
    ) {
        itemsIndexed(state.queue, key = { _, track -> "queue-${track.id}" }) { index, track ->
            QueueRow(
                track = track,
                isCurrent = index == state.indexInQueue,
                isPast = index < state.indexInQueue,
                onClick = { playback.playQueueIndex(index) },
            )
        }
    }
}

@Composable
private fun QueueRow(track: Track, isCurrent: Boolean, isPast: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            // Translucent, not opaque: the artwork wash is the point, and a
            // solid list background would paint it out entirely.
            .background(
                if (isCurrent) PlayerForeground.copy(alpha = 0.14f) else Color.Transparent
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                // Played tracks stay in the list — the queue is where you came
                // from as well as where you are going — but they recede.
                color = if (isPast) PlayerForegroundMuted else PlayerForeground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                track.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = PlayerForegroundMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(12.dp))
        Text(
            track.duration,
            style = MaterialTheme.typography.labelMedium,
            color = PlayerForegroundMuted,
        )
    }
}

/**
 * Time-synced lyrics, highlighting and scrolling the line being sung.
 *
 * The core resolves them — server first, then LRCLIB — so this is only ever
 * display. Three states are deliberately distinguished, because the difference
 * matters to the person reading:
 *
 *   * lines, which scroll;
 *   * a trustworthy "no lyrics for this song";
 *   * and a *silent* nothing, when the core could not actually find out. Saying
 *     "no lyrics" there would be asserting something nobody checked.
 */
@Composable
private fun LyricsPane(
    state: PlaybackState,
    library: MozzLibrary,
    onInteraction: () -> Unit,
) {
    val track = state.track
    var lyrics by remember(track?.remoteId) { mutableStateOf<Lyrics?>(null) }
    var loading by remember(track?.remoteId) { mutableStateOf(true) }
    val listState = rememberLazyListState()

    LaunchedEffect(track?.remoteId) {
        val current = track ?: return@LaunchedEffect
        loading = true
        lyrics = runCatching { library.lyrics(current.serverId, current.remoteId) }.getOrNull()
        loading = false
    }

    val currentLine = lyrics?.lineIndex(state.positionMillis / 1000.0)

    // Keep the sung line a third of the way down rather than at the very top:
    // the lines just gone are as much of the context as the ones coming.
    LaunchedEffect(currentLine) {
        val index = currentLine ?: return@LaunchedEffect
        listState.animateScrollToItem(index.coerceAtLeast(0), scrollOffset = -220)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(Unit) { detectTapGestures { onInteraction() } },
        contentAlignment = Alignment.Center,
    ) {
        val resolved = lyrics
        when {
            loading -> Unit
            resolved == null || resolved.isEmpty -> {
                if (resolved?.staySilent != true) {
                    Text("No lyrics for this song.", style = quietBody)
                }
            }
            else -> LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = 32.dp, horizontal = 8.dp),
            ) {
                itemsIndexed(resolved.lines) { index, line ->
                    val sung = index == currentLine
                    Text(
                        line.text,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = if (sung) FontWeight.Bold else FontWeight.Medium,
                        // Unsung lines recede rather than disappear, so the shape
                        // of the song stays readable.
                        color = if (sung || !resolved.isSynced) PlayerForeground else PlayerForegroundMuted,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    )
                }
                resolved.source?.let { source ->
                    item {
                        Text(
                            "Lyrics from $source",
                            style = MaterialTheme.typography.labelSmall,
                            color = PlayerForegroundMuted,
                            modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackTitles(state: PlaybackState, centred: Boolean) {
    val track = state.track ?: return
    val textAlign = if (centred) TextAlign.Center else TextAlign.Start

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (centred) Alignment.CenterHorizontally else Alignment.Start,
    ) {
        Text(
            track.title,
            style = MaterialTheme.typography.headlineMedium,
            textAlign = textAlign,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            listOfNotNull(track.artistName, track.albumTitle).joinToString(" · "),
            style = MaterialTheme.typography.bodyMedium,
            color = PlayerForegroundMuted,
            textAlign = textAlign,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The scrubber holds its own position while a drag is in progress.
 *
 * Without that, the twice-a-second position tick fights the finger: the thumb
 * snaps back to wherever the player actually is between drag events. The seek
 * happens once, when the finger lifts.
 */
@Composable
private fun Scrubber(state: PlaybackState, playback: PlayerController) {
    var dragging by remember { mutableStateOf(false) }
    var draggedFraction by remember { mutableFloatStateOf(0f) }
    val fraction = if (dragging) draggedFraction else state.progress

    Column(modifier = Modifier.fillMaxWidth()) {
        Slider(
            value = fraction,
            onValueChange = {
                dragging = true
                draggedFraction = it
            },
            onValueChangeFinished = {
                playback.seekToFraction(draggedFraction)
                dragging = false
            },
            colors = SliderDefaults.colors(
                thumbColor = PlayerForeground,
                activeTrackColor = PlayerForeground,
                inactiveTrackColor = PlayerForeground.copy(alpha = 0.28f),
            ),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                clock((fraction * state.durationMillis).toLong()),
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
            Text(
                clock(state.durationMillis),
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
        }
    }
}

@Composable
private fun Transport(state: PlaybackState, playback: PlayerController) {
    val active = PlayerForeground
    val idle = PlayerForegroundMuted

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = playback::toggleShuffle) {
            Icon(
                painterResource(R.drawable.ic_shuffle),
                contentDescription = if (state.shuffle) "Shuffle on" else "Shuffle off",
                // On/off is carried by contrast, not by the accent: the accent
                // means "the action", and a shuffle toggle is not that.
                tint = if (state.shuffle) active else idle,
            )
        }

        IconButton(onClick = { playback.previous() }) {
            Icon(
                painterResource(R.drawable.ic_skip_back),
                contentDescription = "Previous",
                tint = active,
                modifier = Modifier.size(30.dp),
            )
        }

        // The one crimson thing on the screen, and the only control anyone
        // reaches for without looking.
        Surface(
            color = MaterialTheme.colorScheme.primary,
            shape = RoundedCornerShape(percent = 50),
            modifier = Modifier.size(68.dp).clickable(onClick = playback::togglePlayPause),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    painterResource(
                        if (state.isPlaying) R.drawable.ic_pause else R.drawable.ic_play
                    ),
                    contentDescription = if (state.isPlaying) "Pause" else "Play",
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(30.dp),
                )
            }
        }

        IconButton(onClick = { playback.next() }, enabled = state.hasNext) {
            Icon(
                painterResource(R.drawable.ic_skip_forward),
                contentDescription = "Next",
                tint = if (state.hasNext) active else idle,
                modifier = Modifier.size(30.dp),
            )
        }

        IconButton(onClick = playback::cycleRepeat) {
            Icon(
                painterResource(R.drawable.ic_repeat),
                contentDescription = when (state.repeat) {
                    RepeatMode.OFF -> "Repeat off"
                    RepeatMode.ALL -> "Repeat all"
                    RepeatMode.ONE -> "Repeat one"
                },
                tint = if (state.repeat == RepeatMode.OFF) idle else active,
            )
        }
    }
}

/** m:ss, matching how durations read everywhere else in the app. */
private fun clock(millis: Long): String {
    if (millis <= 0) return "0:00"
    val total = millis / 1000
    val hours = total / 3600
    val minutes = (total % 3600) / 60
    val seconds = total % 60
    return if (hours >= 1) "%d:%02d:%02d".format(hours, minutes, seconds)
    else "%d:%02d".format(minutes, seconds)
}

/**
 * Long enough to scrub or skip without the controls sliding out from under you,
 * short enough that simply looking at the lyrics gets you the full-screen view.
 * The same five seconds iOS uses.
 */
private const val IMMERSIVE_DELAY_MS = 5000L

/** Slides the player up over whatever is behind it, and back down on dismiss. */
@Composable
fun PlayerSheet(
    visible: Boolean,
    state: PlaybackState,
    server: MozzServer,
    library: MozzLibrary,
    playback: PlayerController,
    onCollapse: () -> Unit,
) {
    AnimatedVisibility(
        visible = visible && state.track != null,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        PlayerScreen(state, server, library, playback, onCollapse)
    }
}
