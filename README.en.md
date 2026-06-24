# Gemini Subtitles

Real-time, AI-powered on-screen subtitles for any audio playing on your
device. Captures system audio or microphone input, streams it to Gemini Live,
and renders the translated text as a floating, click-through, draggable
overlay. Great for watching videos, attending meetings, or learning languages.

Powered by the **Gemini Live `gemini-3.5-live-translate-preview`** model. You
will need a Gemini API key with access to this model.

---

## Features

### Subtitles & translation
- **Real-time translation** — 20+ target languages (defaults to Cantonese `yue`). Gemini accepts base ISO 639 codes (`yue`, `zh`, `en`, `ja`, `ko`, …)
- **Punctuation-aware splitting** — incoming fragments are split on CJK / Latin punctuation or 1.5 s speech pauses; up to 2 sentences visible at once
- **Bilingual OSD** (macOS) — source-language line displayed alongside the translation, great for language learners
- **OSD length cap** — long sentences wrap to up to 4 lines and head-truncate (`…most recent text`); the OSD never overflows the screen

### Audio sources
- **System audio** — any audio playing on the device (ScreenCaptureKit on macOS, MediaProjection on Android)
- **Per-app isolation** (macOS) — restrict capture to a single application (e.g. Chrome, Spotify); everything else is filtered out at the ScreenCaptureKit layer, so you can translate a YouTube video without picking up notification sounds or music from another app
- **Microphone input** — internal or external mic for translating live conversations (Android uses `VOICE_RECOGNITION` source with a flat frequency response optimized for ASR)

### OSD experience
- **Floating overlay** — click-through by default so it never blocks the app underneath; unlock to drag anywhere
- **Visible across all Spaces** (macOS) / displays over other apps (Android)
- **Configurable font size** — 14–72 pt, persisted
- **Auto-fade** — 4 s after the last update (200 ms alpha fade)
- **Drag clamp** (macOS) — released drags snap back inside the visible area
- **Dynamic line budget** — large fonts on short screens shrink the line count so the OSD never exceeds screen height

### Quality-of-life
- **Subtitle history** — every session is saved automatically and exportable (macOS supports SRT / VTT / JSON / TXT)
- **Inactivity auto-stop** — optional 5 / 15 / 30 / 60 min timeout
- **Built-in auto-update** (macOS) — Sparkle checks for new versions at launch and on demand via **Check for Updates…**
- **Status indicator** — colored menu-bar icon (macOS) or status-card dot (Android) shows current state at a glance

### Status colors

| Color | macOS meaning | Android meaning |
|-------|---------------|-----------------|
| Gray  | Stopped | Not running |
| Yellow | Connecting / reconnecting | WebSocket opening |
| Green | Active — streaming audio to Gemini | Active |
| Blue  | Non-zero audio frames observed | — |
| Red   | Error (also surfaces a notification) | Error |

---

## Platforms

| Platform | Status | Source |
|----------|--------|--------|
| macOS 14.0+ | Shipping — release builds signed with a stable self-signed cert, with built-in Sparkle auto-update | `Sources/` (Swift) |
| Android 10+ (API 29) | Working debug builds | `shared/` + `androidApp/` (Kotlin Multiplatform) |

---

## macOS

### Installation

1. Download the latest `GeminiSubtitles-vX.Y.Z.zip` from [Releases](https://github.com/gordonxc/gemini-osd-subtitles/releases)
2. Unzip and drag `GeminiSubtitles.app` to `~/Applications` (Sparkle can self-update when the bundle lives in a user-writable location; `/Applications` prompts for an admin password on update)
3. Launch with right-click → **Open** the first time (Gatekeeper will warn because the bundle is self-signed rather than Apple Developer ID-signed). Or clear the quarantine flag:
   ```sh
   xattr -dr com.apple.quarantine GeminiSubtitles.app
   open GeminiSubtitles.app
   ```

### First-run setup

1. Click the captions-bubble icon in the menu bar → **Set API Key…** → paste your Gemini API key (stored in Keychain)
2. Choose a target language (defaults to Cantonese `yue`)
3. Click **Start**. On first run you'll be deep-linked to **System Settings → Privacy & Security → Screen Recording** — toggle **Gemini Subtitles** ON, then quit and relaunch
4. Play any audio. Translated subtitles appear within 1–3 s

### Menu overview

- **Start / Stop** — toggles the capture → Gemini → OSD pipeline
- **Target Language** — target language picker
- **Audio Source** — three options:
  - **System Audio** — whole-system mix
  - **Single App** — per-app isolation (pick from currently-running apps)
  - **Microphone** — mic input
- **Font Size** — 14–72 pt
- **Auto-stop** — Off / 5 / 15 / 30 / 60 min
- **Bilingual: On/Off** — show source text alongside translation
- **History** — view / export / clear session history
- **Unlock OSD to Move / Lock OSD** — toggle draggability
- **Set API Key…**
- **Check for Updates…**
- **Quit**

### Debugging

Diagnostic logs are written to `~/Library/Logs/GeminiSubtitles.log`:

```sh
tail -f ~/Library/Logs/GeminiSubtitles.log
```

---

## Android

### Installation

1. Download the latest `androidApp-debug.apk` from [Releases](https://github.com/gordonxc/gemini-osd-subtitles/releases) (or build it yourself: `gradle assembleDebug`)
2. `adb install -r androidApp-debug.apk` (or tap the APK on the device to install)

### First-run setup

1. Open the app → enter your Gemini API key
2. Choose a target language (defaults to Cantonese)
3. Tap **Start** → grant "Display over other apps" permission if prompted
4. System will ask for screen capture permission (MediaProjection) → **Start now**
   * In Mic mode: RECORD_AUDIO permission prompt → Allow
5. Play any audio — translated subtitles appear in the floating overlay

### Audio source switching

The settings screen has an **Audio Source** switch:

- **System Audio (default)** — MediaProjection captures any app's playback audio. Great for translating videos / music
- **Microphone** — `AudioRecord` + `VOICE_RECOGNITION`. Great for translating live conversations

Switching while running automatically restarts the pipeline.

### Permissions

| Permission | Why |
|------------|-----|
| `INTERNET` + `ACCESS_NETWORK_STATE` | Reach the Gemini WebSocket endpoint |
| `RECORD_AUDIO` | Audio capture via MediaProjection and microphone |
| `FOREGROUND_SERVICE` + `_MEDIA_PROJECTION` + `_MICROPHONE` | Background audio capture |
| `SYSTEM_ALERT_WINDOW` | Floating subtitle overlay |
| `POST_NOTIFICATIONS` | Error notifications (Android 13+) |

### Debugging

```sh
adb logcat -s GeminiSubtitles:D
adb logcat -b crash    # crash traces
```

---

## Reference

The Gemini protocol and reconnect logic is ported from
[`gemini-live-translate-livekit`](https://github.com/pixellegend/gemini-live-translate-livekit)'s
`translation-bridge.ts`. The language list is a curated subset of the same
source.
