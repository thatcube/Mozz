package com.thatcube.mozz.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Where a server's access token lives.
 *
 * The core hands a token out of `connect` (or `plexPinCheck`) and then forgets
 * it; keeping it is the platform's job, and on each platform it is a different
 * one — DPAPI on Windows, the Keychain on Apple, this here.
 *
 * The token is encrypted with an AES-256-GCM key held in the AndroidKeyStore,
 * which means the key material is in hardware-backed storage on any device that
 * has it and never enters this process. The ciphertext then goes in ordinary
 * SharedPreferences, which is fine: without the Keystore key it is inert, and
 * the Keystore key cannot be exported off the device.
 *
 * `setUserAuthenticationRequired` is deliberately **not** set. Mozz resumes
 * playback and syncs in the background, so a token that could only be read
 * behind a biometric prompt would mean a lock-screen prompt to keep listening.
 * The threat model here is a lost phone, which the device lock already answers.
 */
class SecretStore(context: Context) {

    private val preferences =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    /** Returns null if nothing is stored, or if what is stored can no longer be read. */
    fun get(key: String): String? {
        val stored = preferences.getString(key, null) ?: return null
        return try {
            val separator = stored.indexOf(SEPARATOR)
            if (separator <= 0) return null
            val iv = Base64.decode(stored.substring(0, separator), Base64.NO_WRAP)
            val ciphertext = Base64.decode(stored.substring(separator + 1), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (error: Exception) {
            // A Keystore key is invalidated by, among other things, the user
            // removing their device lock. Losing a token must mean signing in
            // again, never a crash on launch — so drop the unreadable value and
            // report nothing stored.
            preferences.edit().remove(key).apply()
            null
        }
    }

    /** Store [value], or remove the entry when it is null. */
    fun set(key: String, value: String?) {
        if (value == null) {
            preferences.edit().remove(key).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        // GCM must never reuse an IV with the same key; the one the cipher
        // generated for this operation is stored beside the ciphertext, which is
        // what it is for — an IV is not a secret.
        val encoded = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) +
            SEPARATOR +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        preferences.edit().putString(key, encoded).apply()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val PREFERENCES = "mozz.secrets"
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "mozz.secrets.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        const val SEPARATOR = ':'
    }
}
