# Gemini Subtitles

[English](./README.en.md)

用 **Gemini Live `gemini-3.5-live-translate-preview`** 模型做即時字幕。擷取裝置播放緊嘅系統音訊，串流到 Gemini，再將翻譯文字顯示做一個可拖動、可點擊穿透嘅浮動 Overlay。

呢個 repo 入面有兩個 native port：

| 平台    | 路徑        | 狀態 |
|---------|-------------|------|
| macOS   | `Sources/` (Swift) | 推出中 — 用穩定自簽憑證簽署嘅 release build，內建 Sparkle 自動更新 |
| Android | `shared/` + `androidApp/` (Kotlin Multiplatform) | Debug build 可用 |

---

## macOS app

Menu bar 工具（`LSUIElement = true`，無 Dock icon）。用 ScreenCaptureKit 擷取全系統音訊；浮動 OSD 用 `NSPanel`。

* **無任何第三方依賴** —— 全部用 Apple framework（AppKit、ScreenCaptureKit、AVFoundation、CoreGraphics、Security、UserNotifications）。
* **雙行 OSD + 標點感知斷句** —— 收到嘅 fragment 會喺 CJK / Latin 標點或者 1.5 秒語音停頓處斷開，畫面最多同時顯示 2 句。
* **可調字體大小（14–72 pt）、可拖動、持久化** —— Unlock OSD 就可以拖到任何位置；預設 click-through 唔會擋住下面個 app。
* **閒置自動停止** —— 可選 5 / 15 / 30 / 60 分鐘無音訊後自動停止 session。

> Gemini 協定同 reconnect 邏輯係 `gemini-live-translate-livekit/src/lib/translation-bridge.ts` 嘅 Swift port，LiveKit 音訊傳輸改做 native ScreenCaptureKit。

### 系統需求

* macOS 14.0 或以上（已測試 macOS 26 Tahoe）
* Xcode command-line tools（`xcode-select --install`）
* 有 `gemini-3.5-live-translate-preview` 權限嘅 Gemini API key

### 編譯

```sh
swift build -c release
```

Binary 會喺 `.build/release/GeminiSubtitles`。

### 用 `.app` bundle 執行

`run.sh` 會編譯 release binary、複製入 `GeminiSubtitles.app/`、重新簽署 bundle，再用 `open` 啟動（令 TCC 見到正確嘅 bundle identity）：

```sh
./run.sh
```

第一次要用 right-click → **Open** 開（因為 bundle 用自簽憑證而唔係 Apple Developer ID，Gatekeeper 會彈警告）。要清除隔離 flag：

```sh
xattr -dr com.apple.quarantine GeminiSubtitles.app
open GeminiSubtitles.app
```

### 首次設定

1. 撳 menu bar 嗰個 captions-bubble icon → **Set API Key…** → 貼你嘅 Gemini API key。會儲喺 Keychain（`com.gemini-subtitles.apikey`）。
2. 揀目標語言（預設廣東話 `yue`）。Gemini 淨係接受基本 ISO 639 code（`yue`、`zh`、`en`、`ja`……）。
3. 撳 **Start**。第一次會跳去 **System Settings → Privacy & Security → Screen Recording** —— 開啟 **Gemini Subtitles**，然後 quit 再重開。
4. 播任何音訊。1–3 秒內就會見到翻譯字幕。狀態 icon 會由綠色轉做 **藍色**（偵測到非零音訊 frame），靜音 3 秒後轉返綠色。

> **macOS 26 Tahoe 注意：** 我哋用 ScreenCaptureKit 嘅音訊擷取而唔係 CoreAudio process tap（`AudioHardwareCreateProcessTap`）。Tahoe 上 CATap 對自簽／未公證嘅 app 會靜悄悄填零音訊 buffer 無任何 error。ScreenCaptureKit 嘅 **Screen Recording** 權限就正常運作。

### Per-app capture（單一 app 擷取）

喺 **Audio Source → Single App** 入面可以將擷取限制做單一運行緊嘅應用程式（Chrome、Spotify、QuickTime Player……）。淨係嗰個 app 嘅音訊會傳去 Gemini，其他全部喺 ScreenCaptureKit layer 用 `SCContentFilter(display:including:exceptingWindows:)` 過濾走。用例：

- 翻譯 YouTube 影片但唔想收入通知聲或者另一個 app 嘅音樂。
- 將視像會議嘅音訊同系統提示聲隔開。

注意事項：

- Picker 列出有 on-screen window 嘅 regular-policy app；每次打開 menu 都會刷新。
- 選擇用 **bundle identifier** 持久化（PID 每次開都變）。如果揀咗嘅 app 啟動嗰陣冇 running，capture 會退返去 whole-system 並 log 一行，唔會硬性 fail。
- 無法 per-tab 隔離 —— 瀏覽器每個 process 淨係出一條音訊 stream，唔係每個 tab 一條。

### 狀態 icon 顏色

| 顏色  | 意思                                                  |
|---------|----------------------------------------------------------|
| 灰     | 已停止                                                  |
| 黃     | 連線中 / 重連中                                |
| 綠     | 活動中 —— 緊要傳送音訊去 Gemini                      |
| 藍     | 偵測到非零音訊 frame（capture 正常）     |
| 紅     | 錯誤（會同時彈 macOS 通知）              |

### OSD 行為

* **雙行捲動顯示** —— 收到嘅 fragment 會累積喺 `SubtitleBuffer`，喺 CJK / Latin 標點或者 1.5 秒語音停頓處斷開。最多同時顯示 2 行。
* **字體大小** —— picker 提供 14–72 pt（預設 20）。儲存喺 UserDefaults。Window 會動態調整大小。
* **Lock / Unlock** —— 預設 click-through；**Unlock OSD to Move** 可以拖。
* **自動淡出** —— 最後一次更新後 4 秒（200 ms alpha fade）。3 秒靜音降級時自動 hide。
* **所有 Space 都見到**（`collectionBehavior = .canJoinAllSpaces`）。

### Menu

* **Start / Stop** —— 切換 capture → Gemini → OSD pipeline。
* **Target Language** —— picker（精選，預設廣東話）。
* **Audio Source** —— 系統預設、指定輸出裝置、**單一應用程式**（per-app 隔離），或者 mic。
* **Font Size** —— 14–72 pt。
* **Auto-stop** —— Off / 5 / 15 / 30 / 60 分鐘閒置 timeout。
* **Unlock OSD to Move / Lock OSD** —— 切換可拖性。
* **Set API Key…** —— modal 輸入，key 儲喺 Keychain。
* **Check for Updates…** —— 經 Sparkle 檢查 `appcast.xml` 有冇新版本（launch 時都會自動檢查一次）。
* **Quit**

### 架構（macOS）

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

| 檔案                          | 職責                                                  |
|-------------------------------|-----------------------------------------------------------------|
| `main.swift` / `AppDelegate`  | Bootstrap、status item、icon 上色                            |
| `StatusMenuController`        | Menu、語言 / 音源 / 字體大小 / auto-stop picker、API-key alert |
| `KeychainStore`               | API key 嘅 `SecItem` wrapper                               |
| `Permissions`                 | Screen Capture TCC preflight / request / deep-link              |
| `AudioCapture`                | `SCStream` wrapper，AudioBufferList → Float32                   |
| `AudioPipeline`               | Float32→Int16、base64、100 ms framing                           |
| `GeminiClient`                | `URLSessionWebSocketTask`、setup、receive loop、reconnect       |
| `GeminiProtocol`              | Setup / realtimeInput / outputTranscription message helpers     |
| `SubtitleBuffer`              | 累積 fragment、喺標點 / 停頓處斷開、2-line window |
| `SubtitleWindow` / `SubtitleViewController` | 浮動 panel、font resize、lock/unlock、fade timer |
| `NotificationManager`         | `UNUserNotificationCenter` for critical errors                  |
| `DebugLog`                    | File logger（`~/Library/Logs/GeminiSubtitles.log`）繞過 unified-log privacy masking |
| `AppCoordinator`              | 統籌 capture ↔ Gemini ↔ OSD；將狀態 map 去 icon/menu   |

### 自動更新（Sparkle 2）

macOS app 內建 [Sparkle 2](https://github.com/sparkle-project/Sparkle) 做 in-app 自動更新。運作方式：

* App 啟動嗰陣會自動 fetch 一次 `appcast.xml`（單次檢查，唔會背景定期 poll）。
* 亦可以隨時撳 menu bar → **Check for Updates…** 手動檢查。
* 有新版本就會彈出 Sparkle 嘅標準更新視窗，確認後會下載、驗證 EdDSA 簽名、取代 `.app` bundle 再 relaunch。
* 更新封存（zip）用 EdDSA 簽名（獨立於 code-signing 憑證），所以即使個 bundle 用自簽憑證，Sparkle 都可以驗證更新檔無被竄改。
* **安裝位置限制：** 如果個 app 放喺 `~/Applications`、`~/Downloads` 等可寫位置，Sparkle 可以無需密碼直接替換。如果放喺 `/Applications`（system-wide），Sparkle 會彈 admin 密碼 prompt。

Feed URL（`Info.plist` 嘅 `SUFeedURL`）：

```
https://raw.githubusercontent.com/gordonxc/gemini-osd-subtitles/main/appcast.xml
```

#### 發佈新版本

1. 改 `Sources/GeminiSubtitles/Assets/Info.plist` 嘅 `CFBundleShortVersionString` 去新版本（例如 `0.7.0`）。
2. 確保你已經有 Sparkle 嘅 EdDSA keypair（只需做一次）：
   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   `generate_keys` 會印出公鑰 —— 貼去 `Info.plist` 嘅 `SUPublicEDKey`。私鑰儲喺你嘅 login Keychain（唔會寫落 disk）；要喺另一部機發佈就用 `generate_keys -x <file>` 匯出。
3. 跑：
   ```sh
   ./publish-release.sh 0.7.0 "Release notes..."
   ```
   Script 會：build release → `ditto` 打 zip → `sign_update` EdDSA 簽 → `gh release create` 上傳去 GitHub Releases → 更新 `appcast.xml` → commit + push。

`appcast.xml` 係 source-of-truth，每次發佈都會喺 repo 入面更新；用戶端嘅 app 會由 raw GitHub URL 讀取。

### 除錯（macOS）

診斷 log 會寫去 `~/Library/Logs/GeminiSubtitles.log`。Tail：

```sh
tail -f ~/Library/Logs/GeminiSubtitles.log
```

常用 grep 關鍵字：

* `AudioCapture SCK: ... silent=false` —— 有音訊 frame 流過（icon 轉藍）。
* `GeminiClient setupComplete received ✓` —— WebSocket setup 成功。
* `AudioPipeline emit chunk #N` —— 緊要傳音訊 chunk 去 Gemini。
* `GeminiClient.handleIncoming` —— 原始 server 回應（翻譯喺 `serverContent.outputTranscription.text`）。

---

## Android app（KMP port）

Kotlin Multiplatform port。Gemini 協定、音訊 pipeline、字幕緩衝放喺 `shared/commonMain`，Android 特定實作放喺 `shared/androidMain` 同 `androidApp`。

### 平台決策

- **音訊擷取：** MediaProjection + AudioPlaybackCaptureConfiguration（系統音訊）或 `AudioRecord` + `VOICE_RECOGNITION`（mic）
- **OSD：** WindowManager TYPE_APPLICATION_OVERLAY（浮動、click-through、可拖）
- **UI：** Jetpack Compose（設定）+ 傳統 View（Overlay）
- **iOS：** 暫緩 —— KMP 架構透過 platform interface 預留位

### 系統需求

- Android 10+（API 29）
- 有 `gemini-3.5-live-translate-preview` 權限嘅 Gemini API key
- JDK 17（Gradle 8.11.1 + AGP 8.7.3 + Kotlin 2.1.0）

### 編譯

Repo 無 `gradlew` wrapper，要用本地 Gradle 8.11.1（AGP 8.7.3 同新版 Gradle 唔相容）：

```sh
# 指定 Android SDK 路徑
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties

# 編譯 debug APK
gradle assembleDebug        # 如果 PATH 有 gradle 8.11.1，或：
/path/to/gradle-8.11.1/bin/gradle assembleDebug
```

APK 會喺 `androidApp/build/outputs/apk/debug/androidApp-debug.apk`。

安裝到連接嘅裝置：

```sh
adb install -r androidApp/build/outputs/apk/debug/androidApp-debug.apk
```

### 權限

| 權限 | 點解要用 |
|------------|-----|
| `INTERNET` + `ACCESS_NETWORK_STATE` | 連去 Gemini WebSocket endpoint |
| `RECORD_AUDIO` | MediaProjection 同 mic 擷取音訊 |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION` + `FOREGROUND_SERVICE_MICROPHONE` | 背景擷取音訊 |
| `SYSTEM_ALERT_WINDOW` | 浮動字幕 overlay |
| `POST_NOTIFICATIONS` | 錯誤通知（Android 13+） |

### 首次設定

1. 開 app → 輸入 Gemini API key
2. 揀目標語言（預設廣東話 `yue`）
3. 撳 **Start** → 如果問就授「Display over other apps」權限
4. 系統會問 screen capture 權限（MediaProjection）→ **Start now**
   * 如果用緊 Mic 模式：會問 RECORD_AUDIO 權限 → Allow
5. 播任何音訊 —— 翻譯字幕就會喺浮動 overlay 出現

### 音源切換

Settings 入面有 **Audio Source** switch：

- **System Audio（預設）** —— 用 MediaProjection 擷取任何 app 嘅播放音訊。適合翻譯影片 / 音樂。
- **Microphone** —— 用 `AudioRecord` + `AudioSource.VOICE_RECOGNITION`（平坦頻率響應，為 ASR 最佳化）。適合翻譯現場對話。

切換時如果正緊 running，pipeline 會自動重啟。由 Mic 切去 System 會再問一次 MediaProjection consent。

### 架構（Android）

```
MediaProjection / AudioRecord ──Float32 PCM──▶ AudioPipeline ──base64 Int16 PCM──▶ GeminiClient
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

### 模組結構

| 模組 | 內容 |
|--------|---------|
| `shared/commonMain` | GeminiClient、GeminiProtocol、AudioPipeline、SubtitleBuffer、Languages、AppCoordinator + platform interface |
| `shared/androidMain` | Android DebugLog、Base64 |
| `androidApp` | MainActivity (Compose)、SubtitleService、MediaProjectionAudioCapture、MicrophoneAudioCapture、SubtitleOverlayView、OutlinedTextView、EncryptedApiKeyStore |

### 狀態

Status Card 有色點指示狀態：

| 狀態 | 色點顏色 | 意思 |
|-----------|---------|------|
| Stopped | 灰 | 未運行 |
| Connecting | 黃 | WebSocket 開緊 |
| Running | 綠 | 活動中 —— 緊要傳音訊去 Gemini |
| Error | 紅 | 出咗錯（睇通知） |

### 除錯（Android）

診斷 log 經 `android.util.Log.d` 出，tag 係 `GeminiSubtitles`。捕捉：

```sh
adb logcat -s GeminiSubtitles:D
# Crash trace：
adb logcat -b crash
```

常用 grep 關鍵字：

* `GeminiClient.webSocket connected` —— TCP/TLS handshake 完成。
* `GeminiClient received frame #N: Binary` —— Gemini 通常用 Binary frame 發 JSON；client 兩種都 decode。
* `GeminiClient setupComplete received ✓` —— handshake 成功；準備好收音訊。
* `AppCoordinator.beginAudioCaptureIfRunning: starting capture` —— capture 開始（500 ms grace period 之後）。
* `AudioPipeline emit chunk #N` —— 緊要傳音訊 chunk 去 Gemini。

### 注意事項

* **Ktor 3.x package 改名：** WebSocket API 由 2.x 嘅 `io.ktor.client.plugins.websockets`（眾數）改做 3.x 嘅 `io.ktor.client.plugins.websocket`（單數）。呢個 code 同 import 反映 3.x。
* **Binary frame：** Gemini bidi endpoint 用 Binary（唔係 Text）frame 回 `setup`。Receive loop 兩種都當 UTF-8 JSON decode。
* **無 gradle wrapper：** merge 淨係帶咗 `gradle-wrapper.properties`，無 `gradlew` / `gradlew.bat`。要用本地 Gradle 8.11.1。

---

## 參考

* Gemini setup message 同 reconnect pattern：ported 自 `gemini-live-translate-livekit/src/lib/translation-bridge.ts`。
* 語言清單：`gemini-live-translate-livekit/src/lib/languages.ts` 嘅精選子集。
