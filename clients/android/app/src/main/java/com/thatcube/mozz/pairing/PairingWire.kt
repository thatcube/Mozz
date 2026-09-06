package com.thatcube.mozz.pairing

/**
 * Turns a stream of bytes back into pairing frames, matching
 * `Sources/MozzPairing/PairingWire.swift` and the desktop's `PairingWire.cs`.
 *
 * This is the only part of pairing written on every platform, and it is
 * deliberately the smallest part. Nothing here decodes a frame's contents — the
 * bytes go straight to the core through `pairingReceive` and steps come back —
 * so the protocol and the cryptography have exactly one implementation. What
 * remains is a four-byte length prefix, small enough to be obviously the same
 * on all four sides.
 *
 * TCP does not preserve message boundaries, so a frame can arrive in pieces,
 * two frames can arrive in one read, and both can happen at once.
 */
class PairingWire {

    private var buffer = ByteArray(0)

    /** Bytes held back waiting for the rest of their frame. */
    val pendingByteCount: Int get() = buffer.size

    /**
     * Feed whatever arrived; returns every frame that is now complete, which
     * may be none, one, or several.
     */
    fun append(bytes: ByteArray, count: Int = bytes.size): List<ByteArray> {
        buffer = buffer + bytes.copyOf(count)
        val frames = mutableListOf<ByteArray>()
        var offset = 0

        while (buffer.size - offset >= PREFIX) {
            // Read into a Long and compare BEFORE narrowing. A length with the
            // high bit set becomes a negative Int, which sails past a
            // `> MAX_FRAME_LENGTH` check and then indexes out of bounds. Swift
            // reads this into a 64-bit Int and rejects it correctly, so getting
            // it wrong here would make the two disagree on exactly the input an
            // attacker picks.
            val claimed =
                ((buffer[offset].toLong() and 0xFF) shl 24) or
                    ((buffer[offset + 1].toLong() and 0xFF) shl 16) or
                    ((buffer[offset + 2].toLong() and 0xFF) shl 8) or
                    (buffer[offset + 3].toLong() and 0xFF)
            if (claimed > MAX_FRAME_LENGTH) {
                // Refuse before reserving anything. A length is a claim, and a
                // claim from a peer nobody has authenticated yet is exactly the
                // kind not to act on.
                throw IllegalArgumentException("pairing frame of $claimed bytes exceeds the limit")
            }
            val length = claimed.toInt()
            if (buffer.size - offset - PREFIX < length) break

            frames += buffer.copyOfRange(offset + PREFIX, offset + PREFIX + length)
            offset += PREFIX + length
        }

        buffer = if (offset == 0) buffer else buffer.copyOfRange(offset, buffer.size)
        return frames
    }

    companion object {
        private const val PREFIX = 4

        /** Matches `PairingWire.maxFrameLength` in Swift: 8 KiB plus envelope. */
        const val MAX_FRAME_LENGTH = 8 * 1024 + 1024

        /** Prefix a payload for the wire. */
        fun frame(payload: ByteArray): ByteArray {
            val framed = ByteArray(payload.size + PREFIX)
            framed[0] = (payload.size ushr 24).toByte()
            framed[1] = (payload.size ushr 16).toByte()
            framed[2] = (payload.size ushr 8).toByte()
            framed[3] = payload.size.toByte()
            payload.copyInto(framed, PREFIX)
            return framed
        }
    }
}
