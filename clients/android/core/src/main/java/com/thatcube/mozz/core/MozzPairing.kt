package com.thatcube.mozz.core

import kotlinx.serialization.Serializable

/**
 * One instruction from the core about what to do next.
 *
 * The shell never reads a frame's contents and never decides what follows: it
 * hands whatever arrived to [MozzPairing.receive] and does what comes back.
 * That is what keeps RFC 9180 written once, in Swift, for all four platforms.
 */
@Serializable
data class PairingStep(
    /** `send`, `digits`, `seal`, `open` or `finished`. */
    val kind: String,
    val frame: String? = null,
    val digits: String? = null,
    val transcript: String? = null,
    val joinerPublicKey: String? = null,
    val encapsulated: String? = null,
    val ciphertext: String? = null,
)

@Serializable
data class PairingBegan(
    val pairingId: String,
    val publicKey: String,
    /** Present for a joiner: the text to render as a QR code. */
    val qrText: String? = null,
    val steps: List<PairingStep> = emptyList(),
)

@Serializable
data class PairingSteps(
    val steps: List<PairingStep> = emptyList(),
    /**
     * Learned from the peer's authenticated transcript. A human-readable roster
     * label only — the circle key, not this string, is the authority.
     */
    val peerName: String? = null,
    val peerDeviceID: String? = null,
)

/** The circle this device belongs to, as the core reports it. */
@Serializable
data class CircleSecrets(
    val channelId: String,
    val channelKey: String,
    val credentialsKey: String,
    val epoch: Int = 1,
    val relayKey: String = "",
)

/**
 * The pairing ceremony, as far as this process is concerned.
 *
 * Every decision belongs to the core — what to send, when to ask a human, when
 * it is finished. What is left on this side is a socket, a length prefix and a
 * screen, which is why Android needed a few hundred lines rather than an
 * implementation of RFC 9180. See ADR-0013.
 */
class MozzPairing(private val core: MozzCore) {

    /** Start a ceremony. A joiner also gets the text for its QR code back. */
    suspend fun begin(
        role: String,
        path: String,
        deviceName: String,
        deviceId: String,
        scannedCode: String? = null,
    ): PairingBegan = core.require(
        CoreRequest(
            cmd = "pairingBegin",
            role = role,
            pairingPath = path,
            scannedCode = scannedCode,
            deviceName = deviceName,
            deviceId = deviceId,
        )
    )

    /** Hand over one frame from the wire; get back what to do about it. */
    suspend fun receive(pairingId: String, frame: String): PairingSteps = core.require(
        CoreRequest(cmd = "pairingReceive", pairingId = pairingId, frame = frame)
    )

    /**
     * Say whether the person confirmed the six digits.
     *
     * A `false` fails the call rather than returning steps: the core ends the
     * session and nothing is shared. That is the point of the ceremony, so it
     * is deliberately not a value this side can ignore.
     */
    suspend fun confirm(pairingId: String, matched: Boolean): PairingSteps = core.require(
        CoreRequest(cmd = "pairingConfirm", pairingId = pairingId, matched = matched)
    )

    /** Seal this device's circle to the joiner's key. */
    suspend fun seal(
        pairingId: String,
        circle: CircleSecrets,
        transcript: String?,
        joinerPublicKey: String?,
    ): PairingSteps = core.require(
        CoreRequest(
            cmd = "pairingSeal",
            pairingId = pairingId,
            circle = circle,
            transcript = transcript,
            joinerPublicKey = joinerPublicKey,
        )
    )

    /** Open the sealed circle. The key doing this has never left the core. */
    suspend fun open(
        pairingId: String,
        encapsulated: String?,
        ciphertext: String?,
        transcript: String?,
    ): CircleSecrets = core.require(
        CoreRequest(
            cmd = "pairingOpen",
            pairingId = pairingId,
            encapsulated = encapsulated,
            ciphertext = ciphertext,
            transcript = transcript,
        )
    )

    /**
     * Make a circle. Storing it is this side's job, because where a secret
     * belongs is the one genuinely platform-specific part.
     */
    suspend fun createCircle(): CircleSecrets = core.require(CoreRequest(cmd = "circleCreate"))

    /**
     * Drop the session. Best effort and safe to call twice: a failed attempt
     * must not leave a handle alive holding a key.
     */
    suspend fun end(pairingId: String) {
        runCatching { core.call<PairingSteps>(CoreRequest(cmd = "pairingEnd", pairingId = pairingId)) }
    }
}
