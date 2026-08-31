package com.thatcube.mozz.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.util.concurrent.atomic.AtomicInteger

/**
 * A session against one Mozz library.
 *
 * The C ABI is synchronous and blocking by nature — `mozz_session_call` parks
 * the calling thread while the Swift side runs its async work to completion. So
 * every call here hops to [Dispatchers.IO] and none of them may be made from the
 * main thread. The core is safe to drive from several threads at once: requests
 * carry an `id` that is echoed back, so callers can pipeline without correlating
 * by arrival order.
 *
 * One session owns the database connection pool for its lifetime. Open it once
 * per process, not once per screen.
 */
class MozzCore private constructor(private val handle: Long) : Closeable {

    private val nextRequestId = AtomicInteger(1)

    companion object {
        /**
         * Null fields are dropped rather than sent, so a request carries only the
         * keys its command needs; unknown keys in a response are ignored so the
         * core can grow a field without breaking an older client.
         */
        val json: Json = Json {
            encodeDefaults = false
            explicitNulls = false
            ignoreUnknownKeys = true
        }

        /**
         * Open the library at [dbPath]. Throws if the core refuses it, because a
         * caller holding a zero handle has nothing useful it can do.
         */
        fun open(dbPath: String): MozzCore {
            val handle = MozzNative.nativeOpen(dbPath.toByteArray(Charsets.UTF_8))
            if (handle == 0L) throw MozzCoreException("could not open the library at $dbPath")
            return MozzCore(handle)
        }
    }

    /**
     * Send one raw JSON request and return the raw JSON response.
     *
     * Public because the typed helpers below are `inline` and need it, not
     * because anything else should call it. Compose a [CoreRequest] instead.
     */
    suspend fun callRaw(requestJson: String): String = withContext(Dispatchers.IO) {
        val response = MozzNative.nativeCall(handle, requestJson.toByteArray(Charsets.UTF_8))
            ?: throw MozzCoreException("the core returned nothing for: $requestJson")
        String(response, Charsets.UTF_8)
    }

    /** An id unique within this session, for correlating pipelined calls. */
    fun nextId(): Int = nextRequestId.getAndIncrement()

    override fun close() {
        MozzNative.nativeClose(handle)
    }
}

/**
 * Run a command and decode its payload.
 *
 * Throws [MozzCoreException] when the core reports `ok: false`, so callers deal
 * in results rather than in envelopes.
 */
suspend inline fun <reified T> MozzCore.call(request: CoreRequest): T? {
    val text = callRaw(MozzCore.json.encodeToString(request.copy(id = nextId())))
    val envelope = MozzCore.json.decodeFromString<Envelope<T>>(text)
    if (!envelope.ok) coreFailure(request.cmd, envelope.error)
    return envelope.payload
}

/** As [call], but for a command that must produce a payload. */
suspend inline fun <reified T> MozzCore.require(request: CoreRequest): T =
    call<T>(request) ?: throw MozzCoreException("${request.cmd} returned no payload")

/**
 * One page of a listing, and where to resume it. The cursor rides the envelope,
 * so [call] stays usable for everything that does not page.
 */
suspend inline fun <reified T> MozzCore.callPage(request: CoreRequest): Page<T> {
    val text = callRaw(MozzCore.json.encodeToString(request.copy(id = nextId())))
    val envelope = MozzCore.json.decodeFromString<Envelope<T>>(text)
    if (!envelope.ok) coreFailure(request.cmd, envelope.error)
    return Page(envelope.payload, envelope.nextCursor)
}

/**
 * Fail loudly, then throw.
 *
 * Every caller of the helpers above wraps them in `runCatching` — one artwork
 * URL that will not resolve should not take down a screen — which means an FFI
 * error otherwise leaves no trace anywhere. This is the only place it is
 * guaranteed to be seen, so it logs before it throws.
 */
fun coreFailure(cmd: String, message: String?): Nothing {
    val text = message ?: "unknown error"
    android.util.Log.w("Mozz", "core refused $cmd: $text")
    throw MozzCoreException(text)
}

class MozzCoreException(message: String) : Exception(message)
