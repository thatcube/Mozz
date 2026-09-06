package com.thatcube.mozz.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** A Mozz device found on the network, waiting to be paired. */
data class PairingCandidate(val name: String, val host: String, val port: Int)

/**
 * Finds devices advertising `_mozz._tcp`.
 *
 * The joining device advertises, because it is the one asking to be let in;
 * this side goes looking, because it is the one holding something worth giving.
 * Several may answer at once in a house with more than one Mozz device, so this
 * reports all of them and the caller tries each — a device that is not the one
 * whose code was scanned is rejected by the core, so "wrong device" and
 * "impostor" need no separate handling here.
 */
class PairingDiscovery(context: Context) {

    private val manager =
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    /**
     * Emits each device once, until the collector stops.
     *
     * Resolution is a second round trip, and a service that fails to resolve is
     * dropped rather than reported without an address: a row that cannot be
     * connected to is worse than no row.
     */
    fun watch(): Flow<PairingCandidate> = callbackFlow {
        val seen = mutableSetOf<String>()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                if (!seen.add(info.serviceName)) return
                resolve(info) { candidate -> trySend(candidate) }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                // Allowed back in: a device that dropped off while its screen
                // was still open is one someone is very likely still trying to
                // pair with.
                seen.remove(info.serviceName)
            }

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "could not browse for devices (error $errorCode)")
                close()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }

        manager.discoverServices(
            PairingHost.SERVICE_TYPE,
            NsdManager.PROTOCOL_DNS_SD,
            listener,
        )
        awaitClose { runCatching { manager.stopServiceDiscovery(listener) } }
    }

    /**
     * `resolveService` is deprecated from API 34 in favour of
     * `registerServiceInfoCallback`, which needs API 34. This app runs from 28,
     * and the deprecated call still resolves on every level it supports, so one
     * path is honest where two would be ceremony.
     */
    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo, onResolved: (PairingCandidate) -> Unit) {
        manager.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "could not resolve ${info.serviceName} (error $errorCode)")
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val address = info.host?.hostAddress ?: return
                onResolved(PairingCandidate(info.serviceName, address, info.port))
            }
        })
    }

    private companion object {
        const val TAG = "MozzPairing"
    }
}
