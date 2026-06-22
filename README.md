# Gemini Subtitles

Real-time on-screen subtitles for any audio playing on your device, powered by
the **Gemini Live `gemini-3.5-live-translate-preview`** model. Captures system
audio, streams it to Gemini, and renders translated text as a floating,
click-through overlay.

Two native ports share this repo:

| Platform | Path        | Status |
|----------|-------------|--------|
| macOS    | `Sources/` (Swift) | Shipping — adhoc-signed release builds |
| Android  | `shared/` + `androidApp/` (Kotlin Multiplatform) | Initial port |

---

## macOS app

A menu-bar utility (`LSUIElement = true`, no Dock icon). System-wide audio
capture via ScreenCaptureKit; floating OSD via `NSPanel`.

* **Zero third-party dependencies** — built entirely on Apple frameworks
  (AppKit, ScreenCaptureKit, AVFoundation, CoreGraphics, Security,
  UserNotifications).
* **2-line OSD with punctuation-aware splitting** — fragments are buffered and
  split on CJK / Latin punctuation or 1.5 s speech pauses; up to 2 sentences
  stay on screen at once.
* **Configurable font size (14–72 pt), draggable, persistent** — unlock the
  OSD to drag it anywhere; click-through by default so it never blocks the app
  underneath.
* **Inactivity auto-stop** — optionally stop the session after 5 / 15 / 30 /
  60 min without audio.

> The Gemini protocol and reconnect logic is a Swift port of
> `gemini-live-translate-livekit/src/lib/translation-bridge.ts`, with the
> LiveKit audio transport replaced by native ScreenCaptureKit.

### Requirements

* macOS 14.0 or later (tested on macOS 26 Tahoe)
* Xcode command-line tools (`xcode-select --install`)
* A Gemini API key with access to `gemini-3.5-live-translate-preview`

### Build

```sh
swift build -c release
```

The binary is emitted at `.build/release/GeminiSubtitles`.

### Run as a `.app` bundle

`run.sh` builds the release binary, copies it into `GeminiSubtitles.app/`,
re-signs the bundle, and launches via `open` so TCC sees a proper bundle
identity:

```sh
./run.sh
```

Launch with right-click → **Open** the first time (Gatekeeper will warn
because the bundle is adhoc-signed). To clear the quarantine flag on your own
machine:

```sh
xattr -dr com.apple.quarantine GeminiSubtitles.app
open GeminiSubtitles.app
```

### First-run setup

1. Click the captions-bubble icon in the menu bar → **Set API Key…** → paste
   your Gemini API key. Stored in Keychain under `com.gemini-subtitles.apikey`.
2. Choose a target language (defaults to Cantonese `yue`). Gemini accepts
   base ISO 639 codes only (`yue`, `zh`, `en`, `ja`, …).
3. Click **Start**. On first run you'll be deep-linked to **System Settings →
   Privacy & Security → Screen Recording** — toggle **Gemini Subtitles** ON,
   then quit and relaunch.
4. Play any audio. Translated subtitles appear within 1–3 s. The status icon
   flips green → **blue** the moment non-zero audio frames are observed, and
   back to green after 3 s of silence.

> **macOS 26 Tahoe note:** we use ScreenCaptureKit's audio capture rather
> than the CoreAudio process tap (`AudioHardwareCreateProcessTap`). On Tahoe
> the CATap path silently zero-fills audio buffers for adhoc-signed apps
> with no error. ScreenCaptureKit's **Screen Recording** permission works
> reliably for adhoc signatures.

### Status icon colours

| Colour  | Meaning                                                  |
|---------|----------------------------------------------------------|
| Gray    | Stopped                                                  |
| Yellow  | Connecting / reconnecting                                |
| Green   | Active — streaming audio to Gemini                       |
| Blue    | Non-zero audio frames observed (capture is flowing)      |
| Red     | Error (also surfaces a macOS notification)               |

### OSD behaviour

* **2-line rolling display** — incoming fragments are accumulated in
  `SubtitleBuffer` and split on CJK / Latin punctuation or a 1.5 s speech
  pause. At most 2 lines are visible at once.
* **Font size** — picker offers 14–72 pt (default 20). Persisted in
  UserDefaults. The window resizes dynamically.
* **Lock / Unlock** — click-through by default; **Unlock OSD to Move** makes
  it draggable.
* **Auto-fade** 4 s after the last update (200 ms alpha fade). Auto-hides on
  the 3-s silence demotion.
* **Visible across all Spaces** (`collectionBehavior = .canJoinAllSpaces`).

### Menu

* **Start / Stop** — toggles the capture → Gemini → OSD pipeline.
* **Target Language** — picker (curated, defaults to Cantonese).
* **Audio Source** — system default or a specific output device.
* **Font Size** — 14–72 pt.
* **Auto-stop** — Off / 5 / 15 / 30 / 60 min inactivity timeout.
* **Unlock OSD to Move / Lock OSD** — toggle draggability.
* **Set API Key…** — modal prompt storing the key in Keychain.
* **Quit**

### Architecture (macOS)

```
ScreenCaptureKit ──Float32 PCM──▶ AudioPipeline ──base64 Int16 PCM──▶ GeminiClient
                                       (48 kHz, 100 ms chunks)               │
                                                                            │ WS
                                                                            ▼
                                                                   BidiGenerateContent
                                                                            │
                                                                   outputTranscription
                                                                            │
                                                                            ▼
                                              SubtitleBuffer ──split on punctuation / pause──▶ onUpdate
                                                                                                    │
       SubtitleWindow ◀────────────────────────────────────────────────── handleTranscription(text)
```

| File                          | Responsibility                                                  |
|-------------------------------|-----------------------------------------------------------------|
| `main.swift` / `AppDelegate`  | Bootstrap, status item, icon tinting                            |
| `StatusMenuController`        | Menu, language / audio-source / font-size / auto-stop pickers, API-key alert |
| `KeychainStore`               | `SecItem` wrapper for the API key                               |
| `Permissions`                 | Screen Capture TCC preflight / request / deep-link              |
| `AudioCapture`                | `SCStream` wrapper, AudioBufferList → Float32                   |
| `AudioPipeline`               | Float32→Int16, base64, 100 ms framing                           |
| `GeminiClient`                | `URLSessionWebSocketTask`, setup, receive loop, reconnect       |
| `GeminiProtocol`              | Setup / realtimeInput / outputTranscription message helpers     |
| `SubtitleBuffer`              | Accumulates fragments, splits on punctuation / pause, 2-line window |
| `SubtitleWindow` / `SubtitleViewController` | Floating panel, font resize, lock/unlock, fade timer |
| `NotificationManager`         | `UNUserNotificationCenter` for critical errors                  |
| `DebugLog`                    | File logger (`~/Library/Logs/GeminiSubtitles.log`) bypassing unified-log privacy masking |
| `AppCoordinator`              | Orchestrates capture ↔ Gemini ↔ OSD; maps status to icon/menu   |

### Debugging (macOS)

Diagnostic logs are written to `~/Library/Logs/GeminiSubtitles.log`. Tail
with:

```sh
tail -f ~/Library/Logs/GeminiSubtitles.log
```

Key signals to grep for:

* `AudioCapture SCK: ... silent=false` — audio frames flowing (icon turns blue).
* `GeminiClient setupComplete received ✓` — WebSocket setup succeeded.
* `AudioPipeline emit chunk #N` — audio chunks being sent to Gemini.
* `GeminiClient.handleIncoming` — raw server responses (translations live
  under `serverContent.outputTranscription.text`).

---

## Android app (KMP port)

A Kotlin Multiplatform port. Shares the Gemini protocol, audio pipeline, and
subtitle buffering in `shared/commonMain`, with Android-specific
implementations in `shared/androidMain` and `androidApp`.

### Platform decisions

- **Audio capture:** MediaProjection + AudioPlaybackCaptureConfiguration (system audio)
- **OSD:** WindowManager TYPE_APPLICATION_OVERLAY (floating, click-through, draggable)
- **UI:** Jetpack Compose (Settings) + traditional View (Overlay)
- **iOS:** Deferred — KMP architecture reserves the slot via platform interfaces

### Requirements

- Android 10+ (API 29)
- A Gemini API key with access to `gemini-3.5-live-translate-preview`

### Build

```sh
./gradlew assembleDebug
```

### Permissions

| Permission | Why |
|------------|-----|
| `RECORD_AUDIO` | Audio capture via MediaProjection |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background audio capture |
| `SYSTEM_ALERT_WINDOW` | Floating subtitle overlay |
| `POST_NOTIFICATIONS` | Error notifications (Android 13+) |

### First-run setup

1. Open app → enter Gemini API key
2. Choose target language (defaults to Cantonese `yue`)
3. Tap **Start** → grant "Display over other apps" permission if prompted
4. System will ask for screen capture permission (MediaProjection) → **Start now**
5. Play any audio — translated subtitles appear in the floating overlay

### Architecture (Android)

```
MediaProjection ──Float32 PCM──▶ AudioPipeline ──base64 Int16 PCM──▶ GeminiClient
            (48 kHz, 100 ms chunks)                                         │
                                                                            │ WS
                                                                            ▼
                                                                   BidiGenerateContent
                                                                            │
                                                                   outputTranscription
                                                                            │
                                                                            ▼
                                              SubtitleBuffer ──split on punctuation / pause──▶ onUpdate
                                                                                                    │
                                         SubtitleOverlayView ◀──────────────────── updateText(text)
```

### Module structure

| Module | Content |
|--------|---------|
| `shared/commonMain` | GeminiClient, GeminiProtocol, AudioPipeline, SubtitleBuffer, Languages, AppCoordinator + platform interfaces |
| `shared/androidMain` | Android DebugLog, Base64 |
| `androidApp` | MainActivity (Compose), SubtitleService, MediaProjectionAudioCapture, SubtitleOverlayView, EncryptedApiKeyStore |

### Status

| App state | Meaning |
|-----------|---------|
| Stopped | Not running |
| Connecting to Gemini… | WebSocket opening |
| Running · {Language} | Active — streaming audio to Gemini |
| Listening · {Language} | Non-zero audio frames observed |
| Error | Something went wrong (check notification) |

---

## Reference

* Gemini setup message and reconnect pattern: ported from
  `gemini-live-translate-livekit/src/lib/translation-bridge.ts`.
* Language list: curated subset of
  `gemini-live-translate-livekit/src/lib/languages.ts`.
