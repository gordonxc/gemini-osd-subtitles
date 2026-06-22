package com.gordonxc.geminisubtitles.platform

/** Platform-agnostic API key storage. */
interface PlatformApiKeyStore {
    fun getApiKey(): String?
    fun setApiKey(key: String)
    fun deleteApiKey()
}
