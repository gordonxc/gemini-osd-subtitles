package com.gordonxc.geminisubtitles.android.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log
import com.gordonxc.geminisubtitles.DebugLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext

/**
 * Decodes any Android-supported audio file (mp3, m4a, aac, ogg, amr, wav, opus, etc.)
 * into Float32 PCM mono at the target sample rate, calling [onChunk] for each
 * batch of samples.
 *
 * Uses MediaExtractor + MediaCodec — no third-party dependencies.
 *
 * The output sample rate is configurable; we use 48000 Hz to match Gemini Live's
 * expected input rate (see GeminiProtocol.INPUT_SAMPLE_RATE).
 *
 * Resampling is done via simple linear interpolation if the source rate differs
 * from the target. Voice messages are typically mono and relatively short, so
 * CPU cost is negligible.
 */
class AudioFileDecoder(
    private val context: Context,
    private val targetSampleRate: Int = 48000,
) {
    private companion object {
        const val TAG = "AudioFileDecoder"
        const val TIMEOUT_US = 10_000L
    }

    /**
     * Decodes the audio file at [uri] and delivers Float32 PCM samples in batches.
     * If mono conversion is needed, stereo channels are averaged.
     * If resampling is needed, linear interpolation is used.
     *
     * Returns the total number of samples delivered.
     */
    suspend fun decode(uri: Uri, onChunk: (FloatArray) -> Unit): Int {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var totalSamples = 0

        try {
            extractor.setDataSource(context, uri, null)

            // Find the first audio track
            var audioTrackIndex = -1
            var inputFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    inputFormat = format
                    break
                }
            }

            if (audioTrackIndex < 0 || inputFormat == null) {
                throw IllegalArgumentException("No audio track found in shared file")
            }

            extractor.selectTrack(audioTrackIndex)

            val inputMime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            val sourceSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val sourceChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            DebugLog.write("AudioFileDecoder: source=$uri mime=$inputMime rate=$sourceSampleRate ch=$sourceChannels")

            // Configure decoder — request mono output at target sample rate if supported
            val decodeFormat = MediaFormat(inputFormat).apply {
                // Some decoders honor these hints; if not, we handle it ourselves
                if (sourceSampleRate != targetSampleRate) {
                    setInteger(MediaFormat.KEY_SAMPLE_RATE, targetSampleRate)
                }
                if (sourceChannels > 1) {
                    setInteger(MediaFormat.KEY_CHANNEL_COUNT, 1)
                }
            }

            decoder = MediaCodec.createDecoderByType(inputMime)
            decoder.configure(decodeFormat, null, null, 0)
            decoder.start()

            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val pendingSamples = mutableListOf<Float>()

            while (!sawOutputEOS && coroutineContext.isActive) {
                // Feed input
                if (!sawInputEOS) {
                    val inputBufferIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inputBufferIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputBufferIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(
                                inputBufferIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            sawInputEOS = true
                        } else {
                            decoder.queueInputBuffer(
                                inputBufferIndex, 0, sampleSize,
                                extractor.sampleTime, 0
                            )
                            extractor.advance()
                        }
                    }
                }

                // Drain output
                val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                if (outputBufferIndex >= 0) {
                    val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)!!

                    // Determine actual output format
                    val outFormat = decoder.outputFormat
                    val outSampleRate = try {
                        outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    } catch (_: Exception) { sourceSampleRate }
                    val outChannels = try {
                        outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    } catch (_: Exception) { sourceChannels }

                    if (bufferInfo.size > 0 && bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        // Decode based on the actual output format
                        val samples = decodePcmBuffer(
                            outputBuffer, bufferInfo.offset, bufferInfo.size,
                            outChannels, outSampleRate
                        )

                        if (samples.isNotEmpty()) {
                            pendingSamples.addAll(samples.toList())
                            totalSamples += samples.size

                            // Emit in ~100ms batches (4800 samples at 48kHz)
                            while (pendingSamples.size >= targetSampleRate / 10) {
                                val chunkSize = targetSampleRate / 10
                                val chunk = FloatArray(chunkSize)
                                for (j in 0 until chunkSize) {
                                    chunk[j] = pendingSamples[j]
                                }
                                pendingSamples.subList(0, chunkSize).clear()
                                onChunk(chunk)
                            }
                        }
                    }

                    decoder.releaseOutputBuffer(outputBufferIndex, false)

                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        sawOutputEOS = true
                    }
                }
            }

            // Flush any remaining samples
            if (pendingSamples.isNotEmpty()) {
                onChunk(pendingSamples.toFloatArray())
            }

            DebugLog.write("AudioFileDecoder: done, total $totalSamples samples (${totalSamples / targetSampleRate.toDouble()}s)")
        } catch (e: Exception) {
            DebugLog.write("AudioFileDecoder FAILED: ${e::class.simpleName}: ${e.message}")
            Log.e(TAG, "Decode failed", e)
            throw e
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            extractor.release()
        }

        return totalSamples
    }

    /**
     * Decodes a raw PCM buffer from MediaCodec into Float32 mono samples.
     * Handles 16-bit signed PCM (the most common decoder output format).
     * Downmixes to mono by averaging channels.
     * Resamples to targetSampleRate via linear interpolation if needed.
     */
    private fun decodePcmBuffer(
        buffer: java.nio.ByteBuffer,
        offset: Int,
        size: Int,
        channels: Int,
        sourceSampleRate: Int,
    ): FloatArray {
        // Assume 16-bit signed PCM (Android's default decoder output)
        val bytesPerFrame = channels * 2  // 2 bytes per 16-bit sample per channel
        val frameCount = size / bytesPerFrame
        if (frameCount == 0) return FloatArray(0)

        // Step 1: Decode to mono Float32
        val mono = FloatArray(frameCount)
        buffer.position(offset)
        for (i in 0 until frameCount) {
            var sum = 0f
            for (ch in 0 until channels) {
                val shortVal = buffer.short.toInt()  // reads 2 bytes, big-endian
                sum += shortVal.toFloat() / 32768f
            }
            mono[i] = sum / channels
        }

        // Step 2: Resample if necessary
        return if (sourceSampleRate == targetSampleRate) {
            mono
        } else {
            linearResample(mono, sourceSampleRate, targetSampleRate)
        }
    }

    /**
     * Simple linear interpolation resampling.
     */
    private fun linearResample(
        input: FloatArray,
        sourceRate: Int,
        targetRate: Int,
    ): FloatArray {
        val ratio = sourceRate.toDouble() / targetRate.toDouble()
        val outputLength = (input.size / ratio).toInt().coerceAtLeast(1)
        val output = FloatArray(outputLength)
        for (i in 0 until outputLength) {
            val srcIndex = i * ratio
            val srcIdx = srcIndex.toInt()
            val frac = srcIndex - srcIdx
            if (srcIdx + 1 < input.size) {
                output[i] = (input[srcIdx] * (1 - frac) + input[srcIdx + 1] * frac).toFloat()
            } else {
                output[i] = input[srcIdx.coerceAtMost(input.lastIndex)]
            }
        }
        return output
    }
}
