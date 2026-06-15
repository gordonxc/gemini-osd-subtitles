# Gemini Subtitles (macOS OSD)

A macOS menu-bar utility that captures system audio, streams it to the
**Gemini Live `gemini-3.5-live-translate-preview`** model, and renders the
translated text as a floating, on-screen subtitle overlay.

* **Zero third-party dependencies** — built entirely on Apple frameworks
  (AppKit, ScreenCaptureKit, AVFoundation, CoreGraphics, Security,
  UserNotifications).
* **Menu-bar only** — `LSUIElement = true`, no Dock icon.
* **System-wide audio** — ScreenCaptureKit taps the main display's audio
  output, so anything playing on the Mac (browser, video player, Zoom, …)
  is translated.
* **2-line OSD with punctuation-aware splitting** — incoming fragments are
  buffered and split on CJK / Latin punctuation or 1.5 s speech pauses; up
  to 2 sentences stay on screen at once.
* **Configurable font size, draggable, persistent** — pick from 14–72 pt;
  unlock the OSD to drag it anywhere; click-through by default so it never
  blocks the app underneath.

> The Gemini protocol and reconnect logic is a Swift port of
> `gemini-live-translate-livekit/src/lib/translation-bridge.ts`, with the
> LiveKit audio transport replaced by native ScreenCaptureKit.

## Requirements

* macOS 14.0 or later (tested on macOS 26 Tahoe)
* Xcode command-line tools (`xcode-select --install`)
* A Gemini API key with access to `gemini-3.5-live-translate-preview`

## Build

From this directory:

```sh
swift build -c release
```

The binary is emitted at `.build/release/GeminiSubtitles`.

## Run as a `.app` bundle

`swift build` produces a bare executable; to get the menu-bar behaviour,
`LSUIElement`, and TCC usage strings, wrap it in a minimal bundle. The
provided `run.sh` script does this end-to-end:

```sh
./run.sh
```

It builds the release binary, copies it into `GeminiSubtitles.app/`,
re-signs the bundle with the bundled entitlements, and launches via `open`
so TCC sees a proper bundle identity. Manual steps if you prefer:

```sh
mkdir -p GeminiSubtitles.app/Contents/MacOS
cp .build/release/GeminiSubtitles GeminiSubtitles.app/Contents/MacOS/
cp Sources/GeminiSubtitles/Assets/Info.plist GeminiSubtitles.app/Contents/
codesign --force --deep --sign - \
  --entitlements GeminiSubtitles.entitlements GeminiSubtitles.app
open GeminiSubtitles.app
```

Launch with right-click → **Open** the first time (Gatekeeper will warn
because the bundle is adhoc-signed). To clear the quarantine flag for your
own machine:

```sh
xattr -dr com.apple.quarantine GeminiSubtitles.app
open GeminiSubtitles.app
```

## First-run setup

1. Click the captions-bubble icon in the menu bar → **Set API Key…** → paste
   your Gemini API key. It is stored in the macOS Keychain under
   `com.gemini-subtitles.apikey` (verify with
   `security find-generic-password -s com.gemini-subtitles.apikey`).
2. Choose a target language from the menu (defaults to Cantonese `yue`).
   Gemini accepts base ISO 639 codes only (`yue`, `zh`, `en`, `ja`, …); the
   picker exposes a curated list.
3. Click **Start**. On first run you'll be deep-linked to **System Settings →
   Privacy & Security → Screen Recording** — toggle **Gemini Subtitles** ON,
   then **Quit and relaunch** the app (TCC requires a restart after the
   first grant).
4. Play any audio on your Mac. Translated subtitles appear in the floating
   panel near the bottom of the screen within 1–3 s. The status icon flips
   from green to **blue** the moment non-zero audio frames are observed.

> **macOS 26 Tahoe note:** we use ScreenCaptureKit's audio capture rather
> than the CoreAudio process tap (`AudioHardwareCreateProcessTap`). On Tahoe
> the CATap path silently zero-fills audio buffers for adhoc-signed apps
> with no error, even when the user toggles the **System Audio Recording**
> permission ON. ScreenCaptureKit's **Screen Recording** permission works
> reliably for adhoc signatures.

## Status icon colours

| Colour  | Meaning                                                  |
|---------|----------------------------------------------------------|
| Gray    | Stopped                                                  |
| Yellow  | Connecting / reconnecting                                |
| Green   | Active — streaming audio to Gemini                       |
| Blue    | Non-zero audio frames observed (capture is flowing)      |
| Red     | Error (also surfaces a macOS notification)               |

Transient network blips are silent: the icon briefly flickers and the
WebSocket auto-reconnects after 1 s. Only critical errors (invalid API key,
exhausted reconnects, capture failures) post a notification.

## OSD behaviour

* **2-line rolling display** — incoming transcription fragments are
  accumulated in `SubtitleBuffer` and split into lines on:
  * CJK punctuation: `。 ？ ！ ， 、 ； ： …`
  * Latin punctuation: `. ? ! , ; :` and newlines
  * **1.5 s speech pause** (no new text arrived)
  At most 2 lines are visible at once; older lines scroll off as new ones
  arrive.
* **Font size** — picker in the menu offers 14, 18, 20, 24, 28, 32, 40, 48,
  56, 64, 72 pt (default 20). Selection is persisted in UserDefaults and
  restored on next Start. The window resizes dynamically to fit the chosen
  font.
* **Lock / Unlock** — by default the OSD is click-through (mouse events
  pass to the app underneath). Use **Unlock OSD to Move** to make it
  draggable; click **Lock OSD** to resume click-through at the new position.
* **Auto-fade** 4 s after the last update (200 ms alpha fade).
* **Visible across all Spaces** (`collectionBehavior = .canJoinAllSpaces`).

## Menu

* **Start** / **Stop** — toggles the capture → Gemini → OSD pipeline.
* **Target Language** — picker (curated, defaults to Cantonese).
* **Audio Source** — system default or a specific output device.
* **Font Size** — 14–72 pt.
* **Unlock OSD to Move** / **Lock OSD** — toggle draggability.
* **Set API Key…** — modal prompt storing the key in Keychain.
* **Quit**

## Architecture

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
                                              SubtitleBuffer ──split on punctuation / pause──▶ on.update
                                                                                                    │
       SubtitleWindow ◀────────────────────────────────────────────────── handleTranscription(text)
```

| File                          | Responsibility                                                  |
|-------------------------------|-----------------------------------------------------------------|
| `main.swift` / `AppDelegate`  | Bootstrap, status item, icon tinting                            |
| `StatusMenuController`        | Menu, language / audio-source / font-size pickers, API-key alert |
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

## Debugging

Diagnostic logs are written to `~/Library/Logs/GeminiSubtitles.log`. Tail
with:

```sh
tail -f ~/Library/Logs/GeminiSubtitles.log
```

Key signals to grep for:

* `AudioCapture SCK: ... silent=false` — audio frames flowing (icon will
  turn blue).
* `GeminiClient setupComplete received ✓` — WebSocket setup succeeded.
* `AudioPipeline emit chunk #N` — audio chunks being sent to Gemini.
* `GeminiClient.handleIncoming` — raw server responses (translations live
  under `serverContent.outputTranscription.text`).

## Reference

* Gemini setup message and reconnect pattern: ported from
  `gemini-live-translate-livekit/src/lib/translation-bridge.ts`
  (setup at lines 328–354, reconnect at 272–326, send at 579–617).
* Language list: curated subset of
  `gemini-live-translate-livekit/src/lib/languages.ts`.
