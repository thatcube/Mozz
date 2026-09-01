package com.thatcube.mozz.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.thatcube.mozz.R

/**
 * The app's three places.
 *
 * Same three as iOS, in the same order, because the two apps are one product and
 * muscle memory should carry between them.
 */
enum class AppTab(val title: String, val icon: Int, val selectedIcon: Int) {
    HOME("Home", R.drawable.ic_home, R.drawable.ic_home_filled),
    LIBRARY("Library", R.drawable.ic_library, R.drawable.ic_library_filled),
    SEARCH("Search", R.drawable.ic_search, R.drawable.ic_search_filled),
}

/**
 * Navigation, in Material's geometry and Mozz's paint.
 *
 * The measurements are Material's — 80dp tall, a 64×32 indicator, 48dp targets —
 * because those are the numbers thumbs on this platform are calibrated to, and
 * getting clever with them only makes an app that is harder to hit. Everything
 * you can see is ours: no tonal-elevation wash, no filled pill in a colour the
 * palette does not have. Selection is carried by weight and contrast, which is
 * the same trick the rest of the app uses in place of decorative colour.
 */
@Composable
fun MozzNavBar(
    selected: AppTab,
    onSelect: (AppTab) -> Unit,
    /**
     * The window's bottom inset — the gesture bar's strip.
     *
     * The bar extends over it and pads its own contents up, rather than being
     * lifted above it. Sitting above the inset left a band between the tab
     * labels and the bottom edge that belonged to nobody, and the page scrolled
     * through it: album covers slid past underneath the labels.
     */
    bottomInset: Dp = 0.dp,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .height(Dock.navBarHeight + bottomInset)
            .background(MaterialTheme.colorScheme.background),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().height(Dock.navBarHeight),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AppTab.entries.forEach { tab ->
                NavItem(
                    tab = tab,
                    selected = tab == selected,
                    onSelect = { onSelect(tab) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/**
 * The same navigation, stood on its end.
 *
 * Used instead of the bar once there is width for it — and it stops above the
 * dock rather than running the full height, because the transport owns the
 * bottom edge of the window at every size. That is the arrangement every desktop
 * music player converged on, and it is what keeps the dock's geometry (and
 * therefore the morph) identical on a phone and a tablet.
 */
@Composable
fun MozzNavRail(
    selected: AppTab,
    onSelect: (AppTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(Dock.railWidth)
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.background),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Top,
    ) {
        Spacer(Modifier.height(12.dp))
        AppTab.entries.forEach { tab ->
            NavItem(
                tab = tab,
                selected = tab == selected,
                onSelect = { onSelect(tab) },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(4.dp))
        }
    }
}

/**
 * One destination.
 *
 * The icon lifts and settles rather than snapping — a small spring on scale, on
 * the icon only. Material's own indicator pill animates too; this is the same
 * gesture with the pill's colour taken out and put into the icon's weight.
 */
@Composable
private fun NavItem(
    tab: AppTab,
    selected: Boolean,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.08f else 1f,
        animationSpec = spring(dampingRatio = 0.55f, stiffness = 520f),
        label = "nav-icon-scale",
    )
    val indicator by animateFloatAsState(
        targetValue = if (selected) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 400f),
        label = "nav-indicator",
    )

    Column(
        modifier = modifier
            .selectable(
                selected = selected,
                onClick = onSelect,
                role = Role.Tab,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 40.dp),
            )
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                // Taller than Material's 64×32, which is sized for a 24dp icon.
                // At 30dp — iOS's size, and the size the rest of this app's
                // controls are matched to — a 32dp pill clips the glyph's corners
                // against its own rounded edge.
                .size(width = 64.dp, height = 40.dp)
                .clip(RoundedCornerShape(percent = 50))
                // A faint wash, not a filled pill: the one saturated colour in
                // this app means "the action", and a tab is not that.
                .background(scheme.onBackground.copy(alpha = 0.10f * indicator)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painterResource(if (selected) tab.selectedIcon else tab.icon),
                contentDescription = tab.title,
                tint = if (selected) scheme.onBackground else scheme.onSurfaceVariant,
                // iOS's tab icon size. Material's own is 24dp, but every other
                // control in this app is already matched to iOS's metrics, and a
                // navigation bar that alone disagreed read as a smaller icon
                // rather than a deliberate one.
                modifier = Modifier.size(30.dp).scale(scale),
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(
            tab.title,
            style = MaterialTheme.typography.labelMedium,
            fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (selected) scheme.onBackground else scheme.onSurfaceVariant,
        )
    }
}

/** A hairline over the navigation, so content scrolling under it has an edge to meet. */
@Composable
fun NavEdge(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Color.Transparent),
    )
}
