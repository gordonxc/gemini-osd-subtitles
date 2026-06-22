package com.gordonxc.geminisubtitles

import com.gordonxc.geminisubtitles.platform.PlatformApiKeyStore
import com.gordonxc.geminisubtitles.platform.PlatformAudioCapture
import com.gordonxc.geminisubtitles.platform.PlatformNotifier
import com.gordonxc.geminisubtitles.platform.PlatformOverlay
import io.ktor.client.HttpClient
import io.ktor.client.plugins.websockets.WebSockets
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Orchestrates the end-to-end pipeline:
 *
 *     AudioCapture → Float32 → AudioPipeline (Int16+base64) → GeminiClient
 *                                                                    ↓
 *     Overlay ← (SubtitBuffer ← onTranscription)
 *
 * Plus status reporting via [state] and [statusText] StateFlows.
 *
 * Ported from Swift `AppCoordinator.swift`. Platform abstractions are
 * injected via constructor — each platform provides its own
 * AudioCapture, Overlay, ApiKeyStore, and Notifier.
 */
class AppCoordinator(
    private val apiKeyStore: PlatformApiKeyStore,
    private val audioCapture: PlatformAudioCapture,
    private val overlay: PlatformOverlay,
    private val notifier: PlatformNotifier,
) {
    enum class RunState {
        STOPPED, STARTING, ACTIVE, RECEIVING_AUDIO, ERROR
    }

    enum class StopReason { USER_REQUESTED, LANGUAGE_CHANGED }

    private val _state = MutableStateFlow(RunState.STOPPED)
    val state: StateFlow<RunState> = _state

    private val _statusText = MutableStateFlow("Stopped")
    val statusText: StateFlow<String> = _statusText

    private var gemini: GeminiClient? = null
    private val pipeline = AudioPipeline()
    private val subtitleBuffer = SubtitleBuffer()

    private var currentTargetLanguage: String = Languages.defaultCode
    private var fontSize: Float = 20f

    private val httpClient = HttpClient {
        install(WebSockets)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // MARK: Launch

    fun start(targetLanguage: String) {
        currentTargetLanguage = targetLanguage
        DebugLog.write("AppCoordinator.start targetLanguage=$targetLanguage")

        // 1. API key check.
        val apiKey = apiKeyStore.getApiKey()
        if (apiKey.isNullOrEmpty()) {
            DebugLog.write("AppCoordinator.start: NO API KEY")
            _state.value = RunState.ERROR
            _statusText.value = "No API key set"
            notifier.notify(
                "Gemini Subtitles",
                "Set your Gemini API key from settings to start."
            )
            return
        }

        _state.value = RunState.STARTING
        _statusText.value = "Connecting to Gemini…"

        // 2. Build Gemini client.
        DebugLog.write("AppCoordinator.start got API key (length=${apiKey.length})")
        val client = GeminiClient(
            apiKey = apiKey,
            targetLanguage = targetLanguage,
            httpClient = httpClient,
        )
        client.onTranscription = { text, _ ->
            subtitleBuffer.append(text)
        }
        client.onError = { error -> handleGeminiError(error) }
        client.onStatusChange = { status -> handleGeminiStatus(status) }
        gemini = client

        // 3. Wire audio capture → pipeline → Gemini.
        audioCapture.onSamples = { samples, silent ->
            pipeline.process(samples)
            if (!silent) markAudioReceived()
        }
        audioCapture.onError = { error -> handleAudioError(error) }

        // 4. Wire pipeline chunks → GeminiClient.sendAudio.
        pipeline.onChunk = { base64 ->
            gemini?.sendAudio(base64)
        }

        // 5. Wire subtitle buffer → overlay.
        subtitleBuffer.onUpdate = { text ->
            overlay.updateText(text)
        }

        // 6. Start Gemini first; audio kicks in once setup is complete.
        client.start()

        // Show the OSD.
        overlay.setFontSize(fontSize)
        overlay.reveal()

        // 7. Start audio capture after a brief grace period for Gemini setup.
        scope.launch {
            delay(500)
            beginAudioCaptureIfRunning()
        }
    }

    fun stop(reason: StopReason = StopReason.USER_REQUESTED) {
        audioCapture.stop()
        gemini?.stop()
        gemini = null
        pipeline.reset()
        subtitleBuffer.reset()
        overlay.hide()
        _state.value = RunState.STOPPED
        _statusText.value = if (reason == StopReason.LANGUAGE_CHANGED) "Switching language…" else "Stopped"
    }

    // MARK: Callbacks

    fun toggleOSDLock(): Boolean = overlay.toggleLock()

    fun setSubtitleFontSize(size: Float) {
        fontSize = size
        overlay.setFontSize(size)
    }

    private fun markAudioReceived() {
        if (_state.value == RunState.ACTIVE) {
            _state.value = RunState.RECEIVING_AUDIO
            _statusText.value = "Listening · ${Languages.nameForCode(currentTargetLanguage)}"
        }
    }

    private fun handleGeminiStatus(status: GeminiClient.Status) {
        when (status) {
            GeminiClient.Status.READY -> {
                _state.value = RunState.ACTIVE
                _statusText.value = "Running · ${Languages.nameForCode(currentTargetLanguage)}"
            }
            GeminiClient.Status.CONNECTING -> {
                if (_state.value != RunState.STARTING) {
                    _state.value = RunState.STARTING
                    _statusText.value = "Reconnecting…"
                }
            }
            GeminiClient.Status.CLOSED -> {
                if (_state.value != RunState.STOPPED) {
                    _state.value = RunState.STOPPED
                    _statusText.value = "Disconnected"
                }
            }
            GeminiClient.Status.IDLE -> {}
        }
    }

    private fun handleGeminiError(error: Throwable) {
        _state.value = RunState.ERROR
        _statusText.value = "Error: ${error.message}"
        notifier.notify("Gemini Subtitles error", error.message ?: "Unknown error")
    }

    private fun handleAudioError(error: Throwable) {
        val isPermissionError = error.message?.lowercase()?.let {
            it.contains("permission") || it.contains("not authorized") || it.contains("denied")
        } ?: false

        _state.value = RunState.ERROR
        _statusText.value = if (isPermissionError) {
            "Audio capture permission required"
        } else {
            "Audio: ${error.message}"
        }

        notifier.notify(
            if (isPermissionError) "Audio capture permission needed" else "Audio capture error",
            error.message ?: "Unknown error"
        )
    }

    private fun beginAudioCaptureIfRunning() {
        if (gemini == null) {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning: no gemini client, aborting")
            return
        }
        DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning: starting capture")
        try {
            audioCapture.start()
        } catch (e: Exception) {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning FAILED: ${e.message}")
            handleAudioError(e)
        }
    }

    fun destroy() {
        // Save gemini ref before stop() nulls it
        val g = gemini
        stop()
        g?.destroy()
        httpClient.cancel()
        subtitleBuffer.destroy()
        scope.cancel()
    }
}
