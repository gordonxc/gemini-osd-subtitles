package com.gordonxc.geminisubtitles.android.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.gordonxc.geminisubtitles.AppCoordinator
import com.gordonxc.geminisubtitles.DebugLog
import com.gordonxc.geminisubtitles.Languages
import com.gordonxc.geminisubtitles.android.MainActivity
import com.gordonxc.geminisubtitles.android.audio.AudioFileDecoder
import com.gordonxc.geminisubtitles.android.audio.MediaProjectionAudioCapture
import com.gordonxc.geminisubtitles.android.audio.MicrophoneAudioCapture
import com.gordonxc.geminisubtitles.android.overlay.SubtitleOverlayView
import com.gordonxc.geminisubtitles.android.storage.EncryptedApiKeyStore
import com.gordonxc.geminisubtitles.platform.PlatformNotifier
import com.gordonxc.geminisubtitles.platform.PlatformAudioCapture
import com.gordonxc.geminisubtitles.platform.PlatformOverlay
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Foreground Service that runs the subtitle pipeline.
 *
 * Holds the AppCoordinator + platform implementations.
 * MediaProjection runs here to survive activity recreation.
 *
 * Exposes StateFlows via companion object so the Activity can observe
 * running state and status text without a direct binding.
 */
class SubtitleService : Service(), PlatformNotifier {

    companion object {
        const val ACTION_START = "com.gordonxc.geminisubtitles.START"
        const val ACTION_STOP = "com.gordonxc.geminisubtitles.STOP"
        const val ACTION_TRANSCRIBE_FILE = "com.gordonxc.geminisubtitles.TRANSCRIBE_FILE"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val EXTRA_TARGET_LANGUAGE = "target_language"
        const val EXTRA_FONT_SIZE = "font_size"
        /// `"system"` or `"mic"`. Defaults to `"system"` if absent.
        const val EXTRA_SOURCE = "audio_source"
        const val EXTRA_AUDIO_URI = "audio_uri"

        /// Allowed values for EXTRA_SOURCE.
        const val SOURCE_SYSTEM = "system"
        const val SOURCE_MIC = "mic"

        private const val CHANNEL_ID = "subtitle_service"
        private const val NOTIFICATION_ID = 1

        // Observable state for UI
        val isRunning = MutableStateFlow(false)
        val statusText = MutableStateFlow("Stopped")
        val overlayLocked = MutableStateFlow(true)
        val runState = MutableStateFlow(AppCoordinator.RunState.STOPPED)

        // File transcription state
        val isTranscribing = MutableStateFlow(false)
        val transcriptionResult = MutableStateFlow("")
        val transcriptionParts = MutableStateFlow<List<String>>(emptyList())

        var coordinator: AppCoordinator? = null
            private set
    }

    private var overlay: SubtitleOverlayView? = null
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Rotation / multi-window resize — recompute OSD geometry so it
        // doesn't keep stale dimensions after a screen-geometry change.
        overlay?.onConfigurationChanged(newConfig)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val source = intent.getStringExtra(EXTRA_SOURCE) ?: SOURCE_SYSTEM
                val targetLanguage = intent.getStringExtra(EXTRA_TARGET_LANGUAGE) ?: Languages.defaultCode
                val fontSize = intent.getFloatExtra(EXTRA_FONT_SIZE, 20f)

                if (source == SOURCE_MIC) {
                    startForegroundCompat(source)
                    startPipelineMic(targetLanguage, fontSize)
                } else {
                    val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                    @Suppress("DEPRECATION")
                    val resultData: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
                    if (resultData != null) {
                        startForegroundCompat(source)
                        startPipelineSystem(resultCode, resultData, targetLanguage, fontSize)
                    }
                }
            }
            ACTION_STOP -> {
                stopPipeline()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_TRANSCRIBE_FILE -> {
                val uriString = intent.getStringExtra(EXTRA_AUDIO_URI) ?: return START_NOT_STICKY
                val targetLanguage = intent.getStringExtra(EXTRA_TARGET_LANGUAGE) ?: Languages.defaultCode
                startFileTranscription(uriString, targetLanguage)
            }
        }
        return START_NOT_STICKY
    }

    private fun startPipelineSystem(resultCode: Int, resultData: Intent, targetLanguage: String, fontSize: Float) {
        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mediaProjection = projectionManager.getMediaProjection(resultCode, resultData)

        val audioCapture = MediaProjectionAudioCapture(mediaProjection)
        startPipelineCommon(audioCapture, targetLanguage, fontSize)
    }

    private fun startPipelineMic(targetLanguage: String, fontSize: Float) {
        val audioCapture = MicrophoneAudioCapture()
        startPipelineCommon(audioCapture, targetLanguage, fontSize)
    }

    private fun startPipelineCommon(
        audioCapture: com.gordonxc.geminisubtitles.platform.PlatformAudioCapture,
        targetLanguage: String,
        fontSize: Float,
    ) {
        overlay = SubtitleOverlayView(this)
        val apiKeyStore = EncryptedApiKeyStore(this)

        val coord = AppCoordinator(
            apiKeyStore = apiKeyStore,
            audioCapture = audioCapture,
            overlay = overlay!!,
            notifier = this,
        )
        coordinator = coord
        coord.setSubtitleFontSize(fontSize)
        coord.start(targetLanguage)

        // Observe coordinator state and push to companion object StateFlows
        serviceScope.launch {
            coord.state.collectLatest { state ->
                runState.value = state
                isRunning.value = state != AppCoordinator.RunState.STOPPED &&
                        state != AppCoordinator.RunState.ERROR
            }
        }
        serviceScope.launch {
            coord.statusText.collectLatest { text ->
                statusText.value = text
            }
        }
    }

    // MARK: File transcription

    private fun startFileTranscription(uriString: String, targetLanguage: String) {
        // Reset state
        transcriptionResult.value = ""
        transcriptionParts.value = emptyList()
        isTranscribing.value = true
        statusText.value = "Decoding audio…"

        // Foreground notification (no audio capture type needed)
        createNotificationChannel()
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Gemini Subtitles")
            .setContentText("Translating shared audio…")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, 0)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val apiKeyStore = EncryptedApiKeyStore(this)
        val coord = AppCoordinator(
            apiKeyStore = apiKeyStore,
            audioCapture = NoOpAudioCapture,
            overlay = NoOpOverlay,
            notifier = this,
        )
        coordinator = coord

        val parts = mutableListOf<String>()

        coord.onFileTranscription = { text, isFinal ->
            DebugLog.write("SubtitleService onFileTranscription: text='${text.take(50)}' isFinal=$isFinal")
            // Accumulate all parts
            parts.add(text)
            transcriptionParts.value = parts.toList()
            transcriptionResult.value = parts.joinToString("")
        }

        coord.startFileTranscription(targetLanguage)

        // Observe coordinator state
        serviceScope.launch {
            coord.state.collectLatest { state ->
                runState.value = state
            }
        }
        serviceScope.launch {
            coord.statusText.collectLatest { text ->
                statusText.value = text
            }
        }

        // Decode audio file and feed samples
        serviceScope.launch(Dispatchers.IO) {
            try {
                // Wait for Gemini to be ready
                kotlinx.coroutines.delay(1000)

                val decoder = AudioFileDecoder(this@SubtitleService)
                val uri = Uri.parse(uriString)
                statusText.value = "Decoding audio…"

                withContext(Dispatchers.IO) {
                    decoder.decode(uri) { samples ->
                        coord.feedFileSamples(samples)
                    }
                }

                coord.finishFileTranscription()
                statusText.value = "Translating…"

                // Wait for Gemini to return remaining transcription
                kotlinx.coroutines.delay(5000)

                // Mark transcription as done (results remain visible)
                isTranscribing.value = false
                if (transcriptionResult.value.isNotEmpty()) {
                    statusText.value = "完成"
                } else {
                    statusText.value = "沒有偵測到語音"
                }

                // Stop the coordinator (closes Gemini connection)
                coord.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            } catch (e: Exception) {
                DebugLog.write("SubtitleService file transcription FAILED: ${e.message}")
                statusText.value = "Error: ${e.message}"
                // Mirror the success-path teardown: without this, a decode
                // failure (unsupported codec, unreadable URI, no audio track)
                // leaves isTranscribing stuck true, the Gemini WebSocket open,
                // and the foreground notification undying — only a force-stop
                // could clear it.
                isTranscribing.value = false
                runCatching { coord.stop() }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun stopPipeline() {
        coordinator?.stop()
        coordinator?.destroy()
        coordinator = null
        overlay = null
        isRunning.value = false
        statusText.value = "Stopped"
        overlayLocked.value = true
        runState.value = AppCoordinator.RunState.STOPPED
        isTranscribing.value = false
        serviceScope.cancel()
        // Recreate scope so a subsequent start() can launch coroutines again
        serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    // MARK: PlatformNotifier

    override fun notify(title: String, body: String) {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .build()

        getSystemService(NotificationManager::class.java)
            .notify(System.currentTimeMillis().toInt(), notification)
    }

    // MARK: Foreground notification

    private fun startForegroundCompat(source: String) {
        createNotificationChannel()

        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, SubtitleService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val isMic = source == SOURCE_MIC
        val smallIcon = if (isMic) android.R.drawable.ic_btn_speak_now
                        else android.R.drawable.ic_lock_silent_mode_off
        val contentText = if (isMic) "Running — capturing microphone"
                          else "Running — capturing system audio"

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle("Gemini Subtitles")
            .setContentText(contentText)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = if (isMic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                       else ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Subtitle Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Audio capture for live translation"
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPipeline()
    }
}

/** No-op audio capture for file transcription mode (no live audio needed). */
private object NoOpAudioCapture : PlatformAudioCapture {
    override var onSamples: ((samples: FloatArray, silent: Boolean) -> Unit)? = null
    override var onError: ((Throwable) -> Unit)? = null
    override fun start() {}
    override fun stop() {}
}

/** No-op overlay for file transcription mode (results shown in-app, not OSD). */
private object NoOpOverlay : PlatformOverlay {
    override fun reveal() {}
    override fun hide() {}
    override fun updateText(text: String) {}
    override fun setFontSize(size: Float) {}
    override fun toggleLock(): Boolean = true
    override val isLocked: Boolean = true
}
