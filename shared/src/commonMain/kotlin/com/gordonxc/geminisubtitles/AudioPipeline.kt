package com.gordonxc.geminisubtitles

/**
 * Converts a stream of Float32 PCM samples into base64-encoded Int16 PCM
 * chunks of ~100 ms (4800 samples at 48 kHz), matching the cadence that
 * translation-bridge.ts configures via `AudioStream({ frameSizeMs: 100 })`.
 *
 * Ported from Swift `AudioPipeline.swift`. vDSP (Accelerate) is replaced
 * with a plain Kotlin loop — 4800 samples at ~10Hz is trivial CPU work.
 */
class AudioPipeline {

    var onChunk: ((String) -> Unit)? = null

    private val buffer = ArrayList<Float>(CHUNK_SIZE * 2)
    private var chunksEmitted = 0UL
    private val lock = Any()

    companion object {
        const val CHUNK_SIZE = 4800  // 100 ms @ 48 kHz
    }

    /** Append a Float32 sample run. Thread-safe. */
    fun process(samples: FloatArray) {
        val count = samples.size
        if (count == 0) return
        synchronized(lock) {
            for (s in samples) buffer.add(s)

            while (buffer.size >= CHUNK_SIZE) {
                convertAndEmit()
            }
        }
    }

    /** Flush any buffered samples as a final (shorter) chunk. */
    fun flush() {
        synchronized(lock) {
            if (buffer.isNotEmpty()) {
                convertAndEmit(all = true)
            }
        }
    }

    /** Reset state without emitting. */
    fun reset() {
        synchronized(lock) {
            buffer.clear()
            chunksEmitted = 0UL
        }
    }

    // MARK: Private

    private fun convertAndEmit(all: Boolean = false) {
        val size = if (all) buffer.size else CHUNK_SIZE
        val int16 = ShortArray(size)
        for (i in 0 until size) {
            val scaled = buffer[i] * 32767f
            int16[i] = scaled.toInt()
                .coerceIn(-32768, 32767)
                .toShort()
        }

        // Remove consumed samples
        repeat(size) { if (buffer.isNotEmpty()) buffer.removeAt(0) }

        // Convert ShortArray → ByteArray → base64
        val bytes = ByteArray(size * 2)
        for (i in 0 until size) {
            bytes[i * 2] = (int16[i].toInt() and 0xFF).toByte()
            bytes[i * 2 + 1] = (int16[i].toInt() shr 8 and 0xFF).toByte()
        }

        val base64 = base64Encode(bytes)
        chunksEmitted++
        if (chunksEmitted % 20UL == 1UL) {
            DebugLog.write("AudioPipeline emit chunk #$chunksEmitted ($size samples, ${base64.length} base64 chars)")
        }
        onChunk?.invoke(base64)
    }
}

// MARK: - Base64 (expect/actual for platform-specific implementation)

/** Encode a ByteArray to a base64 string. Platform-specific. */
expect fun base64Encode(data: ByteArray): String
