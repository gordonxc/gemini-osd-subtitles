import Foundation
import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// System-wide audio capture via ScreenCaptureKit (audio-only).
///
/// SCStream on macOS 14+ captures system audio output using the
/// "Screen Recording" TCC permission category, which works reliably
/// for adhoc-signed apps (unlike CoreAudio's CATap which on macOS 26
/// Tahoe silently zero-fills buffers without an Apple Developer ID).
///
/// We need a display filter for SCStream, but never read any video
/// content — only `.audio` sample buffers are subscribed.
final class AudioCapture: NSObject, SCStreamDelegate {

    /// Delivered on the capture queue. `pointer` is valid only for the
    /// duration of the callback; copy if retention is needed. `silent`
    /// is true when all samples in this batch are zero.
    var onSamples: ((UnsafePointer<Float32>, Int, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    /// Device UID override is currently a no-op under SCStream — capture
    /// always uses the main display's audio.
    var deviceUID: String?

    /// When set, the SCContentFilter is restricted to this single
    /// application via `SCContentFilter(display:including:exceptingWindows:)`,
    /// so only that app's audio is captured. nil/empty = whole-system mix.
    /// Resolved against `SCShareableContent.current.applications` at
    /// `start()` time; if the app isn't running we fall back to the
    /// whole-display filter (with a log line) rather than failing hard.
    var applicationBundleID: String?

    private var stream: SCStream?
    private var running = false
    private let queue = DispatchQueue(label: "GeminiSubtitles.audio", qos: .userInitiated)
    /// Background queue for diagnostic logging — never blocks the audio thread.
    private let diagQueue = DispatchQueue(label: "GeminiSubtitles.audio.diag", qos: .utility)
    /// Counts IOProc invocations; used to throttle full stats computation.
    private var diagCounter: UInt = 0

    // MARK: Lifecycle

    func start() throws {
        guard !running else { return }
        running = true

        DebugLog.write("AudioCapture (SCStream) requesting shareable content…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    DebugLog.write("AudioCapture no displays available")
                    await MainActor.run {
                        self.running = false
                        self.onError?(AudioCaptureError.noDisplayAvailable)
                    }
                    return
                }
                DebugLog.write("AudioCapture got shareable content: \(content.displays.count) display(s), using displayID=\(display.displayID)")
                // Resolve per-app filter target against currently-running
                // apps. We pass the resolved SCRunningApplication along so
                // startStream can build the including: filter without
                // re-fetching shareable content.
                var targetApp: SCRunningApplication? = nil
                if let bid = self.applicationBundleID, !bid.isEmpty {
                    targetApp = content.applications.first { $0.bundleIdentifier == bid }
                    if targetApp == nil {
                        DebugLog.write("AudioCapture: app \(bid) not running; falling back to whole-system capture")
                    } else {
                        DebugLog.write("AudioCapture: restricting capture to app \(bid)")
                    }
                }
                self.startStream(for: display, including: targetApp)
            } catch {
                DebugLog.write("AudioCapture SCShareableContent error: \(error.localizedDescription)")
                await MainActor.run {
                    self.running = false
                    self.onError?(error)
                }
            }
        }
    }

    private func startStream(for display: SCDisplay, including app: SCRunningApplication?) {
        let filter: SCContentFilter
        if let app {
            // macOS 14+: a content filter restricted to specific running
            // applications also restricts the audio stream to those apps.
            // This is the per-app isolation path; no CATap involved so it
            // works for self-signed bundles on Tahoe.
            filter = SCContentFilter(
                display: display,
                including: [app],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: queue)
        } catch {
            DebugLog.write("AudioCapture addStreamOutput failed: \(error.localizedDescription)")
            running = false
            onError?(error)
            return
        }
        self.stream = stream

        stream.startCapture { [weak self] (error: Error?) in
            guard let self else { return }
            if let error {
                DebugLog.write("AudioCapture startCapture FAILED: \(error.localizedDescription)")
                self.running = false
                self.onError?(error)
                return
            }
            DebugLog.write("AudioCapture startCapture OK (stream running)")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let stream {
            stream.stopCapture { _ in
                DebugLog.write("AudioCapture stream stopped")
            }
            self.stream = nil
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DebugLog.write("AudioCapture stream didStopWithError: \(error.localizedDescription)")
        running = false
        onError?(error)
    }

    // MARK: Device enumeration (used by menu picker)

    /// Enumerates currently-running applications that are eligible for
    /// per-app audio capture. Filters to apps with at least one on-screen
    /// window (ScreenCaptureKit reports many background helpers that would
    /// only clutter the picker). Returns (bundleID, display name) tuples,
    /// sorted by name. Safe to call from the main thread.
    static func enumerateRunningApplications() -> [(bundleID: String, name: String)] {
        // SCShareableContent is async-only; bridge via a semaphore so the
        // menu builder (synchronous) can call this directly.
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(bundleID: String, name: String)] = []
        Task {
            if let content = try? await SCShareableContent.current {
                // Filter to .regular-activation-policy apps via
                // NSRunningApplication; SCRunningApplication itself exposes
                // no activation policy, and the raw list includes many
                // background helpers (loginwindow, Spotlight, …) that
                // would only clutter the picker.
                let regularBundleIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .map { $0.bundleIdentifier ?? "" }
                )
                for app in content.applications {
                    guard regularBundleIDs.contains(app.bundleIdentifier) else { continue }
                    let name = app.applicationName.isEmpty ? app.bundleIdentifier : app.applicationName
                    result.append((bundleID: app.bundleIdentifier, name: name))
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Enumerates output devices via CoreAudio for the menu picker. Returns
    /// (display name, device UID) tuples. Note: under SCStream the audio
    /// source is the display's audio, not these devices directly.
    static func enumerateOutputDevices() -> [(name: String, uid: String)] {
        var result: [(name: String, uid: String)] = []
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids)
        for id in ids {
            var outSize: UInt32 = 0
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &outSize)
            guard outSize > 0 else { continue }

            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr else { continue }

            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr else { continue }

            result.append((name: name as String, uid: uid as String))
        }
        return result
    }
}

// MARK: - SCStreamOutput

extension AudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let asbd, asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        var blockBuffer: CMBlockBuffer?
        let bufferListSize = MemoryLayout<AudioBufferList>.size
        var audioBufferList = AudioBufferList()
        var sizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: &audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        // Read first buffer's data (mono channel expected from config).
        let mdata = audioBufferList.mBuffers.mData
        let byteSize = audioBufferList.mBuffers.mDataByteSize
        guard let mdata, byteSize > 0 else { return }
        let frameCount = Int(byteSize) / MemoryLayout<Float32>.size
        guard frameCount > 0 else { return }

        mdata.withMemoryRebound(to: Float32.self, capacity: frameCount) { ptr in
            // Cheap silence heuristic: check first / middle / last sample.
            // Real audio virtually never has all three at exact zero; the
            // TCC privacy fallback (and genuinely silent output) does.
            // This avoids a full O(N) pass on every real-time audio callback.
            let last = frameCount - 1
            let mid = frameCount >> 1
            let silent = ptr[0] == 0 && ptr[mid] == 0 && ptr[last] == 0

            // Every ~10 callbacks (~1/sec at 93 calls/sec), compute full
            // RMS/maxAbs for diagnostics. Offload DebugLog writes to a
            // utility queue so file I/O never blocks the audio thread.
            diagCounter &+= 1
            if diagCounter % 10 == 0 {
                var sumSq: Float = 0
                var maxAbs: Float = 0
                for j in 0..<frameCount {
                    let s = ptr[j]; sumSq += s * s
                    let a = abs(s); if a > maxAbs { maxAbs = a }
                }
                let rms = sqrtf(sumSq / Float(frameCount))
                let frames = frameCount
                let isSilent = silent
                diagQueue.async {
                    DebugLog.write("AudioCapture SCK: frames=\(frames) rms=\(String(format: "%.6f", rms)) maxAbs=\(String(format: "%.6f", maxAbs)) silent=\(isSilent)")
                }
            }

            onSamples?(ptr, frameCount, silent)
        }
    }
}

// MARK: Errors

enum AudioCaptureError: Error, LocalizedError {
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for audio capture"
        }
    }
}
