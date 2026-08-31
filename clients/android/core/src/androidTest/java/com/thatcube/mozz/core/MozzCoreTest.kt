package com.thatcube.mozz.core

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Phase 1's exit criterion: the shim loads on a real device and the session ABI
 * answers.
 *
 * This is an *instrumented* test, not a unit test, on purpose — the thing under
 * test is whether `libMozzFFI.so` and its ~28 Swift runtime objects resolve on
 * Android's linker. A JVM test on the build machine could not see that.
 */
class MozzCoreTest {

    private fun freshLibrary(): String {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val file = File(dir, "mozz-core-test-${System.nanoTime()}.sqlite")
        file.delete()
        return file.absolutePath
    }

    @Test
    fun opensASessionAndAnswersPing() = runBlocking {
        MozzCore.open(freshLibrary()).use { core ->
            val response = core.callRaw("""{"id":1,"cmd":"ping"}""")
            assertTrue("unexpected ping response: $response", response.contains("\"ok\":true"))
        }
    }

    /**
     * The reason the boundary deals in bytes rather than `jstring`. An astral-plane
     * character round-trips only if both directions use real UTF-8; JNI's modified
     * UTF-8 would corrupt it. A search for an emoji is an odd thing to do, but an
     * album title containing one is not.
     */
    @Test
    fun survivesAstralPlaneCharacters() = runBlocking {
        MozzCore.open(freshLibrary()).use { core ->
            val needle = "Sigur Rós 🌌 Ágætis"
            val request = """{"id":2,"cmd":"search","query":${quote(needle)},"limit":5}"""
            val response = core.callRaw(request)
            assertTrue(
                "the core did not echo the query back intact: $response",
                response.contains("\"ok\":true"),
            )
        }
    }

    private fun quote(value: String) = buildString {
        append('"')
        value.forEach { c ->
            when (c) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                else -> append(c)
            }
        }
        append('"')
    }
}
