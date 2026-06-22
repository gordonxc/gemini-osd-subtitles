package com.gordonxc.geminisubtitles.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.core.content.ContextCompat
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import com.gordonxc.geminisubtitles.Languages
import com.gordonxc.geminisubtitles.android.service.SubtitleService
import com.gordonxc.geminisubtitles.android.storage.EncryptedApiKeyStore
import com.gordonxc.geminisubtitles.android.ui.SettingsScreen
import kotlinx.coroutines.flow.collectLatest

class MainActivity : ComponentActivity() {

    private lateinit var apiKeyStore: EncryptedApiKeyStore

    private val mediaProjectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            startSubtitleServiceSystem(result.resultCode, result.data!!)
        }
    }

    private val micPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            startSubtitleServiceMic()
        } else {
            SubtitleService.statusText.value = "Microphone permission denied"
        }
    }

    private val prefs by lazy { getSharedPreferences("settings", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        apiKeyStore = EncryptedApiKeyStore(this)

        setContent {
            MaterialTheme {
                Surface {
                    AppContent()
                }
            }
        }
    }

    @Composable
    private fun AppContent() {
        var apiKey by remember { mutableStateOf(apiKeyStore.getApiKey() ?: "") }
        var selectedLanguage by remember {
            mutableStateOf(prefs.getString("target_language", Languages.defaultCode)!!)
        }
        var selectedFontSize by remember { mutableStateOf(prefs.getFloat("font_size", 20f)) }
        var captureFromMic by remember {
            mutableStateOf(prefs.getString("audio_source", "system") == "mic")
        }

        // Observe service state
        val isRunning by SubtitleService.isRunning.collectAsState()
        val statusText by SubtitleService.statusText.collectAsState()
        val runState by SubtitleService.runState.collectAsState()
        var hasOverlayPermission by remember {
            mutableStateOf(Settings.canDrawOverlays(this@MainActivity))
        }
        var overlayLocked by remember { mutableStateOf(true) }

        // Refresh overlay-permission flag every time we return to the foreground
        // (user may have just toggled it in system settings).
        val lifecycleOwner = LocalLifecycleOwner.current
        DisposableEffect(lifecycleOwner) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) {
                    hasOverlayPermission = Settings.canDrawOverlays(this@MainActivity)
                }
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
        }

        // Observe overlay lock changes
        LaunchedEffect(Unit) {
            SubtitleService.overlayLocked.collectLatest { overlayLocked = it }
        }

        SettingsScreen(
            apiKey = apiKey,
            onApiKeyChange = {
                apiKey = it
                apiKeyStore.setApiKey(it)
            },
            selectedLanguage = selectedLanguage,
            onLanguageChange = {
                selectedLanguage = it
                prefs.edit().putString("target_language", it).apply()
            },
            selectedFontSize = selectedFontSize,
            onFontSizeChange = {
                selectedFontSize = it
                prefs.edit().putFloat("font_size", it).apply()
                SubtitleService.coordinator?.setSubtitleFontSize(it)
            },
            isRunning = isRunning,
            runState = runState,
            hasOverlayPermission = hasOverlayPermission,
            onStart = { handleStart() },
            onStop = { handleStop() },
            captureFromMic = captureFromMic,
            onToggleSource = {
                val newValue = !captureFromMic
                captureFromMic = newValue
                prefs.edit()
                    .putString("audio_source", if (newValue) "mic" else "system")
                    .apply()
                // Mid-session toggle: restart pipeline so new source takes effect.
                // System mode re-prompts for MediaProjection consent (per locked decision).
                if (SubtitleService.isRunning.value) {
                    handleStop()
                    handleStart()
                }
            },
            overlayLocked = overlayLocked,
            onToggleLock = {
                SubtitleService.coordinator?.let {
                    val newLocked = it.toggleOSDLock()
                    SubtitleService.overlayLocked.value = newLocked
                }
            },
            statusText = statusText,
        )
    }

    private fun handleStart() {
        if (apiKeyStore.getApiKey().isNullOrEmpty()) {
            SubtitleService.statusText.value = "Set your API key first"
            return
        }

        if (!Settings.canDrawOverlays(this)) {
            startActivity(Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            ))
            SubtitleService.statusText.value = "Grant overlay permission and try again"
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
            }
        }

        val sourceIsMic = prefs.getString("audio_source", "system") == "mic"
        if (sourceIsMic) {
            if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
                micPermissionLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
            } else {
                startSubtitleServiceMic()
            }
        } else {
            val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjectionLauncher.launch(projectionManager.createScreenCaptureIntent())
        }
    }

    private fun startSubtitleServiceSystem(resultCode: Int, data: Intent) {
        val serviceIntent = Intent(this, SubtitleService::class.java).apply {
            action = SubtitleService.ACTION_START
            putExtra(SubtitleService.EXTRA_SOURCE, SubtitleService.SOURCE_SYSTEM)
            putExtra(SubtitleService.EXTRA_RESULT_CODE, resultCode)
            putExtra(SubtitleService.EXTRA_RESULT_DATA, data)
            putExtra(SubtitleService.EXTRA_TARGET_LANGUAGE, prefs.getString("target_language", Languages.defaultCode))
            putExtra(SubtitleService.EXTRA_FONT_SIZE, prefs.getFloat("font_size", 20f))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun startSubtitleServiceMic() {
        val serviceIntent = Intent(this, SubtitleService::class.java).apply {
            action = SubtitleService.ACTION_START
            putExtra(SubtitleService.EXTRA_SOURCE, SubtitleService.SOURCE_MIC)
            putExtra(SubtitleService.EXTRA_TARGET_LANGUAGE, prefs.getString("target_language", Languages.defaultCode))
            putExtra(SubtitleService.EXTRA_FONT_SIZE, prefs.getFloat("font_size", 20f))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun handleStop() {
        startService(Intent(this, SubtitleService::class.java).apply {
            action = SubtitleService.ACTION_STOP
        })
    }
}
