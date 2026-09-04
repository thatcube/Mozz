package com.thatcube.mozz.analysis

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.thatcube.mozz.MozzApplication
import kotlinx.coroutines.delay
import java.util.concurrent.TimeUnit

/**
 * Analysis that keeps going when the app does not.
 *
 * Nine thousand tracks is hours, and nobody sits with a music app open for
 * hours — so as long as this only ran on screen it was never going to finish.
 * The work itself is unchanged: the same resumable pass in the Swift core,
 * which stores each vector as it goes and picks up wherever it stopped.
 *
 * `WorkManager` rather than a foreground service because the conditions ARE the
 * feature. Charging and unmetered are constraints the system understands: it
 * runs the job when they hold, stops it the moment they lapse, and starts it
 * again later without a notification sitting in the shade claiming the app is
 * busy. A ten-minute execution window is no obstacle to work that is designed
 * to be interrupted — [doWork] simply returns and the next window continues.
 *
 * Periodic at the minimum interval, and each firing works one bounded shift
 * before yielding, so a plugged-in phone chews through a library over a night
 * or two of ordinary charging without anybody deciding to let it — and without
 * spending the timeout quota that would make its background work unreliable.
 */
class SonicAnalysisWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? MozzApplication ?: return Result.success()
        val server = app.server
        val account = server.savedAccounts().firstOrNull() ?: return Result.success()

        // The core forgets tokens between processes, and this one may have been
        // started by the scheduler with no UI ever having run.
        runCatching { server.attach(account) }.onFailure {
            Log.w(TAG, "cannot attach for analysis", it)
            return Result.retry()
        }

        runCatching { server.analyzeSonics(account.serverId, SonicWeights.path(applicationContext)) }.onFailure {
            Log.w(TAG, "cannot start analysis", it)
            return Result.retry()
        }

        // Hold the worker open while the pass runs — returning would end the
        // process's claim on the CPU — but only for a bounded stretch.
        //
        // WorkManager kills a job at around ten minutes, and Android counts
        // those kills: a device that had been analysing for a while showed 17
        // timeouts against a quota of 3, which puts the whole app in a
        // restricted bucket and makes every future job harder to schedule. The
        // work is resumable by design, so the right shape is a short shift
        // followed by a clean exit and a fresh job later, not one job that
        // tries to finish a library.
        val deadline = System.currentTimeMillis() + SHIFT_MS
        while (!isStopped && System.currentTimeMillis() < deadline) {
            delay(POLL_MS)
            val progress = runCatching {
                server.sonicProgress(account.serverId, SonicWeights.path(applicationContext))
            }.getOrNull() ?: continue
            if (!progress.running) {
                Log.i(TAG, "analysis idle at ${progress.analyzed}/${progress.total}")
                return Result.success()
            }
        }
        // Stop cleanly whether the shift ended or a constraint lapsed. Vectors
        // already written stay written; the next job picks up from them.
        runCatching { server.cancelSonics() }
        Log.i(TAG, if (isStopped) "stopped by the system" else "shift over, yielding")
        return Result.success()
    }

    companion object {
        private const val TAG = "MozzSonic"
        private const val POLL_MS = 10_000L

        /**
         * How long one shift lasts.
         *
         * Comfortably inside the roughly ten minutes WorkManager allows, so the
         * job ends on its own terms rather than being killed — a killed job
         * counts against a quota that, once spent, makes the app's background
         * work unreliable for a day.
         */
        private const val SHIFT_MS = 8 * 60 * 1000L
        private const val WORK_NAME = "mozz.sonic-analysis"

        /**
         * Register the recurring job. Idempotent — `KEEP` means an existing
         * schedule survives app restarts rather than being reset by each one.
         */
        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiresCharging(true)
                .setRequiredNetworkType(NetworkType.UNMETERED)
                .setRequiresBatteryNotLow(true)
                .build()
            val request = PeriodicWorkRequestBuilder<SonicAnalysisWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        /** Stop scheduling it — the Settings switch, once there is one. */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }
}
