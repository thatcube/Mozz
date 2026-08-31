package com.thatcube.mozz.core

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The typed layer, against an empty library.
 *
 * Empty is the point: these assert that requests encode into the shape the Swift
 * decoder expects and that responses decode back, which is where a hand-written
 * wire mirror goes wrong. Whether the *contents* are right needs a real server,
 * and is checked by signing in.
 */
class MozzLibraryTest {

    private fun freshCore(): MozzCore {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val file = File(dir, "mozz-library-test-${System.nanoTime()}.sqlite")
        file.delete()
        return MozzCore.open(file.absolutePath)
    }

    @Test
    fun readsCountsFromAnEmptyLibrary() = runBlocking {
        freshCore().use { core ->
            val counts = MozzLibrary(core).counts()
            assertEquals(0, counts.artists)
            assertEquals(0, counts.albums)
            assertEquals(0, counts.tracks)
        }
    }

    @Test
    fun emptyListingsDecodeAsEmptyRatherThanFailing() = runBlocking {
        freshCore().use { core ->
            val library = MozzLibrary(core)
            assertTrue(library.likedTracks().isEmpty())
            assertTrue(library.servers().isEmpty())

            val albums = library.albums()
            assertTrue(albums.rows.isNullOrEmpty())
            // No rows means no next page — the only end-of-listing signal there is.
            assertNull(albums.nextCursor)
        }
    }

    @Test
    fun searchAcceptsAQueryAndReturnsThreeEmptyBuckets() = runBlocking {
        freshCore().use { core ->
            val results = MozzLibrary(core).search("björk")
            assertTrue(results.artists.isEmpty())
            assertTrue(results.albums.isEmpty())
            assertTrue(results.tracks.isEmpty())
        }
    }

    /**
     * The core reports its own failures through the envelope, and the typed
     * layer has to turn those into exceptions rather than silently returning
     * null — a caller that cannot tell "no results" from "you asked wrong" will
     * ship the second one as an empty screen.
     */
    @Test
    fun aRefusedCommandThrowsRatherThanReturningNothing() = runBlocking {
        freshCore().use { core ->
            val failure = runCatching {
                // albumTracks requires a remoteId or a groupKey; this has neither.
                core.call<List<Track>>(CoreRequest(cmd = "albumTracks", serverId = "nope"))
            }.exceptionOrNull()
            assertTrue(
                "expected a MozzCoreException, got $failure",
                failure is MozzCoreException,
            )
        }
    }

    /** Requests must omit the fields a command does not use, not send them as null. */
    @Test
    fun requestsOmitNullFields() {
        val encoded = MozzCore.json.encodeToString(
            CoreRequest(cmd = "counts", serverId = "abc")
        )
        assertEquals("""{"cmd":"counts","serverId":"abc"}""", encoded)
    }
}
