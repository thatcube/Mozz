package com.thatcube.mozz.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.thatcube.mozz.R
import kotlin.math.roundToInt
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Everything about the rating control's feel, in one place so it is cheap to
 * change on device. Values are iOS's, from `RatingTuning`.
 */
object RatingTuning {
    const val STAR_COUNT = 5
    val stripStarSize: Dp = 30.dp
    val stripStarSpacing: Dp = 10.dp

    /**
     * How long a finger must rest on the star before the strip appears and
     * drag-to-rate begins. Short enough to feel immediate, long enough that a
     * quick tap still opens the sticky bubble instead.
     */
    const val HOLD_MS = 180L

    /** How far above the star the strip sits, so a finger does not cover it. */
    val revealYOffset: Dp = (-78).dp
    val bubbleCorner: Dp = 24.dp
}

/**
 * Map a horizontal position, measured from the first star's leading edge, to a
 * snapped rating.
 *
 * The left half of star `i` gives `i - 0.5` and the right half gives `i`, so the
 * whole strip is reachable in half steps. A position left of the first star means
 * "clear" rather than "half a star" — dragging off the end is how you take a
 * rating away, and it has to be reachable without lifting.
 *
 * Ported from `RatingMath` in the iOS app; the two must agree, or the same drag
 * would set different ratings on the two clients.
 */
fun ratingAtX(x: Float, starSize: Float, spacing: Float): Double? {
    if (x < 0f) return null
    val pitch = starSize + spacing
    val index = (x / pitch).toInt()
    if (index >= RatingTuning.STAR_COUNT) return 5.0
    val within = x - index * pitch
    val value = if (within < starSize / 2f) index + 0.5 else index + 1.0
    return minOf(value, 5.0)
}

/** Trailing zeroes are noise on a star count: 4.0 reads as "4", 4.5 as "4.5". */
fun formatRating(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

/** "1 star", but "1.5 stars" — the only singular is exactly one. */
fun ratingLabel(value: Double): String =
    if (value == 1.0) "1 star" else formatRating(value) + " stars"

/**
 * A row of five stars showing [value], half steps included.
 *
 * The half-filled glyph is a real icon rather than a clipped full one, so it
 * matches the stroke weight of the outline beside it.
 */
@Composable
fun RatingStrip(
    value: Double?,
    starSize: Dp = RatingTuning.stripStarSize,
    spacing: Dp = RatingTuning.stripStarSpacing,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(spacing),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(RatingTuning.STAR_COUNT) { index ->
            val filled = (value ?: 0.0) - index
            val glyph = when {
                filled >= 1.0 -> R.drawable.ic_star_filled
                filled >= 0.5 -> R.drawable.ic_star_half
                else -> R.drawable.ic_star
            }
            Icon(
                painterResource(glyph),
                contentDescription = null,
                tint = if (filled >= 0.5) PlayerForeground else PlayerForegroundMuted,
                modifier = Modifier.size(starSize),
            )
        }
    }
}

/**
 * The player's rating control: one star that expands into five.
 *
 * Two gestures share it, resolved on touch-up, which is what iOS does and why it
 * is a raw pointer loop rather than a button plus a drag (the two would fight
 * over the hold):
 *
 *  * a **quick tap** opens a sticky bubble you can aim at;
 *  * a **press and hold** reveals the strip above your finger and rates as you
 *    drag, committing when you let go — with a tick at every half step, so the
 *    drag feels detented rather than continuous.
 *
 * Dragging left of the first star clears the rating, so removing one never
 * requires a second interaction.
 */
@Composable
fun FluidRatingControl(
    rating: Double?,
    onSet: (Double?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    val starPx = with(density) { RatingTuning.stripStarSize.toPx() }
    val spacingPx = with(density) { RatingTuning.stripStarSpacing.toPx() }
    val stripWidth = RatingTuning.stripStarSize * RatingTuning.STAR_COUNT +
        RatingTuning.stripStarSpacing * (RatingTuning.STAR_COUNT - 1)
    val stripWidthPx = with(density) { stripWidth.toPx() }

    var dragging by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<Double?>(null) }
    var pickerOpen by remember { mutableStateOf(false) }
    var pressed by remember { mutableStateOf(false) }

    val press by animateFloatAsState(
        targetValue = if (pressed) 0.9f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = 900f),
        label = "rating-press",
    )

    Box(
        modifier = modifier
            .size(MIN_HIT)
            .pointerInput(rating) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    pressed = true
                    // A hold engages drag-to-rate; a release before it is a tap.
                    val lifted = withTimeoutOrNull(RatingTuning.HOLD_MS) {
                        waitForUpOrCancellation()
                    }
                    if (lifted != null) {
                        pressed = false
                        if (lifted.pressed.not()) pickerOpen = true
                        return@awaitEachGesture
                    }

                    dragging = true
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)

                    // The strip is centred on the star and so is this control, so
                    // the star's position on screen cancels: a finger at the
                    // control's own centre is at the strip's centre. That leaves
                    // the mapping as pure local arithmetic, which is one fewer
                    // measured value to get wrong.
                    fun ratingFor(localX: Float): Double? =
                        ratingAtX(localX - size.width / 2f + stripWidthPx / 2f, starPx, spacingPx)

                    var last = ratingFor(down.position.x)
                    preview = last

                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull() ?: break
                        val next = ratingFor(change.position.x)
                        if (next != last) {
                            last = next
                            preview = next
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        }
                        change.consume()
                        if (!change.pressed) break
                    }

                    onSet(last)
                    dragging = false
                    pressed = false
                    preview = null
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        CollapsedStar(rating = rating, scale = press)

        // Declared inside the star, so the popup anchors on the star rather than
        // on whatever happens to contain the control. A popup also sits above the
        // travelling artwork, which would otherwise cover a strip drawn inside
        // the player's own hierarchy.
        if (dragging) {
            RatingBubble {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                RatingStrip(preview)
                Spacer(Modifier.height(8.dp))
                    Text(
                        preview?.let(::ratingLabel) ?: "No rating",
                        style = MaterialTheme.typography.labelSmall,
                        color = PlayerForegroundMuted,
                    )
                }
            }
        }

        if (pickerOpen) {
            RatingBubble(onDismiss = { pickerOpen = false }) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(RatingTuning.stripStarSpacing),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    repeat(RatingTuning.STAR_COUNT) { index ->
                        val filled = (rating ?: 0.0) - index
                        Icon(
                            painterResource(
                                when {
                                    filled >= 1.0 -> R.drawable.ic_star_filled
                                    filled >= 0.5 -> R.drawable.ic_star_half
                                    else -> R.drawable.ic_star
                                }
                            ),
                            contentDescription = "${index + 1} stars",
                            tint = if (filled >= 0.5) PlayerForeground else PlayerForegroundMuted,
                            modifier = Modifier
                                .size(RatingTuning.stripStarSize)
                                .clickable {
                                    onSet((index + 1).toDouble())
                                    pickerOpen = false
                                },
                        )
                    }
                }
                if (rating != null) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Clear",
                        style = MaterialTheme.typography.labelLarge,
                        color = PlayerForegroundMuted,
                        modifier = Modifier
                            .clip(RoundedCornerShape(percent = 50))
                            .clickable {
                                onSet(null)
                                pickerOpen = false
                            }
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    }
                }
            }
        }
    }
}

/**
 * The resting control: a star, plus the number when there is one to show.
 *
 * The number is why this is not simply an icon — at a glance "4.5" is the whole
 * point of a rating, and a half-filled star alone does not say it.
 */
@Composable
private fun CollapsedStar(rating: Double?, scale: Float) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        val glyph = when {
            rating == null -> R.drawable.ic_star
            rating >= 1.0 -> R.drawable.ic_star_filled
            else -> R.drawable.ic_star_half
        }
        Icon(
            painterResource(glyph),
            contentDescription = rating?.let { "Rated ${formatRating(it)} stars" } ?: "Not rated",
            tint = if (rating != null) PlayerForeground else PlayerForegroundMuted,
            modifier = Modifier.size(24.dp * scale),
        )
        if (rating != null) {
            Text(
                formatRating(rating),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = PlayerForeground,
            )
        }
    }
}

/**
 * A bubble sitting above the star. Solid rather than glass — that is iOS-only.
 *
 * Positioned by a provider rather than an offset, because `Popup`'s `offset` is
 * measured from the anchor, not from the window. Feeding it absolute coordinates
 * put the bubble in the corner of the screen with most of it cut off. A provider
 * is handed the anchor's bounds and the window's size, so it can do the two
 * things that actually matter: centre on the star, and stay on screen.
 */
@Composable
private fun RatingBubble(
    onDismiss: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val gap = with(density) { -RatingTuning.revealYOffset.roundToPx() }
    val margin = with(density) { 12.dp.roundToPx() }

    val position = remember(gap, margin) {
        object : PopupPositionProvider {
            override fun calculatePosition(
                anchorBounds: IntRect,
                windowSize: IntSize,
                layoutDirection: LayoutDirection,
                popupContentSize: IntSize,
            ): IntOffset {
                val x = anchorBounds.center.x - popupContentSize.width / 2
                val above = anchorBounds.top - popupContentSize.height - gap
                // Below the star when there is no room above it, which is the
                // case whenever the control sits near the top of the window.
                val y = if (above >= margin) above else anchorBounds.bottom + gap
                return IntOffset(
                    x.coerceIn(margin, maxOf(margin, windowSize.width - popupContentSize.width - margin)),
                    y.coerceIn(margin, maxOf(margin, windowSize.height - popupContentSize.height - margin)),
                )
            }
        }
    }

    Popup(
        popupPositionProvider = position,
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = onDismiss != null),
    ) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(RatingTuning.bubbleCorner))
                .background(RatingBubbleBackground)
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            content()
        }
    }
}

/** Dark enough to read white stars on, over any artwork backdrop. */
private val RatingBubbleBackground = androidx.compose.ui.graphics.Color(0xE6161616)
