package com.thatcube.mozz.pairing

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * One pairing conversation over one socket.
 *
 * Deliberately thin, and the mirror of `PairingLink` in Swift and on the
 * desktop. The protocol and the cryptography live in the core and are reached
 * through `pairingReceive`; what is left here is a socket and a length prefix.
 */
class PairingLink internal constructor(private val socket: Socket) : Closeable {

    private val wire = PairingWire()
    private val pending = ArrayDeque<ByteArray>()
    private val scratch = ByteArray(PairingWire.MAX_FRAME_LENGTH)

    suspend fun send(frame: ByteArray) = withContext(Dispatchers.IO) {
        val output = socket.getOutputStream()
        output.write(PairingWire.frame(frame))
        output.flush()
    }

    /**
     * Reads until one whole frame is available. A read returning fewer bytes
     * than a frame is ordinary rather than exceptional, which is why the loop
     * is here and the reassembly is in [PairingWire].
     */
    suspend fun receive(): ByteArray = withContext(Dispatchers.IO) {
        while (true) {
            pending.removeFirstOrNull()?.let { return@withContext it }

            val read = socket.getInputStream().read(scratch)
            if (read <= 0) throw IOException("the other device closed the connection")
            pending.addAll(wire.append(scratch, read))
        }
        @Suppress("UNREACHABLE_CODE")
        throw IllegalStateException()
    }

    override fun close() {
        runCatching { socket.close() }
    }

    companion object {
        /**
         * A device that is on the network but not listening should fail quickly
         * rather than leave someone watching a spinner: pairing is face to face
         * and a person is waiting on both ends.
         */
        private const val CONNECT_TIMEOUT_MS = 10_000

        suspend fun connect(host: String, port: Int): PairingLink = withContext(Dispatchers.IO) {
            val socket = Socket()
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            PairingLink(socket)
        }
    }
}
