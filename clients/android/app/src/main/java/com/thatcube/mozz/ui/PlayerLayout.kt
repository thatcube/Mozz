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
    /** Dock inset from the content area's side edges. */
    val margin: Dp = 12.dp

    /**
     * The widest the dock is allowed to get.
     *
     * Past this it stops growing and simply centres itself over the content, so
     * on a tablet it reads as a floating capsule rather than a bar welded across
     * the window. One rule covers both shapes: on a phone the content is narrower
     * than the cap, so the dock is full width less a margin and nothing appears
     * to be capped at all.
     */
    val maxWidth: Dp = 640.dp

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
    /**
     * Left edge of the content area — the rail's width when there is a rail.
     *
     * The dock centres over the content, not over the window, so it does not sit
     * visibly off-centre with a rail down one side. The rail itself runs the full
     * height and passes behind nothing: the dock simply floats above it.
     */
    val contentLeft: Float,
    /** Widest the docked pill may be, in px. */
    val dockMaxWidthPx: Float,
    /** How much of that bar is on screen: 1 shown, 0 slid away under the scroll. */
    val navShown: Float,
    /** Which way the expanded player is laid out — decides where the cover flies to. */
    val presentation: PlayerPresentation,
    /**
     * The display's own corner radius, when the device will say.
     *
     * A sheet covering the screen looks most like a sheet when its corners are
     * the screen's corners. Android reports this from API 31; below that, and on
     * a device that declines to answer, [expandedRadiusPx] falls back to a
     * proportion of the dock's own corner.
     */
    val deviceCornerPx: Float? = null,
    /**
     * Queue-open progress: 0 = cover big in the middle of the player, 1 = docked
     * into the now-playing card's thumbnail slot at the top of the queue.
     *
     * A second stage on top of [pRaw], and only meaningful once the player is
     * open. Composing the two as `dock → big → card` rather than as one blend is
     * what lets the queue open and close without disturbing the dock morph, and
     * it is how iOS does it.
     */
    val queue: Float = 0f,
    /** The card's thumbnail slot, measured, once the card is laid out. */
    val cardArtCenterX: Float? = null,
    val cardArtCenterY: Float? = null,
    val cardArtSide: Float? = null,
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
    val q: Float get() = queue.coerceIn(0f, 1f)

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

    val dockWidth: Float
        get() {
            val available = (width - contentLeft) - 2 * dockMarginPx
            return minOf(available, dockMaxWidthPx).coerceAtLeast(0f)
        }

    /** Centred in the content area, which is the window less any rail. */
    val dockLeft: Float
        get() = contentLeft + ((width - contentLeft) - dockWidth) / 2

    // Morphing surface --------------------------------------------------------

    val surfaceLeft: Float get() = lerp(dockLeft, 0f, p)
    val surfaceTop: Float get() = lerp(dockTop, 0f, p)
    val surfaceWidth: Float get() = lerp(dockWidth, width, p)
    val surfaceHeight: Float get() = lerp(dockBottom, height, p) - surfaceTop

    /**
     * The surface's corner, from the pill's to the open player's.
     *
     * Never square. It used to ease to zero, which meant the moment you started
     * pulling the player down its top corners were hard — a sheet with square
     * corners does not read as sitting over anything. iOS keeps 24pt at full
     * screen for the same reason, and the library showing through those corners
     * is the point rather than a leak.
     */
    val surfaceRadius: Float get() = lerp(dockRadiusPx, expandedRadiusPx, p)

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

    private val restingArtSide: Float
        get() = lerp(expandedArtSide, cardArtSide ?: expandedArtSide, q)
    private val restingArtCenterX: Float
        get() = lerp(expandedArtCenterX, cardArtCenterX ?: expandedArtCenterX, q)
    private val restingArtCenterY: Float
        get() = lerp(expandedArtCenterY, cardArtCenterY ?: expandedArtCenterY, q)
    private val restingArtRadius: Float
        get() = lerp(expandedArtRadiusPx, cardArtRadiusPx, q)

    val artSide: Float get() = lerp(dockArtSidePx, restingArtSide, p)
    val artCenterX: Float get() = lerp(dockArtCenterX, restingArtCenterX, p)
    val artCenterY: Float get() = lerp(dockArtCenterY, restingArtCenterY, p)
    val artRadius: Float get() = lerp(dockArtRadiusPx, restingArtRadius, p)

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

    /**
     * The open player's corner: the display's, when the device reports one.
     *
     * Matching the screen is what makes the player read as a sheet laid over the
     * device rather than a rectangle drawn on it. The fallback is iOS's
     * `expandedRadius`, expressed against the dock's own corner.
     */
    val expandedRadiusPx: Float
        get() = deviceCornerPx?.takeIf { it > 0f } ?: (dockRadiusPx * 1.33f)

    private val expandedArtInsetPx: Float get() = dockMarginPx * 2.6f
    private val expandedArtRadiusPx: Float get() = dockArtRadiusPx * 2.2f
    private val cardArtRadiusPx: Float get() = dockArtRadiusPx * 1.4f
    private val expandedArtTopGapPx: Float get() = dockHeightPx * 0.95f
}

internal fun lerp(a: Float, b: Float, t: Float): Float = a + (b - a) * t

