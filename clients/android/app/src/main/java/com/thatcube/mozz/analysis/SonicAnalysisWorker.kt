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
 * Periodic at the minimum interval, so a plugged-in phone chews through a
 * library over a night or two of ordinary charging without anybody deciding to
 * let it.
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

        // Hold the worker open while the pass runs, because returning would end
        // the process's claim on the CPU. `isStopped` goes true when a
        // constraint lapses or the window closes; cancelling then is what keeps
        // a pulled charger from costing someone their battery.
        while (!isStopped) {
            delay(POLL_MS)
            val progress = runCatching { server.sonicProgress(account.serverId, SonicWeights.path(applicationContext)) }.getOrNull() ?: continue
            if (!progress.running) {
                Log.i(TAG, "analysis idle at ${progress.analyzed}/${progress.total}")
                return Result.success()
            }
        }
        runCatching { server.cancelSonics() }
        return Result.success()
    }

    companion object {
        private const val TAG = "MozzSonic"
        private const val POLL_MS = 10_000L
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
