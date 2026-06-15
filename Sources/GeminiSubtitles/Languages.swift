import Foundation

/// A curated shortlist of translation targets.
///
/// IMPORTANT: `gemini-3.5-live-translate-preview` only accepts the base
/// ISO 639 language code (e.g. "yue", "zh", "ja"). BCP-47 region tags like
/// "yue-HK" or "zh-CN" are rejected with close code 1007 "invalid argument"
/// immediately after setupComplete. Region distinctions are kept in the
/// display name only. Mirrors `gemini-live-translate-livekit/src/lib/languages.ts`.
struct Language: Hashable {
    let code: String   // e.g. "yue" — base ISO 639 code only
    let name: String   // e.g. "Cantonese"
}

enum Languages {
    /// Default language applied on first launch / when none is stored.
    static let defaultCode = "yue"

    /// Hand-picked targets covering common use cases. Region tags in names
    /// are cosmetic — the API only accepts the base code.
    static let all: [Language] = [
        Language(code: "yue", name: "Cantonese"),
        Language(code: "zh", name: "Chinese (Mandarin)"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "en", name: "English"),
        Language(code: "es", name: "Spanish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "th", name: "Thai"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese")
    ]

    static func name(forCode code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }
}
