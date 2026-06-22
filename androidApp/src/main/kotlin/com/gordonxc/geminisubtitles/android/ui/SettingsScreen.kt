package com.gordonxc.geminisubtitles.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.gordonxc.geminisubtitles.Languages

/**
 * Main settings screen — Compose UI.
 *
 * Equivalent of macOS `StatusMenuController.swift` (menu → Compose).
 */
@Composable
fun SettingsScreen(
    apiKey: String,
    onApiKeyChange: (String) -> Unit,
    selectedLanguage: String,
    onLanguageChange: (String) -> Unit,
    selectedFontSize: Float,
    onFontSizeChange: (Float) -> Unit,
    isRunning: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
    overlayLocked: Boolean,
    onToggleLock: () -> Unit,
    statusText: String,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Gemini Subtitles",
            style = MaterialTheme.typography.headlineMedium,
        )

        // Status
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Status", style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(4.dp))
                Text(statusText, style = MaterialTheme.typography.bodyMedium)
            }
        }

        // API Key
        var showKey by remember { mutableStateOf(false) }
        OutlinedTextField(
            value = apiKey,
            onValueChange = onApiKeyChange,
            label = { Text("Gemini API Key") },
            singleLine = true,
            visualTransformation = if (showKey) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            trailingIcon = {
                TextButton(onClick = { showKey = !showKey }) {
                    Text(if (showKey) "Hide" else "Show")
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )

        // Language picker
        Text("Target Language", style = MaterialTheme.typography.titleSmall)
        Languages.all.forEach { lang ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = lang.code == selectedLanguage,
                    onClick = { onLanguageChange(lang.code) },
                )
                Text(lang.name)
            }
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

        // Font size slider
        Text("Font Size: ${selectedFontSize.toInt()} pt", style = MaterialTheme.typography.titleSmall)
        Slider(
            value = selectedFontSize,
            onValueChange = { onFontSizeChange(it) },
            valueRange = 14f..72f,
            steps = 0,  // continuous
        )

        // Overlay lock toggle
        if (isRunning) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Overlay ${if (overlayLocked) "Locked" else "Draggable"}")
                Switch(
                    checked = !overlayLocked,
                    onCheckedChange = { onToggleLock() },
                )
            }
        }

        // Start / Stop
        Button(
            onClick = if (isRunning) onStop else onStart,
            modifier = Modifier.fillMaxWidth(),
            colors = if (isRunning) {
                ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
            } else {
                ButtonDefaults.buttonColors()
            },
        ) {
            Text(if (isRunning) "Stop" else "Start", style = MaterialTheme.typography.titleMedium)
        }

        Spacer(Modifier.height(32.dp))
    }
}
