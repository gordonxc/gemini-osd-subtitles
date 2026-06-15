import Foundation

/// Converts a stream of Float32 PCM samples into base64-encoded Int16 PCM
/// chunks of ~100 ms (4800 samples at 48 kHz), matching the cadence that
/// translation-bridge.ts configures via `AudioStream({ frameSizeMs: 100 })`.
///
/// `process(samples:count:)` accumulates samples across callbacks and emits
/// full chunks via the provided handler. Partial samples stay buffered.
final class AudioPipeline {

    static let chunkSize = 4800  // 100 ms @ 48 kHz

    /// Called with each full chunk's base64 string (native-endian Int16 PCM).
    var onChunk: ((String) -> Void)?

    private var buffer: [Float32] = []
    private let lock = NSLock()
    private var chunksEmitted: UInt64 = 0

    /// Append a Float32 sample run. Thread-safe.
    func process(samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        buffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        while buffer.count >= AudioPipeline.chunkSize {
            let chunk = Array(buffer.prefix(AudioPipeline.chunkSize))
            buffer.removeFirst(AudioPipeline.chunkSize)
            emit(chunk)
        }
        lock.unlock()
    }

    /// Flush any buffered samples as a final (shorter) chunk. Useful on stop.
    func flush() {
        lock.lock()
        if !buffer.isEmpty {
            let chunk = buffer
            buffer.removeAll()
            emit(chunk)
        }
        lock.unlock()
    }

    /// Reset state without emitting.
    func reset() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    private func emit(_ samples: [Float32]) {
        // Float32 [-1, 1] → Int16 (clamp + scale). Same as LiveKit's
        // AudioFrame int16 capture done implicitly upstream.
        var int16 = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            int16[i] = Int16(clamped * Float32(Int16.max))
        }
        // Encode the array CONTENTS (not its metadata). Native endian; matches
        // `audio/pcm;rate=48000` expectation.
        let data = int16.withUnsafeBufferPointer { buf -> Data in
            Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
        }
        let base64 = data.base64EncodedString()
        chunksEmitted &+= 1
        if chunksEmitted % 20 == 1 {
            DebugLog.write("AudioPipeline emit chunk #\(chunksEmitted) (\(samples.count) samples, \(base64.count) base64 chars)")
        }
        onChunk?(base64)
    }
}
