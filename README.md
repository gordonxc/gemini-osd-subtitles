# Gemini Subtitles

[English](./README.en.md)

**用 AI 將任何裝置音訊即時轉做字幕同翻譯。** 擷取系統音訊或 mic，串流去 Gemini Live，再將翻譯文字顯示做一個浮動、可拖動、點擊穿透嘅 Overlay。適合睇片、開會、學語言。

用嘅模型：**Gemini Live `gemini-3.5-live-translate-preview`**。你需要一個有呢個 model 權限嘅 Gemini API key。

---

## 主要功能

### 字幕同翻譯
- **即時翻譯** —— 支援 20+ 種目標語言（預設廣東話 `yue`），Gemini 接受基本 ISO 639 code（`yue`、`zh`、`en`、`ja`、`ko`……）
- **標點感知斷句** —— 收到嘅 fragment 喺 CJK / Latin 標點或 1.5 秒語音停頓處斷開，畫面最多同時顯示 2 句
- **雙語 OSD**（macOS）—— 原文行同翻譯行同時顯示，方便語言學習
- **OSD 長度限制** —— 超長句子自動換行到最多 4 行，並頭部截斷（`…最近嘅文字`），永遠唔會超出螢幕

### 音訊來源
- **系統音訊** —— 任何 app 播放緊嘅聲（macOS 用 ScreenCaptureKit，Android 用 MediaProjection）
- **Per-app 隔離**（macOS）—— 淨係擷取指定 app（例如 Chrome、Spotify）嘅音訊，其他全部喺 ScreenCaptureKit layer 過濾走，翻譯影片嗰陣唔會收入通知聲或者另一個 app 嘅音樂
- **Mic 輸入** —— 用內建或外接 mic 翻譯現場對話（Android 用 `VOICE_RECOGNITION` source，平坦頻率響應為 ASR 最佳化）

### OSD 體驗
- **浮動 Overlay** —— 預設 click-through 唔擋住下面個 app；Unlock 之後可以拖到任何位置
- **所有 Space 都見到**
- **字體大小可調** —— 14–72 pt，持久化儲存
- **自動淡出** —— 最後一次更新後 4 秒淡出（200 ms alpha fade）
- **拖出螢幕自動彈返**（macOS）—— 放手嗰陣自動 snap 返入可見區域
- **動態 line budget** —— 大字體喺短螢幕會自動減少行數，OSD 永遠唔會高過螢幕

### 實用功能
- **字幕歷史** —— 每次 session 自動儲存，可匯出（macOS 支援 SRT/VTT/JSON/TXT）
- **閒置自動停止** —— 可選 5 / 15 / 30 / 60 分鐘無音訊後自動停
- **內建自動更新**（macOS）—— 經 Sparkle 檢查新版本，launch 時自動檢查一次，亦可以手動撳 **Check for Updates…**
- **狀態 icon 顏色**（macOS）/ 狀態 Card 色點（Android）—— 一眼睇到目前狀態

### 狀態顏色

| 顏色 | macOS 意思 | Android 意思 |
|------|-----------|-------------|
| 灰   | 已停止 | 未運行 |
| 黃   | 連線中 / 重連中 | WebSocket 開緊 |
| 綠   | 活動中 —— 緊要傳送音訊去 Gemini | 活動中 |
| 藍   | 偵測到非零音訊 frame | — |
| 紅   | 錯誤（會彈通知） | 出錯 |

---

## 平台

| 平台 | 狀態 | 來源 |
|------|------|------|
| macOS 14.0+ | 穩定 —— 用穩定自簽憑證簽署，內建 Sparkle 自動更新 | `Sources/` (Swift) |
| Android 10+ (API 29) | Debug build | `shared/` + `androidApp/` (Kotlin Multiplatform) |

---

## macOS

### 安裝

1. 去 [Releases](https://github.com/gordonxc/gemini-osd-subtitles/releases) 下載最新嘅 `GeminiSubtitles-vX.Y.Z.zip`
2. 解壓縮，將 `GeminiSubtitles.app` 拖去 `~/Applications`（Sparkle 喺可寫位置可以做 in-place 更新；放 `/Applications` 更新嗰陣要 admin 密碼）
3. 第一次要用 right-click → **Open** 開（因為 bundle 用自簽憑證而唔係 Apple Developer ID，Gatekeeper 會彈警告）。或者清除隔離 flag：
   ```sh
   xattr -dr com.apple.quarantine GeminiSubtitles.app
   open GeminiSubtitles.app
   ```

### 首次設定

1. 撳 menu bar 嗰個 captions-bubble icon → **Set API Key…** → 貼你嘅 Gemini API key（儲喺 Keychain）
2. 揀目標語言（預設廣東話 `yue`）
3. 撳 **Start**。第一次會跳去 **System Settings → Privacy & Security → Screen Recording** —— 開啟 **Gemini Subtitles**，然後 quit 再重開
4. 播任何音訊。1–3 秒內就會見到翻譯字幕

### Menu 一覽

- **Start / Stop** —— 切換 capture → Gemini → OSD pipeline
- **Target Language** —— 目標語言 picker
- **Audio Source** —— 三種：
  - **System Audio** —— 全系統混音
  - **Single App** —— per-app 隔離（揀目前運行緊嘅 app）
  - **Microphone** —— mic 輸入
- **Font Size** —— 14–72 pt
- **Auto-stop** —— Off / 5 / 15 / 30 / 60 分鐘
- **Bilingual: On/Off** —— 顯示原文 + 翻譯
- **History** —— 查看 / 匯出 / 清除歷史
- **Unlock OSD to Move / Lock OSD** —— 切換可拖性
- **Set API Key…**
- **Check for Updates…**
- **Quit**

### 除錯

診斷 log 喺 `~/Library/Logs/GeminiSubtitles.log`：

```sh
tail -f ~/Library/Logs/GeminiSubtitles.log
```

---

## Android

### 安裝

1. 去 [Releases](https://github.com/gordonxc/gemini-osd-subtitles/releases) 下載最新嘅 `androidApp-debug.apk`（或者自己編譯：`gradle assembleDebug`）
2. `adb install -r androidApp-debug.apk`（或者直接喺手機撳 APK 安裝）

### 首次設定

1. 開 app → 輸入 Gemini API key
2. 揀目標語言（預設廣東話）
3. 撳 **Start** → 授「Display over other apps」權限
4. 系統會問 screen capture 權限（MediaProjection）→ **Start now**
   * Mic 模式會問 RECORD_AUDIO 權限 → Allow
5. 播任何音訊 —— 翻譯字幕就會喺浮動 overlay 出現

### 音源切換

Settings 入面有 **Audio Source** switch：

- **System Audio（預設）** —— MediaProjection 擷取任何 app 嘅播放音訊。適合翻譯影片 / 音樂
- **Microphone** —— `AudioRecord` + `VOICE_RECOGNITION`。適合翻譯現場對話

切換時如果正緊 running，pipeline 會自動重啟。

### 權限

| 權限 | 點解要用 |
|------|----------|
| `INTERNET` + `ACCESS_NETWORK_STATE` | 連 Gemini WebSocket |
| `RECORD_AUDIO` | MediaProjection 同 mic 擷取音訊 |
| `FOREGROUND_SERVICE` + `_MEDIA_PROJECTION` + `_MICROPHONE` | 背景擷取音訊 |
| `SYSTEM_ALERT_WINDOW` | 浮動字幕 overlay |
| `POST_NOTIFICATIONS` | 錯誤通知（Android 13+） |

### 除錯

```sh
adb logcat -s GeminiSubtitles:D
adb logcat -b crash    # crash trace
```

---

## 參考

Gemini 協定同 reconnect 邏輯：ported 自 [`gemini-live-translate-livekit`](https://github.com/pixellegend/gemini-live-translate-livekit) 嘅 `translation-bridge.ts`。語言清單係同一來源嘅精選子集。
