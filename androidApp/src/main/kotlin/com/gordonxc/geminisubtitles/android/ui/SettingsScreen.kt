package com.gordonxc.geminisubtitles.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.gordonxc.geminisubtitles.AppCoordinator
import com.gordonxc.geminisubtitles.Languages

/**
 * Main settings screen — Compose UI.
 *
 * Layout: TopAppBar + scrollable Column of Cards (Status / Setup / Capture) +
 * sticky bottom Start/Stop button. Material 3 with dynamic color on Android 12+.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    apiKey: String,
    onApiKeyChange: (String) -> Unit,
    selectedLanguage: String,
    onLanguageChange: (String) -> Unit,
    selectedFontSize: Float,
    onFontSizeChange: (Float) -> Unit,
    captureFromMic: Boolean,
    onToggleSource: () -> Unit,
    isRunning: Boolean,
    runState: AppCoordinator.RunState,
    hasOverlayPermission: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
    overlayLocked: Boolean,
    onToggleLock: () -> Unit,
    statusText: String,
) {
    val canStart = apiKey.isNotBlank() && hasOverlayPermission
    val disabledReason = when {
        apiKey.isBlank() -> "Set API key to enable Start"
        !hasOverlayPermission -> "Grant overlay permission to enable Start"
        else -> null
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Gemini Subtitles") }) },
        bottomBar = {
            Surface(tonalElevation = 4.dp) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Button(
                        onClick = if (isRunning) onStop else onStart,
                        enabled = if (isRunning) true else canStart,
                        modifier = Modifier.fillMaxWidth(),
                        colors = if (isRunning) {
                            ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                        } else {
                            ButtonDefaults.buttonColors()
                        },
                    ) {
                        Text(
                            if (isRunning) "Stop" else "Start",
                            style = MaterialTheme.typography.titleMedium,
                        )
                    }
                    if (!isRunning && disabledReason != null) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            disabledReason,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            StatusCard(runState = runState, statusText = statusText,
                targetLabel = Languages.nameForCode(selectedLanguage),
                sourceLabel = if (captureFromMic) "Mic" else "System")

            SetupCard(
                apiKey = apiKey,
                onApiKeyChange = onApiKeyChange,
                selectedLanguage = selectedLanguage,
                onLanguageChange = onLanguageChange,
                selectedFontSize = selectedFontSize,
                onFontSizeChange = onFontSizeChange,
            )

            CaptureCard(
                captureFromMic = captureFromMic,
                onToggleSource = onToggleSource,
                overlayLocked = overlayLocked,
                onToggleLock = onToggleLock,
                overlayLockEnabled = isRunning,
            )

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun StatusCard(
    runState: AppCoordinator.RunState,
    statusText: String,
    targetLabel: String,
    sourceLabel: String,
) {
    val (dotColor, stateLabel) = when (runState) {
        AppCoordinator.RunState.STOPPED -> Color.Gray to "Stopped"
        AppCoordinator.RunState.STARTING -> Color(0xFFFFC107) to "Connecting"
        AppCoordinator.RunState.ACTIVE,
        AppCoordinator.RunState.RECEIVING_AUDIO -> Color(0xFF4CAF50) to "Running"
        AppCoordinator.RunState.ERROR -> Color(0xFFF44336) to "Error"
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(dotColor),
                )
                Spacer(Modifier.size(8.dp))
                Text(stateLabel, style = MaterialTheme.typography.titleMedium)
            }
            Spacer(Modifier.height(4.dp))
            Text(statusText, style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(2.dp))
            Text(
                "Target: $targetLabel · $sourceLabel",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SetupCard(
    apiKey: String,
    onApiKeyChange: (String) -> Unit,
    selectedLanguage: String,
    onLanguageChange: (String) -> Unit,
    selectedFontSize: Float,
    onFontSizeChange: (Float) -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Setup", style = MaterialTheme.typography.titleSmall)

            // API Key
            var showKey by remember { mutableStateOf(false) }
            OutlinedTextField(
                value = apiKey,
                onValueChange = onApiKeyChange,
                label = { Text("Gemini API Key") },
                singleLine = true,
                visualTransformation = if (showKey) VisualTransformation.None
                                       else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    TextButton(onClick = { showKey = !showKey }) {
                        Text(if (showKey) "Hide" else "Show")
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )

            // Language dropdown
            var langExpanded by remember { mutableStateOf(false) }
            ExposedDropdownMenuBox(
                expanded = langExpanded,
                onExpandedChange = { langExpanded = it },
                modifier = Modifier.fillMaxWidth(),
            ) {
                OutlinedTextField(
                    value = Languages.nameForCode(selectedLanguage),
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Target Language") },
                    trailingIcon = {
                        ExposedDropdownMenuDefaults.TrailingIcon(expanded = langExpanded)
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .menuAnchor(),
                )
                DropdownMenu(
                    expanded = langExpanded,
                    onDismissRequest = { langExpanded = false },
                ) {
                    Languages.all.forEach { lang ->
                        DropdownMenuItem(
                            text = { Text(lang.name) },
                            onClick = {
                                onLanguageChange(lang.code)
                                langExpanded = false
                            },
                        )
                    }
                }
            }

            // Font size + live preview
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "Font Size: ${selectedFontSize.toInt()} pt",
                    style = MaterialTheme.typography.titleSmall,
                )
                Slider(
                    value = selectedFontSize,
                    onValueChange = onFontSizeChange,
                    valueRange = 14f..72f,
                )
                Text(
                    "字幕範例",
                    fontSize = selectedFontSize.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun CaptureCard(
    captureFromMic: Boolean,
    onToggleSource: () -> Unit,
    overlayLocked: Boolean,
    onToggleLock: () -> Unit,
    overlayLockEnabled: Boolean,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Capture", style = MaterialTheme.typography.titleSmall)

            // Audio source
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(if (captureFromMic) "Microphone" else "System Audio")
                    Text(
                        if (captureFromMic)
                            "Captures in-person speech via the device mic."
                        else
                            "Captures playback via MediaProjection (any app).",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = captureFromMic,
                    onCheckedChange = { onToggleSource() },
                )
            }

            // Overlay lock
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Overlay ${if (overlayLocked) "Locked" else "Draggable"}")
                    if (!overlayLockEnabled) {
                        Text(
                            "Available while running",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Switch(
                    checked = !overlayLocked,
                    onCheckedChange = { onToggleLock() },
                    enabled = overlayLockEnabled,
                )
            }
        }
    }
}
