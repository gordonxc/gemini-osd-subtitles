package com.gordonxc.geminisubtitles

/**
 * A curated shortlist of translation targets.
 *
 * IMPORTANT: `gemini-3.5-live-translate-preview` only accepts the base
 * ISO 639 language code (e.g. "yue", "zh", "ja"). BCP-47 region tags like
 * "yue-HK" or "zh-CN" are rejected with close code 1007 "invalid argument"
 * immediately after setupComplete. Region distinctions are kept in the
 * display name only.
 */
data class Language(
    val code: String,   // e.g. "yue" — base ISO 639 code only
    val name: String    // e.g. "Cantonese"
)

object Languages {
    /** Default language applied on first launch / when none is stored. */
    const val defaultCode = "yue"

    /** Hand-picked targets covering common use cases. */
    val all: List<Language> = listOf(
        Language("yue", "Cantonese"),
        Language("zh", "Chinese (Mandarin)"),
        Language("ja", "Japanese"),
        Language("ko", "Korean"),
        Language("en", "English"),
        Language("es", "Spanish"),
        Language("fr", "French"),
        Language("de", "German"),
        Language("vi", "Vietnamese"),
        Language("th", "Thai"),
        Language("it", "Italian"),
        Language("pt", "Portuguese"),
    )

    fun nameForCode(code: String): String =
        all.firstOrNull { it.code == code }?.name ?: code
}
