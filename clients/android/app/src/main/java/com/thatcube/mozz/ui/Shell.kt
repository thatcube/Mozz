package com.thatcube.mozz.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.playback.PlayerController
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.LayoutDirection
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.launch

/**
 * The app once there is a library to look at: navigation, the dock, and the
 * player they morph into.
 *
 * These three are one hierarchy rather than a `Scaffold` with a `bottomBar`,
 * because the dock does not sit *next to* the player — it **is** the player,
 * collapsed. A scaffold slot would put a hard boundary exactly where the morph
 * needs to cross.
 *
 * Navigation moves rather than duplicating: a bar along the bottom when there is
 * one column, a rail down the left when there is room for two. The dock does not
 * move. It is the same floating pill at every width, spanning the bottom under
 * the rail, which is both what every desktop player does and what lets a single
 * morph serve a phone and a tablet.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun MozzShell(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    onResync: () -> Unit,
    onSignOut: () -> Unit,
) {
    val state by playback.state.collectAsStateWithLifecycle()
    // The same question the library's list/detail scaffold asks, answered the
    // same way — the pane directive, not a raw width, because a half-open Fold
    // shows two panes at a width that still classifies as a phone.
    // Computed once, here, and handed to everything that needs it. Letting the
    // shell and the library's scaffold each ask for their own was a disagreement
    // waiting to happen — and it happened: a narrow window with a bottom bar
    // (shell: one column) still split the library into two panes.
    val directive = calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())
    val wide = directive.maxHorizontalPartitions > 1

    var tab by remember { mutableStateOf(AppTab.HOME) }

    // The single piece of player state the presentation rules read. Not one
    // value per layout: closing the queue means the same thing at every width,
    // so folding the device mid-song rearranges the screen without changing what
    // was asked for. See PlayerLayout.kt.
    var panel by remember { mutableStateOf<PlayerPanel?>(null) }

    // Opening onto the queue when there is a column for it, and onto the artwork
    // when there is not, is a *default* rather than a rule — hence the one-shot
    // effect. Once someone has chosen, their choice survives folding.
    var panelDefaulted by remember { mutableStateOf(false) }
    LaunchedEffect(wide) {
        if (!panelDefaulted && wide) {
            panel = PlayerPanel.QUEUE
            panelDefaulted = true
        }
    }

    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    // Morph progress: 0 docked, 1 full screen. An Animatable rather than a
    // boolean with a transition, because the back gesture scrubs it — the
    // predictive-back drag drives this value directly, frame by frame.
    val p = remember { Animatable(0f) }
    var expanded by remember { mutableStateOf(false) }

    /**
     * Whether the player is on screen at all — true through the collapse, false
     * once it has finished.
     *
     * The player's body is full-screen and stays laid out for the morph, so while
     * it was mounted it sat over the whole app swallowing touches: the library,
     * the navigation and the top bar all stopped responding, and only the dock
     * still worked because it is drawn above it. Not mounting it at all when the
     * player is away is the fix; blocking its touches was treating the symptom.
     */
    var playerMounted by remember { mutableStateOf(false) }

    /**
     * The mirror of [playerMounted], for the pill's own controls.
     *
     * The dock's rectangle does not move with the morph — it is always a pill at
     * the bottom of the screen — so anything of the dock's left composed while the
     * player is open sits over whatever the player has put there. It was over the
     * transport, which is why play, pause and the skips did nothing while the
     * lyrics and queue buttons below them worked.
     */
    var dockMounted by remember { mutableStateOf(true) }

    // How much of the bottom navigation is on screen. Driven by scrolling, and
    // only meaningful when the bar exists at all: a rail does not hide.
    val navShown = remember { mutableFloatStateOf(1f) }
    LaunchedEffect(wide) { if (wide) navShown.floatValue = 1f }

    val navBarPx = with(density) { Dock.navBarHeight.toPx() }
    /** How far the sheet has to travel for the drag to have collapsed it fully. */
    val dismissTravelPx = with(density) { DISMISS_TRAVEL.toPx() }
    val hideOnScroll = remember(navBarPx, wide) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                // Programmatic scrolls — the queue following the music, the lyrics
                // tracking the sung line — must not move the navigation.
                if (wide || source != NestedScrollSource.UserInput) return Offset.Zero
                navShown.floatValue =
                    (navShown.floatValue + available.y / navBarPx).coerceIn(0f, 1f)
                return Offset.Zero
            }
        }
    }

    var size by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    val insets = WindowInsets.safeDrawing.asPaddingValues()
    val safeTopPx = with(density) { insets.calculateTopPadding().toPx() }
    val safeBottomPx = with(density) { insets.calculateBottomPadding().toPx() }

    val hasTrack = state.track != null
    val presentation = playerPresentation(wide, panel)

    // Not destructured with `by`: the morph lambdas read this inside the layout
    // and draw phases, so a frame of the queue opening costs a re-layout rather
    // than a recomposition of the list underneath it.
    val queueDock = animateFloatAsState(
        targetValue = if (presentation == PlayerPresentation.PANEL_INSTEAD) 1f else 0f,
        animationSpec = QueueDockSpring,
        label = "queue-dock",
    )

    fun morphAt(progress: Float, artSlot: Rect?, cardSlot: Rect?) = Morph(
        pRaw = progress,
        width = size.width.toFloat(),
        height = size.height.toFloat(),
        safeTop = safeTopPx,
        safeBottom = safeBottomPx,
        dockHeightPx = with(density) { Dock.height.toPx() },
        dockMarginPx = with(density) { Dock.margin.toPx() },
        dockRadiusPx = with(density) { Dock.radius.toPx() },
        dockGapPx = with(density) { Dock.gapAboveNav.toPx() },
        navBarHeightPx = navBarPx,
        dockArtSidePx = with(density) { Dock.artSide.toPx() },
        dockArtRadiusPx = with(density) { Dock.artRadius.toPx() },
        dockArtLeadingPx = with(density) { Dock.artLeading.toPx() },
        hasBottomNav = !wide,
        navShown = navShown.floatValue,
        presentation = presentation,
        contentLeft = if (wide) with(density) { Dock.railWidth.toPx() } else 0f,
        dockMaxWidthPx = with(density) { Dock.maxWidth.toPx() },
        measuredArtCenterX = artSlot?.center?.x,
        measuredArtCenterY = artSlot?.center?.y,
        measuredArtSide = artSlot?.let { minOf(it.width, it.height) },
        queue = queueDock.value,
        cardArtCenterX = cardSlot?.center?.x,
        cardArtCenterY = cardSlot?.center?.y,
        cardArtSide = cardSlot?.let { minOf(it.width, it.height) },
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .onSizeChanged { size = it },
    ) {
        // Pages, with the rail beside them when there is one.
        Row(modifier = Modifier.fillMaxSize()) {
            if (wide) {
                MozzNavRail(
                    selected = tab,
                    onSelect = { tab = it },
                    modifier = Modifier
                        .fillMaxHeight()
                        // The rail runs the full height of the window, so it has
                        // to inset itself: without this its first destination
                        // sits under the status bar and wears the notification
                        // icons. The page beside it has a Scaffold doing the same
                        // job; the rail has nobody to do it for it.
                        .windowInsetsPadding(
                            WindowInsets.safeDrawing.only(
                                WindowInsetsSides.Top + WindowInsetsSides.Start
                            )
                        )
                        // The rail runs the full height and the dock floats over
                        // the content beside it, so there is nothing to stop
                        // short of — only the rail's own last item to keep clear
                        // of the bottom edge.
                        .padding(bottom = Dock.margin),
                )
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .nestedScroll(hideOnScroll),
            ) {
                TabContent(
                    tab = tab,
                    account = account,
                    library = library,
                    server = server,
                    playback = playback,
                    directive = directive,
                    bottomReserve = Dock.reserve(hasTrack, hasBottomNav = !wide),
                    onResync = onResync,
                    onSignOut = onSignOut,
                )
            }
        }

        // The bottom bar, which slides away as you read and comes back as you
        // scroll up. Offset in the draw phase so the descent stays smooth.
        if (!wide) {
            MozzNavBar(
                selected = tab,
                onSelect = { tab = it; navShown.floatValue = 1f },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = with(density) { safeBottomPx.toDp() })
                    .graphicsLayer {
                        translationY = (1f - navShown.floatValue) * (navBarPx + safeBottomPx)
                    },
            )
        }

        if (hasTrack) {
            MorphHost(
                state = state,
                server = server,
                library = library,
                playback = playback,
                progress = { p.value },
                morphAt = ::morphAt,
                queueProgress = { queueDock.value },
                presentation = presentation,
                panel = panel,
                onPanel = { panel = it },
                wide = wide,
                expanded = expanded,
                mounted = playerMounted,
                dockMounted = dockMounted,
                onOpen = {
                    expanded = true
                    playerMounted = true
                    scope.launch {
                        p.animateTo(1f, MorphSpring)
                        dockMounted = false
                    }
                },
                onCollapse = {
                    expanded = false
                    dockMounted = true
                    scope.launch {
                        p.animateTo(0f, MorphSpring)
                        playerMounted = false
                    }
                },
                // The drag drives the same value the back gesture drives, so
                // there is one collapse in the app rather than two that have to
                // be kept looking alike.
                onDismissDrag = { travelled ->
                    dockMounted = true
                    scope.launch {
                        p.snapTo((1f - travelled / dismissTravelPx).coerceIn(0f, 1f))
                    }
                },
                onDismissEnd = { travelled ->
                    scope.launch {
                        // Past a third of the way down it goes; short of that it
                        // springs back open, so a stray downward brush on the
                        // artwork never costs you the player.
                        if (travelled > dismissTravelPx * DISMISS_FRACTION) {
                            expanded = false
                            p.animateTo(0f, MorphSpring)
                            playerMounted = false
                        } else {
                            p.animateTo(1f, MorphSpring)
                        }
                    }
                },
            )
        }

        // The back ladder. Only the player's own collapse is scrubbable — the
        // other rungs are state changes with nothing to drag, and giving them a
        // progress gesture would just fight the panel's crossfade.
        val panelIsModal = presentation == PlayerPresentation.PANEL_INSTEAD

        BackHandler(enabled = expanded && panelIsModal) { panel = null }

        PredictiveBackHandler(enabled = expanded && !panelIsModal) { events ->
            dockMounted = true
            try {
                events.collect { event ->
                    // Ease the gesture: a linear drag makes the player feel like
                    // it is being dragged rather than released.
                    val eased = event.progress * event.progress * (3f - 2f * event.progress)
                    p.snapTo(1f - eased)
                }
                expanded = false
                p.animateTo(0f, MorphSpring)
                playerMounted = false
            } catch (_: CancellationException) {
                // Cancelled mid-gesture: spring back open from wherever the
                // finger left it, which is why this is an Animatable.
                p.animateTo(1f, MorphSpring)
            }
        }
    }
}

/**
 * The one spring the whole morph moves on.
 *
 * Shared so the surface, the travelling cover and the body cannot settle at
 * different times — the thing that makes a morph read as several animations
 * instead of one object.
 */
internal val MorphSpring: AnimationSpec<Float> =
    spring(dampingRatio = 0.86f, stiffness = 380f)

/**
 * Travel that maps to the whole collapse.
 *
 * Shorter than the screen on purpose: a drag that had to cross a tablet's full
 * height to put the player away would be a workout, and the gesture should read
 * as a flick rather than a haul.
 */
private val DISMISS_TRAVEL = 340.dp

/** How much of that travel commits the dismiss on release. */
private const val DISMISS_FRACTION = 0.33f

/**
 * The cover's trip into the queue card, and the title cross-fade riding on it.
 *
 * Gentler than [MorphSpring]: this is a rearrangement inside a screen that is
 * already open, not the screen arriving, and it carries a directional cross-fade
 * that needs room to read.
 */
private val QueueDockSpring: AnimationSpec<Float> =
    spring(dampingRatio = 0.9f, stiffness = 260f)

/**
 * The page for the selected tab.
 *
 * Kept in the shell rather than inside a navigation component so each page is an
 * ordinary composable that knows nothing about tabs, the dock, or the morph — and
 * so the bottom inset every page needs is calculated in exactly one place.
 */
@Composable
private fun TabContent(
    tab: AppTab,
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    playback: PlayerController,
    directive: androidx.compose.material3.adaptive.layout.PaneScaffoldDirective,
    bottomReserve: androidx.compose.ui.unit.Dp,
    onResync: () -> Unit,
    onSignOut: () -> Unit,
) {
    when (tab) {
        AppTab.HOME -> HomeScreen(
            account = account,
            library = library,
            server = server,
            playback = playback,
            directive = directive,
            bottomReserve = bottomReserve,
            onResync = onResync,
            onSignOut = onSignOut,
        )
        AppTab.LIBRARY -> ComingSoon("Library", "Artists, albums and playlists, in one place.")
        AppTab.SEARCH -> ComingSoon("Search", "Everything on this server, by name.")
    }
}

/**
 * A page that exists in navigation before it exists in code.
 *
 * Deliberately says what will be here rather than "coming soon" on its own: a
 * tab that explains itself is a plan, a tab that apologises is a hole.
 */
@Composable
private fun ComingSoon(title: String, promise: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.layout.Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 40.dp),
        ) {
            androidx.compose.material3.Text(
                title,
                style = MaterialTheme.typography.headlineMedium,
                // Explicit: nothing above this provides a content colour, and
                // Material's default is black — which on this background is a
                // heading that simply is not there.
                color = MaterialTheme.colorScheme.onBackground,
            )
            androidx.compose.foundation.layout.Spacer(Modifier.height(8.dp))
            androidx.compose.material3.Text(
                promise,
                style = com.thatcube.mozz.ui.theme.quietBody,
            )
        }
    }
}
