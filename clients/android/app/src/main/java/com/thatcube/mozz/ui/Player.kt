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
import androidx.compose.foundation.border
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.zIndex
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.gestures.detectTapGestures
import com.thatcube.mozz.R
import com.thatcube.mozz.core.LikeGlyph
import com.thatcube.mozz.core.Lyrics
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.playback.PlaybackState
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.playback.RepeatMode
import com.thatcube.mozz.ui.theme.quietBody
import kotlin.math.roundToInt
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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
    /** Heart or star — the server's answer, not the client's guess. */
    likeGlyph: LikeGlyph,
    onCollapse: () -> Unit,
    onArtSlot: (Rect) -> Unit,
    /** Where the queue card's thumbnail landed — the cover's second destination. */
    onCardArtSlot: (Rect) -> Unit,
    /** Queue-open progress, read in layout and draw rather than in composition. */
    queueProgress: () -> Float,
    /** True once the cover has arrived in the card and the card's own can take over. */
    panelSettled: () -> Boolean,
    /** Live drag of the dismiss gesture, in pixels down from where it started. */
    onDismissDrag: (Float) -> Unit,
    /** Finger lifted, with its velocity in px/s — positive is downward. */
    onDismissEnd: (Float) -> Unit,
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

    // The like, held locally so the tap lands immediately. The core writes the
    // row and queues the server call, but the queue this player is reading came
    // from the database when playback started, so nothing would refresh it.
    val scope = rememberCoroutineScope()
    var likeOverride by remember(track.remoteId) { mutableStateOf<Boolean?>(null) }
    val liked = likeOverride ?: track.isLiked
    val toggleLike: () -> Unit = {
        val next = !liked
        likeOverride = next
        scope.launch {
            val settled = runCatching {
                library.setLiked(track.serverId, track.remoteId, next, playback.deviceId)
            }.getOrNull()
            // Snap back if the core disagreed; it owns the policy for what a like
            // means on this backend.
            if (settled != null) likeOverride = settled
        }
    }

    // Warm the next cover while the current one is still playing. Holding the
    // previous artwork stops the black square; this is what stops the wait.
    val context = LocalContext.current
    LaunchedEffect(state.indexInQueue, state.queue.size) {
        prefetchArtwork(server, context, state.queue.getOrNull(state.indexInQueue + 1), 1024)
    }

    CompositionLocalProvider(LocalContentColor provides PlayerForeground) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                // Drag the sheet down to put it away. Attached here rather than to
                // the whole player so a scrolling queue keeps its own gestures:
                // children see the pointer first, so a list that is scrolling
                // consumes the drag before this ever sees it.
                .dismissDrag(onDismissDrag, onDismissEnd),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            AnimatedVisibility(
                visible = !immersive,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 8.dp)
                        // A grabber rather than a close button, matching iOS. The
                        // sheet is dragged away, and Android's back gesture does
                        // the same job for anyone who does not reach for it.
                        .semantics {
                            contentDescription = "Drag down to close the player"
                            onClick("Close the player") { onCollapse(); true }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 36.dp, height = 5.dp)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(PlayerForegroundMuted.copy(alpha = 0.5f))
                    )
                }
            }

            when (presentation) {
                PlayerPresentation.PANEL_BESIDE -> Row(
                    modifier = Modifier.weight(1f).fillMaxWidth()
                        .padding(start = 32.dp, end = 24.dp),
                ) {
                    // Left: the record and its controls, with the output route
                    // under them — the reference puts it at the bottom of this
                    // column, not spread across the whole window.
                    Column(
                        modifier = Modifier.weight(1f).fillMaxHeight().widthIn(max = 620.dp),
                        verticalArrangement = Arrangement.Center,
                    ) {
                        ArtSlot(onArtSlot, Modifier.weight(1f, fill = false))
                        Spacer(Modifier.height(28.dp))
                        Chrome(
                            state, playback, queueProgress, panelOpen = false,
                            likeGlyph = likeGlyph, liked = liked, onToggleLike = toggleLike,
                        )
                    }
                    Spacer(Modifier.width(32.dp))
                    // Right: the panel, with its two toggles sitting at the
                    // bottom of the same column they act on.
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        Panel(
                            panel = panel ?: PlayerPanel.QUEUE,
                            state = state,
                            server = server,
                            playback = playback,
                            library = library,
                            // Beside the artwork there is no need to repeat the
                            // current track as a card, or to offer shuffle and
                            // repeat a second time — both are already in the
                            // column next to this one.
                            showsNowPlayingCard = false,
                            bottomInset = 0.dp,
                            onCardArtSlot = onCardArtSlot,
                            queueProgress = queueProgress,
                            panelSettled = panelSettled,
                            onShowArtwork = { onPanel(null) },
                            likeGlyph = likeGlyph,
                            liked = liked,
                            onToggleLike = toggleLike,
                            onInteraction = { interactions++ },
                        )
                    }
                }

                else -> Column(
                    modifier = Modifier
                        .weight(1f)
                        // Capped *before* filling: `fillMaxWidth` pins the
                        // minimum to the parent's width, so a cap applied after
                        // it has nothing left to shrink.
                        .widthIn(max = SINGLE_COLUMN_MAX)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp),
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
                                bottomInset = 0.dp,
                                onCardArtSlot = onCardArtSlot,
                                queueProgress = queueProgress,
                                panelSettled = panelSettled,
                                onShowArtwork = { onPanel(null) },
                                likeGlyph = likeGlyph,
                                liked = liked,
                                onToggleLike = toggleLike,
                                onInteraction = { interactions++ },
                            )
                        }
                    }

                    AnimatedVisibility(
                        visible = !immersive,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically(),
                    ) {
                        Column {
                            Spacer(Modifier.height(24.dp))
                            Chrome(
                                state, playback, queueProgress, panelOpen = panel != null,
                                likeGlyph = likeGlyph, liked = liked, onToggleLike = toggleLike,
                            )
                        }
                    }
                }
            }

            // One row for both layouts, below everything else rather than over
            // the panel — so the casting control and the two panel toggles share
            // a baseline, and neither sits on top of a song title.
            AnimatedVisibility(
                visible = !immersive,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (presentation == PlayerPresentation.PANEL_BESIDE) {
                        // Two columns: casting belongs under the record, the
                        // panel toggles under the panel they act on.
                        RouteButton()
                        Spacer(Modifier.weight(1f))
                        PanelToggles(panel, onPanel)
                    } else {
                        // One column, so the three share it — iOS's order.
                        PanelButton(
                            icon = R.drawable.ic_lyrics,
                            label = "Lyrics",
                            selected = panel == PlayerPanel.LYRICS,
                            onClick = {
                                onPanel(if (panel == PlayerPanel.LYRICS) null else PlayerPanel.LYRICS)
                            },
                        )
                        Spacer(Modifier.weight(1f))
                        RouteButton()
                        Spacer(Modifier.weight(1f))
                        PanelButton(
                            icon = R.drawable.ic_queue,
                            label = "Queue",
                            selected = panel == PlayerPanel.QUEUE,
                            onClick = {
                                onPanel(if (panel == PlayerPanel.QUEUE) null else PlayerPanel.QUEUE)
                            },
                        )
                    }
                }
            }
        }
    }
}

/**
 * Drag the player down to dismiss it.
 *
 * The morph is already a single scrubbable value, so this is not a second
 * animation — the finger drives exactly what the back gesture drives, and letting
 * go hands the same value to the same spring.
 *
 * Deliberately a plain drag detector on a parent rather than a nested-scroll
 * connection: Compose gives children the pointer first, so a queue that is
 * scrolling consumes the gesture and this never fires inside it. Dragging works
 * on the artwork, the chrome and the empty space, which is where anyone reaches
 * to put a sheet away.
 */
private fun Modifier.dismissDrag(
    onDrag: (Float) -> Unit,
    onEnd: (Float) -> Unit,
): Modifier = this.pointerInput(Unit) {
    var travelled = 0f
    detectVerticalDragGestures(
        onDragStart = { travelled = 0f },
        onVerticalDrag = { change, delta ->
            // Only downward travel dismisses; dragging up does nothing rather
            // than winding the morph past its open state.
            travelled = (travelled + delta).coerceAtLeast(0f)
            if (travelled > 0f) change.consume()
            onDrag(travelled)
        },
        onDragEnd = { onEnd(travelled) },
        onDragCancel = { onEnd(0f) },
    )
}

/** The two panel toggles, as a pair — they share a job and sit together. */
@Composable
private fun PanelToggles(panel: PlayerPanel?, onPanel: (PlayerPanel?) -> Unit) {
    PanelButton(
        icon = R.drawable.ic_lyrics,
        label = "Lyrics",
        selected = panel == PlayerPanel.LYRICS,
        onClick = { onPanel(if (panel == PlayerPanel.LYRICS) null else PlayerPanel.LYRICS) },
    )
    PanelButton(
        icon = R.drawable.ic_queue,
        label = "Queue",
        selected = panel == PlayerPanel.QUEUE,
        onClick = { onPanel(if (panel == PlayerPanel.QUEUE) null else PlayerPanel.QUEUE) },
    )
}

/**
 * Where iOS shows the current output device and opens the AirPlay picker.
 *
 * Android's equivalent is Cast, which needs a MediaRouter and a receiver — real
 * work, and not this pass. Present and quiet, because a control the layout is
 * built around is harder to add back later than one that waits.
 */
@Composable
private fun RouteButton() {
    Box(modifier = Modifier.size(MIN_HIT), contentAlignment = Alignment.Center) {
        Icon(
            painterResource(R.drawable.ic_cast),
            contentDescription = "Cast (not yet available)",
            tint = PlayerForegroundMuted.copy(alpha = 0.4f),
            modifier = Modifier.size(22.dp),
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
            .size(MIN_HIT)
            .clip(RoundedCornerShape(percent = 50))
            .background(PlayerForeground.copy(alpha = wash))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = label,
            tint = if (selected) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(UTILITY_GLYPH),
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
private fun Chrome(
    state: PlaybackState,
    playback: PlayerController,
    queueProgress: () -> Float,
    panelOpen: Boolean,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        HeroTitles(state, queueProgress, likeGlyph, liked, onToggleLike)
        Spacer(Modifier.height(20.dp))
        Scrubber(state, playback)
        Spacer(Modifier.height(16.dp))
        // Shuffle and repeat move to the pills above the queue when it is open,
        // so the transport drops to the three controls that are still its job.
        Transport(state, playback, compact = panelOpen)
        // The row of panel toggles sits below this. Without the gap, a thumb
        // reaching for pause lands on the queue.
        Spacer(Modifier.height(20.dp))
    }
}

/**
 * The title row, and its half of the cross-fade into the queue card.
 *
 * As the queue opens this rises and fades, while the card's own title rises from
 * below and fades in to catch it — a directional cross-fade rather than one
 * label dissolving into another. It also collapses out of the layout as it goes,
 * or the chrome below would hold a gap where an invisible row used to be.
 *
 * The numbers are iOS's: lift 360dp ending at q=0.9, fade across q 0.2 → 0.68.
 */
@Composable
private fun HeroTitles(
    state: PlaybackState,
    queueProgress: () -> Float,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .layout { measurable, constraints ->
                val placeable = measurable.measure(constraints)
                val gone = fadeProgress(queueProgress())
                val height = (placeable.height * (1f - gone)).roundToInt()
                layout(placeable.width, height) { placeable.place(0, 0) }
            }
            .graphicsLayer {
                val q = queueProgress()
                translationY = -HERO_ROW_LIFT.toPx() * (q / HERO_LIFT_END).coerceIn(0f, 1f)
                alpha = 1f - fadeProgress(q)
            },
    ) {
        TrackTitles(state, likeGlyph, liked, onToggleLike)
    }
}

/** How far through its fade the hero row is, at queue progress [q]. */
private fun fadeProgress(q: Float): Float =
    ((q - HERO_FADE_START) / (HERO_FADE_END - HERO_FADE_START)).coerceIn(0f, 1f)

private val HERO_ROW_LIFT = 360.dp
private const val HERO_LIFT_END = 0.9f
private const val HERO_FADE_START = 0.2f
private const val HERO_FADE_END = 0.68f

/** Where the card's own row comes in, once the hero row has mostly cleared. */
private const val CARD_FADE_START = 0.7f
private val CARD_ROW_RISE = 80.dp

@Composable
private fun Panel(
    panel: PlayerPanel,
    state: PlaybackState,
    server: MozzServer,
    playback: PlayerController,
    library: MozzLibrary,
    showsNowPlayingCard: Boolean,
    bottomInset: Dp,
    onCardArtSlot: (Rect) -> Unit,
    queueProgress: () -> Float,
    panelSettled: () -> Boolean,
    onShowArtwork: () -> Unit,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
    onInteraction: () -> Unit,
) {
    when (panel) {
        PlayerPanel.QUEUE -> QueuePane(
            state = state,
            server = server,
            playback = playback,
            showsNowPlayingCard = showsNowPlayingCard,
            bottomInset = bottomInset,
            onCardArtSlot = onCardArtSlot,
            queueProgress = queueProgress,
            panelSettled = panelSettled,
            onShowArtwork = onShowArtwork,
            likeGlyph = likeGlyph,
            liked = liked,
            onToggleLike = onToggleLike,
        )
        PlayerPanel.LYRICS -> LyricsPane(state, library, bottomInset, onInteraction)
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
    bottomInset: Dp,
    onCardArtSlot: (Rect) -> Unit,
    queueProgress: () -> Float,
    panelSettled: () -> Boolean,
    onShowArtwork: () -> Unit,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
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

    // Open with the card at the top and the history just above it — where you
    // came from is part of the queue, it just is not what you opened it for. This
    // is the resting position iOS reaches with a snap detent, arrived at by
    // scrolling to the card instead.
    val cardIndex = if (history.isEmpty()) 0 else history.size + 1
    LaunchedEffect(Unit) {
        if (cardIndex > 0) listState.scrollToItem(cardIndex)
    }
    LaunchedEffect(current) {
        if (cardIndex > 0) listState.animateScrollToItem(cardIndex)
    }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().fadeOutBottom(),
        contentPadding = PaddingValues(top = 8.dp, bottom = 8.dp + bottomInset),
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

        // In the list, between what has played and what is next — where it
        // belongs, and where iOS keeps it. Scrolled to the top when the queue
        // opens, so the cover has a settled slot to fly into.
        if (showsNowPlayingCard) {
            state.track?.let { track ->
                item(key = "now-playing") {
                    NowPlayingCard(
                        track = track,
                        isPlaying = state.intendsToPlay,
                        server = server,
                        onArtSlot = onCardArtSlot,
                        queueProgress = queueProgress,
                        panelSettled = panelSettled,
                        onTapArtwork = onShowArtwork,
                        likeGlyph = likeGlyph,
                        liked = liked,
                        onToggleLike = onToggleLike,
                        modifier = Modifier.animateItem(),
                    )
                }
            }
            item(key = "queue-controls") {
                QueueControls(state, playback, Modifier.animateItem())
            }
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

/**
 * Dissolve the last of a scrolling panel into the backdrop.
 *
 * The controls at the bottom of the player sit over this, and a row of song
 * titles running underneath them reads as a collision. Fading the content out
 * before it gets there gives the controls somewhere to be without a scrim or a
 * hard edge — the artwork wash simply shows through, which is what iOS does.
 */
private fun Modifier.fadeOutBottom(height: Dp = PANEL_FADE_HEIGHT): Modifier = this
    // Required for DstIn: without an offscreen layer the blend has nothing but
    // the backdrop to erase from, and takes a bite out of that instead.
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        val fade = height.toPx()
        drawRect(
            brush = Brush.verticalGradient(
                0f to Color.Black,
                1f to Color.Transparent,
                startY = size.height - fade,
                endY = size.height,
            ),
            blendMode = BlendMode.DstIn,
        )
    }

/** Enough to clear the controls beneath, plus room for the fade to read. */
private val PANEL_FADE_HEIGHT = 96.dp

/**
 * Widest a single column of player content gets before it simply centres.
 *
 * Stretched across a tablet, one column of artwork and transport reads as a
 * phone layout that has been pulled apart rather than a layout for this screen.
 */
private val SINGLE_COLUMN_MAX = 560.dp

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
            label = "Shuffle",
            description = if (state.shuffle) "Shuffle on" else "Shuffle off",
            selected = state.shuffle,
            onClick = playback::toggleShuffle,
            modifier = Modifier.weight(1f),
        )
        QueuePill(
            icon = if (state.repeat == RepeatMode.ONE) R.drawable.ic_repeat_one
            else R.drawable.ic_repeat,
            label = "Repeat",
            description = when (state.repeat) {
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
    description: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val wash by animateFloatAsState(
        targetValue = if (selected) 0.22f else 0.08f,
        animationSpec = tween(PANEL_SWAP_MS),
        label = "queue-pill",
    )
    Row(
        modifier = modifier
            .height(44.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(PlayerForeground.copy(alpha = wash))
            .border(
                width = 1.dp,
                color = PlayerForeground.copy(alpha = if (selected) 0.28f else 0.12f),
                shape = RoundedCornerShape(percent = 50),
            )
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = description,
            tint = if (selected) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) PlayerForeground else PlayerForegroundMuted,
        )
    }
}

/**
 * The current track, at the top of the queue.
 *
 * Shown only when the panel has taken the artwork's place — beside the artwork it
 * would be the same track twice. Its thumbnail slot is where the travelling cover
 * lands, so the two are the same size in the same place and the hand-off is
 * invisible.
 *
 * Its title and star are the arriving half of a directional cross-fade: they rise
 * from below and fade in as the hero row above lifts away, so the titles appear
 * to be caught rather than swapped.
 */
@Composable
private fun NowPlayingCard(
    track: Track,
    isPlaying: Boolean,
    server: MozzServer,
    onArtSlot: (Rect) -> Unit,
    queueProgress: () -> Float,
    panelSettled: () -> Boolean,
    onTapArtwork: () -> Unit,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
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
            .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(CARD_ART_SIDE)
                .reportBounds(onArtSlot)
                // Tapping the cover puts the record back, which is the shortest
                // way out of the queue and what iOS does. Only once it has
                // settled: mid-flight the cover is not really here yet.
                .clickable(enabled = panelSettled(), onClick = onTapArtwork),
        ) {
            // The card's own cover, which appears only once the travelling one
            // has arrived on this exact slot — so it can then scroll and clip
            // with the panel instead of floating above it.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        alpha = if (panelSettled()) 1f else 0f
                        scaleX = breathe
                        scaleY = breathe
                    }
                    .clip(RoundedCornerShape(11.dp)),
            ) {
                Artwork(
                    server = server,
                    serverId = track.serverId,
                    artworkKey = track.artworkKey,
                    size = 256,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .graphicsLayer {
                    val arrived = cardArrival(queueProgress())
                    translationY = CARD_ROW_RISE.toPx() * (1f - arrived)
                    alpha = arrived
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                MarqueeLine(
                    text = track.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = PlayerForeground,
                    weight = FontWeight.SemiBold,
                )
                Text(
                    track.artistName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PlayerForegroundMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(8.dp))
            StarAndOverflow(likeGlyph, liked, onToggleLike)
        }
    }
}

/** How far into its arrival the card's row is, at queue progress [q]. */
private fun cardArrival(q: Float): Float =
    ((q - CARD_FADE_START) / (1f - CARD_FADE_START)).coerceIn(0f, 1f)

/** iOS's queue thumbnail, which the travelling cover docks into. */
private val CARD_ART_SIDE = 72.dp

/** The card's cover shrinks when paused, like the big one does. */
private const val PAUSED_CARD_SHRINK = 0.06f

/**
 * The track's star and its overflow menu, shown in both places a track heads a
 * screen: the hero title row, and the queue card it collapses into.
 *
 * The star reports the state the server already has — on Plex a "like" is a
 * 5-star rating, which is what fills Liked Songs. Neither control acts yet: the
 * star needs a session command the core does not expose, and the menu needs
 * artist and album destinations that Android has no routes for. A star that lied
 * about whether it took would be worse than one that only reports.
 */
@Composable
private fun StarAndOverflow(likeGlyph: LikeGlyph, liked: Boolean, onToggleLike: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        // A heart where the server has favourites, a star where it has ratings —
        // Jellyfin and Plex genuinely mean different things by "liked", and the
        // glyph should say which one you are setting.
        val glyph = when (likeGlyph) {
            LikeGlyph.HEART -> if (liked) R.drawable.ic_heart_filled else R.drawable.ic_heart
            LikeGlyph.STAR -> if (liked) R.drawable.ic_star_filled else R.drawable.ic_star
        }
        Box(
            modifier = Modifier
                .size(MIN_HIT)
                .clip(RoundedCornerShape(percent = 50))
                .clickable(onClick = onToggleLike),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painterResource(glyph),
                contentDescription = if (liked) "Liked" else "Not liked",
                tint = if (liked) PlayerForeground else PlayerForegroundMuted,
                modifier = Modifier.size(24.dp),
            )
        }
        IconButton(onClick = {}, enabled = false) {
            Icon(
                painterResource(R.drawable.ic_more),
                contentDescription = "More (not yet available)",
                tint = PlayerForegroundMuted.copy(alpha = 0.5f),
                modifier = Modifier.size(22.dp),
            )
        }
    }
}


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
    bottomInset: Dp,
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
                contentPadding = PaddingValues(
                    top = 32.dp,
                    bottom = 32.dp + bottomInset,
                    start = 8.dp,
                    end = 8.dp,
                ),
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
private fun TrackTitles(
    state: PlaybackState,
    likeGlyph: LikeGlyph,
    liked: Boolean,
    onToggleLike: () -> Unit,
) {
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
        StarAndOverflow(likeGlyph, liked, onToggleLike)
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
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                clock((fraction * state.durationMillis).toLong()),
                style = MaterialTheme.typography.labelMedium,
                color = PlayerForegroundMuted,
            )
            // What the server is actually sending. Quiet, because it only
            // matters to the people it matters to — and absent entirely when the
            // server did not say, rather than guessed at.
            state.track?.format?.let { format ->
                Text(
                    format,
                    style = MaterialTheme.typography.labelSmall,
                    color = PlayerForegroundMuted,
                    modifier = Modifier
                        .clip(RoundedCornerShape(percent = 50))
                        .background(PlayerForeground.copy(alpha = 0.10f))
                        .padding(horizontal = 8.dp, vertical = 2.dp),
                )
            }
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
private fun Transport(
    state: PlaybackState,
    playback: PlayerController,
    /** Queue open: shuffle and repeat are pills up there, so drop them here. */
    compact: Boolean,
) {
    val active = PlayerForeground
    val idle = PlayerForegroundMuted

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (!compact) {
            TransportButton(
                icon = R.drawable.ic_shuffle,
                label = if (state.shuffle) "Shuffle on" else "Shuffle off",
                // On/off is carried by contrast, not by the accent: the accent
                // means "the action", and a shuffle toggle is not that.
                tint = if (state.shuffle) active else idle,
                glyph = UTILITY_GLYPH,
                hit = MIN_HIT,
                onClick = playback::toggleShuffle,
            )
        }

        TransportButton(
            icon = R.drawable.ic_skip_back,
            label = "Previous",
            tint = active,
            glyph = SKIP_GLYPH,
            hit = SKIP_HIT,
            onClick = { playback.previous() },
        )

        PlayButton(isPlaying = state.isPlaying, onClick = playback::togglePlayPause)

        TransportButton(
            icon = R.drawable.ic_skip_forward,
            label = "Next",
            tint = if (state.hasNext) active else idle,
            glyph = SKIP_GLYPH,
            hit = SKIP_HIT,
            enabled = state.hasNext,
            onClick = { playback.next() },
        )

        if (!compact) {
            TransportButton(
                icon = if (state.repeat == RepeatMode.ONE) R.drawable.ic_repeat_one
                else R.drawable.ic_repeat,
                label = when (state.repeat) {
                    RepeatMode.OFF -> "Repeat off"
                    RepeatMode.ALL -> "Repeat all"
                    RepeatMode.ONE -> "Repeat one"
                },
                tint = if (state.repeat == RepeatMode.OFF) idle else active,
                glyph = UTILITY_GLYPH,
                hit = MIN_HIT,
                onClick = playback::cycleRepeat,
            )
        }
    }
}

/**
 * A transport control: a glyph centred in a square that is bigger than it.
 *
 * The two sizes are separate on purpose. The visible icon is whatever reads
 * right next to its neighbours; the tappable square is whatever a thumb needs.
 * Tying them together is how skip buttons end up being missed.
 */
@Composable
private fun TransportButton(
    icon: Int,
    label: String,
    tint: Color,
    glyph: Dp,
    hit: Dp,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(hit)
            .clip(RoundedCornerShape(percent = 50))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = label,
            tint = tint,
            modifier = Modifier.size(glyph),
        )
    }
}

/**
 * Play and pause, as one glyph swapping for the other.
 *
 * No filled disc: iOS draws this as a plain glyph the same colour as its
 * neighbours, and the accent is spent elsewhere. The outgoing icon shrinks away
 * while the incoming one grows past its mark and settles, which is what sells a
 * toggle as a physical switch rather than a picture changing.
 */
@Composable
private fun PlayButton(isPlaying: Boolean, onClick: () -> Unit) {
    val swap = spring<Float>(dampingRatio = 0.62f, stiffness = 246f)
    val playAlpha by animateFloatAsState(if (isPlaying) 0f else 1f, swap, label = "play-glyph")
    val playScale by animateFloatAsState(if (isPlaying) 0.62f else 1f, swap, label = "play-scale")
    val pauseAlpha by animateFloatAsState(if (isPlaying) 1f else 0f, swap, label = "pause-glyph")
    val pauseScale by animateFloatAsState(if (isPlaying) 1f else 0.62f, swap, label = "pause-scale")

    Box(
        modifier = Modifier
            .size(PLAY_HIT)
            .clip(RoundedCornerShape(percent = 50))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(R.drawable.ic_play),
            contentDescription = null,
            tint = PlayerForeground,
            modifier = Modifier
                .size(PLAY_GLYPH)
                .graphicsLayer { alpha = playAlpha; scaleX = playScale; scaleY = playScale },
        )
        Icon(
            painterResource(R.drawable.ic_pause),
            contentDescription = if (isPlaying) "Pause" else "Play",
            tint = PlayerForeground,
            modifier = Modifier
                .size(PLAY_GLYPH)
                .graphicsLayer { alpha = pauseAlpha; scaleX = pauseScale; scaleY = pauseScale },
        )
    }
}

// iOS's control metrics, so a thumb that has learned one app has learned both.
// Glyph sizes and hit targets are kept separate: the icon is sized to read, the
// square around it is sized to be hit.
private val UTILITY_GLYPH = 26.dp
private val SKIP_GLYPH = 40.dp
private val PLAY_GLYPH = 60.dp
private val MIN_HIT = 48.dp
private val SKIP_HIT = 60.dp
private val PLAY_HIT = 76.dp

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
