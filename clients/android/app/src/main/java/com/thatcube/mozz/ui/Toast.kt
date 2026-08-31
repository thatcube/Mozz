package com.thatcube.mozz.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * A transient, non-modal message shown briefly near the bottom of the screen.
 *
 * Mozz's answer to "did that work?", and — for the few things worth offering —
 * "let me do something about it". iOS has had this since the design doc's §9;
 * this is the same object with the same rules, so the two apps confirm and
 * apologise in the same words, for the same length of time, in the same place.
 *
 * The rule that matters is that [action] stays RARE. A toast with a button on
 * every one of them trains people to ignore all of them, and floods screen
 * readers besides. iOS reserves it for Undo on two destructive-ish actions;
 * a failure someone can retry is the other case that earns it.
 */
data class Toast(
    val id: Long,
    /** One short line, directly describing what happened. */
    val message: String,
    /** The single optional trailing action — Material's one-per-snackbar rule. */
    val action: ToastAction? = null,
    val durationMs: Long,
)

data class ToastAction(val title: String, val handler: () -> Unit)

/**
 * Owns the visible toast and its auto-dismiss timer.
 *
 * Application-scoped, like the player is: the thing raising a toast is often
 * something that outlives the screen you were looking at when it happened.
 */
class ToastCenter(private val scope: CoroutineScope) {

    private val _current = MutableStateFlow<Toast?>(null)
    val current: StateFlow<Toast?> = _current.asStateFlow()

    private var dismissJob: Job? = null
    private var nextId = 0L

    fun show(message: String, action: ToastAction? = null) {
        val toast = Toast(
            id = nextId++,
            message = message,
            action = action,
            durationMs = if (action != null) ACTION_MS else PLAIN_MS,
        )
        dismissJob?.cancel()
        _current.value = toast
        dismissJob = scope.launch {
            delay(toast.durationMs)
            dismiss(toast.id)
        }
    }

    /** Dismiss [id] if it is still the one showing, so stale timers do nothing. */
    fun dismiss(id: Long) {
        if (_current.value?.id != id) return
        dismissJob?.cancel()
        dismissJob = null
        _current.value = null
    }

    fun perform(toast: Toast) {
        toast.action?.handler?.invoke()
        dismiss(toast.id)
    }

    private companion object {
        /** Material's 4s/10s split, tuned down the way iOS tuned it. */
        const val PLAIN_MS = 2_500L
        const val ACTION_MS = 8_000L
    }
}

/**
 * The current toast, as a card floating clear of whatever is at the bottom.
 *
 * [bottomInset] is what it has to stay above: the navigation bar, and the dock
 * when something is playing. Passed in rather than measured here because the
 * shell already computes exactly that number for the content it lays out, and
 * two answers to "where does the bottom start" is how a toast ends up half
 * behind the dock on one screen size.
 */
@Composable
fun ToastOverlay(
    toasts: ToastCenter,
    bottomInset: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {
    val toast by toasts.current.collectAsStateWithLifecycle()
    // Kept after the state clears so the card keeps its words all the way
    // through the exit animation. Reading the live value inside the content
    // would empty it the moment dismissal starts, and the toast would slide
    // away as a blank slab.
    var last by remember { mutableStateOf<Toast?>(null) }
    if (toast != null) last = toast

    AnimatedVisibility(
        visible = toast != null,
        enter = slideInVertically(spring(stiffness = 320f)) { it } + fadeIn(),
        exit = slideOutVertically(spring(stiffness = 320f)) { it } + fadeOut(),
        modifier = modifier,
    ) {
        val shown = last ?: return@AnimatedVisibility
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHighest,
            contentColor = MaterialTheme.colorScheme.onSurface,
            shape = RoundedCornerShape(16.dp),
            tonalElevation = 3.dp,
            shadowElevation = 8.dp,
            modifier = Modifier
                .padding(horizontal = 14.dp)
                .padding(bottom = bottomInset + 10.dp)
                .widthIn(max = 520.dp)
                // Announced without stealing focus, so it is perceivable to a
                // screen reader that is somewhere else on the page (WCAG 4.1.3).
                .semantics { liveRegion = LiveRegionMode.Polite },
        ) {
            Row(
                modifier = Modifier.padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    shown.message,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false).padding(vertical = 9.dp),
                )
                shown.action?.let { action ->
                    Spacer(Modifier.width(0.dp))
                    TextButton(onClick = { toasts.perform(shown) }) {
                        Text(
                            action.title,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
        }
    }
}
