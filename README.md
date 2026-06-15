# Gemini Subtitles (Android)

A Kotlin Multiplatform port of [gemini-osd-subtitles](https://github.com/gordonxc/gemini-osd-subtitles) — a macOS menu-bar app that captures system audio, streams it to the **Gemini Live `gemini-3.5-live-translate-preview`** model, and renders translated text as a floating on-screen subtitle overlay.

## Architecture

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

### Platform decisions

- **Audio capture:** MediaProjection + AudioPlaybackCaptureConfiguration (system audio)
- **OSD:** WindowManager TYPE_APPLICATION_OVERLAY (floating, click-through, draggable)
- **UI:** Jetpack Compose (Settings) + traditional View (Overlay)
- **iOS:** Deferred — KMP architecture reserves the slot via platform interfaces

## Requirements

- Android 10+ (API 29)
- A Gemini API key with access to `gemini-3.5-live-translate-preview`

## Build

```sh
./gradlew assembleDebug
```

## Permissions

| Permission | Why |
|------------|-----|
| `RECORD_AUDIO` | Audio capture via MediaProjection |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background audio capture |
| `SYSTEM_ALERT_WINDOW` | Floating subtitle overlay |
| `POST_NOTIFICATIONS` | Error notifications (Android 13+) |

## First-run setup

1. Open app → enter Gemini API key
2. Choose target language (defaults to Cantonese `yue`)
3. Tap **Start** → grant "Display over other apps" permission if prompted
4. System will ask for screen capture permission (MediaProjection) → **Start now**
5. Play any audio — translated subtitles appear in the floating overlay

## Status

| App state | Meaning |
|-----------|---------|
| Stopped | Not running |
| Connecting to Gemini… | WebSocket opening |
| Running · {Language} | Active — streaming audio to Gemini |
| Listening · {Language} | Non-zero audio frames observed |
| Error | Something went wrong (check notification) |

## Reference

- macOS original: [gemini-osd-subtitles](https://github.com/gordonxc/gemini-osd-subtitles)
- Gemini protocol: ported from `gemini-live-translate-livekit/src/lib/translation-bridge.ts`
