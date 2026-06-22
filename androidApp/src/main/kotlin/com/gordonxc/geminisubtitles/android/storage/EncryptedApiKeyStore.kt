package com.gordonxc.geminisubtitles.android.storage

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.gordonxc.geminisubtitles.platform.PlatformApiKeyStore

/**
 * Stores the Gemini API key using EncryptedSharedPreferences.
 * Android equivalent of macOS `KeychainStore.swift`.
 */
class EncryptedApiKeyStore(context: Context) : PlatformApiKeyStore {

    companion object {
        private const val PREFS_NAME = "gemini_subtitles_secure_prefs"
        private const val KEY_API_KEY = "api_key"
    }

    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun getApiKey(): String? =
        prefs.getString(KEY_API_KEY, null)?.takeIf { it.isNotEmpty() }

    override fun setApiKey(key: String) {
        prefs.edit().putString(KEY_API_KEY, key).apply()
    }

    override fun deleteApiKey() {
        prefs.edit().remove(KEY_API_KEY).apply()
    }
}
