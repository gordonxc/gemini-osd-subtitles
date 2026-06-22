package com.gordonxc.geminisubtitles.platform

/**
 * Platform-agnostic audio capture interface.
 *
 * On Android: implemented via MediaProjection + AudioPlaybackCaptureConfiguration.
 * On macOS: implemented via ScreenCaptureKit (future iOS would use ReplayKit).
 */
interface PlatformAudioCapture {
    /** Delivered on a capture thread. [samples] is Float32 PCM at 48kHz mono.
     *  [silent] is true when all samples in this batch are zero. */
    var onSamples: ((samples: FloatArray, silent: Boolean) -> Unit)?
    var onError: ((Throwable) -> Unit)?

    fun start()
    fun stop()
}
