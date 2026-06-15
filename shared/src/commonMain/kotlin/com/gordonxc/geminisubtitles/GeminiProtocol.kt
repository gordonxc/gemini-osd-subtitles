package com.gordonxc.geminisubtitles

import kotlinx.serialization.json.*

/**
 * Message-building and parsing helpers for the Gemini Live
 * `BidiGenerateContent` bidi stream.
 *
 * Ported from Swift `GeminiProtocol.swift` which was itself ported from
 * `gemini-live-translate-livekit/src/lib/translation-bridge.ts`.
 *
 * The wire format is JSON over WebSocket. We use kotlinx.serialization's
 * JsonObject builders for outgoing messages and JsonObject accessors for
 * incoming parsing.
 */
object GeminiProtocol {

    const val MODEL = "models/gemini-3.5-live-translate-preview"
    const val INPUT_SAMPLE_RATE = 48000
    const val AUDIO_MIME = "audio/pcm;rate=48000"

    // MARK: Outgoing

    /** `setup` message. See translation-bridge.ts:328-354. */
    fun setupMessage(targetLanguage: String): JsonObject = buildJsonObject {
        put("setup", buildJsonObject {
            put("model", MODEL)
            putJsonObject("outputAudioTranscription") {}
            putJsonObject("generationConfig") {
                putJsonArray("responseModalities") { add("AUDIO") }
                putJsonObject("translationConfig") {
                    put("targetLanguageCode", targetLanguage)
                    put("echoTargetLanguage", true)
                }
            }
            putJsonObject("realtimeInputConfig") {
                putJsonObject("automaticActivityDetection") {
                    put("disabled", false)
                }
            }
        })
    }

    /** `realtimeInput` audio chunk. See translation-bridge.ts:601-608. */
    fun realtimeAudioMessage(base64PCM: String): JsonObject = buildJsonObject {
        put("realtimeInput", buildJsonObject {
            putJsonObject("audio") {
                put("mimeType", AUDIO_MIME)
                put("data", base64PCM)
            }
        })
    }

    fun encodeJson(message: JsonObject): String =
        Json.encodeToString(JsonObject.serializer(), message)

    // MARK: Incoming parsing

    /** Parsed transcription event from a server frame. */
    data class TranscriptionEvent(
        val text: String,
        val isFinal: Boolean,
    )

    /**
     * Walks a server frame and returns a transcription event if one is present.
     * Mirrors translation-bridge.ts:356-418.
     */
    fun parseTranscription(json: JsonObject): TranscriptionEvent? {
        val serverContent = json["serverContent"] as? JsonObject ?: return null
        val transcription = serverContent["outputTranscription"] as? JsonObject ?: return null
        val text = transcription["text"]?.jsonPrimitive?.content ?: return null
        if (text.isEmpty()) return null

        val turnComplete = serverContent["turnComplete"]?.jsonPrimitive?.booleanOrNull ?: false
        // Per the reference: isFinal = !turnComplete
        return TranscriptionEvent(text = text, isFinal = !turnComplete)
    }

    /**
     * Gemini sends `{"setupComplete": {}}` (empty object), not a bool.
     * Accept either form: empty object, true, or null.
     */
    fun isSetupComplete(json: JsonObject): Boolean {
        val value = json["setupComplete"] ?: return false
        // setupComplete: {} (empty object) or true or null
        if (value is JsonObject && value.isEmpty()) return true
        if (value == JsonNull) return true
        if (value is JsonPrimitive) {
            return value.booleanOrNull == true || value.content.isEmpty()
        }
        return false
    }

    fun isGoAway(json: JsonObject): Boolean {
        val serverContent = json["serverContent"] as? JsonObject ?: return false
        return serverContent["goAway"]?.jsonPrimitive?.booleanOrNull ?: false
    }
}
