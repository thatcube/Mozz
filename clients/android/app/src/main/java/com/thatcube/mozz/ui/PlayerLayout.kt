package com.thatcube.mozz.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Where the player, the dock and the navigation sit — as rules, not as `if (wide)`
 * scattered through a composable.
 *
 * This file is deliberately free of Compose: it is arithmetic and enums. The
 * layout it describes is meant to reach iPad, desktop and the web, and the thing
 * that should travel is the *reasoning* — which panel shows where, what the dock
 * morphs from — not a screenful of Kotlin. Anything a second client would have to
 * guess at belongs here with a comment saying why.
 *
 * See ADR-0016.
 */

/** What is showing beside — or instead of — the artwork. Mirrors iOS's `PlayerPanel`. */
enum class PlayerPanel { QUEUE, LYRICS }

/**
 * How the player arranges itself.
 *
 * Note there is exactly one piece of *state* behind this — `PlayerPanel?` — and
 * width only decides how that state is drawn. That is the whole design: closing
 * the queue means the same thing on a phone and a tablet, so folding a device
 * mid-song rearranges the screen without ever changing what you asked for.
 */
enum class PlayerPresentation {
    /** No panel: artwork centred, given the whole width. */
    ARTWORK,

    /** Player on the left, queue or lyrics in a column of their own on the right. */
    PANEL_BESIDE,

    /**
     * The panel takes the artwork's place, leaving the transport where it was.
     * What iOS does today, and the only honest option when there is one column.
     */
    PANEL_INSTEAD,
}

/**
 * The rule. Two inputs, three outcomes, no hidden state.
 *
 * `wide` is not a raw width comparison at the call site — it comes from the
 * adaptive pane directive, which accounts for a fold's hinge. A half-open Fold
 * is showing two panes at a width that still classifies as a phone, and the
 * player has to agree with the library about that or the two disagree on screen.
 */
fun playerPresentation(wide: Boolean, panel: PlayerPanel?): PlayerPresentation = when {
    panel == null -> PlayerPresentation.ARTWORK
    wide -> PlayerPresentation.PANEL_BESIDE
    else -> PlayerPresentation.PANEL_INSTEAD
}

/**
 * Shared metrics for the bottom of the app, so the dock, the navigation and the
 * morph all agree. iOS learned this the hard way in `BottomBar`: the moment two
 * of them derive the same edge from different constants, the player stops landing
 * where it launched from.
 *
 * The dock's geometry is deliberately **identical at every width** — always a
 * floating pill, full width less [margin], at the bottom. Only how far up it sits
 * changes: a navigation bar's worth on a phone, nothing on a tablet, where the
 * rail is beside the content and stops above the dock. That is what lets one
 * morph serve both, instead of a phone morph and a tablet morph that drift apart.
 */
object Dock {
    /** Dock inset from the screen's side edges. */
    val margin: Dp = 12.dp

    /** The docked pill. Tall enough for a 48dp cover plus breathing room. */
    val height: Dp = 64.dp
    val radius: Dp = 18.dp

    /** Gap between the dock and the navigation bar below it. */
    val gapAboveNav: Dp = 8.dp

    /** Material's navigation-bar height. Ours is painted differently, not sized differently. */
    val navBarHeight: Dp = 80.dp

    /** Collapsed navigation rail, used instead of the bar when there is width for it. */
    val railWidth: Dp = 88.dp

    /** Cover inside the docked pill. */
    val artSide: Dp = 48.dp
    val artRadius: Dp = 8.dp
    val artLeading: Dp = 8.dp

    /**
     * Space a scrolling page must leave clear at the bottom.
     *
     * Generous on purpose. Content hidden behind the dock is a bug; a little extra
     * air under the last row is not.
     */
    fun reserve(hasTrack: Boolean, hasBottomNav: Boolean): Dp {
        val nav = if (hasBottomNav) navBarHeight else 0.dp
        val dock = if (hasTrack) height + gapAboveNav else 0.dp
        return nav + dock + margin
    }
}

/**
 * The dock ⇄ full-screen player morph, as pure geometry.
 *
 * Everything is a lerp on [p] (0 = docked pill, 1 = full screen), which is what
 * makes the morph scrubbable: the predictive-back gesture drives `p` backwards
 * frame by frame and every element follows, rather than the whole thing being an
 * animation that can only be played or reversed.
 *
 * All values are pixels — Compose positions by pixel, and converting once here
 * beats converting at twenty call sites.
 */
data class Morph(
    /** 0 = docked, 1 = full screen. May briefly exceed the range while a spring settles. */
    val pRaw: Float,
    val width: Float,
    val height: Float,
    val safeTop: Float,
    val safeBottom: Float,
    /** Docked pill dimensions, in px. */
    val dockHeightPx: Float,
    val dockMarginPx: Float,
    val dockRadiusPx: Float,
    val dockGapPx: Float,
    val navBarHeightPx: Float,
    val dockArtSidePx: Float,
    val dockArtRadiusPx: Float,
    val dockArtLeadingPx: Float,
    /** Whether a bottom navigation bar exists at all (false when the rail is showing). */
    val hasBottomNav: Boolean,
    /** How much of that bar is on screen: 1 shown, 0 slid away under the scroll. */
    val navShown: Float,
    /** Which way the expanded player is laid out — decides where the cover flies to. */
    val presentation: PlayerPresentation,
    /**
     * Where the expanded player actually put its artwork slot, once it has been
     * laid out and has said so.
     *
     * Measured rather than predicted. The alternative — deriving the cover's
     * destination from the same constants the player's layout uses — means two
     * pieces of code that must agree forever, and iOS records in `BottomBar` that
     * every attempt to predict a measured edge was eventually wrong somewhere.
     * The computed values below are a first-frame fallback, nothing more.
     */
    val measuredArtCenterX: Float? = null,
    val measuredArtCenterY: Float? = null,
    val measuredArtSide: Float? = null,
) {
    val p: Float get() = pRaw.coerceIn(0f, 1f)

    // Docked pill -------------------------------------------------------------

    /**
     * Distance from the screen's bottom edge to the dock's bottom edge.
     *
     * Lerped by [navShown] rather than switched, so when the bar slides away on
     * scroll the dock *descends into the space it vacated* instead of jumping.
     * That descent is the Android answer to iOS's minimize: same beat — the dock
     * takes over the bottom while you are reading — without transplanting a
     * gesture the platform does not use.
     */
    val dockBottomInset: Float
        get() {
            val parked = safeBottom + dockMarginPx
            if (!hasBottomNav) return parked
            val raised = safeBottom + navBarHeightPx + dockGapPx
            return lerp(parked, raised, navShown.coerceIn(0f, 1f))
        }

    val dockBottom: Float get() = height - dockBottomInset
    val dockTop: Float get() = dockBottom - dockHeightPx
    val dockLeft: Float get() = dockMarginPx
    val dockWidth: Float get() = width - 2 * dockMarginPx

    // Morphing surface --------------------------------------------------------

    val surfaceLeft: Float get() = lerp(dockLeft, 0f, p)
    val surfaceTop: Float get() = lerp(dockTop, 0f, p)
    val surfaceWidth: Float get() = lerp(dockWidth, width, p)
    val surfaceHeight: Float get() = lerp(dockBottom, height, p) - surfaceTop

    /**
     * Square at the pill, square-ish at full screen, and never a stadium in
     * between: the radius eases to a large-but-finite corner rather than to zero,
     * because a rectangle with hard corners appearing mid-gesture reads as the
     * animation breaking.
     */
    val surfaceRadius: Float get() = lerp(dockRadiusPx, 0f, easeOutQuad(p))

    // Travelling artwork ------------------------------------------------------
    //
    // One image, moved — not a small one that fades into a big one. A cover that
    // visibly travels from the pill to the middle of the screen is most of what
    // makes the morph feel like a physical object rather than a screen change.

    val dockArtCenterX: Float get() = dockLeft + dockArtLeadingPx + dockArtSidePx / 2
    val dockArtCenterY: Float get() = dockTop + dockHeightPx / 2

    /**
     * The cover's expanded size and position, which depend on the layout it is
     * flying into. Beside a panel it lives in the left half; otherwise it gets the
     * middle of the screen.
     */
    val expandedArtSide: Float
        get() {
            measuredArtSide?.let { if (it > 0f) return it }
            val column = when (presentation) {
                PlayerPresentation.PANEL_BESIDE -> width / 2
                else -> width
            }
            // Leave room for the transport underneath, which is why height is in
            // this at all: a tall narrow window would otherwise size the cover off
            // the bottom of the screen.
            val byWidth = column - 2 * expandedArtInsetPx
            val byHeight = (height - safeTop - safeBottom) * 0.52f
            return minOf(byWidth, byHeight).coerceAtLeast(0f)
        }

    val expandedArtCenterX: Float
        get() = measuredArtCenterX ?: when (presentation) {
            PlayerPresentation.PANEL_BESIDE -> width / 4
            else -> width / 2
        }

    val expandedArtCenterY: Float
        get() = measuredArtCenterY ?: when (presentation) {
            // Beside a panel the cover is vertically centred in its column, with
            // the transport below it, so the two halves read as one row.
            PlayerPresentation.PANEL_BESIDE ->
                safeTop + (height - safeTop - safeBottom) * 0.42f
            else -> safeTop + expandedArtTopGapPx + expandedArtSide / 2
        }

    val artSide: Float get() = lerp(dockArtSidePx, expandedArtSide, p)
    val artCenterX: Float get() = lerp(dockArtCenterX, expandedArtCenterX, p)
    val artCenterY: Float get() = lerp(dockArtCenterY, expandedArtCenterY, p)
    val artRadius: Float get() = lerp(dockArtRadiusPx, expandedArtRadiusPx, p)

    // Opacities ---------------------------------------------------------------

    /**
     * The pill's own controls. Gone well before the surface finishes growing, so
     * they never linger as ghosts over the opening player.
     */
    val dockContentAlpha: Float get() = ((0.34f - p) / (0.34f - 0.10f)).coerceIn(0f, 1f)

    /** The player's body arrives late, once there is somewhere to put it. */
    val bodyAlpha: Float get() = ((p - 0.55f) / 0.45f).coerceIn(0f, 1f)

    /** The artwork backdrop, which has to be there before the body it sits behind. */
    val backdropAlpha: Float get() = ((p - 0.12f) / 0.38f).coerceIn(0f, 1f)

    private val expandedArtInsetPx: Float get() = dockMarginPx * 2.6f
    private val expandedArtRadiusPx: Float get() = dockArtRadiusPx * 2.2f
    private val expandedArtTopGapPx: Float get() = dockHeightPx * 0.95f
}

internal fun lerp(a: Float, b: Float, t: Float): Float = a + (b - a) * t

private fun easeOutQuad(t: Float): Float = 1f - (1f - t) * (1f - t)
