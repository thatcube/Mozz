package com.thatcube.mozz.downloads

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.thatcube.mozz.MozzApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Fetches one track and reports what happened.
 *
 * The core keeps the record; this moves the bytes. It resolves a stream URL,
 * writes the file into this app's own storage, and tells the core how far it
 * got — which is what turns a queued download into an active one, and finally
 * into a finished one.
 *
 * `WorkManager` rather than a plain coroutine because a download outlives the
 * screen that asked for it and should survive the app being backgrounded or
 * killed. Unmetered by default for the same reason analysis is: a library is a
 * lot of bytes and a cellular plan is a bill.
 */
class DownloadWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val app = applicationContext as MozzApplication
        val serverId = inputData.getString(KEY_SERVER_ID) ?: return@withContext Result.failure()
        val remoteId = inputData.getString(KEY_REMOTE_ID) ?: return@withContext Result.failure()

        val destination = fileFor(applicationContext, serverId, remoteId)
        val partial = File(destination.path + ".part")
        try {
            val source = app.server.stream(serverId, remoteId)
            destination.parentFile?.mkdirs()

            val connection = (URL(source.url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 30_000
            }
            val total = connection.contentLengthLong.takeIf { it > 0 }

            connection.inputStream.use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var received = 0L
                    var lastReported = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        received += read
                        // Reported about every quarter megabyte rather than on
                        // every buffer: each report is a round trip through the
                        // core, and no progress bar can show more than that.
                        if (received - lastReported >= PROGRESS_STEP_BYTES) {
                            app.downloads.reportProgress(serverId, remoteId, received, total)
                            lastReported = received
                        }
                        if (isStopped) {
                            // Cancelled: leave no half file claiming to be music.
                            partial.delete()
                            return@withContext Result.failure()
                        }
                    }
                }
            }
            // Renamed only once the last byte is written, so a file that exists
            // is a file that is whole. A crash mid-transfer leaves a .part,
            // which nothing will ever try to play.
            partial.renameTo(destination)
            app.downloads.complete(serverId, remoteId, destination.path, destination.length())
            Result.success()
        } catch (error: Exception) {
            Log.w(TAG, "download failed for $remoteId", error)
            runCatching {
                app.downloads.fail(serverId, remoteId, error.message ?: "download failed")
            }
            partial.delete()
            // Retried by WorkManager: a download that failed because the wifi
            // dropped should not need asking for again.
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    companion object {
        private const val TAG = "MozzDownloads"
        private const val KEY_SERVER_ID = "serverId"
        private const val KEY_REMOTE_ID = "remoteId"
        private const val PROGRESS_STEP_BYTES = 256L * 1024
        private const val MAX_ATTEMPTS = 3

        /**
         * Where a downloaded track lives.
         *
         * Inside the app's own files directory, so uninstalling takes the music
         * with it and no storage permission is needed to write it. Named by
         * server and remote id rather than by title: two tracks can share a
         * title, and a file has to be findable from a record.
         */
        fun fileFor(context: Context, serverId: String, remoteId: String): File =
            File(File(context.filesDir, "downloads/${serverId.safeFileName()}"),
                 "${remoteId.safeFileName()}.audio")

        /** One unique job per track, so asking twice does not fetch twice. */
        fun enqueue(
            context: Context,
            serverId: String,
            remoteId: String,
            allowMetered: Boolean = false,
        ) {
            val request = OneTimeWorkRequestBuilder<DownloadWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(KEY_SERVER_ID, serverId)
                        .putString(KEY_REMOTE_ID, remoteId)
                        .build()
                )
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(
                            if (allowMetered) NetworkType.CONNECTED else NetworkType.UNMETERED
                        )
                        .build()
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                workName(serverId, remoteId), ExistingWorkPolicy.KEEP, request
            )
        }

        fun cancel(context: Context, serverId: String, remoteId: String) {
            WorkManager.getInstance(context).cancelUniqueWork(workName(serverId, remoteId))
        }

        private fun workName(serverId: String, remoteId: String) = "download:$serverId:$remoteId"

        /**
         * A remote id is whatever the server says it is — Plex's are numbers,
         * Jellyfin's are hex — and neither is promised to be safe as a file
         * name. A slash would silently write somewhere else entirely.
         */
        private fun String.safeFileName(): String =
            map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }.joinToString("")
    }
}
