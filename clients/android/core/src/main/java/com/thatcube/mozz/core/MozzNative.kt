package com.thatcube.mozz.core

/**
 * The only Kotlin that knows the core is native.
 *
 * Everything above this file talks to [MozzCore] and sees ordinary suspend
 * functions returning JSON. Everything below it is `Sources/` — the same Swift
 * the iOS and desktop apps run.
 *
 * The boundary deals in `ByteArray`, not `String`: JNI's `NewStringUTF` speaks
 * *modified* UTF-8, which mangles anything outside the Basic Multilingual Plane.
 * A library with an emoji in an album title would be corrupted crossing it. The
 * conversion happens here instead, with an explicit charset. See `mozz_jni.c`.
 */
internal object MozzNative {

    init {
        // Only the shim is named. `libMozzFFI.so` and the ~28 Swift Android
        // runtime objects beside it are pulled in by the dynamic linker through
        // the shim's DT_NEEDED entries, which is why they all have to be in
        // jniLibs/<abi>/ rather than merely on the build machine.
        System.loadLibrary("mozzjni")
    }

    /** Returns a positive handle, or 0 if the library could not be opened. */
    @JvmStatic
    external fun nativeOpen(dbPath: ByteArray): Long

    /** Returns the response JSON, or null if the core produced nothing at all. */
    @JvmStatic
    external fun nativeCall(handle: Long, request: ByteArray): ByteArray?

    /** Returns 1 if the handle was live, 0 otherwise. */
    @JvmStatic
    external fun nativeClose(handle: Long): Int
}
