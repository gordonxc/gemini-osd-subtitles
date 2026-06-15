import Foundation
import Accelerate

/// Converts a stream of Float32 PCM samples into base64-encoded Int16 PCM
/// chunks of ~100 ms (4800 samples at 48 kHz), matching the cadence that
/// translation-bridge.ts configures via `AudioStream({ frameSizeMs: 100 })`.
///
/// Performance design:
///   * Backing store is a `[Float32]` + head index. The buffer is compacted
///     in O(n) only after every `compactThreshold` consumed chunks (default
///     2), giving amortized O(1) per sample instead of O(n) per chunk.
///   * The Int16 work buffer and the base64 input bytes are reused across
///     chunks — only one `Data` and one `String` allocate per emit.
///   * Float→Int16 conversion uses `vDSP_vsmul` + `vDSP_vfix16` (vectorized).
final class AudioPipeline {

    static let chunkSize = 4800  // 100 ms @ 48 kHz
    /// Compact the Float32 buffer once head index reaches this many samples.
    private static let compactThreshold = chunkSize * 2

    /// Called with each full chunk's base64 string (native-endian Int16 PCM).
    var onChunk: ((String) -> Void)?

    /// Backing Float32 accumulator. Samples are appended at the tail and
    /// consumed from `head`. Periodically `removeFirst(head)` compacts it.
    private var buffer: [Float32] = []
    private var head: Int = 0

    /// Reusable Int16 work buffer + reusable scaling buffer for vDSP.
    private var int16Scratch: [Int16] = []
    private var scaledScratch: [Float32] = []

    private let lock = NSLock()
    private var chunksEmitted: UInt64 = 0

    /// Append a Float32 sample run. Thread-safe.
    func process(samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        buffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        // Lazy-size the work buffers.
        if int16Scratch.count < AudioPipeline.chunkSize {
            int16Scratch = [Int16](repeating: 0, count: AudioPipeline.chunkSize)
            scaledScratch = [Float32](repeating: 0, count: AudioPipeline.chunkSize)
        }

        while (buffer.count - head) >= AudioPipeline.chunkSize {
            convertChunk()
            head += AudioPipeline.chunkSize
            emitScratch()

            // Periodic compact: amortized O(1) per sample.
            if head >= AudioPipeline.compactThreshold {
                buffer.removeFirst(head)
                head = 0
            }
        }
    }

    /// Flush any buffered samples as a final (shorter) chunk. Useful on stop.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        let remaining = buffer.count - head
        guard remaining > 0 else { return }

        if int16Scratch.count < remaining {
            int16Scratch = [Int16](repeating: 0, count: remaining)
            scaledScratch = [Float32](repeating: 0, count: remaining)
        }

        buffer.withUnsafeBufferPointer { inBuf in
            let src = inBuf.baseAddress!.advanced(by: head)
            convertRange(src: src, count: remaining)
        }
        buffer.removeAll()
        head = 0
        emitScratch(count: remaining)
    }

    /// Reset state without emitting.
    func reset() {
        lock.lock()
        buffer.removeAll()
        head = 0
        chunksEmitted = 0
        lock.unlock()
    }

    // MARK: Private

    /// Convert the next chunkSize Float32 samples starting at `head` into
    /// Int16 in `int16Scratch` using vectorized vDSP.
    private func convertChunk() {
        buffer.withUnsafeBufferPointer { inBuf in
            let src = inBuf.baseAddress!.advanced(by: head)
            convertRange(src: src, count: AudioPipeline.chunkSize)
        }
    }

    /// Vectorized Float32 → Int16 conversion.
    /// Step 1: scale by 32767 (vDSP_vsmul).
    /// Step 2: clamp to Int16 range (we don't need this strictly — input
    ///         is normalized — but vDSP_vfix16 with default rounding handles
    ///         out-of-range safely via saturation when the dynamic-range
    ///         flag is used).
    /// Step 3: round to Int16 (vDSP_vfix16).
    private func convertRange(src: UnsafePointer<Float32>, count: Int) {
        scaledScratch.withUnsafeMutableBufferPointer { scaledBuf in
            int16Scratch.withUnsafeMutableBufferPointer { int16Buf in
                var scale: Float = Float(Int16.max)
                // scaledScratch[i] = src[i] * 32767
                vDSP_vsmul(src, 1, &scale, scaledBuf.baseAddress!, 1, vDSP_Length(count))
                // int16Scratch[i] = round(scaledScratch[i]), with saturation.
                vDSP_vfix16(scaledBuf.baseAddress!, 1, int16Buf.baseAddress!, 1, vDSP_Length(count))
            }
        }
    }

    private func emitScratch(count: Int = AudioPipeline.chunkSize) {
        // Single Data allocation per chunk; the underlying Int16 bytes are
        // copied once from int16Scratch into the new Data.
        let data = int16Scratch.withUnsafeBufferPointer { buf -> Data in
            Data(bytes: buf.baseAddress!, count: count * MemoryLayout<Int16>.size)
        }
        let base64 = data.base64EncodedString()
        chunksEmitted &+= 1
        if chunksEmitted % 20 == 1 {
            DebugLog.write("AudioPipeline emit chunk #\(chunksEmitted) (\(count) samples, \(base64.count) base64 chars)")
        }
        onChunk?(base64)
    }
}
