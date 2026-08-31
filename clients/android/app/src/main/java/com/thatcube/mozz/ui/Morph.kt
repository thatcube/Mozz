package com.thatcube.mozz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.playback.PlaybackState
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.playback.RepeatMode
import kotlin.math.roundToInt

/**
 * The dock and the player, which are one object.
 *
 * Nothing here fades a small thing out and a big thing in. There is a single
 * surface that grows, a single cover that travels, and two sets of controls that
 * hand off — which is the whole difference between a screen appearing and an
 * object opening.
 *
 * The geometry lives in [Morph]; this file is only the wiring. Everything that
 * moves every frame is positioned in the layout or draw phase (see [morphFrame]
 * and the `graphicsLayer` alphas) rather than by recomposition, so opening the
 * player over a loaded queue does not stutter.
 */
@Composable
internal fun MorphHost(
    state: PlaybackState,
    server: MozzServer,
    library: MozzLibrary,
    playback: PlayerController,
    progress: () -> Float,
    morphAt: (Float, Rect?, Rect?) -> Morph,
    queueProgress: () -> Float,
    presentation: PlayerPresentation,
    panel: PlayerPanel?,
    onPanel: (PlayerPanel?) -> Unit,
    wide: Boolean,
    /** Target state, not progress: a boolean that flips twice per open, so the
     *  touch gating below costs two recompositions rather than one per frame. */
    expanded: Boolean,
    /** Whether the player's body should exist at all — see the shell. */
    mounted: Boolean,
    /** Whether the pill's own controls should exist — see the shell. */
    dockMounted: Boolean,
    onOpen: () -> Unit,
    onCollapse: () -> Unit,
    onDismissDrag: (Float) -> Unit,
    onDismissEnd: (Float) -> Unit,
) {
    val track = state.track ?: return

    // Where the expanded player put its cover. Null until it has been laid out,
    // which is what the fallback in `Morph` is for.
    var artSlot by remember { mutableStateOf<Rect?>(null) }
    // The queue card's thumbnail slot, which the cover docks into once the panel
    // has taken the artwork's place.
    var cardSlot by remember { mutableStateOf<Rect?>(null) }

    // Read once per frame in the layout/draw lambdas below, never in composition.
    val frame = { morphAt(progress(), artSlot, cardSlot) }

    /**
     * True once the cover has arrived in the card's slot, at which point the
     * card's own artwork takes over so it can scroll and clip with the list. The
     * swap happens at a coincident position, so it reads as nothing at all.
     *
     * Gated on the player actually being open. The panel is a remembered choice,
     * not a thing that closes when the player does, so without this a collapsed
     * dock whose queue happened to be open hid its own cover — handing off to a
     * card that was nowhere on screen.
     */
    val panelSettled = { expanded && queueProgress() > 0.995f }

    Box(modifier = Modifier.fillMaxSize()) {
        // The surface. One rounded rectangle that is a pill at rest and the whole
        // screen when open.
        Box(
            modifier = Modifier
                .morphFrame { frame().let { Rect(it.surfaceLeft, it.surfaceTop, it.surfaceLeft + it.surfaceWidth, it.surfaceTop + it.surfaceHeight) } }
                .graphicsLayer {
                    val m = frame()
                    shape = RoundedCornerShape(m.surfaceRadius)
                    clip = true
                }
                .background(MaterialTheme.colorScheme.surfaceVariant)
                // Collapsed, the whole pill is the tap target. Expanded the
                // modifier is removed outright rather than disabled: a disabled
                // `clickable` is still a pointer region, and this one grows to
                // fill the screen as the player opens.
                .then(
                    if (expanded) Modifier else Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpen,
                    )
                ),
        ) {
            // The artwork wash, which has to arrive before the body that sits on
            // it. Held across track changes by PlayerBackground itself.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = frame().backdropAlpha },
            ) {
                PlayerBackground(
                    server = server,
                    library = library,
                    serverId = track.serverId,
                    artworkKey = track.artworkKey,
                )
            }
        }

        // The player's body: everything except the cover, which travels. Full
        // size while it exists — only its opacity moves — so the queue and the
        // lyrics are laid out once rather than re-measured every frame.
        //
        // Not composed at all when the player is away. It is full-screen, so
        // leaving it mounted put an invisible sheet over the entire app.
        if (mounted) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = frame().bodyAlpha }
                // During the collapse it is still on screen but no longer the
                // thing being used, so it stops taking touches a beat early.
                .then(if (expanded) Modifier else Modifier.blockTouches()),
        ) {
            PlayerBody(
                state = state,
                server = server,
                library = library,
                playback = playback,
                presentation = presentation,
                panel = panel,
                onPanel = onPanel,
                wide = wide,
                onCollapse = onCollapse,
                onArtSlot = { artSlot = it },
                onCardArtSlot = { cardSlot = it },
                queueProgress = queueProgress,
                panelSettled = panelSettled,
                onDismissDrag = onDismissDrag,
                onDismissEnd = onDismissEnd,
            )
        }
        }

        // The travelling cover. One image, moved — not a small one dissolving
        // into a big one. This is most of what makes the morph read as a physical
        // object, so it is drawn above both the surface and the body, and the
        // body leaves a hole for it to land in.
        //
        // It fades where it stands when a panel takes its place, which is the
        // only honest reading of "the queue replaces the artwork": the cover does
        // not slide away or shrink, the panel arrives over it.
        // Apple Music's paused shrink, on iOS's numbers: the cover sits 25%
        // smaller at rest and grows as the music starts. Scaled by `p` so only
        // the expanded cover does it — the pill's 48dp thumbnail must not
        // breathe. Driven by intent rather than `isPlaying`, or it shrinks for a
        // moment on every track change while the next one buffers.
        val pausedShrink by animateFloatAsState(
            targetValue = if (state.intendsToPlay) 0f else PAUSED_ART_SHRINK,
            animationSpec = spring(dampingRatio = 0.72f, stiffness = 224f),
            label = "paused-shrink",
        )
        // Only once it has arrived, and never behind a panel: a shadow that
        // animates its blur re-rasterises every frame, which is a hitch exactly
        // where the morph can least afford one.
        val shadow by animateFloatAsState(
            targetValue = if (expanded && presentation != PlayerPresentation.PANEL_INSTEAD) 1f else 0f,
            animationSpec = tween(300),
            label = "cover-shadow",
        )
        val coverAlpha by animateFloatAsState(
            targetValue = if (presentation == PlayerPresentation.PANEL_INSTEAD) 0f else 1f,
            animationSpec = tween(PANEL_SWAP_MS),
            label = "cover-visible",
        )
        Box(
            modifier = Modifier
                .morphFrame {
                    val m = frame()
                    val half = m.artSide / 2
                    Rect(
                        m.artCenterX - half,
                        m.artCenterY - half,
                        m.artCenterX + half,
                        m.artCenterY + half,
                    )
                }
                .graphicsLayer {
                    val m = frame()
                    val scale = 1f - pausedShrink * m.p
                    scaleX = scale
                    scaleY = scale
                    shape = RoundedCornerShape(m.artRadius)
                    clip = true
                    alpha = if (panelSettled()) 0f else 1f
                    shadowElevation = COVER_SHADOW.toPx() * shadow * m.p
                    ambientShadowColor = Color.Black
                    spotShadowColor = Color.Black
                },
        ) {
            Artwork(
                server = server,
                serverId = track.serverId,
                artworkKey = track.artworkKey,
                size = 1024,
                modifier = Modifier.fillMaxSize(),
            )
        }

        // The pill's own controls, gone well before the body arrives — and not
        // composed at all once the player is open. The pill's rectangle stays at
        // the bottom of the screen whatever the morph is doing, so leaving these
        // mounted put an invisible strip of dock controls across whatever the
        // open player had placed there.
        if (dockMounted) {
            Box(
                modifier = Modifier
                    .morphFrame {
                        val m = frame()
                        Rect(m.dockLeft, m.dockTop, m.dockLeft + m.dockWidth, m.dockBottom)
                    }
                    .graphicsLayer { alpha = frame().dockContentAlpha },
            ) {
                DockContent(state = state, playback = playback, wide = wide, onOpen = onOpen)
            }
        }
    }
}

/**
 * What the pill says while it is a pill.
 *
 * The cover is not here — it belongs to the morph, which is drawing it on top of
 * this row. The leading space is left empty for it to occupy.
 */
@Composable
private fun DockContent(
    state: PlaybackState,
    playback: PlayerController,
    /** A wide dock has room for the controls a phone-width one cannot fit. */
    wide: Boolean,
    onOpen: () -> Unit,
) {
    val track = state.track ?: return

    Row(
        modifier = Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onOpen,
            )
            .padding(end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The cover's berth.
        Spacer(Modifier.width(Dock.artLeading + Dock.artSide + 12.dp))

        Column(modifier = Modifier.weight(1f)) {
            MarqueeLine(
                text = track.title,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                weight = FontWeight.Medium,
            )
            Text(
                track.artistName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Shuffle and repeat only where there is room. On a phone-width pill,
        // artwork plus a title plus five controls is a row of things too small to
        // hit; on a tablet the space is there and reaching the player to shuffle
        // is a trip you should not have to make.
        if (wide) {
            IconButton(onClick = playback::toggleShuffle) {
                Icon(
                    painterResource(R.drawable.ic_shuffle),
                    contentDescription = if (state.shuffle) "Shuffle on" else "Shuffle off",
                    tint = if (state.shuffle) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        IconButton(onClick = playback::togglePlayPause) {
            Icon(
                painterResource(if (state.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                contentDescription = if (state.isPlaying) "Pause" else "Play",
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(22.dp),
            )
        }
        IconButton(onClick = { playback.next() }, enabled = state.hasNext) {
            Icon(
                painterResource(R.drawable.ic_skip_forward),
                contentDescription = "Next",
                tint = if (state.hasNext) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp),
            )
        }

        if (wide) {
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
                    tint = if (state.repeat == RepeatMode.OFF)
                        MaterialTheme.colorScheme.onSurfaceVariant
                    else MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/**
 * Place a child at an absolute rectangle, re-read every layout pass.
 *
 * The lambda is deliberately not a parameter captured at composition: reading the
 * morph's progress *inside* it means a frame of the animation costs a layout
 * pass, not a recomposition of everything underneath.
 */
private fun Modifier.morphFrame(rect: () -> Rect): Modifier = this.layout { measurable, constraints ->
    val r = rect()
    val w = r.width.roundToInt().coerceAtLeast(0)
    val h = r.height.roundToInt().coerceAtLeast(0)
    val placeable = measurable.measure(Constraints.fixed(w, h))
    layout(constraints.maxWidth, constraints.maxHeight) {
        placeable.place(r.left.roundToInt(), r.top.roundToInt())
    }
}

/**
 * Lay out and draw, but never receive a touch.
 *
 * Consumed in the initial pass so nothing underneath sees the event either — a
 * fully transparent player still occupies the screen, and its controls must not
 * intercept taps meant for the library behind it.
 */
private fun Modifier.blockTouches(): Modifier = this.pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        }
    }
}

/**
 * Report where this composable ended up, in the shell's coordinates.
 *
 * Used for the artwork slot: the player lays its cover out naturally, says where
 * it landed, and the travelling cover flies there — rather than two files
 * agreeing forever on a constant.
 */
internal fun Modifier.reportBounds(onBounds: (Rect) -> Unit): Modifier =
    this.onGloballyPositioned { onBounds(it.boundsInRoot()) }

/** iOS's panel crossfade, to the millisecond. Shared with the player's own swap. */
private const val PANEL_SWAP_MS = 180

/** How much smaller the expanded cover sits when paused. iOS's value. */
private const val PAUSED_ART_SHRINK = 0.25f

/** Lift under the settled cover, so it reads as sitting on the backdrop. */
private val COVER_SHADOW = 16.dp
