import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Microphone capture via AVAudioEngine, sibling to `AudioCapture`.
///
/// Uses the system default input device unless `deviceUID` is set, in which
/// case the underlying HAL output unit is repointed via
/// `kAudioOutputUnitProperty_CurrentDevice`.
///
/// Tap format is forced to 48 kHz Float32 mono so the downstream pipeline
/// (`AudioPipeline` + `GeminiClient`) is identical to the SCStream path.
/// AVAudioEngine handles any necessary resample / down-mix.
///
/// Silence detection is RMS-based because mic input always contains ambient
/// noise — the zero-fill heuristic used by the SCStream path does not apply.
final class MicrophoneCapture {

    /// Same callback signature as `AudioCapture.onSamples` so the two
    /// sources can drive the pipeline interchangeably. `pointer` is valid
    /// only for the duration of the callback.
    var onSamples: ((UnsafePointer<Float32>, Int, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    /// UID of the input device to use (empty/nil = system default).
    var deviceUID: String?

    /// Batches with RMS below this are treated as silent. ~-50 dBFS.
    /// Tuned empirically for the macOS built-in mic: ambient room noise
    /// measures ~0.002 RMS while normal speech measures ~0.012-0.020, so
    /// 0.005 cleanly separates the two and avoids flagging mid-sentence
    /// word gaps as silence.
    private let silenceThreshold: Float = 0.005

    private let engine = AVAudioEngine()
    private var running = false
    private let queue = DispatchQueue(label: "GeminiSubtitles.mic", qos: .userInitiated)
    private let diagQueue = DispatchQueue(label: "GeminiSubtitles.mic.diag", qos: .utility)
    private var diagCounter: UInt = 0

    // MARK: Lifecycle

    func start() throws {
        guard !running else { return }
        running = true

        let inputNode = engine.inputNode

        // If a specific device UID is set, repoint the underlying HAL
        // output unit before installing the tap. We do this by matching
        // UID → device ID via CoreAudio enumeration.
        if let uid = deviceUID, !uid.isEmpty,
           let deviceID = Self.findInputDeviceID(byUID: uid) {
            Self.setCurrentInputDevice(deviceID, onNode: inputNode)
        }

        // Install the tap directly in the target format. AVAudioEngine
        // internally handles any necessary resample / channel down-mix.
        // Note: querying `outputFormat(forBus:)` here would give the HW
        // format; AVAudioEngine still accepts our requested format on the
        // tap and performs the conversion.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false) else {
            running = false
            onError?(MicrophoneCaptureError.formatUnavailable)
            return
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: targetFormat) {
            [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            DebugLog.write("MicrophoneCapture: started (hwRate=\(hwFormat.sampleRate) Hz, hwCh=\(hwFormat.channelCount), tapRate=48000 tapCh=1)")
        } catch {
            running = false
            inputNode.removeTap(onBus: 0)
            DebugLog.write("MicrophoneCapture.start FAILED: \(error.localizedDescription)")
            onError?(error)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DebugLog.write("MicrophoneCapture: stopped")
    }

    // MARK: Sample handling

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let channelPtr = channelData[0]

        // RMS-based silence detection.
        var sumSq: Float = 0
        var maxAbs: Float = 0
        for j in 0..<frames {
            let s = channelPtr[j]
            sumSq += s * s
            let a = abs(s)
            if a > maxAbs { maxAbs = a }
        }
        let rms = sqrtf(sumSq / Float(frames))
        let silent = rms < silenceThreshold

        // Diagnostic logging every ~10 callbacks (~1/sec at typical rates).
        diagCounter &+= 1
        if diagCounter % 10 == 0 {
            let frames2 = frames
            let rms2 = rms
            let maxAbs2 = maxAbs
            let isSilent = silent
            diagQueue.async {
                DebugLog.write("MicrophoneCapture: frames=\(frames2) rms=\(String(format: "%.6f", rms2)) maxAbs=\(String(format: "%.6f", maxAbs2)) silent=\(isSilent)")
            }
        }

        channelPtr.withMemoryRebound(to: Float32.self, capacity: frames) { ptr in
            onSamples?(ptr, frames, silent)
        }
    }

    // MARK: Device enumeration

    /// Enumerates input devices for the Microphone submenu. Returns
    /// `(display name, device UID)` tuples.
    static func enumerateInputDevices() -> [(name: String, uid: String)] {
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
            // Only devices that have input streams are microphones.
            var inSize: UInt32 = 0
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &inSize)
            guard inSize > 0 else { continue }

            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr
            else { continue }

            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Some devices don't expose a UID; fall back to a stringified ID.
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr
            else {
                result.append((name: name as String, uid: "\(id)"))
                continue
            }
            result.append((name: name as String, uid: uid as String))
        }
        return result
    }

    /// Resolve a UID to a HAL `AudioDeviceID`. Returns nil if not found.
    private static func findInputDeviceID(byUID uid: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids)

        for id in ids {
            var current: CFString = "" as CFString
            var curSize = UInt32(MemoryLayout<CFString>.size)
            var curAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(id, &curAddr, 0, nil, &curSize, &current) == noErr,
               (current as String) == uid {
                return id
            }
        }
        return nil
    }

    /// Set the underlying HAL output unit's current device so the
    /// AVAudioEngine tap records from `deviceID`.
    private static func setCurrentInputDevice(
        _ deviceID: AudioDeviceID, onNode node: AVAudioNode
    ) {
        guard let unit = (node as? AVAudioIONode)?.audioUnit else { return }
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size)
    }
}

// MARK: Errors

enum MicrophoneCaptureError: Error, LocalizedError {
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Could not create the target audio format for mic capture"
        }
    }
}
