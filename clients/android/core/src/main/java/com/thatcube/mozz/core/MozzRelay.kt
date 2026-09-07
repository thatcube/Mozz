package com.thatcube.mozz.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What a catalog sync moved.
 *
 * [importedFeatures] is the number that matters most on a phone: every one of
 * those is a track this device now never has to analyse, and analysis costs a
 * phone an evening — sixteen hours for ten thousand tracks on ADR-0018's
 * numbers.
 */
@Serializable
data class RelayCatalogSync(
    val status: String = "",
    val counts: RelayCatalogCounts = RelayCatalogCounts(),
    val published: Boolean = false,
    val importedFavorites: Int = 0,
    val importedFeatures: Int = 0,
    val publishedFeatures: Int = 0,
    /** Replacement capability after provisioning or renewal — persist it. */
    val relayKey: String = "",
    val expiresAtMS: Long = 0,
)

@Serializable
data class RelayCatalogCounts(
    val artists: Int = 0,
    val albums: Int = 0,
    val tracks: Int = 0,
    val playlists: Int = 0,
    val playlistItems: Int = 0,
    val features: Int = 0,
)

/**
 * One server as the circle knows it.
 *
 * Carries the credential, which is the point: a device that joins should be
 * able to play music without its owner finding a password again. [removedAtMS]
 * is how a sign-out travels — a record that vanished would simply be restored
 * by the next device to publish, so removal has to be a fact rather than an
 * absence.
 */
@Serializable
data class RelayServerRecord(
    val id: String,
    val kind: String,
    val name: String? = null,
    @SerialName("baseURL") val baseUrl: String? = null,
    val token: String? = null,
    val accountToken: String? = null,
    @SerialName("userID") val userId: String? = null,
    val username: String? = null,
    val serverMachineIdentifier: String? = null,
    @SerialName("musicSectionIDs") val musicSectionIds: List<String>? = null,
    val allMusicLibraries: Boolean? = null,
    val updatedAtMS: Long = 0,
    val removedAtMS: Long? = null,
) {
    val isRemoved: Boolean get() = removedAtMS != null
}

/** A device in the circle, by the name a person would recognise. */
@Serializable
data class RelayMemberRecord(
    @SerialName("deviceID") val deviceId: String,
    val name: String? = null,
    val updatedAtMS: Long = 0,
    val removedAtMS: Long? = null,
)

@Serializable
data class RelayServerSync(
    val servers: List<RelayServerRecord> = emptyList(),
    val members: List<RelayMemberRecord> = emptyList(),
    val relayKey: String = "",
    val expiresAtMS: Long = 0,
)

@Serializable
data class RelayPlaybackSettingsSync(
    val settings: PlaybackSettings = PlaybackSettings(),
    /** True when the circle's answer differed from what this device held. */
    val changed: Boolean = false,
    val relayKey: String = "",
    val expiresAtMS: Long = 0,
)

@Serializable
data class RelayHistorySync(
    val imported: Int = 0,
    val relayKey: String = "",
    val expiresAtMS: Long = 0,
)

/**
 * Moving what this device knows between the devices in its circle.
 *
 * The relay is a dumb encrypted store: the endpoint holds ciphertext under the
 * circle's keys and can read none of it (ADR-0012). Everything here needs a
 * circle, which is what [MozzPairing] establishes.
 */
class MozzRelay(private val core: MozzCore) {

    /**
     * Listening history, both directions.
     *
     * Run first: it is what provisions the relay capability when a circle has
     * none, and both calls need one.
     */
    suspend fun syncHistory(
        circle: CircleSecrets,
        deviceId: String,
        deviceName: String,
        endpoint: String = DEFAULT_ENDPOINT,
    ): RelayHistorySync? = core.call(
        CoreRequest(
            cmd = "relaySyncHistory",
            circle = circle,
            deviceId = deviceId,
            deviceName = deviceName,
            relayEndpoint = endpoint,
        )
    )

    /**
     * The catalog, the favourites, and the analysed vectors.
     *
     * The vectors are the reason this exists on a phone. A vector computed on
     * one device belongs in the same index as the same track computed on
     * another — both engines are free of every platform framework for exactly
     * that reason — so a phone that joins a circle should not repeat an evening
     * of work to arrive at bytes another device already has.
     */
    suspend fun syncCatalog(
        circle: CircleSecrets,
        deviceId: String,
        serverId: String,
        musicSectionIds: List<String>? = null,
        allMusicLibraries: Boolean = musicSectionIds.isNullOrEmpty(),
        endpoint: String = DEFAULT_ENDPOINT,
    ): RelayCatalogSync? = core.call(
        CoreRequest(
            cmd = "relaySyncCatalog",
            circle = circle,
            deviceId = deviceId,
            serverId = serverId,
            musicSectionIDs = musicSectionIds,
            allMusicLibraries = allMusicLibraries,
            relayEndpoint = endpoint,
        )
    )

    /**
     * Equalizer and loudness levelling, both directions.
     *
     * These are core behaviour, not shell behaviour — sound may not differ
     * between a listener's devices — so they travel with everything else. The
     * seed is what this device holds today; the answer is what the circle
     * agreed, which may be what somebody chose on their desktop.
     */
    suspend fun syncPlaybackSettings(
        circle: CircleSecrets,
        deviceId: String,
        settings: PlaybackSettings,
        endpoint: String = DEFAULT_ENDPOINT,
    ): RelayPlaybackSettingsSync? = core.call(
        CoreRequest(
            cmd = "relaySyncPlaybackSettings",
            circle = circle,
            deviceId = deviceId,
            playbackSettings = settings,
            relayEndpoint = endpoint,
        )
    )

    /**
     * The servers this listener is signed in to, and who is in the circle.
     *
     * The fourth thing ADR-0013 says pairing unblocks: a new phone or PC
     * getting the user's servers without anyone retyping a password. What
     * travels is what the relay always carries — ciphertext under the circle's
     * keys — and the merge happens in the core, so this side only says what it
     * has and applies what comes back.
     */
    suspend fun syncServers(
        circle: CircleSecrets,
        deviceId: String,
        servers: List<RelayServerRecord>,
        members: List<RelayMemberRecord> = emptyList(),
        endpoint: String = DEFAULT_ENDPOINT,
    ): RelayServerSync? = core.call(
        CoreRequest(
            cmd = "relaySyncServers",
            circle = circle,
            deviceId = deviceId,
            servers = servers,
            members = members,
            relayEndpoint = endpoint,
        )
    )

    companion object {
        const val DEFAULT_ENDPOINT = "https://relay.mozzmusic.com"
    }
}
