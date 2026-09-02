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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.foundation.lazy.items
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.MusicLibrary
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
    nav: Navigator,
    bottomReserve: Dp,
    onResync: () -> Unit,
    onSignOut: () -> Unit,
) {
    val context = LocalContext.current
    fun open(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
    }

    ListPage("Settings", onBack = nav::back) { inset, _ ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = bottomReserve + 24.dp),
        ) {
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
                    SettingsRow(
                        R.drawable.ic_more, "Not Recommended", inset,
                        onClick = { nav.open(Route.SettingsSuppressions) },
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
