package com.gordonxc.geminisubtitles.android.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.gordonxc.geminisubtitles.DebugLog
import com.gordonxc.geminisubtitles.platform.PlatformAudioCapture
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * Microphone capture using AudioRecord with AudioSource.VOICE_RECOGNITION.
 *
 * Sibling to `MediaProjectionAudioCapture`. Used when the user wants to
 * translate in-person speech rather than system playback. VOICE_RECOGNITION
 * applies flat frequency response with minimal processing — tuned for ASR
 * input like Gemini.
 *
 * Silence detection uses an RMS threshold rather than exact-zero check
 * because mic input always contains ambient noise.
 */
class MicrophoneAudioCapture : PlatformAudioCapture {

    override var onSamples: ((samples: FloatArray, silent: Boolean) -> Unit)? = null
    override var onError: ((Throwable) -> Unit)? = null

    private val sampleRate = 48000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val bufferSize = AudioRecord.getMinBufferSize(
        sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(sampleRate / 10 * 2)  // at least 100 ms

    /// Batches with RMS below this are treated as silent. ~-40 dBFS,
    /// tuned to ignore typical room ambient noise.
    private val silenceThreshold = 0.01f

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var running = false

    @SuppressLint("MissingPermission")
    override fun start() {
        if (running) return
        running = true

        try {
            val audioFormat = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(channelConfig)
                .build()

            val record = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("AudioRecord failed to initialize (state=${record.state})")
            }

            audioRecord = record
            record.startRecording()
            DebugLog.write("MicrophoneAudioCapture: started (bufferSize=$bufferSize)")

            captureThread = thread(name = "mic-capture", isDaemon = true) {
                captureLoop(record)
            }
        } catch (e: Exception) {
            running = false
            DebugLog.write("MicrophoneAudioCapture.start FAILED: ${e.message}")
            onError?.invoke(e)
        }
    }

    override fun stop() {
        running = false
        captureThread?.join(500)
        captureThread = null
        releaseAudioRecord()
        DebugLog.write("MicrophoneAudioCapture: stopped")
    }

    /// Stop + release the AudioRecord. Called from stop() (after joining the
    /// capture thread) and from captureLoop's fatal-error path. Safe to call
    /// twice — the second invocation finds audioRecord null and no-ops.
    private fun releaseAudioRecord() {
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
    }

    private fun captureLoop(record: AudioRecord) {
        // Read in chunks of ~100 ms (4800 Int16 samples = 9600 bytes)
        val chunkSamples = sampleRate / 10  // 4800
        val shortBuffer = ShortArray(chunkSamples)
        val floatBuffer = FloatArray(chunkSamples)

        while (running) {
            val read = record.read(shortBuffer, 0, chunkSamples)
            if (read <= 0) {
                if (read == AudioRecord.ERROR_INVALID_OPERATION ||
                    read == AudioRecord.ERROR_BAD_VALUE
                ) {
                    DebugLog.write("MicrophoneAudioCapture: read error $read")
                    // Release the hardware now rather than waiting for the
                    // user to press stop: handleAudioError only flips state
                    // to ERROR, so without this the AudioRecord stays in
                    // RECORDING and holds the mic until a manual stop.
                    // We can't call public stop() here — it joins the
                    // capture thread we're currently running on.
                    running = false
                    releaseAudioRecord()
                    onError?.invoke(RuntimeException("AudioRecord.read returned $read"))
                    break
                }
                continue
            }

            // Convert Int16 → Float32 [-1.0, 1.0] and accumulate sum-of-squares
            // for RMS-based silence detection.
            var sumSq = 0.0
            for (i in 0 until read) {
                val s = shortBuffer[i] / 32768f
                floatBuffer[i] = s
                sumSq += (s.toDouble() * s.toDouble())
            }
            val rms = sqrt(sumSq / read)
            val silent = rms < silenceThreshold

            // Copy only the actual samples read
            val samples = if (read == chunkSamples) floatBuffer else floatBuffer.copyOf(read)
            onSamples?.invoke(samples, silent)
        }
    }
}
