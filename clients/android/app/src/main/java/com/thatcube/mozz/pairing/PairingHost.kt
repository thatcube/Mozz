package com.thatcube.mozz.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.net.ServerSocket

/**
 * A phone with no circle, waiting to be let into one.
 *
 * The reverse of [PairingDiscovery]. The device asking to be admitted listens
 * and advertises; an established device opens its own Devices screen, finds
 * this one and connects. That makes setup order irrelevant — phone first and
 * desktop first are the same ceremony with the roles swapped.
 */
class PairingHost private constructor(
    private val manager: NsdManager,
    private val socket: ServerSocket,
    private val registration: NsdManager.RegistrationListener,
) : Closeable {

    val port: Int get() = socket.localPort

    /** Blocks until the other device connects. */
    suspend fun accept(): PairingLink = withContext(Dispatchers.IO) {
        PairingLink(socket.accept())
    }

    override fun close() {
        runCatching { manager.unregisterService(registration) }
        runCatching { socket.close() }
    }

    companion object {
        /** The same service the desktop advertises and the iPhone browses for. */
        const val SERVICE_TYPE = "_mozz._tcp"

        fun start(context: Context, name: String): PairingHost {
            val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
            // Port 0: the system picks one and tells us, which is then what goes
            // in the advertisement. A fixed port would collide with a second
            // Mozz on the same device and, worse, with anything else.
            val socket = ServerSocket(0)
            val info = NsdServiceInfo().apply {
                serviceName = name
                serviceType = SERVICE_TYPE
                port = socket.localPort
            }
            val registration = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) = Unit
                override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                    // The only breadcrumb when a phone never shows up in the
                    // other device's list. Nothing else reports this.
                    Log.w(TAG, "could not advertise for pairing (error $errorCode)")
                }
                override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
                override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
            }
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
            return PairingHost(manager, socket, registration)
        }

        private const val TAG = "MozzPairing"
    }
}
