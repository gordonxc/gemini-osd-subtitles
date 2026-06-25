package com.gordonxc.geminisubtitles.android.audio

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import com.gordonxc.geminisubtitles.DebugLog
import com.gordonxc.geminisubtitles.platform.PlatformAudioCapture
import kotlin.concurrent.thread

/**
 * System-wide audio capture via MediaProjection (audio-only).
 *
 * Android equivalent of macOS `AudioCapture.swift` (ScreenCaptureKit).
 * Captures audio output from any app using AudioPlaybackCaptureConfiguration
 * (requires Android 10+ / API 29+).
 *
 * AudioRecord delivers PCM_16BIT natively; we convert to Float32 for
 * compatibility with the shared AudioPipeline.
 */
class MediaProjectionAudioCapture(
    private val mediaProjection: MediaProjection,
) : PlatformAudioCapture {

    override var onSamples: ((samples: FloatArray, silent: Boolean) -> Unit)? = null
    override var onError: ((Throwable) -> Unit)? = null

    private val sampleRate = 48000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    // 100ms buffer: 4800 samples × 2 bytes (Int16)
    private val bufferSize = AudioRecord.getMinBufferSize(
        sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(sampleRate / 10 * 2)  // at least 100ms

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var running = false

    @SuppressLint("MissingPermission")
    override fun start() {
        if (running) return
        running = true

        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .apply {
                    // Capture audio from all apps and system
                    addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    addMatchingUsage(AudioAttributes.USAGE_GAME)
                    addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                }
                .build()

            val audioFormat = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(channelConfig)
                .build()

            val record = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("AudioRecord failed to initialize (state=${record.state})")
            }

            audioRecord = record
            record.startRecording()
            DebugLog.write("MediaProjectionAudioCapture: started (bufferSize=$bufferSize)")

            captureThread = thread(name = "audio-capture", isDaemon = true) {
                captureLoop(record)
            }
        } catch (e: Exception) {
            running = false
            DebugLog.write("MediaProjectionAudioCapture.start FAILED: ${e.message}")
            onError?.invoke(e)
        }
    }

    override fun stop() {
        running = false
        captureThread?.join(500)
        captureThread = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {
            DebugLog.write("MediaProjectionAudioCapture.stop: audioRecord cleanup error: ${e.message}")
        }
        audioRecord = null
        // Release the MediaProjection token so the system knows we're done
        // capturing. Without this the projection stays active (holding the
        // user's screen-capture grant) and on Android 14+ violates the
        // foreground-service-type coupling rule, risking the system killing
        // the app. stop() is safe to call after the projection is no longer
        // in use; the framework tears down the virtual display.
        try {
            mediaProjection.stop()
        } catch (e: Exception) {
            DebugLog.write("MediaProjectionAudioCapture.stop: mediaProjection.stop error: ${e.message}")
        }
        DebugLog.write("MediaProjectionAudioCapture: stopped")
    }

    private fun captureLoop(record: AudioRecord) {
        // Read in chunks of ~100ms (4800 Int16 samples = 9600 bytes)
        val chunkSamples = sampleRate / 10  // 4800
        val shortBuffer = ShortArray(chunkSamples)
        val floatBuffer = FloatArray(chunkSamples)

        while (running) {
            val read = record.read(shortBuffer, 0, chunkSamples)
            if (read <= 0) {
                if (read == AudioRecord.ERROR_INVALID_OPERATION ||
                    read == AudioRecord.ERROR_BAD_VALUE
                ) {
                    DebugLog.write("MediaProjectionAudioCapture: read error $read")
                    onError?.invoke(RuntimeException("AudioRecord.read returned $read"))
                    break
                }
                continue
            }

            // Convert Int16 → Float32 [-1.0, 1.0]
            var silent = true
            for (i in 0 until read) {
                floatBuffer[i] = shortBuffer[i] / 32768f
                if (shortBuffer[i] != 0.toShort()) silent = false
            }

            // Copy only the actual samples read
            val samples = if (read == chunkSamples) floatBuffer else floatBuffer.copyOf(read)
            onSamples?.invoke(samples, silent)
        }
    }
}
