package com.thatcube.mozz.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.zIndex
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.gestures.detectTapGestures
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
 * the artwork wash — always dark, whatever the system theme is doing — so scheme
 * colours would be legible in dark mode and invisible in light.
 */
internal val PlayerForeground = Color(0xFFF6F6F6)
internal val PlayerForegroundMuted = Color(0xB3F6F6F6)

/**
 * Everything in the player except the cover and the backdrop, both of which
 * belong to the morph — it is drawing the cover on top of this, travelling.
 *
 * The layout is chosen by [PlayerPresentation], which is a rule in one place
 * rather than `if (wide)` sprinkled through here. What that buys: the queue and
 * the lyrics are one piece of state at every width, so folding the device
 * rearranges the screen without changing what the person asked for.
 */
@Composable
internal fun PlayerBody(
    state: PlaybackState,
    server: MozzServer,
    library: MozzLibrary,
    playback: PlayerController,
    presentation: PlayerPresentation,
    panel: PlayerPanel?,
    onPanel: (PlayerPanel?) -> Unit,
    wide: Boolean,
    onCollapse: () -> Unit,
    onArtSlot: (Rect) -> Unit,
) {
    val track = state.track ?: return

    // Bumped by any touch in the lyrics, which restarts the idle countdown.
    var interactions by remember { mutableIntStateOf(0) }
    var immersive by remember { mutableStateOf(false) }

    // The idle takeover: after a few seconds alone with the lyrics, the chrome
    // drifts away. Armed only while audio is actually running — a stopped player
    // with no controls is a dead end — and torn down the moment anything happens.
    LaunchedEffect(presentation, panel, state.isPlaying, interactions) {
        // Clearing first is the whole fix: a touch bumps `interactions`, which
        // restarts this effect, and without this line the chrome never came back.
        immersive = false
        // Nothing to take over beside a panel: the lyrics already have a column,
        // and hiding the transport there would buy nothing.
        if (presentation != PlayerPresentation.PANEL_INSTEAD) return@LaunchedEffect
        if (panel != PlayerPanel.LYRICS || !state.isPlaying) return@LaunchedEffect
        delay(IMMERSIVE_DELAY_MS)
        immersive = true
    }

    // Warm the next cover while the current one is still playing. Holding the
    // previous artwork stops the black square; this is what stops the wait.
    val context = LocalContext.current
    LaunchedEffect(state.indexInQueue, state.queue.size) {
        prefetchArtwork(server, context, state.queue.getOrNull(state.indexInQueue + 1), 1024)
    }

    CompositionLocalProvider(LocalContentColor provides PlayerForeground) {
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
                }
            }

            when (presentation) {
                PlayerPresentation.PANEL_BESIDE -> Row(
                    modifier = Modifier.weight(1f).fillMaxWidth()
                        .padding(start = 32.dp, end = 24.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f).fillMaxHeight().widthIn(max = 620.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        ArtSlot(onArtSlot, Modifier.weight(1f, fill = false))
                        Spacer(Modifier.height(28.dp))
                        Chrome(state, playback)
                    }
                    Spacer(Modifier.width(32.dp))
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        Panel(
                            panel = panel ?: PlayerPanel.QUEUE,
                            state = state,
                            server = server,
                            playback = playback,
                            library = library,
                            // Beside the artwork there is no need to repeat the
                            // current track as a card — it is already the biggest
                            // thing on the screen, in the next column.
                            showsNowPlayingCard = false,
                            onInteraction = { interactions++ },
                        )
                    }
                }

                else -> Column(
                    modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // One box, two occupants. The cover is drawn into it by the
                    // morph; a panel, when there is one, takes the same space —
                    // which is what "replaces the artwork" has to mean if the
                    // transport is not to move under the user's thumb.
                    Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                        ArtSlot(onArtSlot, Modifier.fillMaxSize())
                        androidx.compose.animation.AnimatedVisibility(
                            visible = panel != null,
                            enter = fadeIn(tween(PANEL_SWAP_MS)),
                            exit = fadeOut(tween(PANEL_SWAP_MS)),
                        ) {
                            Panel(
                                panel = panel ?: PlayerPanel.QUEUE,
                                state = state,
                                server = server,
                                playback = playback,
                                library = library,
                                // Here the panel has taken the artwork's place,
                                // so the card is the only thing still showing
                                // what is playing — and it is where the
                                // travelling cover lands.
                                showsNowPlayingCard = true,
                                onInteraction = { interactions++ },
                            )
                        }
                    }

                    AnimatedVisibility(
                        visible = !immersive,
                        enter = fadeIn(spring()) + expandVertically(spring()),
                        exit = fadeOut(spring()) + shrinkVertically(spring()),
                    ) {
                        Column {
                            Spacer(Modifier.height(24.dp))
                            Chrome(state, playback)
                        }
                    }
                }
            }

            AnimatedVisibility(
                visible = !immersive,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                PlayerBottomBar(panel = panel, onPanel = onPanel)
            }
        }
    }
}

/**
 * The row along the bottom: lyrics, output route, queue.
 *
 * iOS's order, so the two apps put the same control under the same thumb. The
 * two panel toggles are mutually exclusive and share a job — tapping one while
 * the other is open swaps between them rather than closing anything.
 *
 * Persistent icons rather than labelled tabs. The panels are somewhere you go and
 * come back from, not a mode the player is in, and a lit icon says that better
 * than a selected tab does — it also stops the controls above from reflowing
 * every time a panel opens.
 */
@Composable
private fun PlayerBottomBar(panel: PlayerPanel?, onPanel: (PlayerPanel?) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PanelButton(
            icon = R.drawable.ic_lyrics,
            label = "Lyrics",
            selected = panel == PlayerPanel.LYRICS,
            onClick = { onPanel(if (panel == PlayerPanel.LYRICS) null else PlayerPanel.LYRICS) },
        )
        Spacer(Modifier.weight(1f))
        // iOS shows the real output route here and opens the AirPlay picker.
        // Android's equivalent is Cast, which is a receiver and a MediaRouter
        // away — real work, not this pass. Present and quiet, because a control
        // the layout assumes is harder to add back later than one that waits.
        IconButton(onClick = {}, enabled = false) {
            Icon(
                painterResource(R.drawable.ic_cast),
                contentDescription = "Cast (not yet available)",
                tint = PlayerForegroundMuted.copy(alpha = 0.4f),
            )
        }
        Spacer(Modifier.weight(1f))
        PanelButton(
            icon = R.drawable.ic_queue,
            label = "Queue",
            selected = panel == PlayerPanel.QUEUE,
            onClick = { onPanel(if (panel == PlayerPanel.QUEUE) null else PlayerPanel.QUEUE) },
        )
    }
}

/** One panel toggle: a lit circle when its panel is open. */
@Composable
private fun PanelButton(icon: Int, label: String, selected: Boolean, onClick: () -> Unit) {
    val wash by animateFloatAsState(
        targetValue = if (selected) 0.22f else 0f,
        animationSpec = tween(PANEL_SWAP_MS),
        label = "panel-button",
    )
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(PlayerForeground.copy(alpha = wash))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = label,
            tint = if (selected) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(22.dp),
        )
    }
}

/**
 * The hole the travelling cover lands in.
 *
 * Draws nothing. It exists to be laid out naturally and then to say where it
 * ended up, so the morph can fly the cover to a measured rectangle rather than to
 * a constant two files have to keep agreeing on.
 */
@Composable
private fun ArtSlot(onBounds: (Rect) -> Unit, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier = modifier, contentAlignment = Alignment.Center) {
        val side = minOf(maxWidth, maxHeight)
        Box(Modifier.size(side).reportBounds(onBounds))
    }
}

/** Titles, scrubber and transport — everything that is not the cover or a panel. */
@Composable
private fun Chrome(state: PlaybackState, playback: PlayerController) {
    Column(modifier = Modifier.fillMaxWidth()) {
        TrackTitles(state)
        Spacer(Modifier.height(20.dp))
        Scrubber(state, playback)
        Spacer(Modifier.height(12.dp))
        Transport(state, playback)
    }
}

@Composable
private fun Panel(
    panel: PlayerPanel,
    state: PlaybackState,
    server: MozzServer,
    playback: PlayerController,
    library: MozzLibrary,
    showsNowPlayingCard: Boolean,
    onInteraction: () -> Unit,
) {
    when (panel) {
        PlayerPanel.QUEUE -> QueuePane(state, server, playback, showsNowPlayingCard)
        PlayerPanel.LYRICS -> LyricsPane(state, library, onInteraction)
    }
}

/**
 * What has played, what is playing, and what is coming.
 *
 * Three sections in iOS's order and with iOS's names — History, the now-playing
 * card, then Queue — because the two apps are one product and a queue that calls
 * the same thing by two names is the kind of difference people notice without
 * being able to say why. ("Continue Playing" is Apple's phrase, and only ever
 * appeared in Mozz's code comments; the string iOS actually ships is "Queue".)
 *
 * The structure is what produces the animation the flat list could not: when a
 * track starts it *leaves* the queue and becomes the card, so the row shrinks out
 * of the list rather than a highlight silently jumping down one place.
 */
@Composable
private fun QueuePane(
    state: PlaybackState,
    server: MozzServer,
    playback: PlayerController,
    showsNowPlayingCard: Boolean,
) {
    val listState = rememberLazyListState()
    val haptics = LocalHapticFeedback.current
    val current = state.indexInQueue
    val history = remember(state.queue, current) {
        state.queue.take(current.coerceAtLeast(0))
    }
    val committed = remember(state.queue, current) {
        if (current + 1 in state.queue.indices) state.queue.drop(current + 1) else emptyList()
    }

    // While a row is lifted the list shows a local preview, so the reorder is
    // visible under the finger before anything is asked of the player. Only the
    // net move is committed on release — dragging past six songs is one
    // instruction, not six.
    var preview by remember { mutableStateOf<List<Track>?>(null) }
    var lifted by remember { mutableIntStateOf(-1) }
    var liftedFrom by remember { mutableIntStateOf(-1) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var rowHeight by remember { mutableFloatStateOf(0f) }
    val upNext = preview ?: committed

    // Open on what is playing, with the history above it rather than scrolled
    // away — where you came from is part of the queue, it just is not what you
    // are looking for.
    LaunchedEffect(Unit) {
        if (history.isNotEmpty()) listState.scrollToItem(history.size)
    }
    LaunchedEffect(current) {
        if (history.isNotEmpty()) listState.animateScrollToItem(history.size)
    }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 8.dp),
    ) {
        if (history.isNotEmpty()) {
            item(key = "history-header") {
                SectionRow("History", onClear = playback::clearHistory, Modifier.animateItem())
            }
        }
        itemsIndexed(history, key = { _, t -> "past-${t.id}" }) { index, track ->
            QueueRow(
                track = track,
                server = server,
                muted = true,
                draggable = false,
                onClick = { playback.playQueueIndex(index) },
                modifier = Modifier.animateItem(),
            )
        }

        if (showsNowPlayingCard) {
            state.track?.let { track ->
                item(key = "now-playing") {
                    NowPlayingCard(track, state.intendsToPlay, server, Modifier.animateItem())
                }
            }
        }

        item(key = "queue-controls") {
            QueueControls(state, playback, Modifier.animateItem())
        }

        if (upNext.isNotEmpty()) {
            item(key = "queue-header") {
                SectionRow("Queue", onClear = playback::clearQueue, Modifier.animateItem())
            }
        }

        itemsIndexed(upNext, key = { _, t -> "next-${t.id}" }) { index, track ->
            val isLifted = index == lifted
            QueueRow(
                track = track,
                server = server,
                muted = false,
                draggable = true,
                onClick = { playback.playQueueIndex(current + 1 + index) },
                modifier = Modifier
                    // The lifted row is driven by the finger, so it must not also
                    // be animated into place by the list — the two would fight,
                    // and the row would lag behind the touch.
                    .then(if (isLifted) Modifier else Modifier.animateItem())
                    .then(if (isLifted) Modifier.zIndex(1f) else Modifier)
                    .onSizeChanged { if (it.height > 0) rowHeight = it.height.toFloat() }
                    .graphicsLayer {
                        if (isLifted) {
                            translationY = dragOffset
                            scaleX = LIFT_SCALE
                            scaleY = LIFT_SCALE
                            shadowElevation = 12f
                        }
                    }
                    .pointerInput(index, committed) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = {
                                lifted = index
                                liftedFrom = index
                                dragOffset = 0f
                                preview = committed
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            },
                            onDrag = { change, delta ->
                                change.consume()
                                dragOffset += delta.y
                                val h = rowHeight
                                if (h <= 0f) return@detectDragGesturesAfterLongPress
                                var list = preview ?: committed
                                var at = lifted
                                // Half a row of travel swaps with the neighbour,
                                // and the offset is repaid so the row stays under
                                // the finger rather than drifting away from it.
                                while (dragOffset > h / 2 && at < list.lastIndex) {
                                    list = list.toMutableList().apply { add(at + 1, removeAt(at)) }
                                    at += 1
                                    dragOffset -= h
                                }
                                while (dragOffset < -h / 2 && at > 0) {
                                    list = list.toMutableList().apply { add(at - 1, removeAt(at)) }
                                    at -= 1
                                    dragOffset += h
                                }
                                if (at != lifted) {
                                    preview = list
                                    lifted = at
                                }
                            },
                            onDragEnd = {
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                if (lifted >= 0 && liftedFrom >= 0 && lifted != liftedFrom) {
                                    playback.moveQueueItem(
                                        current + 1 + liftedFrom,
                                        current + 1 + lifted,
                                    )
                                }
                                preview = null
                                lifted = -1
                                liftedFrom = -1
                                dragOffset = 0f
                            },
                            onDragCancel = {
                                preview = null
                                lifted = -1
                                liftedFrom = -1
                                dragOffset = 0f
                            },
                        )
                    },
            )
        }
    }
}

/** How much a lifted row grows, so it reads as picked up rather than slid. */
private const val LIFT_SCALE = 1.03f

/** A section's name, with the control that empties it. */
@Composable
private fun SectionRow(title: String, onClear: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 12.dp, top = 20.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = PlayerForeground,
        )
        Spacer(Modifier.weight(1f))
        Text(
            "Clear",
            style = MaterialTheme.typography.labelLarge,
            color = PlayerForegroundMuted,
            modifier = Modifier
                .clip(RoundedCornerShape(percent = 50))
                .clickable(onClick = onClear)
                .padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}

/**
 * Shuffle and repeat, as pills above the queue.
 *
 * The same two controls as the transport below, deliberately: they change what
 * the queue *is*, so they belong where you are looking at it — iOS puts them in
 * the same place for the same reason.
 */
@Composable
private fun QueueControls(
    state: PlaybackState,
    playback: PlayerController,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        QueuePill(
            icon = R.drawable.ic_shuffle,
            label = if (state.shuffle) "Shuffle on" else "Shuffle off",
            selected = state.shuffle,
            onClick = playback::toggleShuffle,
            modifier = Modifier.weight(1f),
        )
        QueuePill(
            icon = if (state.repeat == RepeatMode.ONE) R.drawable.ic_repeat_one
            else R.drawable.ic_repeat,
            label = when (state.repeat) {
                RepeatMode.OFF -> "Repeat off"
                RepeatMode.ALL -> "Repeat all"
                RepeatMode.ONE -> "Repeat one"
            },
            selected = state.repeat != RepeatMode.OFF,
            onClick = playback::cycleRepeat,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun QueuePill(
    icon: Int,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val wash by animateFloatAsState(
        targetValue = if (selected) 0.22f else 0.08f,
        animationSpec = tween(PANEL_SWAP_MS),
        label = "queue-pill",
    )
    Box(
        modifier = modifier
            .height(38.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(PlayerForeground.copy(alpha = wash))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = label,
            tint = if (selected) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * The current track, sitting in the queue where it belongs.
 *
 * Shown only when the panel has taken the artwork's place — beside the artwork it
 * would just be the same track twice. Its cover is where the travelling cover
 * lands, so the two are the same size and in the same place.
 */
@Composable
private fun NowPlayingCard(
    track: Track,
    isPlaying: Boolean,
    server: MozzServer,
    modifier: Modifier = Modifier,
) {
    val breathe by animateFloatAsState(
        targetValue = if (isPlaying) 1f else 1f - PAUSED_CARD_SHRINK,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = 224f),
        label = "now-playing-breathe",
    )

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(PlayerForeground.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            server = server,
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            size = 256,
            modifier = Modifier
                .size(64.dp)
                .graphicsLayer { scaleX = breathe; scaleY = breathe }
                .clip(RoundedCornerShape(9.dp)),
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            MarqueeLine(
                text = track.title,
                style = MaterialTheme.typography.bodyLarge,
                color = PlayerForeground,
                weight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                track.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = PlayerForegroundMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** The card's cover shrinks when paused, like the big one does. */
private const val PAUSED_CARD_SHRINK = 0.06f

@Composable
private fun QueueRow(
    track: Track,
    server: MozzServer,
    muted: Boolean,
    draggable: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = 16.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            server = server,
            serverId = track.serverId,
            artworkKey = track.artworkKey,
            size = 160,
            modifier = Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                track.title,
                style = MaterialTheme.typography.bodyLarge,
                // Played tracks stay in the list — the queue is where you came
                // from as well as where you are going — but they recede.
                color = if (muted) PlayerForegroundMuted else PlayerForeground,
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
        Spacer(Modifier.width(8.dp))
        if (draggable) {
            // The affordance the long-press needs. Without it, a queue you can
            // reorder is indistinguishable from one you cannot.
            Icon(
                painterResource(R.drawable.ic_grip),
                contentDescription = "Drag to reorder",
                tint = PlayerForegroundMuted.copy(alpha = 0.6f),
                modifier = Modifier.size(20.dp),
            )
        } else {
            Text(
                track.duration,
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
        }
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
                    LyricLine(
                        text = line.text,
                        sung = index == currentLine,
                        alwaysLit = !resolved.isSynced,
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

/**
 * One line, lighting up as it is sung.
 *
 * The change is animated rather than switched. A hard cut between two greys on
 * every line reads as flicker at the tempo of the song; an eased one reads as
 * the words arriving.
 */
@Composable
private fun LyricLine(text: String, sung: Boolean, alwaysLit: Boolean) {
    val lit by animateFloatAsState(
        targetValue = if (sung || alwaysLit) 1f else 0f,
        animationSpec = tween(LYRIC_LIGHT_MS),
        label = "lyric-line",
    )
    Text(
        text,
        style = MaterialTheme.typography.headlineSmall,
        fontWeight = if (sung) FontWeight.Bold else FontWeight.Medium,
        // Unsung lines recede rather than disappear, so the shape of the song
        // stays readable.
        color = androidx.compose.ui.graphics.lerp(PlayerForegroundMuted, PlayerForeground, lit),
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
    )
}

/**
 * Title over artist, with the track's star beside them.
 *
 * Left-aligned rather than centred, and the star sits on the same row's trailing
 * edge — iOS's arrangement, so the two apps read the same. The title block is
 * greedy and the star has a fixed width, so a long title reflows around it
 * instead of pushing it off the row.
 */
@Composable
private fun TrackTitles(state: PlaybackState) {
    val track = state.track ?: return

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            MarqueeLine(
                text = track.title,
                style = MaterialTheme.typography.headlineSmall,
                color = PlayerForeground,
                weight = FontWeight.Bold,
            )
            MarqueeLine(
                text = track.artistName,
                style = MaterialTheme.typography.titleMedium,
                color = PlayerForegroundMuted,
            )
        }
        Spacer(Modifier.width(8.dp))
        // Reports the state the server already has — on Plex a "like" is a 5-star
        // rating, which is what fills Liked Songs. Deliberately not tappable yet:
        // setting it needs a session command the core does not expose, and a star
        // that lies about whether it took is worse than one that only reports.
        Icon(
            painterResource(
                if (track.isFavorite) R.drawable.ic_star_filled else R.drawable.ic_star
            ),
            contentDescription = if (track.isFavorite) "Liked" else "Not liked",
            tint = if (track.isFavorite) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(26.dp),
        )
    }
}

/**
 * The scrubber.
 *
 * Drawn rather than assembled from `Slider`, which in Material 3 Expressive is a
 * chunky thumb, a gap, and a stop-indicator dot at the end of the track — three
 * pieces of vocabulary this app does not speak. A scrubber wants to be a line
 * with a position on it.
 *
 * It holds its own position while a drag is in progress. Without that, the
 * twice-a-second position tick fights the finger: the thumb snaps back to
 * wherever the player actually is between drag events. The seek happens once,
 * when the finger lifts.
 */
@Composable
private fun Scrubber(state: PlaybackState, playback: PlayerController) {
    var dragging by remember { mutableStateOf(false) }
    var draggedFraction by remember { mutableFloatStateOf(0f) }
    val fraction = (if (dragging) draggedFraction else state.progress).coerceIn(0f, 1f)
    // The thumb grows under the finger, so it is visible past the fingertip
    // covering it.
    val grip by animateFloatAsState(
        targetValue = if (dragging) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = 700f),
        label = "scrub-grip",
    )

    Column(modifier = Modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(SCRUB_TOUCH_HEIGHT)
                .pointerInput(Unit) {
                    detectHorizontalDragGestures(
                        onDragStart = { offset ->
                            dragging = true
                            draggedFraction = (offset.x / size.width).coerceIn(0f, 1f)
                        },
                        onHorizontalDrag = { change, delta ->
                            change.consume()
                            draggedFraction =
                                (draggedFraction + delta / size.width).coerceIn(0f, 1f)
                        },
                        onDragEnd = {
                            playback.seekToFraction(draggedFraction)
                            dragging = false
                        },
                        onDragCancel = { dragging = false },
                    )
                }
                .pointerInput(Unit) {
                    detectTapGestures { offset ->
                        playback.seekToFraction((offset.x / size.width).coerceIn(0f, 1f))
                    }
                },
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                val h = SCRUB_TRACK_HEIGHT.toPx()
                val midY = size.height / 2
                val r = h / 2
                drawRoundRect(
                    color = PlayerForegroundMuted.copy(alpha = 0.28f),
                    topLeft = Offset(0f, midY - r),
                    size = Size(size.width, h),
                    cornerRadius = CornerRadius(r, r),
                )
                drawRoundRect(
                    color = PlayerForeground,
                    topLeft = Offset(0f, midY - r),
                    size = Size(size.width * fraction, h),
                    cornerRadius = CornerRadius(r, r),
                )
                drawCircle(
                    color = PlayerForeground,
                    radius = lerp(SCRUB_THUMB.toPx(), SCRUB_THUMB_HELD.toPx(), grip),
                    center = Offset(size.width * fraction, midY),
                )
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                clock((fraction * state.durationMillis).toLong()),
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
            // Remaining, not total: what is left is the thing anyone actually
            // reads off a scrubber mid-song.
            Text(
                "-" + clock(state.durationMillis - (fraction * state.durationMillis).toLong()),
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
        }
    }
}

/** Thin, because it is a position indicator and not a control surface. */
private val SCRUB_TRACK_HEIGHT = 4.dp

/** Big enough to hit without looking, whatever the track's height. */
private val SCRUB_TOUCH_HEIGHT = 28.dp
private val SCRUB_THUMB = 6.dp
private val SCRUB_THUMB_HELD = 9.dp

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

        PlayButton(isPlaying = state.isPlaying, onClick = playback::togglePlayPause)

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
                painterResource(
                    if (state.repeat == RepeatMode.ONE) R.drawable.ic_repeat_one
                    else R.drawable.ic_repeat
                ),
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

/**
 * The one crimson thing on the screen, and the only control anyone reaches for
 * without looking.
 *
 * It dips under the finger. A 68dp target that does not acknowledge a press is
 * the difference between a control and a picture of one.
 */
@Composable
private fun PlayButton(isPlaying: Boolean, onClick: () -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.90f else 1f,
        animationSpec = spring(dampingRatio = 0.55f, stiffness = 900f),
        label = "play-press",
    )

    Surface(
        color = MaterialTheme.colorScheme.primary,
        shape = RoundedCornerShape(percent = 50),
        modifier = Modifier
            .size(68.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        tryAwaitRelease()
                        pressed = false
                    },
                    onTap = { onClick() },
                )
            },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                painterResource(if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                contentDescription = if (isPlaying) "Pause" else "Play",
                tint = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.size(30.dp),
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

/** iOS's panel crossfade, to the millisecond. */
private const val PANEL_SWAP_MS = 180

/** Slow enough to read as the word arriving rather than a colour switching. */
private const val LYRIC_LIGHT_MS = 220
