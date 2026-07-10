package com.gordonxc.geminisubtitles

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * WebSocket client for the Gemini Live bidi stream.
 *
 * Ported from Swift `GeminiClient.swift`, replacing `URLSessionWebSocketTask`
 * with Ktor WebSocket client.
 *
 * Responsibilities:
 *   - Open the WS, send the `setup` message, await `setupComplete`.
 *   - Run a receive loop, dispatching transcription callbacks.
 *   - Drop audio sends while not ready.
 *   - Reconnect after an unexpected close while in the active state.
 */
class GeminiClient(
    private val apiKey: String,
    private val targetLanguage: String,
    private val httpClient: HttpClient,
) {
    var onTranscription: ((text: String, isFinal: Boolean) -> Unit)? = null
    var onError: ((Throwable) -> Unit)? = null
    var onStatusChange: ((Status) -> Unit)? = null

    enum class Status { IDLE, CONNECTING, READY, CLOSED }

    private val endpointUrl =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private var status: Status = Status.IDLE
        set(value) { field = value; onStatusChange?.invoke(value) }

    private var setupComplete = false
    private var running = false
    private var consecutiveReconnectFailures = 0
    private var audioChunksSent = 0UL

    private val setupTimeoutMs = 15_000L
    private val reconnectDelayMs = 1_000L
    private val maxReconnectAttempts = 3

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sessionJob: Job? = null
    @Volatile private var currentSession: DefaultClientWebSocketSession? = null

    /// Outbound audio queue. A single long-running consumer (`sendJob`)
    /// drains it and sends on `currentSession`, which (a) guarantees FIFO
    /// ordering — per-chunk `scope.launch` could deliver out of order under
    /// backpressure — and (b) bounds memory: `DROP_OLDEST` caps the buffer
    /// instead of letting a slow connection pile up one coroutine per chunk.
    /// Real-time audio at 10 Hz with capacity 100 ≈ 10 s headroom; beyond
    /// that we drop the oldest (most stale) chunk rather than grow unbounded.
    private val sendChannel = Channel<String>(
        capacity = 100,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    private var sendJob: Job? = null

    val isReady: Boolean get() = status == Status.READY && setupComplete

    // MARK: Lifecycle

    fun start() {
        if (running) return
        running = true
        consecutiveReconnectFailures = 0
        sendJob = scope.launch { drainSendChannel() }
        openConnection()
    }

    fun stop() {
        running = false
        setupComplete = false
        sessionJob?.cancel()
        sessionJob = null
        currentSession = null
        sendJob?.cancel()
        sendJob = null
        status = Status.CLOSED
    }

    /** Sends a base64-encoded PCM audio chunk. Drops silently if not ready. */
    fun sendAudio(base64PCM: String) {
        if (!isReady) {
            if (audioChunksSent == 0UL) {
                DebugLog.write("GeminiClient.sendAudio DROPPED (not ready, status=$status, setupComplete=$setupComplete)")
            }
            return
        }
        audioChunksSent++
        if (audioChunksSent % 20UL == 1UL) {
            DebugLog.write("GeminiClient.sendAudio #$audioChunksSent (${base64PCM.length} b64 chars)")
        }
        val payload = GeminiProtocol.encodeJson(GeminiProtocol.realtimeAudioMessage(base64PCM))
        // Non-blocking enqueue; the drain coroutine handles the actual send.
        // trySend returns false only when the buffer is full AND DROP_OLDEST
        // couldn't make room (shouldn't happen with DROP policy, but guard).
        val result = sendChannel.trySend(payload)
        if (result.isFailure) {
            DebugLog.write("GeminiClient.sendAudio buffer full, dropped chunk")
        }
    }

    /// Single consumer for `sendChannel`. Pulls payloads in FIFO order and
    /// sends on `currentSession`. Runs for the lifetime of the client
    /// (launched in start, cancelled in stop). A null session means the
    /// socket is mid-(re)connect — drop the chunk rather than block, since
    /// real-time audio loses value while queued behind a reconnect.
    private suspend fun drainSendChannel() {
        for (payload in sendChannel) {
            try {
                currentSession?.send(Frame.Text(payload))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                DebugLog.write("GeminiClient sender FAILED: ${e.message}")
            }
        }
    }

    // MARK: Connect / reconnect

    private fun openConnection() {
        if (!running) return
        val url = "$endpointUrl?key=$apiKey"
        DebugLog.write("GeminiClient.openConnection url=${url.replace(apiKey, "<redacted:${apiKey.length}chars>")}")
        status = Status.CONNECTING
        setupComplete = false

        sessionJob = scope.launch {
            try {
                httpClient.webSocket(urlString = url) {
                    currentSession = this
                    val session = this
                    DebugLog.write("GeminiClient.webSocket connected")

                    // Send setup message
                    val setupPayload = GeminiProtocol.encodeJson(
                        GeminiProtocol.setupMessage(targetLanguage)
                    )
                    DebugLog.write("GeminiClient.sendSetup $setupPayload")
                    send(Frame.Text(setupPayload))
                    DebugLog.write("GeminiClient.sendSetup OK")

                    // Start setup watchdog
                    val watchdog = launch {
                        delay(setupTimeoutMs)
                        if (running && !setupComplete) {
                            DebugLog.write("GeminiClient.setupWatchdog FIRED")
                            onError?.invoke(GeminiError.SetupTimeout)
                            session.cancel()
                        }
                    }

                    // Receive loop
                    DebugLog.write("GeminiClient receive loop starting")
                    var frameCount = 0
                    for (frame in incoming) {
                        frameCount++
                        if (!running) break
                        // Gemini may send JSON as either Text or Binary frames;
                        // decode both as UTF-8. Non-text/binary frames (Ping,
                        // Pong, Close) are ignored.
                        val text = when (frame) {
                            is Frame.Text -> frame.readText()
                            is Frame.Binary -> frame.data.decodeToString()
                            else -> continue
                        }
                        if (frameCount <= 3) {
                            DebugLog.write("GeminiClient received frame #$frameCount: ${frame::class.simpleName} len=${text.length}")
                        }
                        handleIncoming(text)
                    }
                    val reason = runCatching { closeReason.await() }.getOrNull()
                    DebugLog.write("GeminiClient receive loop EXITED after $frameCount frames; running=$running; closeCode=${reason?.code} closeMsg=${reason?.message}")

                    watchdog.cancel()
                    currentSession = null
                }
                // WebSocket closed normally
                DebugLog.write("GeminiClient.webSocket block exited cleanly; running=$running")
                if (running) scheduleReconnectIfNeeded()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                DebugLog.write("GeminiClient.openConnection FAILED: ${e::class.simpleName}: ${e.message}")
                currentSession = null
                if (isAuthError(e)) {
                    // Don't retry — API key is invalid
                    running = false
                    status = Status.CLOSED
                    onError?.invoke(GeminiError.Unauthorized)
                } else if (running) {
                    scheduleReconnectIfNeeded()
                }
            }
        }
    }

    private fun handleIncoming(text: String) {
        DebugLog.write("GeminiClient.handleIncoming ${text.take(300)}")
        val json = try {
            Json.decodeFromString(JsonObject.serializer(), text)
        } catch (_: Exception) {
            DebugLog.write("GeminiClient.handleIncoming could not parse JSON")
            return
        }

        if (GeminiProtocol.isSetupComplete(json)) {
            DebugLog.write("GeminiClient setupComplete received ✓")
            setupComplete = true
            consecutiveReconnectFailures = 0
            status = Status.READY
            return
        }

        if (GeminiProtocol.isGoAway(json)) {
            DebugLog.write("GeminiClient server sent goAway; will reconnect on close")
            return
        }

        GeminiProtocol.parseTranscription(json)?.let { event ->
            onTranscription?.invoke(event.text, event.isFinal)
        }
    }

    private fun scheduleReconnectIfNeeded() {
        if (!running) {
            status = Status.CLOSED
            return
        }
        consecutiveReconnectFailures++
        if (consecutiveReconnectFailures > maxReconnectAttempts) {
            DebugLog.write("GeminiClient RECONNECT EXHAUSTED ($consecutiveReconnectFailures)")
            onError?.invoke(GeminiError.ReconnectExhausted)
            running = false
            status = Status.CLOSED
            return
        }
        DebugLog.write("GeminiClient reconnecting in ${reconnectDelayMs}ms (attempt $consecutiveReconnectFailures)")
        status = Status.CONNECTING
        scope.launch {
            delay(reconnectDelayMs)
            if (running) openConnection()
        }
    }

    fun destroy() {
        scope.cancel()
    }

    /** Detects HTTP 401/403 from the WebSocket handshake failure message. */
    private fun isAuthError(e: Throwable): Boolean {
        val msg = e.message?.lowercase() ?: return false
        return msg.contains("401") || msg.contains("403") ||
               msg.contains("unauthorized") || msg.contains("forbidden") ||
               msg.contains("api key not valid")
    }
}

sealed class GeminiError(message: String) : Throwable(message) {
    data object SetupTimeout : GeminiError("Gemini setup timed out")
    data object ReconnectExhausted : GeminiError("Could not reconnect to Gemini after multiple attempts")
    data object Unauthorized : GeminiError("Invalid Gemini API key")
}
