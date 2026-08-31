// The JNI shim.
//
// Mozz deliberately does not expose a wide Swift API to its hosts. It exposes
// one coarse-grained C ABI — open / call / close, with every request and
// response a JSON string — so bridging it to Kotlin is this file and nothing
// else. ADR-0014 weighed swift-java against a hand-written shim and chose the
// shim for exactly that reason: there is no rich Swift surface here to generate
// bindings for.
//
// BYTES, NOT jstring, AND WHY
//
// The obvious implementation uses GetStringUTFChars / NewStringUTF. It is
// wrong. Those functions speak JNI's *modified* UTF-8, in which a character
// outside the Basic Multilingual Plane is encoded as a surrogate pair of
// three-byte sequences rather than the four bytes real UTF-8 uses. Swift emits
// and expects real UTF-8. A library with an emoji in an album title, or any
// astral-plane character, would be silently corrupted crossing the boundary —
// and a search for it would quietly never match.
//
// So the boundary deals in byte arrays and the Kotlin side does the String
// conversion with an explicit UTF-8 charset. It is also faster: no copy into a
// JVM string, no re-encode.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The C ABI exported by Sources/MozzFFI. Kept in lockstep with the @_cdecl
// signatures; the CMake link is what makes a mismatch a build error rather than
// a runtime surprise.
extern int64_t mozz_session_open(const char *db_path);
extern char *mozz_session_call(int64_t handle, const char *request_json);
extern int32_t mozz_session_close(int64_t handle);
extern void mozz_ffi_free_string(char *ptr);

// Copy a Java byte[] into a NUL-terminated C string. Returns NULL on allocation
// failure or on a NULL input, which the callers treat as "no request".
static char *bytes_to_cstring(JNIEnv *env, jbyteArray bytes) {
    if (bytes == NULL) return NULL;
    jsize length = (*env)->GetArrayLength(env, bytes);
    char *buffer = malloc((size_t)length + 1);
    if (buffer == NULL) return NULL;
    (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)buffer);
    buffer[length] = '\0';
    return buffer;
}

// Copy a NUL-terminated C string into a fresh Java byte[].
static jbyteArray cstring_to_bytes(JNIEnv *env, const char *string) {
    if (string == NULL) return NULL;
    jsize length = (jsize)strlen(string);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    if (bytes == NULL) return NULL;  // OOM pending; let the JVM raise it
    (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)string);
    return bytes;
}

JNIEXPORT jlong JNICALL
Java_com_thatcube_mozz_core_MozzNative_nativeOpen(JNIEnv *env, jclass clazz, jbyteArray db_path) {
    (void)clazz;
    char *path = bytes_to_cstring(env, db_path);
    if (path == NULL) return 0;
    int64_t handle = mozz_session_open(path);
    free(path);
    return (jlong)handle;
}

JNIEXPORT jbyteArray JNICALL
Java_com_thatcube_mozz_core_MozzNative_nativeCall(JNIEnv *env, jclass clazz, jlong handle,
                                                  jbyteArray request) {
    (void)clazz;
    char *json = bytes_to_cstring(env, request);
    if (json == NULL) return NULL;

    char *response = mozz_session_call((int64_t)handle, json);
    free(json);
    if (response == NULL) return NULL;

    jbyteArray result = cstring_to_bytes(env, response);
    // Every pointer the core hands out is released exactly once, on every path
    // — including the one where NewByteArray failed and `result` is NULL.
    mozz_ffi_free_string(response);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_thatcube_mozz_core_MozzNative_nativeClose(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    return (jint)mozz_session_close((int64_t)handle);
}
