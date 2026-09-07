package com.thatcube.mozz.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.thatcube.mozz.BuildConfig
import com.thatcube.mozz.R
import com.thatcube.mozz.analysis.SonicAnalysisWorker
import com.thatcube.mozz.core.MozzDownloads
import com.thatcube.mozz.core.DownloadRecord
import com.thatcube.mozz.core.StorageUsage
import com.thatcube.mozz.downloads.DownloadWorker
import com.thatcube.mozz.pairing.PairingCandidate
import com.thatcube.mozz.pairing.PairingDiscovery
import com.thatcube.mozz.pairing.PairingService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.collectLatest
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.style.TextOverflow
import com.thatcube.mozz.analysis.SonicWeights
import androidx.compose.foundation.lazy.items
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.MusicLibrary
import com.thatcube.mozz.core.ServerAccountProfile
import com.thatcube.mozz.core.SonicProgress
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlin.math.roundToInt
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Suppression
import com.thatcube.mozz.ui.theme.mozzSurface
import kotlinx.coroutines.launch
import com.thatcube.mozz.ui.theme.LocalMozzSettings
import com.thatcube.mozz.ui.theme.MozzAppearance
import com.thatcube.mozz.ui.theme.MozzDarkStyle

/**
 * Settings, in the shape the iPhone has them.
 *
 * The sections and their order are iOS's, section for section, because this is
 * the map of the app and two products that disagree about where a setting lives
 * are two products. Siri's section is the one omission: it has no counterpart
 * here.
 *
 * Most of what is listed does not work yet, and says so. That is deliberate: a
 * switch that flips and changes nothing is worse than no switch, because it
 * makes a promise the app then quietly breaks. A row marked "Soon" shows where
 * the control will be without claiming it is wired.
 */
@Composable
fun SettingsPage(
    account: ServerAccount,
    server: MozzServer,
    nav: Navigator,
    bottomReserve: Dp,
    onResync: () -> Unit,
    onSignOut: () -> Unit,
) {
    val context = LocalContext.current
    // Polled rather than pushed: the pass lives in the core, and a count that
    // ticks while this screen is open is the only visible sign it is working.
    val sonic by produceState<SonicProgress?>(null, account.serverId) {
        while (true) {
            value = runCatching { server.sonicProgress(account.serverId, SonicWeights.path(context)) }.getOrNull()
            delay(SONIC_POLL_MS)
        }
    }
    val profile by produceState<ServerAccountProfile?>(null, account.serverId) {
        value = runCatching { server.account(account.serverId) }.getOrNull()
    }
    fun open(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
    }

    ListPage("Settings", onBack = nav::back) { inset, _ ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            item {
                AccountHeader(profile, account.serverName, inset)
            }

            item {
                SettingsSection("Library", inset) {
                    SettingsRow(
                        R.drawable.ic_refresh, "Sync Now", inset,
                        showsChevron = false, onClick = onResync,
                    )
                    SettingsRow(
                        R.drawable.ic_server, "Server & Libraries", inset,
                        detail = account.serverName,
                        soon = true,
                        onClick = {
                            nav.open(
                                Route.SettingsSoon(
                                    "Server & Libraries",
                                    "Signing in to more than one server, and choosing which of them a tab is showing.",
                                )
                            )
                        },
                    )
                    SettingsRow(
                        R.drawable.ic_library, "Music Library", inset,
                        onClick = { nav.open(Route.SettingsLibraries) },
                    )
                }
            }

            item {
                SettingsSection("Playback", inset) {
                    SettingsToggle(R.drawable.ic_volume, "Volume Normalization", inset, soon = true)
                    SettingsRow(
                        R.drawable.ic_waveform, "Equalizer", inset, soon = true,
                        onClick = {
                            nav.open(
                                Route.SettingsSoon(
                                    "Equalizer",
                                    "Ten bands and the presets, sharing the same curve the desktop and the iPhone use.",
                                )
                            )
                        },
                    )
                }
            }

            item {
                SettingsSection("Lyrics", inset) {
                    SettingsToggle(R.drawable.ic_quote, "Look Up Lyrics Online", inset, soon = true)
                    SettingsNote(
                        "Checks LRCLIB when your server has none. Only title, artist and length are sent.",
                        inset,
                    )
                    SettingsToggle(R.drawable.ic_download, "Save Lyrics with Downloads", inset, soon = true)
                    SettingsNote("Keeps lyrics with you offline.", inset)
                }
            }

            item {
                SettingsSection("Recommendations", inset) {
                    SettingsToggle(R.drawable.ic_sparkles, "Improve Recommendations", inset, soon = true)
                    SettingsNote(
                        "Sharpens radio and mixes using MusicBrainz. Only song and artist names are sent — off means fully offline.",
                        inset,
                    )
                    val settings = LocalMozzSettings.current
                    if (settings != null) {
                        SettingsSwitch(
                            R.drawable.ic_sparkles, "Analyse on Battery", inset,
                            checked = settings.analyseOnBattery,
                        ) { allowed ->
                            settings.analyseOnBattery = allowed
                            // The constraints are baked into the scheduled job,
                            // so a schedule made while this was off would keep
                            // waiting for a charger no matter what the switch
                            // says now.
                            SonicAnalysisWorker.schedule(context, allowsBattery = allowed)
                        }
                        SettingsNote(
                            "Off, listening waits for a charger. On, it runs on battery too — " +
                                "a whole library is hours of work, so expect it to cost some.",
                            inset,
                        )
                    }
                    val progress = sonic
                    if (progress != null && progress.total > 0) {
                        SonicAnalysisNote(progress, inset)
                    }
                    SettingsRow(
                        R.drawable.ic_more, "Not Recommended", inset,
                        onClick = { nav.open(Route.SettingsSuppressions) },
                    )
                }
            }

            item {
                SettingsSection("Offline", inset) {
                    SettingsRow(
                        R.drawable.ic_download, "Downloads", inset,
                        onClick = { nav.open(Route.SettingsDownloads) },
                    )
                }
            }

            item {
                SettingsSection("Devices", inset) {
                    SettingsRow(
                        R.drawable.ic_cast, "Devices", inset,
                        onClick = { nav.open(Route.SettingsDevices) },
                    )
                }
            }

            item {
                SettingsSection(null, inset) {
                    SettingsRow(
                        R.drawable.ic_palette, "Appearance", inset,
                        detail = LocalMozzSettings.current?.appearance?.label,
                        onClick = { nav.open(Route.SettingsAppearance) },
                    )
                    SettingsRow(
                        R.drawable.ic_stethoscope, "Diagnostics", inset, soon = true,
                        onClick = {
                            nav.open(
                                Route.SettingsSoon(
                                    "Diagnostics",
                                    "What the last sync did, what the server answered, and a log worth attaching to a bug report.",
                                )
                            )
                        },
                    )
                }
            }

            item {
                SettingsSection(null, inset) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = onSignOut)
                            .padding(horizontal = inset, vertical = 16.dp),
                    ) {
                        Text(
                            "Sign Out",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
            }

            item {
                SettingsSection("About", inset) {
                    SettingsRow(
                        R.drawable.ic_github, "Source on GitHub", inset,
                        showsChevron = false,
                    ) { open("https://github.com/thatcube/mozz") }
                    SettingsRow(
                        R.drawable.ic_heart, "Support Development", inset,
                        showsChevron = false,
                    ) { open("https://github.com/sponsors/thatcube") }
                    SettingsRow(
                        R.drawable.ic_info, "Version", inset,
                        detail = BuildConfig.VERSION_NAME,
                        onClick = null,
                    )
                }
                SettingsNote(
                    "Free and open source, GPL-3.0. A star or a tip means a lot — thanks!",
                    inset,
                )
            }
        }
    }
}

/**
 * The one page here that is finished.
 *
 * Two axes, same as the iPhone: which of light and dark, and — because "dark"
 * means two different things on an OLED panel — which flavour of dark.
 */
@Composable
fun AppearancePage(nav: Navigator, bottomReserve: Dp) {
    val settings = LocalMozzSettings.current

    ListPage("Appearance", onBack = nav::back) { inset, _ ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            item {
                SettingsSection("Theme", inset) {
                    MozzAppearance.entries.forEachIndexed { index, option ->
                        if (index > 0) RowDivider(start = inset, end = inset)
                        ChoiceRow(
                            label = option.label,
                            selected = settings?.appearance == option,
                            inset = inset,
                            onClick = { settings?.appearance = option },
                        )
                    }
                }
            }
            item {
                SettingsSection("Dark Style", inset) {
                    MozzDarkStyle.entries.forEachIndexed { index, option ->
                        if (index > 0) RowDivider(start = inset, end = inset)
                        ChoiceRow(
                            label = option.label,
                            selected = settings?.darkStyle == option,
                            inset = inset,
                            onClick = { settings?.darkStyle = option },
                        )
                    }
                }
                SettingsNote(
                    "Dim is a neutral grey. Black is true black, which on this display means the pixels are off.",
                    inset,
                )
            }
        }
    }
}

/**
 * A page that exists so the shape of the app is visible before the work is done.
 *
 * Says what will be here rather than "coming soon" on its own — a page that
 * explains itself is a plan, a page that apologises is a hole.
 */
@Composable
fun SettingsSoonPage(title: String, promise: String, nav: Navigator) {
    ListPage(title, onBack = nav::back) { _, _ ->
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(
                modifier = Modifier.widthIn(max = 420.dp).padding(horizontal = 32.dp, vertical = 48.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                SoonTag()
                Spacer(Modifier.height(16.dp))
                Text(
                    promise,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}

/**
 * Which of a server's music libraries to mirror.
 *
 * Only ever a question when a server has more than one, which is why the page
 * says so rather than showing a list of one and asking someone to choose it. The
 * chosen library is saved and the account re-attached on it before the resync
 * runs — the core builds its backend at attach time, so a sync started before
 * that would still be pointed at the old one.
 */
@Composable
fun MusicLibrariesPage(
    account: ServerAccount,
    server: MozzServer,
    nav: Navigator,
    bottomReserve: Dp,
    onResync: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var libraries by remember { mutableStateOf<List<MusicLibrary>?>(null) }
    var selected by remember { mutableStateOf(account.musicSectionId) }
    var failure by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(account.serverId) {
        runCatching { server.libraries(account.serverId) }
            .onSuccess { libraries = it }
            .onFailure { failure = it.message ?: "Couldn't reach ${account.serverName}." }
    }

    ListPage("Music Library", onBack = nav::back) { inset, _ ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            val rows = libraries
            when {
                failure != null -> item { SettingsNote(failure!!, inset) }
                rows == null -> Unit          // still asking; an empty page beats a spinner that flashes
                rows.isEmpty() -> item {
                    SettingsNote("${account.serverName} has no music library.", inset)
                }
                else -> {
                    item {
                        SettingsSection(account.serverName, inset) {
                            rows.forEachIndexed { index, option ->
                                if (index > 0) RowDivider(start = inset, end = inset)
                                ChoiceRow(
                                    label = option.name,
                                    selected = option.id == selected,
                                    inset = inset,
                                    onClick = {
                                        if (option.id == selected) return@ChoiceRow
                                        selected = option.id
                                        scope.launch {
                                            runCatching { server.selectMusicLibrary(account, option.id) }
                                                .onSuccess { onResync() }
                                                .onFailure {
                                                    selected = account.musicSectionId
                                                    failure = it.message
                                                }
                                        }
                                    },
                                )
                            }
                        }
                        if (rows.size > 1) {
                            SettingsNote(
                                "Switching libraries re-mirrors the catalogue. Your likes and listening history stay.",
                                inset,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Everything the user has told the app to stop recommending, and a way to change
 * their mind.
 *
 * The reason this page exists at all is that the undo on the toast expires. A
 * decision you can only reverse in the five seconds after making it is not a
 * decision anyone can make comfortably.
 */
/**
 * What this device is keeping offline, and what it costs.
 *
 * Reads the records from the core rather than the filesystem, because a record
 * knows the track's title and a file only knows its own name. The one thing it
 * asks the filesystem is whether the bytes are actually there: a record can say
 * "downloaded" while the file has been cleared by the system, and a list that
 * claims music is available when it is not is worse than one that admits it.
 */
/**
 * Pairing this phone with the user's other devices.
 *
 * Two directions, one ceremony (ADR-0013). A phone that is not in a circle
 * waits to be let into one: it listens and advertises, and an established
 * device finds it. A phone that *is* in a circle goes looking, and hands the
 * circle to whatever it finds. Setup order therefore does not matter — phone
 * first and desktop first are the same exchange with the roles swapped.
 *
 * The six digits are shown on the page rather than in a dialog, because
 * comparing them is the whole ceremony: a person is holding two screens and
 * reading both, and a dialog that can be dismissed by tapping beside it is the
 * wrong shape for the one step that must not be waved through.
 */
@Composable
fun DevicesPage(
    pairing: PairingService,
    discovery: PairingDiscovery,
    nav: Navigator,
    bottomReserve: Dp,
) {
    val scope = rememberCoroutineScope()
    var inCircle by remember { mutableStateOf(pairing.hasCircle) }
    var candidates by remember { mutableStateOf<List<PairingCandidate>>(emptyList()) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    // Held rather than passed: the ceremony is suspended inside the pump
    // waiting on this, and the buttons that answer it are drawn from here.
    var digits by remember { mutableStateOf<String?>(null) }
    var answer by remember { mutableStateOf<CompletableDeferred<Boolean>?>(null) }

    suspend fun confirm(shown: String): Boolean {
        val pending = CompletableDeferred<Boolean>()
        digits = shown
        answer = pending
        return try {
            pending.await()
        } finally {
            digits = null
            answer = null
        }
    }

    LaunchedEffect(Unit) {
        // Only a device that already holds a circle has anything to give, so
        // only it goes looking. A fresh phone browsing would list devices it
        // could not admit.
        if (!pairing.hasCircle) return@LaunchedEffect
        discovery.watch().collectLatest { found ->
            if (candidates.none { it.host == found.host && it.port == found.port }) {
                candidates = candidates + found
            }
        }
    }

    ListPage("Devices", onBack = nav::back) { inset, _ ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            digits?.let { shown ->
                item {
                    SettingsSection("Do these match?", inset) {
                        Text(
                            shown.chunked(3).joinToString(" "),
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = inset, vertical = 10.dp),
                        )
                        Row(modifier = Modifier.padding(horizontal = inset)) {
                            TextButton(onClick = { answer?.complete(true) }) { Text("They match") }
                            Spacer(Modifier.width(12.dp))
                            TextButton(onClick = { answer?.complete(false) }) { Text("They don't") }
                        }
                    }
                    SettingsNote(
                        "The same six digits should be on the other device. If they differ, " +
                            "say so — nothing is shared until both sides agree.",
                        inset,
                    )
                }
            }

            status?.let { item { SettingsNote(it, inset) } }

            if (!inCircle) {
                item {
                    SettingsSection("This Device", inset) {
                        SettingsRow(
                            R.drawable.ic_cast,
                            if (busy) "Waiting for another device…" else "Add This Device",
                            inset,
                            onClick = {
                                if (busy) return@SettingsRow
                                busy = true
                                status = "Open Devices on a phone or computer that already has Mozz."
                                scope.launch {
                                    val result = runCatching { pairing.join(::confirm) }
                                    busy = false
                                    status = result.fold(
                                        onSuccess = { peer ->
                                            inCircle = true
                                            "Added to ${peer.name ?: "your other devices"}."
                                        },
                                        onFailure = { it.message ?: "Pairing did not finish." },
                                    )
                                }
                            },
                        )
                    }
                    SettingsNote(
                        "This phone is not sharing anything yet. Adding it lets your devices " +
                            "pass listening history and what they have analysed between them, " +
                            "without any of it going through a service.",
                        inset,
                    )
                }
            } else {
                item {
                    SettingsSection("Nearby", inset) {}
                    if (candidates.isEmpty()) {
                        SettingsNote(
                            "No devices waiting. On the device you want to add, open Settings › " +
                                "Devices and tap Add This Device.",
                            inset,
                        )
                    }
                }
                items(candidates, key = { "${it.host}:${it.port}" }) { candidate ->
                    SettingsRow(
                        R.drawable.ic_cast, candidate.name, inset,
                        detail = if (busy) null else "Add",
                        onClick = {
                            if (busy) return@SettingsRow
                            busy = true
                            status = null
                            scope.launch {
                                val result = runCatching { pairing.admit(candidate, null, ::confirm) }
                                busy = false
                                status = result.fold(
                                    onSuccess = { peer -> "${peer.name ?: candidate.name} added." },
                                    onFailure = { it.message ?: "Pairing did not finish." },
                                )
                            }
                        },
                    )
                }
            }
        }
    }
}

@Composable
fun DownloadsPage(
    downloads: MozzDownloads,
    nav: Navigator,
    bottomReserve: Dp,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<DownloadRecord>?>(null) }
    var usage by remember { mutableStateOf<StorageUsage?>(null) }

    suspend fun reload() {
        rows = runCatching { downloads.list() }.getOrDefault(emptyList())
        usage = runCatching { downloads.storageUsage() }.getOrNull()
    }
    LaunchedEffect(Unit) { reload() }

    ListPage("Downloads", onBack = nav::back) { inset, _ ->
        val items = rows
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            usage?.let { used ->
                item {
                    SettingsNote(
                        "${used.trackCount} ${if (used.trackCount == 1) "song" else "songs"} " +
                            "kept offline — ${formatBytes(used.totalBytes)}.",
                        inset,
                    )
                }
            }
            if (items != null && items.isEmpty()) {
                item {
                    SettingsNote(
                        "Nothing downloaded. Keep a song from its menu and it plays without the server.",
                        inset,
                    )
                }
            }
            items(items ?: emptyList(), key = { it.trackId }) { record ->
                DownloadRow(record) {
                    val serverId = record.serverId ?: return@DownloadRow
                    val remoteId = record.remoteId ?: return@DownloadRow
                    scope.launch {
                        DownloadWorker.cancel(context, serverId, remoteId)
                        runCatching { downloads.forget(serverId, remoteId) }
                        runCatching {
                            DownloadWorker.fileFor(context, serverId, remoteId).delete()
                        }
                        reload()
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadRow(record: DownloadRecord, onRemove: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                record.title ?: record.remoteId ?: "Unknown",
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                when {
                    record.state == "failed" ->
                        record.errorMessage?.let { "Failed — $it" } ?: "Failed"
                    record.isDownloaded -> formatBytes(record.sizeBytes)
                    // A percentage is only honest once something has said how
                    // big the file is; until then, say it is working.
                    record.fraction != null ->
                        "${((record.fraction ?: 0f) * 100).roundToInt()}%"
                    else -> "Waiting"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(onClick = onRemove) { Text("Remove") }
    }
}

/** Bytes as a person reads them. */
private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format("%.1f GB", bytes / 1_000_000_000.0)
    bytes >= 1_000_000 -> String.format("%.0f MB", bytes / 1_000_000.0)
    bytes >= 1_000 -> String.format("%.0f KB", bytes / 1_000.0)
    else -> "$bytes B"
}

@Composable
fun SuppressionsPage(
    account: ServerAccount,
    library: MozzLibrary,
    server: MozzServer,
    nav: Navigator,
    bottomReserve: Dp,
) {
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<Suppression>?>(null) }

    suspend fun reload() {
        items = runCatching { library.suppressions(account.serverId) }.getOrDefault(emptyList())
    }
    LaunchedEffect(account.serverId) { reload() }

    ListPage("Not Recommended", onBack = nav::back) { inset, _ ->
        val rows = items
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
            if (rows != null && rows.isEmpty()) {
                item {
                    SettingsNote(
                        "Nothing here. Anything you tell Mozz not to recommend — from a song's menu, or an artist's — shows up here so you can take it back.",
                        inset,
                    )
                }
            }
            items(rows ?: emptyList(), key = { "${'$'}{it.scope}:${'$'}{it.ref}" }) { item ->
                SuppressionRow(
                    item = item,
                    account = account,
                    server = server,
                    inset = inset,
                    onRestore = {
                        scope.launch {
                            runCatching {
                                if (item.isArtist) library.unsuppressArtist(account.serverId, item.ref)
                                else library.unsuppressTrack(account.serverId, item.ref)
                            }
                            reload()
                        }
                    },
                )
                RowDivider(start = inset, end = inset)
            }
        }
    }
}

@Composable
private fun SuppressionRow(
    item: Suppression,
    account: ServerAccount,
    server: MozzServer,
    inset: Dp,
    onRestore: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = inset, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            server = server,
            serverId = account.serverId,
            artworkKey = item.artworkKey,
            pixels = artworkPixels(44.dp),
            // An artist is a round portrait everywhere else in the app; it would
            // be strange for this one list to disagree.
            modifier = Modifier
                .size(44.dp)
                .clip(if (item.isArtist) CircleShape else RoundedCornerShape(6.dp)),
            shape = if (item.isArtist) CircleShape else RoundedCornerShape(6.dp),
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(item.label, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
            Text(
                item.subtitle?.takeIf { it.isNotEmpty() } ?: if (item.isArtist) "Artist" else "Song",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        Spacer(Modifier.width(12.dp))
        Text(
            "Restore",
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .clip(RoundedCornerShape(percent = 50))
                .clickable(onClick = onRestore)
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}

// MARK: - Pieces

/**
 * A group of rows on one card.
 *
 * Grouped onto a raised surface rather than separated by whitespace alone, which
 * is what makes a long settings page scannable — the same job iOS's grouped
 * `Form` does.
 */
/**
 * How much of the library the analyzer has listened to.
 *
 * Worth a row of its own because this is the one background job whose terms a
 * person can act on: "waiting for a charger" explains a number that would
 * otherwise look stuck.
 */
@Composable
private fun SonicAnalysisNote(progress: SonicProgress, inset: Dp) {
    val onBattery = LocalMozzSettings.current?.analyseOnBattery == true
    val done = progress.remaining == 0
    Column(modifier = Modifier.padding(horizontal = inset, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                when {
                    done -> "Library analysed"
                    progress.running -> "Listening to your library"
                    else -> "Analysis paused"
                },
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.weight(1f),
            )
            Text(
                "${(progress.fraction * 100).roundToInt()}%",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { progress.fraction },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(6.dp))
        Text(
            when {
                done -> "Every song analysed — radio can follow the sound, not just the tags."
                // A stalled count with no explanation is the one thing this row
                // must never show.
                progress.analyzed == 0 && progress.lastError != null ->
                    "Nothing analysed yet — ${progress.lastError}."
                progress.running -> "${progress.analyzed} of ${progress.total} songs analysed."
                // Never name a condition that is not actually holding it up.
                // Telling someone who has just allowed analysis on battery to
                // find a charger sends them after a cable that changes nothing.
                onBattery -> "Waiting for Wi-Fi — ${progress.remaining} songs to go."
                else -> "Waiting for a charger and Wi-Fi — ${progress.remaining} songs to go."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SettingsSection(
    title: String?,
    inset: Dp,
    content: @Composable ColumnScopeAlias.() -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(top = 22.dp)) {
        if (title != null) {
            Text(
                title,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = inset, end = inset, bottom = 8.dp),
            )
        }
        Column(
            modifier = Modifier
                .padding(horizontal = inset - 8.dp)
                .mozzSurface(RoundedCornerShape(14.dp)),
            content = content,
        )
    }
}

private typealias ColumnScopeAlias = androidx.compose.foundation.layout.ColumnScope

@Composable
private fun SettingsRow(
    icon: Int,
    title: String,
    inset: Dp,
    detail: String? = null,
    soon: Boolean = false,
    /** A chevron promises another page. An action that happens here has none. */
    showsChevron: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(22.dp).alpha(if (soon) 0.55f else 1f),
        )
        Spacer(Modifier.width(14.dp))
        Text(
            title,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f).alpha(if (soon) 0.65f else 1f),
        )
        if (soon) {
            SoonTag()
            Spacer(Modifier.width(8.dp))
        }
        if (detail != null) {
            Text(
                detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            Spacer(Modifier.width(6.dp))
        }
        if (onClick != null && showsChevron) {
            Icon(
                painterResource(R.drawable.ic_chevron_right),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/**
 * A switch that actually does something, as opposed to [SettingsToggle], which
 * is the disabled placeholder for controls whose feature has not landed.
 */
@Composable
private fun SettingsSwitch(
    icon: Int,
    title: String,
    inset: Dp,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(14.dp))
        Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun SettingsToggle(icon: Int, title: String, inset: Dp, soon: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(22.dp).alpha(if (soon) 0.55f else 1f),
        )
        Spacer(Modifier.width(14.dp))
        Text(
            title,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f).alpha(if (soon) 0.65f else 1f),
        )
        if (soon) {
            SoonTag()
            Spacer(Modifier.width(8.dp))
        }
        // Disabled rather than absent: the control belongs here, and showing
        // where it will sit is the whole point of the page existing early.
        Switch(
            checked = false,
            onCheckedChange = null,
            enabled = false,
            colors = SwitchDefaults.colors(
                disabledUncheckedTrackColor = MaterialTheme.colorScheme.outlineVariant,
                disabledUncheckedBorderColor = MaterialTheme.colorScheme.outline,
            ),
        )
    }
}

@Composable
private fun ChoiceRow(label: String, selected: Boolean, inset: Dp, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        if (selected) {
            Icon(
                painterResource(R.drawable.ic_check),
                contentDescription = "Selected",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/** The small print under a row, in iOS's voice and iOS's position. */
/**
 * Who the phone is signed in as.
 *
 * The iPhone and the desktop have both shown this for as long as they have had
 * a settings screen; Android showed the server's name and nothing about the
 * person. On a Plex Home with more than one profile that is the difference
 * between knowing whose library this is and guessing.
 *
 * The avatar is whatever the account has. A person with none gets their initial
 * rather than an empty circle, because a blank ring reads as something that
 * failed to load.
 */
@Composable
private fun AccountHeader(profile: ServerAccountProfile?, serverName: String, inset: Dp) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = inset, vertical = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            val avatar = profile?.avatarURL
            if (avatar != null) {
                AsyncImage(
                    model = avatar,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize().clip(CircleShape),
                )
            } else {
                Text(
                    profile?.label?.take(1)?.uppercase() ?: "?",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(
                profile?.label ?: "Signed in",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                serverName,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun SettingsNote(text: String, inset: Dp) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = inset, end = inset, top = 8.dp),
    )
}

/** Says "this is where it goes", without saying "this works". */
@Composable
private fun SoonTag() {
    Text(
        "Soon",
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .clip(RoundedCornerShape(percent = 50))
            .background(MaterialTheme.colorScheme.outlineVariant)
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

/** The settings entry point, in the slot iOS puts its account avatar. */
@Composable
fun SettingsButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(R.drawable.ic_account),
            contentDescription = "Settings",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(26.dp),
        )
    }
}

/** Slow enough to be free, quick enough that the count visibly moves. */
private const val SONIC_POLL_MS = 5_000L
