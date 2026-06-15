import Foundation

/// Message-building and parsing helpers for the Gemini Live `BidiGenerateContent`
/// bidi stream. Ported from `gemini-live-translate-livekit/src/lib/translation-bridge.ts`.
///
/// The wire format is JSON over WebSocket. Outgoing messages are constructed as
/// `[String: Any]` and serialized with `JSONSerialization`; incoming messages
/// are parsed into dictionaries and probed for the documented top-level keys
/// (`setupComplete`, `serverContent`).
enum GeminiProtocol {

    static let model = "models/gemini-3.5-live-translate-preview"
    static let inputSampleRate = 48000
    static let audioMIME = "audio/pcm;rate=48000"

    // MARK: Outgoing

    /// `setup` message. See translation-bridge.ts:328-354.
    static func setupMessage(targetLanguage: String) -> [String: Any] {
        return [
            "setup": [
                "model": model,
                "outputAudioTranscription": [:] as [String: Any],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": targetLanguage,
                        "echoTargetLanguage": true
                    ] as [String: Any]
                ] as [String: Any],
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": false] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    /// `realtimeInput` audio chunk. See translation-bridge.ts:601-608.
    static func realtimeAudioMessage(base64PCM: String) -> [String: Any] {
        return [
            "realtimeInput": [
                "audio": [
                    "mimeType": audioMIME,
                    "data": base64PCM
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static func encodeJSON(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Incoming parsing

    /// Parsed transcription event from a server frame.
    struct TranscriptionEvent {
        let text: String
        let isFinal: Bool
    }

    /// Walks a server frame dict and returns a transcription event if one is
    /// present. Mirrors translation-bridge.ts:356-418. Audio parts under
    /// `serverContent.modelTurn.parts[*].inlineData` are intentionally discarded.
    static func parseTranscription(from json: [String: Any]) -> TranscriptionEvent? {
        guard let serverContent = json["serverContent"] as? [String: Any] else { return nil }
        guard let transcription = serverContent["outputTranscription"] as? [String: Any],
              let text = transcription["text"] as? String, !text.isEmpty else {
            return nil
        }
        let turnComplete = (serverContent["turnComplete"] as? Bool) ?? false
        // Per the reference: isFinal = !turnComplete is inverted from typical
        // usage because each interim chunk is emitted with turnComplete=false
        // until the final chunk where turnComplete=true marks the segment end.
        // We follow the reference exactly: pass `!turnComplete` as "interim".
        return TranscriptionEvent(text: text, isFinal: !turnComplete)
    }

    static func isSetupComplete(_ json: [String: Any]) -> Bool {
        // Gemini sends `{"setupComplete": {}}` (empty object), not a bool.
        // Accept either form.
        let value = json["setupComplete"]
        if let b = value as? Bool { return b }
        if let dict = value as? [String: Any], dict.isEmpty { return true }
        if value is NSNull { return true }
        return false
    }

    static func isGoAway(_ json: [String: Any]) -> Bool {
        guard let serverContent = json["serverContent"] as? [String: Any] else { return false }
        return (serverContent["goAway"] as? Bool) ?? false
    }
}
