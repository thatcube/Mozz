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
    morphAt: (Float, Rect?) -> Morph,
    presentation: PlayerPresentation,
    panel: PlayerPanel?,
    onPanel: (PlayerPanel?) -> Unit,
    wide: Boolean,
    /** Target state, not progress: a boolean that flips twice per open, so the
     *  touch gating below costs two recompositions rather than one per frame. */
    expanded: Boolean,
    onOpen: () -> Unit,
    onCollapse: () -> Unit,
) {
    val track = state.track ?: return

    // Where the expanded player put its cover. Null until it has been laid out,
    // which is what the fallback in `Morph` is for.
    var artSlot by remember { mutableStateOf<Rect?>(null) }

    // Read once per frame in the layout/draw lambdas below, never in composition.
    val frame = { morphAt(progress(), artSlot) }

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
                // Collapsed, the whole pill is the tap target. Expanded, it must
                // not be — the body has its own controls and a stray tap on the
                // background should do nothing.
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    enabled = !expanded,
                    onClick = onOpen,
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
        // size always — only its opacity moves — so the queue and the lyrics are
        // laid out once rather than re-measured every frame of the morph.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = frame().bodyAlpha }
                // Untouchable until it is actually there, or an invisible
                // transport swallows taps meant for the library behind it.
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
            )
        }

        // The travelling cover. One image, moved — not a small one dissolving
        // into a big one. This is most of what makes the morph read as a physical
        // object, so it is drawn above both the surface and the body, and the
        // body leaves a hole for it to land in.
        //
        // It fades where it stands when a panel takes its place, which is the
        // only honest reading of "the queue replaces the artwork": the cover does
        // not slide away or shrink, the panel arrives over it.
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
                    shape = RoundedCornerShape(frame().artRadius)
                    clip = true
                    alpha = coverAlpha
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

        // The pill's own controls, gone well before the body arrives.
        Box(
            modifier = Modifier
                .morphFrame {
                    val m = frame()
                    Rect(m.dockLeft, m.dockTop, m.dockLeft + m.dockWidth, m.dockBottom)
                }
                .graphicsLayer { alpha = frame().dockContentAlpha }
                .then(if (expanded) Modifier.blockTouches() else Modifier),
        ) {
            DockContent(state = state, playback = playback, onOpen = onOpen)
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
