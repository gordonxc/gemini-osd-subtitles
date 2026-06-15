package com.gordonxc.geminisubtitles.android.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.gordonxc.geminisubtitles.AppCoordinator
import com.gordonxc.geminisubtitles.Languages
import com.gordonxc.geminisubtitles.android.MainActivity
import com.gordonxc.geminisubtitles.android.audio.MediaProjectionAudioCapture
import com.gordonxc.geminisubtitles.android.overlay.SubtitleOverlayView
import com.gordonxc.geminisubtitles.android.storage.EncryptedApiKeyStore
import com.gordonxc.geminisubtitles.platform.PlatformNotifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

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
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val EXTRA_TARGET_LANGUAGE = "target_language"
        const val EXTRA_FONT_SIZE = "font_size"

        private const val CHANNEL_ID = "subtitle_service"
        private const val NOTIFICATION_ID = 1

        // Observable state for UI
        val isRunning = MutableStateFlow(false)
        val statusText = MutableStateFlow("Stopped")
        val overlayLocked = MutableStateFlow(true)

        var coordinator: AppCoordinator? = null
            private set
    }

    private var overlay: SubtitleOverlayView? = null
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val resultData: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
                val targetLanguage = intent.getStringExtra(EXTRA_TARGET_LANGUAGE) ?: Languages.defaultCode
                val fontSize = intent.getFloatExtra(EXTRA_FONT_SIZE, 20f)

                if (resultData != null) {
                    startForegroundCompat()
                    startPipeline(resultCode, resultData, targetLanguage, fontSize)
                }
            }
            ACTION_STOP -> {
                stopPipeline()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun startPipeline(resultCode: Int, resultData: Intent, targetLanguage: String, fontSize: Float) {
        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mediaProjection = projectionManager.getMediaProjection(resultCode, resultData)

        val audioCapture = MediaProjectionAudioCapture(mediaProjection)
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

    private fun stopPipeline() {
        coordinator?.stop()
        coordinator?.destroy()
        coordinator = null
        overlay = null
        isRunning.value = false
        statusText.value = "Stopped"
        overlayLocked.value = true
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

    private fun startForegroundCompat() {
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

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Gemini Subtitles")
            .setContentText("Running — capturing audio")
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
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
