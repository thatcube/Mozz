@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.thatcube.mozz.ui

import androidx.compose.foundation.MarqueeSpacing
import androidx.compose.foundation.basicMarquee
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * A title that scrolls when it does not fit, and sits still when it does.
 *
 * The timings are iOS's, to the millisecond, because a title that scrolls at a
 * different rhythm on the two apps is the sort of small wrongness people notice
 * without being able to name. Long enough at the start to read the beginning
 * before it moves; a pause at the end so the last word is not snatched away.
 */
@Composable
fun MarqueeLine(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    weight: FontWeight = FontWeight.Normal,
) {
    Text(
        text,
        style = style,
        color = color,
        fontWeight = weight,
        maxLines = 1,
        softWrap = false,
        modifier = modifier.basicMarquee(
            iterations = Int.MAX_VALUE,
            initialDelayMillis = MarqueeStartDwell,
            repeatDelayMillis = MarqueeEndDwell,
            spacing = MarqueeSpacing(MarqueeGap),
        ),
    )
}

/** Time to read the start of a title before it begins to move. */
private const val MarqueeStartDwell = 2600

/** Time the end of a title stays put before the loop restarts. */
private const val MarqueeEndDwell = 1100

/** Gap between the end of the text and the start of its repeat. */
private val MarqueeGap = 48.dp
