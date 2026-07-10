import Foundation
import AppKit
import AVFoundation

/// Orchestrates the end-to-end pipeline:
///
///     ScreenCaptureKit / AVAudioEngine → Float32 → AudioPipeline (Int16+base64) → GeminiClient
///                                                                   ↓
///     SubtitleWindow ← (onTranscription)
///
/// Plus status reporting back to the menu bar icon and dropdown.
protocol AppCoordinatorDelegate: AnyObject {
    /// Called when the user needs to be prompted for an API key.
    func coordinatorRequestedAPIKeyEntry(_ coordinator: AppCoordinator)
}

final class AppCoordinator {

    enum RunState {
        case stopped
        case starting
        case active
        case receivingAudio   // WS ready AND non-zero audio frames observed
        case error
    }

    enum StopReason {
        case userRequested
        case languageChanged
        case disconnected
    }

    /// Which audio input to capture from.
    enum AudioSource: Equatable {
        /// System audio via ScreenCaptureKit. `uid` selects a specific
        /// output device for the menu picker (currently advisory under
        /// SCStream — capture always uses the main display's audio).
        /// `appBundleID`, when non-nil, restricts capture to that single
        /// running application via SCContentFilter(display:including:).
        case system(audioSourceUID: String?, applicationBundleID: String? = nil)
        /// Microphone via AVAudioEngine. `uid` of nil/empty = system
        /// default input device.
        case microphone(deviceUID: String?)
    }

    weak var delegate: AppCoordinatorDelegate?

    /// Updated by AppDelegate on each state transition to update the icon and
    /// the menu status line. (state, statusText)
    var statusChanged: ((RunState, String) -> Void)?

    private(set) var runState: RunState = .stopped {
        didSet { emitStatus() }
    }

    private var gemini: GeminiClient?
    private var capture: AudioCapture?
    private var micCapture: MicrophoneCapture?
    private let pipeline = AudioPipeline()
    private lazy var subtitleWindow: SubtitleWindow = SubtitleWindow()
    private let subtitleBuffer = SubtitleBuffer()
    private var lastStatusText = "Stopped"

    /// Per-session subtitle history. `beginSession` is called in `start()`,
    /// `append` is wired into `scheduleTranscriptionUpdate`, and
    /// `endSession` is called in `stop()`.
    let history = HistoryStore()

    private var currentTargetLanguage: String = Languages.defaultCode
    private var currentAudioSource: AudioSource = .system(audioSourceUID: nil)
    private var currentBilingual: Bool = false

    /// Re-entrancy guard for stop(); see stop(reason:).
    private var isStopping = false

    /// User-defaults key for the bilingual OSD toggle.
    private let bilingualUDKey = "com.gemini-subtitles.bilingual"

    /// True after `start()` until audio capture has begun. Used to gate the
    /// one-shot `beginAudioCaptureIfRunning()` call from `handleGeminiStatus(.ready)`.
    private var awaitingAudioStart = false

    /// Coalesced transcription update: the latest text waiting to be flushed
    /// to the OSD, plus the pending work item. Reduces main-thread hops when
    /// Gemini bursts many small fragments.
    private var pendingTranscription: String?
    private var pendingOriginal: String?
    private var pendingTranscriptionWork: DispatchWorkItem?

    /// Reusable timer that demotes `.receivingAudio` back to `.active` after
    /// a few seconds of silence, so the icon goes blue → green when audio
    /// stops flowing (e.g. user pauses the video).
    private var silenceDemotionTimer: DispatchSourceTimer?
    /// Seconds of consecutive silence before the icon demotes blue → green.
    /// Short for system audio (user paused video); long for mic because
    /// speech has natural multi-second pauses between sentences.
    private let silenceDemotionSecondsSystem: TimeInterval = 3.0
    private let silenceDemotionSecondsMic: TimeInterval = 10.0

    /// User-defaults key for the auto-stop inactivity timeout in minutes
    /// (0 = off). Read on every poll tick so the menu can change it live.
    private let autoStopUDKey = "com.gemini-subtitles.autoStopMinutes"
    /// Polling interval for the auto-stop check. Coarse is fine because the
    /// timeout itself is minute-scale.
    private let autoStopPollSeconds: TimeInterval = 15.0
    private var autoStopPollTimer: DispatchSourceTimer?
    /// Timestamp of the last non-silent audio batch. Reset on every
    /// `markAudioReceived`; the poll timer measures inactivity against this.
    private var lastAudioActivityAt: Date?

    // MARK: Launch

    /// Called on launch. Preflight Screen Recording permission; if not yet
    /// decided, fire CGRequestScreenCaptureAccess so the OS records a prompt
    /// intent and surfaces it next time SCShareableContent is called.
    func requestScreenCapturePermissionOnLaunch() {
        if !Permissions.preflight() {
            _ = Permissions.request()
        }
    }

    func start(targetLanguage: String) {
        start(targetLanguage: targetLanguage, audioSource: .system(audioSourceUID: nil))
    }

    /// Legacy entry point preserved for older call sites.
    func start(targetLanguage: String, audioSourceUID: String?) {
        start(targetLanguage: targetLanguage,
              audioSource: .system(audioSourceUID: audioSourceUID))
    }

    func start(targetLanguage: String, audioSource: AudioSource) {
        currentTargetLanguage = targetLanguage
        currentAudioSource = audioSource
        currentBilingual = UserDefaults.standard.bool(forKey: bilingualUDKey)
        DebugLog.write("AppCoordinator.start targetLanguage=\(targetLanguage) audioSource=\(audioSource) bilingual=\(currentBilingual)")

        // 1. API key check.
        guard let apiKey = KeychainStore.getAPIKey(), !apiKey.isEmpty else {
            DebugLog.write("AppCoordinator.start: NO API KEY in Keychain")
            runState = .error
            lastStatusText = "No API key set"
            NotificationManager.shared.notify(
                title: "Gemini Subtitles",
                body: "Set your Gemini API key from the menu bar to start."
            )
            delegate?.coordinatorRequestedAPIKeyEntry(self)
            return
        }

        NotificationManager.shared.requestAuthorizationIfNeeded()

        // 2. Mic source requires TCC Microphone permission. Request up
        // front; if denied or still pending, surface the deep-link and
        // bail. The actual `beginStart` runs after the system prompt
        // resolves.
        if case .microphone = audioSource {
            let granted = AVAudioApplication.shared.recordPermission == .granted
            if granted {
                beginStart(apiKey: apiKey)
            } else {
                runState = .starting
                lastStatusText = "Requesting microphone permission…"
                AVAudioApplication.requestRecordPermission { [weak self] ok in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if ok {
                            self.beginStart(apiKey: apiKey)
                        } else {
                            self.runState = .error
                            self.lastStatusText = "Microphone permission denied"
                            NotificationManager.shared.notify(
                                title: "Microphone permission needed",
                                body: "Grant access in System Settings → Privacy & Security → Microphone, then click Start."
                            )
                            Permissions.openMicrophoneSettings()
                        }
                    }
                }
            }
            return
        }

        beginStart(apiKey: apiKey)
    }

    /// Inner start logic, called once mic permission (if applicable) has
    /// been confirmed.
    private func beginStart(apiKey: String) {
        let targetLanguage = currentTargetLanguage
        let audioSource = currentAudioSource

        runState = .starting
        lastStatusText = "Connecting to Gemini…"

        // Start a fresh history session file so the very first line lands
        // in the right place.
        history.beginSession(languageCode: targetLanguage)

        // Build Gemini client.
        DebugLog.write("AppCoordinator.start got API key (length=\(apiKey.count), prefix=\(apiKey.prefix(8)), suffix=\(apiKey.suffix(4)))")
        let client = GeminiClient(apiKey: apiKey, targetLanguage: targetLanguage, bilingual: currentBilingual)
        client.onTranscription = { [weak self] text, isFinal, original in
            // Gemini callbacks arrive on the URLSession delegate queue
            // (background). The buffer + OSD pipeline touch AppKit, so hop
            // to the main thread first. Calling NSTextField.isHidden /
            // layout setters from the WS delegate thread will crash AppKit.
            DispatchQueue.main.async {
                self?.subtitleBuffer.append(text, original: original)
            }
        }
        client.onError = { [weak self] error in
            self?.handleGeminiError(error)
        }
        client.onStatusChange = { [weak self] status in
            self?.handleGeminiStatus(status)
        }
        self.gemini = client

        // Build the appropriate audio capture + pipeline.
        switch audioSource {
        case .system(let uid, let appBundleID):
            let audioCapture = AudioCapture()
            audioCapture.deviceUID = (uid?.isEmpty == false) ? uid : nil
            audioCapture.applicationBundleID = (appBundleID?.isEmpty == false) ? appBundleID : nil
            audioCapture.onError = { [weak self] error in
                self?.handleAudioError(error)
            }
            audioCapture.onSamples = { [weak self] samples, count, silent in
                // Skip the pipeline entirely when the batch is silent so we make
                // no Gemini API calls during idle periods (e.g. user pauses the
                // video). The pipeline's internal partial buffer is preserved
                // and resumes filling once non-silent audio returns.
                guard !silent else { return }
                self?.pipeline.process(samples: samples, count: count)
                self?.markAudioReceived()
            }
            self.capture = audioCapture
        case .microphone(let uid):
            let mic = MicrophoneCapture()
            mic.deviceUID = (uid?.isEmpty == false) ? uid : nil
            mic.onSamples = { [weak self] samples, count, silent in
                guard !silent else { return }
                self?.pipeline.process(samples: samples, count: count)
                self?.markAudioReceived()
            }
            mic.onError = { [weak self] error in
                self?.handleMicError(error)
            }
            self.micCapture = mic
        }

        // Wire pipeline chunks → GeminiClient.sendAudio.
        pipeline.onChunk = { [weak self] base64 in
            self?.gemini?.sendAudio(base64PCM: base64)
        }

        // Start Gemini first; audio kicks in once setup is complete.
        client.start()

        // Show the OSD so it's ready to receive the first line.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Restore persisted font size before showing.
            let storedSize = UserDefaults.standard.integer(forKey: "com.gemini-subtitles.fontSize")
            if storedSize > 0 {
                self.setSubtitleFontSize(CGFloat(storedSize))
            }
            self.subtitleBuffer.onUpdate = { [weak self] text, original in
                self?.scheduleTranscriptionUpdate(text, original: original)
            }
            self.subtitleWindow.reveal()
        }

        // Start audio capture when Gemini reaches `.ready` (handled in
        // `handleGeminiStatus`). A 5 s fallback covers the rare case where
        // `.ready` never fires — capture still starts so we can show the
        // blue icon and diagnose whether audio is flowing.
        awaitingAudioStart = true
        // Schedule on main so the `awaitingAudioStart` read here doesn't
        // race with `handleGeminiStatus` (which mutates it on main). The
        // 5 s asyncAfter is wait-time, not work — main is fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.awaitingAudioStart else { return }
            DebugLog.write("AppCoordinator: ready-not-received fallback firing after 5 s")
            self.beginAudioCaptureIfRunning()
        }

        // Arm the auto-stop inactivity timer. Counts from session start;
        // every non-silent audio batch bumps `lastAudioActivityAt`.
        lastAudioActivityAt = Date()
        startAutoStopPollTimer()
    }

    private func handleMicError(_ error: Error) {
        runState = .error
        lastStatusText = "Mic: \(error.localizedDescription)"
        NotificationManager.shared.notify(
            title: "Microphone capture error",
            body: error.localizedDescription
        )
    }

    func stop(reason: StopReason) {
        // Re-entrancy guard: GeminiClient.stop() fires onStatusChange(.closed)
        // synchronously, which (for the disconnected case below) re-enters
        // stop(). Without this guard the inner call would nil out capture /
        // micCapture / gemini mid-teardown. The flag is reset on return.
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        capture?.stop()
        capture = nil
        micCapture?.stop()
        micCapture = nil
        gemini?.stop()
        gemini = nil
        pipeline.reset()
        awaitingAudioStart = false
        silenceDemotionTimer?.cancel()
        silenceDemotionTimer = nil
        pendingTranscriptionWork?.cancel()
        pendingTranscriptionWork = nil
        pendingTranscription = nil
        pendingOriginal = nil
        autoStopPollTimer?.cancel()
        autoStopPollTimer = nil
        lastAudioActivityAt = nil
        DispatchQueue.main.async { [weak self] in
            self?.subtitleBuffer.reset()
            self?.subtitleWindow.hide()
        }
        // Close the history session file before potentially starting a new
        // one (e.g. on language change).
        history.endSession()
        runState = .stopped
        switch reason {
        case .languageChanged: lastStatusText = "Switching language…"
        case .disconnected:    lastStatusText = "Disconnected"
        case .userRequested:   lastStatusText = "Stopped"
        }
    }

    // MARK: Callbacks

    private func handleTranscription(text: String, isFinal: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.subtitleWindow.update(text: text, isFinal: isFinal)
        }
    }

    /// Coalesce transcription updates before flushing to the OSD. Gemini often
    /// bursts many small fragments in quick succession; updating the window
    /// on each one causes redundant layout passes. We flush immediately on
    /// the first update after a quiet period, then collapse any subsequent
    /// updates arriving within the throttle window into a single flush.
    private func scheduleTranscriptionUpdate(_ text: String, original: String?) {
        pendingTranscription = text
        pendingOriginal = original
        // If a flush is already scheduled, the latest text will be used when
        // it fires — no need to schedule another.
        if pendingTranscriptionWork != nil { return }

        // First update in a burst: flush now so the user sees new text with
        // minimal latency.
        flushPendingTranscription()

        // Schedule a trailing flush 100 ms later; any fragments that arrive
        // in that window overwrite `pendingTranscription` and are flushed
        // together instead of one-by-one.
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingTranscription()
            self?.pendingTranscriptionWork = nil
        }
        pendingTranscriptionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func flushPendingTranscription() {
        guard let text = pendingTranscription else { return }
        pendingTranscription = nil
        let original = pendingOriginal
        pendingOriginal = nil
        subtitleWindow.update(text: text, isFinal: false, original: original)
        // Persist the finalised line to the history session file.
        history.append(text: text, original: original)
    }

    /// Toggle the OSD between click-through (locked) and draggable (unlocked).
    /// Returns the new locked state so the menu can update its checkmark.
    func toggleOSDLock() -> Bool {
        if subtitleWindow.locked {
            subtitleWindow.unlock()
        } else {
            subtitleWindow.lock()
        }
        return subtitleWindow.locked
    }

    /// Apply a new font size to the OSD subtitle text.
    func setSubtitleFontSize(_ size: CGFloat) {
        subtitleWindow.resizeForFontSize(size)
        subtitleWindow.subtitleView?.applyFontSize(size)
    }

    /// Called from the audio thread when a non-silent batch arrives. Promotes
    /// the run state to .receivingAudio so the menu bar icon turns blue, and
    /// (re)arms the silence demotion timer so the icon drops back to green
    /// after `silenceDemotionSeconds` without audio.
    private func markAudioReceived() {
        // Off-main thread; marshal to main for the state change + timer work.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Bump the inactivity timestamp for the auto-stop poll timer.
            self.lastAudioActivityAt = Date()
            if self.runState == .active {
                self.runState = .receivingAudio
            }
            if self.runState == .receivingAudio {
                self.lastStatusText = self.bilingualStatusLine(prefix: "Listening")
                self.armSilenceDemotionTimer()
            }
        }
    }

    /// (Re)start the silence-demotion timer. The timeout depends on the
    /// current source: short for system audio (user paused video → drop OSD
    /// quickly), long for mic (speech has natural pauses between sentences).
    private func armSilenceDemotionTimer() {
        silenceDemotionTimer?.cancel()
        let seconds: TimeInterval = {
            if case .microphone = currentAudioSource {
                return silenceDemotionSecondsMic
            }
            return silenceDemotionSecondsSystem
        }()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.runState == .receivingAudio else { return }
            self.runState = .active
            self.lastStatusText = self.bilingualStatusLine(prefix: "Running")
            // Audio has gone silent — clear and hide the OSD so the last line
            // doesn't linger on screen.
            self.subtitleBuffer.reset()
            self.subtitleWindow.hide()
        }
        timer.resume()
        silenceDemotionTimer = timer
    }

    // MARK: Auto-stop

    /// Start the periodic inactivity checker. The handler reads the timeout
    /// from UserDefaults on every tick so menu changes take effect live.
    private func startAutoStopPollTimer() {
        autoStopPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + autoStopPollSeconds, repeating: autoStopPollSeconds)
        timer.setEventHandler { [weak self] in
            self?.checkAutoStop()
        }
        timer.resume()
        autoStopPollTimer = timer
    }

    private func checkAutoStop() {
        let minutes = UserDefaults.standard.double(forKey: autoStopUDKey)
        guard minutes > 0, let last = lastAudioActivityAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let threshold = minutes * 60.0
        guard elapsed >= threshold else { return }
        let minsInt = Int(minutes)
        DebugLog.write("AppCoordinator: auto-stop firing after \(Int(elapsed)) s inactivity (threshold \(minsInt) min)")
        NotificationManager.shared.notify(
            title: "Gemini Subtitles auto-stopped",
            body: "No audio detected for \(minsInt) minute\(minsInt == 1 ? "" : "s"). Click Start to resume."
        )
        stop(reason: .userRequested)
    }

    private func handleGeminiStatus(_ status: GeminiClient.Status) {
        switch status {
        case .ready:
            runState = .active
            lastStatusText = bilingualStatusLine(prefix: "Running")
            // Kick off audio capture now that the WebSocket is set up. The
            // 5 s fallback in start() covers the rare case where .ready
            // never fires.
            if awaitingAudioStart {
                awaitingAudioStart = false
                beginAudioCaptureIfRunning()
            }
        case .connecting:
            if runState != .starting {
                runState = .starting
                lastStatusText = "Reconnecting…"
            }
        case .closed:
            // A terminal close arrived that wasn't driven by our own stop()
            // (user stop / language change set isStopping, which makes the
            // inner stop() below a no-op so the outer teardown continues).
            // This is the reconnect-exhausted path: without a full teardown
            // here, audio capture keeps running on a dead socket and the
            // overlay shows stale text, burning battery. Calling stop()
            // performs the full cleanup and sets status to "Disconnected".
            if runState != .stopped && !isStopping {
                stop(reason: .disconnected)
            }
        case .idle:
            break
        }
    }

    private func handleGeminiError(_ error: Error) {
        runState = .error
        lastStatusText = "Error: \(error.localizedDescription)"
        NotificationManager.shared.notify(
            title: "Gemini Subtitles error",
            body: error.localizedDescription
        )
    }

    private func handleAudioError(_ error: Error) {
        // ScreenCaptureKit reports permission denial via NSError with
        // domain OSStatusErrorDomain or SCStreamError, typically -12007
        // (no permission) or similar. Fall back to a string match.
        let nsError = error as NSError
        let isPermissionError: Bool
        if nsError.domain == "OSStatusErrorDomain" && (nsError.code == -12007 || nsError.code == -12021) {
            isPermissionError = true
        } else {
            isPermissionError = error.localizedDescription.lowercased().contains("permission")
                || error.localizedDescription.lowercased().contains("not authorized")
        }

        runState = .error
        lastStatusText = isPermissionError ? "Screen Recording permission required" : "Audio: \(error.localizedDescription)"

        if isPermissionError {
            NotificationManager.shared.notify(
                title: "Screen Recording permission needed",
                body: "Grant access in System Settings → Privacy & Security → Screen Recording, then click Start."
            )
            Permissions.openSystemSettings()
        } else {
            NotificationManager.shared.notify(
                title: "Audio capture error",
                body: error.localizedDescription
            )
        }
    }

    private func beginAudioCaptureIfRunning() {
        guard gemini != nil else {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning: no gemini client, aborting")
            return
        }
        do {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning: starting capture")
            if let mic = micCapture {
                try mic.start()
            } else {
                try capture?.start()
            }
        } catch {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning FAILED: \(error.localizedDescription)")
            if micCapture != nil {
                handleMicError(error)
            } else {
                handleAudioError(error)
            }
        }
    }

    private func emitStatus() {
        let state = runState
        let text = lastStatusText
        if Thread.isMainThread {
            statusChanged?(state, text)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusChanged?(state, text)
            }
        }
    }

    /// Build the status line. In bilingual mode shows the source language
    /// name → target language name; otherwise just the target.
    /// Example: "Listening · English → Cantonese".
    private func bilingualStatusLine(prefix: String) -> String {
        let targetName = Languages.name(forCode: currentTargetLanguage)
        guard currentBilingual else {
            return "\(prefix) · \(targetName)"
        }
        // The source language is auto-detected by Gemini; surface it as
        // "Auto" because we never learn the actual detected code from the
        // server (inputTranscription carries no language tag).
        return "\(prefix) · Auto → \(targetName)"
    }
}
