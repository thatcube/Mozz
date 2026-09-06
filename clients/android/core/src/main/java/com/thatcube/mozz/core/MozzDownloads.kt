package com.thatcube.mozz.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Keeping tracks for offline.
 *
 * The split is deliberate and it is the reason this class is thin: the core
 * keeps the record and this side moves the bytes. Nothing here decides what
 * "downloaded" means, when a queued transfer becomes an active one, or what a
 * late progress report does to a finished download — that lives in the core,
 * once, so the phone and the desktop cannot disagree about the state of
 * somebody's library.
 *
 * What this side owns is the part the core deliberately does not: fetching,
 * where the file goes, and deleting it again.
 */
class MozzDownloads(private val core: MozzCore) {

    /** Ask for a track to be kept offline. Returns the record it created. */
    suspend fun enqueue(serverId: String, remoteId: String): DownloadRecord? =
        core.call(CoreRequest(cmd = "enqueueDownload", serverId = serverId, remoteId = remoteId))

    /**
     * Every download, or only those in the given states.
     *
     * Used for the downloads screen and to decide, at play time, whether a
     * track has a file waiting for it.
     */
    suspend fun list(states: List<String>? = null): List<DownloadRecord> =
        core.call<List<DownloadRecord>>(CoreRequest(cmd = "downloads", states = states))
            ?: emptyList()

    /**
     * One track's download.
     *
     * "Absent" rather than an error for a track nobody has downloaded — asking
     * once per row is the ordinary case, and never having been asked for is not
     * a failure.
     */
    suspend fun status(serverId: String, remoteId: String): DownloadRecord? =
        core.call(CoreRequest(cmd = "downloadStatus", serverId = serverId, remoteId = remoteId))

    suspend fun reportProgress(
        serverId: String,
        remoteId: String,
        receivedBytes: Long,
        totalBytes: Long?,
    ): DownloadRecord? = core.call(
        CoreRequest(
            cmd = "reportDownloadProgress",
            serverId = serverId,
            remoteId = remoteId,
            receivedBytes = receivedBytes,
            totalBytes = totalBytes,
        )
    )

    /** [localPath] is this platform's business; the core only records it. */
    suspend fun complete(
        serverId: String,
        remoteId: String,
        localPath: String,
        sizeBytes: Long,
    ): DownloadRecord? = core.call(
        CoreRequest(
            cmd = "completeDownload",
            serverId = serverId,
            remoteId = remoteId,
            localPath = localPath,
            sizeBytes = sizeBytes,
        )
    )

    suspend fun fail(serverId: String, remoteId: String, reason: String): DownloadRecord? =
        core.call(
            CoreRequest(
                cmd = "failDownload",
                serverId = serverId,
                remoteId = remoteId,
                reason = reason,
            )
        )

    /**
     * Forget the record. The file is this side's to delete, because this side
     * is what wrote it and the only thing that knows where.
     */
    suspend fun forget(serverId: String, remoteId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "deleteDownload", serverId = serverId, remoteId = remoteId)
        )
    }

    suspend fun storageUsage(): StorageUsage? =
        core.call(CoreRequest(cmd = "storageUsage"))
}

/** One track's download, as the core records it. */
@Serializable
data class DownloadRecord(
    val trackId: Long = 0,
    val remoteId: String? = null,
    val serverId: String? = null,
    val title: String? = null,
    /** queued, downloading, downloaded, failed — or absent, for never asked. */
    val state: String = "absent",
    /** Where this device put the file, relative to its downloads directory. */
    val localPath: String? = null,
    /** Bytes received so far; the final size once complete. */
    val sizeBytes: Long = 0,
    val totalBytes: Long? = null,
    val requestedAt: Double = 0.0,
    val completedAt: Double? = null,
    val errorMessage: String? = null,
) {
    val isDownloaded: Boolean get() = state == "downloaded"
    val isInFlight: Boolean get() = state == "queued" || state == "downloading"

    /** 0..1, or null while nothing has said how big the file is. */
    val fraction: Float?
        get() {
            val total = totalBytes ?: return null
            if (total <= 0) return null
            return (sizeBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }
}

@Serializable
data class StorageUsage(
    @SerialName("downloadedTrackCount") val trackCount: Int = 0,
    val totalBytes: Long = 0,
)
