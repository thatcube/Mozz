package com.thatcube.mozz.pairing

import android.content.Context
import android.util.Base64
import com.thatcube.mozz.core.CircleSecrets
import com.thatcube.mozz.core.MozzPairing
import com.thatcube.mozz.core.PairingStep
import com.thatcube.mozz.core.SecretStore

/** Who this device was talking to, once the transcript says so. */
data class PairedPeer(val name: String?, val deviceId: String?)

/**
 * Runs a pairing ceremony from Android.
 *
 * Every decision belongs to the core: what to send, when to ask a human, when
 * it is finished. This owns the socket and the discovery, and pumps frames
 * between the two. No protocol logic and no cryptography lives here — which is
 * why Android needed a pump and a screen rather than an implementation of
 * RFC 9180. See ADR-0013.
 */
class PairingService(
    private val context: Context,
    private val pairing: MozzPairing,
    private val secrets: SecretStore,
    private val deviceId: String,
    private val deviceName: String,
) {

    val hasCircle: Boolean get() = loadCircle() != null

    /**
     * Join a circle from a fresh phone.
     *
     * This device advertises and waits; an established device finds it and
     * hands the circle over once both screens agree on the digits.
     */
    suspend fun join(confirmDigits: suspend (String) -> Boolean): PairedPeer {
        val began = pairing.begin(
            role = "joiner",
            path = "digits",
            deviceName = deviceName,
            deviceId = deviceId,
        )
        return PairingHost.start(context, deviceName).use { host ->
            host.accept().use { link ->
                try {
                    for (step in began.steps.filter { it.kind == "send" }) {
                        link.send(decode(step.frame))
                    }
                    pump(began.pairingId, link, confirmDigits)
                } finally {
                    pairing.end(began.pairingId)
                }
            }
        }
    }

    /**
     * Admit a device that is showing a code, or one found on the network.
     *
     * This device is the member: it holds the circle — forming one if it has
     * none — and hands it over.
     */
    suspend fun admit(
        candidate: PairingCandidate,
        scannedCode: String? = null,
        confirmDigits: suspend (String) -> Boolean,
    ): PairedPeer {
        // No code means the digit path: both sides show six digits and a person
        // compares them.
        val usingCode = !scannedCode.isNullOrBlank()
        val began = pairing.begin(
            role = "member",
            path = if (usingCode) "qr" else "digits",
            deviceName = deviceName,
            deviceId = deviceId,
            scannedCode = if (usingCode) scannedCode else null,
        )
        return PairingLink.connect(candidate.host, candidate.port).use { link ->
            try {
                pump(began.pairingId, link, confirmDigits)
            } finally {
                // Let the core drop the session even when this went wrong, so a
                // failed attempt does not leave a handle alive holding a key.
                pairing.end(began.pairingId)
            }
        }
    }

    /**
     * Pumps frames until the ceremony finishes.
     *
     * Both roles share this: the core decides what each side does, so the loop
     * does not need to know which one it is driving beyond where the circle
     * ends up.
     */
    private suspend fun pump(
        pairingId: String,
        link: PairingLink,
        confirmDigits: suspend (String) -> Boolean,
    ): PairedPeer {
        val pending = ArrayDeque<PairingStep>()
        var peerName: String? = null
        var peerDeviceId: String? = null

        while (true) {
            if (pending.isEmpty()) {
                val steps = pairing.receive(pairingId, encode(link.receive()))
                peerName = peerName ?: steps.peerName
                peerDeviceId = peerDeviceId ?: steps.peerDeviceID
                pending.addAll(steps.steps)
                if (pending.isEmpty()) continue
            }

            val next = pending.removeFirst()
            when (next.kind) {
                "send" -> link.send(decode(next.frame))

                "digits" -> {
                    val matched = confirmDigits(next.digits.orEmpty())
                    val after = pairing.confirm(pairingId, matched)
                    peerName = peerName ?: after.peerName
                    peerDeviceId = peerDeviceId ?: after.peerDeviceID
                    pending.addAll(after.steps)
                }

                "seal" -> {
                    val after = pairing.seal(
                        pairingId = pairingId,
                        circle = circleForSharing(),
                        transcript = next.transcript,
                        joinerPublicKey = next.joinerPublicKey,
                    )
                    peerName = peerName ?: after.peerName
                    peerDeviceId = peerDeviceId ?: after.peerDeviceID
                    pending.addAll(after.steps)
                }

                "open" -> {
                    // The core opens it with a key this process never held.
                    storeCircle(
                        pairing.open(
                            pairingId = pairingId,
                            encapsulated = next.encapsulated,
                            ciphertext = next.ciphertext,
                            transcript = next.transcript,
                        )
                    )
                    return PairedPeer(peerName, peerDeviceId)
                }

                "finished" -> return PairedPeer(peerName, peerDeviceId)
            }
        }
    }

    /**
     * The circle to hand over, formed here if this device is not in one — the
     * first pairing anyone does is between two devices where neither is.
     */
    private suspend fun circleForSharing(): CircleSecrets =
        loadCircle() ?: pairing.createCircle().also { storeCircle(it) }

    fun loadCircle(): CircleSecrets? {
        val channelId = secrets.get(CHANNEL_ID) ?: return null
        val channelKey = secrets.get(CHANNEL_KEY) ?: return null
        val credentialsKey = secrets.get(CREDENTIALS_KEY) ?: return null
        return CircleSecrets(
            channelId = channelId,
            channelKey = channelKey,
            credentialsKey = credentialsKey,
            epoch = secrets.get(EPOCH)?.toIntOrNull() ?: 1,
            relayKey = secrets.get(RELAY_KEY).orEmpty(),
        )
    }

    private fun storeCircle(circle: CircleSecrets) {
        // Both halves go to the same store. Unlike Apple, where the channel key
        // sits in ordinary app storage and only the credentials key needs the
        // keychain, a Keystore-wrapped write costs little enough per item here
        // that splitting them buys nothing.
        secrets.set(CHANNEL_ID, circle.channelId)
        secrets.set(CHANNEL_KEY, circle.channelKey)
        secrets.set(CREDENTIALS_KEY, circle.credentialsKey)
        secrets.set(RELAY_KEY, circle.relayKey)
        secrets.set(EPOCH, circle.epoch.toString())
    }

    private companion object {
        const val CHANNEL_ID = "circle.channelId"
        const val CHANNEL_KEY = "circle.channelKey"
        const val CREDENTIALS_KEY = "circle.credentialsKey"
        const val RELAY_KEY = "circle.relayKey"
        const val EPOCH = "circle.epoch"

        /** NO_WRAP: the core reads one base64 string, not a wrapped block. */
        fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

        fun decode(value: String?): ByteArray =
            Base64.decode(value ?: "", Base64.DEFAULT)
    }
}
