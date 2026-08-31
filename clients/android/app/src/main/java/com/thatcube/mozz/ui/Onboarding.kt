package com.thatcube.mozz.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.thatcube.mozz.R
import com.thatcube.mozz.core.MusicLibrary
import com.thatcube.mozz.core.SyncStatus
import com.thatcube.mozz.ui.theme.quietBody

/**
 * The shell every onboarding step sits in.
 *
 * Vertical rhythm per mozz-design-refs/REDESIGN-PLAN.md: the wordmark and
 * tagline in the upper third, the content centred, the licence footer pinned to
 * the bottom — so the whitespace reads as intentional rather than as an empty
 * screen with the controls fallen to the floor.
 *
 * The content is width-capped rather than filling. On the Fold's inner screen, a
 * sign-in form stretched to 8 inches looks broken; a column of a comfortable
 * reading width, centred, does not.
 */
@Composable
private fun OnboardingScaffold(
    title: String,
    subtitle: String? = null,
    content: @Composable () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(64.dp))
            Image(
                painter = painterResource(R.drawable.mozz_logo),
                contentDescription = null,
                modifier = Modifier.size(72.dp),
            )
            Spacer(Modifier.height(14.dp))
            Text("Mozz", style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(8.dp))
            Text(
                "One app for your music, wherever it lives.",
                style = quietBody,
            )

            Spacer(Modifier.weight(0.45f))

            Column(
                modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.headlineMedium,
                    textAlign = TextAlign.Center,
                )
                if (subtitle != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(subtitle, style = quietBody)
                }
                Spacer(Modifier.height(28.dp))
                content()
            }

            Spacer(Modifier.weight(1f))

            Text(
                "Free forever. Open source, GPL-3.0.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
fun SignInScreen(onConnectPlex: () -> Unit) {
    OnboardingScaffold(
        title = "Connect your server",
        subtitle = "Mozz plays the music on your own Plex server. " +
            "You approve the connection in your browser — no password is typed here.",
    ) {
        Button(
            onClick = onConnectPlex,
            modifier = Modifier.fillMaxWidth().height(52.dp),
        ) {
            Text("Connect Plex", style = MaterialTheme.typography.labelLarge)
        }
    }
}

/**
 * No code is shown, deliberately.
 *
 * The core asks Plex for a `strong` PIN, because that is the only kind
 * `app.plex.tv/auth` will claim — and a strong PIN's code is a 25-character
 * token, not the four characters you type at plex.tv/link. Putting it on screen
 * would be an unreadable credential presented as if it were an instruction.
 * The link button is the whole flow.
 */
@Composable
fun LinkingScreen(onOpenBrowser: () -> Unit, onCancel: () -> Unit) {
    OnboardingScaffold(
        title = "Approve Mozz on Plex",
        subtitle = "Plex will open in your browser and ask you to confirm this " +
            "device. Come back here when it says you are linked.",
    ) {
        Button(
            onClick = onOpenBrowser,
            modifier = Modifier.fillMaxWidth().height(52.dp),
        ) {
            Text("Open Plex to approve", style = MaterialTheme.typography.labelLarge)
        }
        Spacer(Modifier.height(16.dp))
        WaitingForPlex()
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = onCancel) { Text("Cancel") }
    }
}

@Composable
private fun WaitingForPlex() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator(
            modifier = Modifier.size(18.dp),
            strokeWidth = 2.dp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))
        Text("Waiting for Plex…", style = quietBody)
    }
}

@Composable
fun LibraryPickerScreen(
    serverName: String,
    libraries: List<MusicLibrary>,
    onSelect: (MusicLibrary) -> Unit,
) {
    OnboardingScaffold(
        title = "Which library?",
        subtitle = "$serverName has more than one. Mozz will mirror the one you pick.",
    ) {
        // One inset card with hairline dividers, not a stack of filled pills —
        // the picker in the redesign plan.
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
        ) {
            LazyColumn(contentPadding = PaddingValues(vertical = 4.dp)) {
                items(libraries, key = { it.id }) { library ->
                    TextButton(
                        onClick = { onSelect(library) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            library.name,
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                        )
                    }
                    if (library != libraries.last()) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }
    }
}

@Composable
fun SyncingScreen(serverName: String, status: SyncStatus?) {
    OnboardingScaffold(
        title = "Mirroring $serverName",
        subtitle = "Your catalogue is copied to this device, so browsing and " +
            "searching stay instant even when the server is not.",
    ) {
        val total = status?.total?.takeIf { it > 0 }
        val done = status?.itemsSynced ?: 0
        if (total != null) {
            LinearProgressIndicator(
                progress = { (done.toFloat() / total).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        Spacer(Modifier.height(14.dp))
        Text(status?.describe() ?: "Connecting", style = quietBody)
    }
}

@Composable
fun FailedScreen(message: String, canRetry: Boolean, onRetry: () -> Unit, onSignOut: () -> Unit) {
    OnboardingScaffold(title = "That did not work", subtitle = message) {
        if (canRetry) {
            Button(onClick = onRetry, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Text("Try again", style = MaterialTheme.typography.labelLarge)
            }
            Spacer(Modifier.height(12.dp))
        }
        OutlinedButton(onClick = onSignOut, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Text("Start over")
        }
    }
}

@Composable
fun StartingScreen() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Image(
                    painter = painterResource(R.drawable.mozz_logo),
                    contentDescription = null,
                    modifier = Modifier.size(72.dp),
                )
                Spacer(Modifier.height(14.dp))
                Text("Mozz", style = MaterialTheme.typography.displaySmall)
                Spacer(Modifier.height(24.dp))
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
