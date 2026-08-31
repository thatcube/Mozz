package com.thatcube.mozz.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.io.File
import java.util.UUID

/**
 * Signing in, mirroring a catalog, and turning a track into a playable URL.
 *
 * A thin, typed layer over [MozzCore]'s command dispatcher. It exists so the
 * rest of the app never composes a request by hand and never sees a magic
 * command string — those belong next to the types they produce, not scattered
 * through view models.
 *
 * It also owns the one thing the Swift core deliberately does not: persistence
 * of the auth token, via [SecretStore]. The core hands a token out of `connect`
 * and forgets it; this puts it in the Keystore and hands it back on the next
 * launch through `attach`.
 *
 * The direct counterpart of `clients/desktop/Core/MozzServer.cs`, and kept
 * deliberately close to it — two clients diverging in how they drive the same
 * core is how subtle differences in behaviour get in.
 */
class MozzServer(
    private val core: MozzCore,
    private val secrets: SecretStore,
    private val accountsFile: File,
) {

    // MARK: Sign-in

    /**
     * Jellyfin and Subsonic sign in with a username and password. Plex does not
     * — see [beginPlexLink].
     */
    suspend fun connect(
        kind: BackendKind,
        baseUrl: String,
        username: String,
        password: String? = null,
        apiKey: String? = null,
    ): ServerAccount {
        val identifier = clientIdentifier()
        val session: SessionPayload = core.require(
            CoreRequest(
                cmd = "connect",
                kind = kind.wire,
                baseURL = baseUrl,
                username = username,
                password = password,
                apiKey = apiKey,
                clientIdentifier = identifier,
            )
        )
        if (session.serverId.isEmpty() || session.token.isEmpty()) {
            // SessionPayload defaults its fields so an unfinished Plex poll can
            // decode; a `connect` that comes back that way is a real failure and
            // must not be persisted as an account with no server.
            throw MozzCoreException("$baseUrl did not return a usable session.")
        }
        return persist(session, username, identifier)
    }

    /**
     * Start Plex's PIN flow. The user opens [PlexLink.linkUrl] in a browser and
     * approves there — no password is ever typed into Mozz — then
     * [pollPlexLink] is called until it returns an account.
     */
    suspend fun beginPlexLink(): PlexLink {
        val pin: PlexPinPayload = core.require(
            CoreRequest(cmd = "plexPin", clientIdentifier = clientIdentifier())
        )
        return PlexLink(pin.pinId, pin.code, pin.clientIdentifier, pin.linkURL)
    }

    /**
     * Poll once. Returns null while the user has not finished linking, which is
     * the normal case for the first several seconds.
     */
    suspend fun pollPlexLink(link: PlexLink): ServerAccount? {
        val session: SessionPayload = core.call(
            CoreRequest(
                cmd = "plexPinCheck",
                pinId = link.pinId,
                code = link.code,
                clientIdentifier = link.clientIdentifier,
            )
        ) ?: return null

        // The core answers `{"url": null}` — which decodes to all-defaults —
        // for "not linked yet". That is the normal case for the first several
        // seconds, so it is a null return rather than an error.
        if (session.token.isEmpty() || session.serverId.isEmpty()) return null
        return persist(session, username = null, identifier = link.clientIdentifier)
    }

    /**
     * Poll until the user finishes linking, or until [timeoutMillis] elapses.
     * Plex's PIN is short-lived, so this gives up rather than polling forever.
     *
     * Two things this has to survive, both learned the hard way:
     *
     * **Rate limiting.** Plex answers 429 if the PIN is checked too eagerly, and
     * it counts every client — a second device (or a stale session left polling)
     * spends the same budget. So a failed poll backs off exponentially instead of
     * hammering at a fixed interval.
     *
     * **Transient failures are not link failures.** A 429, or a dropped Wi-Fi
     * packet, means "ask again later", not "the user declined". Only the deadline
     * ends this loop unhappily; anything else is retried, and the last error is
     * reported if time runs out so the reason is not lost.
     */
    suspend fun awaitPlexLink(
        link: PlexLink,
        timeoutMillis: Long = 5 * 60 * 1000,
        pollMillis: Long = 2000,
        maxBackoffMillis: Long = 15000,
    ): ServerAccount {
        val deadline = System.currentTimeMillis() + timeoutMillis
        var wait = pollMillis
        var lastError: Throwable? = null

        while (System.currentTimeMillis() < deadline) {
            val outcome = runCatching { pollPlexLink(link) }
            outcome.getOrNull()?.let { return it }

            if (outcome.isSuccess) {
                // Not linked yet: the ordinary case. Keep the steady interval.
                wait = pollMillis
            } else {
                lastError = outcome.exceptionOrNull()
                wait = (wait * 2).coerceAtMost(maxBackoffMillis)
            }
            delay(wait)
        }

        throw MozzCoreException(
            lastError?.let { "Plex did not confirm the link: ${it.message}" }
                ?: "The Plex link expired before it was approved."
        )
    }

    // MARK: Attach

    /**
     * Give the core the credentials for a saved account so sync and playback
     * work. Called at launch for every saved account.
     */
    suspend fun attach(account: ServerAccount) {
        val secret = secrets.get(secretKey(account.serverId))
            ?: throw MozzCoreException(
                "No stored credential for ${account.serverName}. Sign in again."
            )

        core.call<Map<String, String>>(
            CoreRequest(
                cmd = "attach",
                kind = account.kind.wire,
                baseURL = account.baseUrl,
                token = secret,
                userID = account.userId,
                username = account.username,
                serverName = account.serverName,
                clientIdentifier = account.clientIdentifier,
                musicSectionID = account.musicSectionId,
            )
        )
    }

    /**
     * Attach an account and leave it ready to sync.
     *
     * Plex addresses its catalog by library section, and a newly linked account
     * has none — the PIN flow yields an account and a server, never a section.
     * Syncing in that state fails with "Plex music section not resolved". So
     * resolve it once, save it, and re-attach, because the core builds its
     * backend at attach time and the one built above still has no section.
     * Returns the account to sync with, which may differ from the one passed in.
     */
    suspend fun attachForSync(account: ServerAccount): ServerAccount {
        attach(account)

        if (account.kind != BackendKind.PLEX || !account.musicSectionId.isNullOrEmpty()) {
            return account
        }

        // Needs the attach above: `libraries` resolves against an attached
        // backend. For Plex it reads library/sections directly, so it does not
        // itself need a section.
        val libraries = libraries(account.serverId)
        if (libraries.isEmpty()) {
            throw MozzCoreException("${account.serverName} has no music library for Mozz to sync.")
        }

        val resolved = account.copy(musicSectionId = libraries.first().id)
        saveAccount(resolved)
        attach(resolved)
        return resolved
    }

    suspend fun libraries(serverId: String): List<MusicLibrary> =
        core.call<List<MusicLibrary>>(CoreRequest(cmd = "libraries", serverId = serverId))
            ?: emptyList()

    suspend fun selectMusicLibrary(account: ServerAccount, libraryId: String): ServerAccount {
        if (libraryId.isBlank()) return account
        val updated = account.copy(musicSectionId = libraryId)
        saveAccount(updated)
        attach(updated)
        return updated
    }

    // MARK: Sync

    /**
     * Run a sync to completion, emitting progress as it goes.
     *
     * Polls rather than taking a callback because the C ABI is synchronous —
     * there is no way for the core to call back into Kotlin mid-command. The
     * flow completes when the sync finishes and throws if it fails.
     */
    fun sync(serverId: String, pollMillis: Long = 400): Flow<SyncStatus> = flow {
        val start: SyncStart? = core.call(CoreRequest(cmd = "sync", serverId = serverId))
        if (start != null && !start.started) {
            throw MozzCoreException("Sync did not start: ${start.reason ?: "no reason given"}")
        }

        while (true) {
            delay(pollMillis)
            val status: SyncStatus = core.call(
                CoreRequest(cmd = "syncStatus", serverId = serverId)
            ) ?: continue

            emit(status)
            if (!status.finished) continue
            status.error?.takeIf { it.isNotEmpty() }?.let { throw MozzCoreException(it) }
            return@flow
        }
    }

    // MARK: Playback

    suspend fun stream(
        serverId: String,
        remoteId: String,
        maxBitrateKbps: Int? = null,
    ): StreamSource = core.require(
        CoreRequest(
            cmd = "streamURL",
            serverId = serverId,
            remoteId = remoteId,
            maxBitrateKbps = maxBitrateKbps,
        )
    )

    suspend fun artworkUrl(serverId: String, artworkKey: String, size: Int = 512): String? =
        core.call<UrlPayload>(
            CoreRequest(
                cmd = "artworkURL",
                serverId = serverId,
                artworkKey = artworkKey,
                size = size,
            )
        )?.url

    /**
     * What the attached server can do.
     *
     * Worth asking rather than inferring: the like control differs per backend —
     * a heart on Jellyfin, a star on Plex, both on Subsonic — and a client that
     * guessed from the backend's name would be wrong the first time a server grew
     * a feature. The core fetches this once per session and remembers it.
     */
    suspend fun capabilities(serverId: String): ServerCapabilities? {
        val fresh = core.call<ServerCapabilities>(
            CoreRequest(cmd = "capabilities", serverId = serverId)
        )
        if (fresh != null) rememberCapabilities(serverId, fresh)
        return fresh
    }

    /**
     * What this server could do last time it was asked.
     *
     * Answering this needs a network round trip, and until it lands a client has
     * to either show nothing or guess. Guessing is worse than waiting: a heart
     * that turns into a star a moment later has told the user something false
     * about their own library. Remembering the last answer means the question is
     * only ever open on the very first run.
     *
     * Deliberately separate from the account file. Capabilities are a fact about
     * the server that we cache, not part of the identity we signed in with, and
     * losing this file costs one round trip rather than an account.
     */
    fun cachedCapabilities(serverId: String): ServerCapabilities? {
        if (!capabilitiesFile.exists()) return null
        return try {
            MozzCore.json
                .decodeFromString<Map<String, ServerCapabilities>>(capabilitiesFile.readText())[serverId]
        } catch (error: Exception) {
            null
        }
    }

    private fun rememberCapabilities(serverId: String, value: ServerCapabilities) {
        val existing = try {
            if (capabilitiesFile.exists()) {
                MozzCore.json.decodeFromString<Map<String, ServerCapabilities>>(
                    capabilitiesFile.readText()
                )
            } else {
                emptyMap()
            }
        } catch (error: Exception) {
            emptyMap()
        }
        runCatching {
            capabilitiesFile.writeText(
                MozzCore.json.encodeToString(existing + (serverId to value))
            )
        }
    }

    private val capabilitiesFile: java.io.File
        get() = java.io.File(accountsFile.parentFile, "capabilities.json")

    // MARK: Saved accounts

    /**
     * The accounts this installation knows about. Non-secret: the token itself
     * is in the Keystore, and this file holds only what is needed to look it up
     * and to label the account in the UI.
     */
    fun savedAccounts(): List<ServerAccount> {
        if (!accountsFile.exists()) return emptyList()
        return try {
            MozzCore.json.decodeFromString<List<ServerAccount>>(accountsFile.readText())
        } catch (error: Exception) {
            // A corrupt accounts file must not brick the app. The tokens are
            // still in the Keystore; the worst case is signing in again.
            emptyList()
        }
    }

    fun forgetAccount(serverId: String) {
        writeAccounts(savedAccounts().filterNot { it.serverId == serverId })
        secrets.set(secretKey(serverId), null)
        secrets.set(plexAccountKey(serverId), null)
    }

    fun forgetAllAccounts() {
        savedAccounts().forEach {
            secrets.set(secretKey(it.serverId), null)
            secrets.set(plexAccountKey(it.serverId), null)
        }
        writeAccounts(emptyList())
    }

    /** Insert or replace one account, leaving the others alone. */
    fun saveAccount(account: ServerAccount) {
        writeAccounts(savedAccounts().filterNot { it.serverId == account.serverId } + account)
    }

    private fun persist(
        session: SessionPayload,
        username: String?,
        identifier: String,
    ): ServerAccount {
        val account = ServerAccount(
            serverId = session.serverId,
            kind = BackendKind.parse(session.kind),
            baseUrl = session.baseURL,
            serverName = session.serverName,
            userId = session.userID,
            username = username,
            clientIdentifier = session.clientIdentifier.ifEmpty { identifier },
            musicSectionId = null,
        )

        secrets.set(secretKey(account.serverId), session.token)
        session.accountToken?.takeIf { it.isNotEmpty() }?.let {
            // Plex's account token is distinct from the per-server access token
            // and is what re-discovers the account's other servers later.
            secrets.set(plexAccountKey(account.serverId), it)
        }

        saveAccount(account)
        return account
    }

    private fun writeAccounts(accounts: List<ServerAccount>) {
        accountsFile.parentFile?.mkdirs()
        accountsFile.writeText(MozzCore.json.encodeToString(accounts))
    }

    /**
     * A stable per-installation id. Servers show it in their device list, so it
     * has to survive restarts — a new one each launch litters someone's Plex
     * account with dozens of "Mozz on Android" entries.
     */
    private fun clientIdentifier(): String {
        secrets.get(CLIENT_IDENTIFIER)?.takeIf { it.isNotEmpty() }?.let { return it }
        return UUID.randomUUID().toString().also { secrets.set(CLIENT_IDENTIFIER, it) }
    }

    private companion object {
        const val CLIENT_IDENTIFIER = "clientIdentifier"
        fun secretKey(serverId: String) = "token.$serverId"
        fun plexAccountKey(serverId: String) = "plex.account.$serverId"
    }
}
