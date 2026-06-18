import Foundation
import AppKit

/// Orchestrates the end-to-end pipeline:
///
///     ScreenCaptureKit → Float32 → AudioPipeline (Int16+base64) → GeminiClient
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
    private let pipeline = AudioPipeline()
    private lazy var subtitleWindow: SubtitleWindow = SubtitleWindow()
    private let subtitleBuffer = SubtitleBuffer()
    private var lastStatusText = "Stopped"

    private var currentTargetLanguage: String = Languages.defaultCode

    /// True after `start()` until audio capture has begun. Used to gate the
    /// one-shot `beginAudioCaptureIfRunning()` call from `handleGeminiStatus(.ready)`.
    private var awaitingAudioStart = false

    /// Coalesced transcription update: the latest text waiting to be flushed
    /// to the OSD, plus the pending work item. Reduces main-thread hops when
    /// Gemini bursts many small fragments.
    private var pendingTranscription: String?
    private var pendingTranscriptionWork: DispatchWorkItem?

    /// Reusable timer that demotes `.receivingAudio` back to `.active` after
    /// a few seconds of silence, so the icon goes blue → green when audio
    /// stops flowing (e.g. user pauses the video).
    private var silenceDemotionTimer: DispatchSourceTimer?
    /// Seconds of consecutive silence before the icon demotes blue → green.
    private let silenceDemotionSeconds: TimeInterval = 3.0

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
        start(targetLanguage: targetLanguage, audioSourceUID: nil)
    }

    func start(targetLanguage: String, audioSourceUID: String?) {
        currentTargetLanguage = targetLanguage
        DebugLog.write("AppCoordinator.start targetLanguage=\(targetLanguage) audioSourceUID=\(audioSourceUID ?? "<default>")")

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

        runState = .starting
        lastStatusText = "Connecting to Gemini…"

        // 2. Build Gemini client.
        DebugLog.write("AppCoordinator.start got API key (length=\(apiKey.count), prefix=\(apiKey.prefix(8)), suffix=\(apiKey.suffix(4)))")
        let client = GeminiClient(apiKey: apiKey, targetLanguage: targetLanguage)
        client.onTranscription = { [weak self] text, isFinal in
            self?.subtitleBuffer.append(text)
        }
        client.onError = { [weak self] error in
            self?.handleGeminiError(error)
        }
        client.onStatusChange = { [weak self] status in
            self?.handleGeminiStatus(status)
        }
        self.gemini = client

        // 3. Build audio capture + pipeline.
        let audioCapture = AudioCapture()
        audioCapture.deviceUID = (audioSourceUID?.isEmpty == false) ? audioSourceUID : nil
        audioCapture.onSamples = { [weak self] samples, count, silent in
            // Skip the pipeline entirely when the batch is silent so we make
            // no Gemini API calls during idle periods (e.g. user pauses the
            // video). The pipeline's internal partial buffer is preserved
            // and resumes filling once non-silent audio returns.
            guard !silent else { return }
            self?.pipeline.process(samples: samples, count: count)
            self?.markAudioReceived()
        }
        audioCapture.onError = { [weak self] error in
            self?.handleAudioError(error)
        }
        self.capture = audioCapture

        // 4. Wire pipeline chunks → GeminiClient.sendAudio.
        pipeline.onChunk = { [weak self] base64 in
            self?.gemini?.sendAudio(base64PCM: base64)
        }

        // 5. Start Gemini first; audio kicks in once setup is complete.
        client.start()

        // Show the OSD so it's ready to receive the first line.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Restore persisted font size before showing.
            let storedSize = UserDefaults.standard.integer(forKey: "com.gemini-subtitles.fontSize")
            if storedSize > 0 {
                self.setSubtitleFontSize(CGFloat(storedSize))
            }
            self.subtitleBuffer.onUpdate = { [weak self] text in
                self?.scheduleTranscriptionUpdate(text)
            }
            self.subtitleWindow.reveal()
        }

        // 6. Start audio capture when Gemini reaches `.ready` (handled in
        // `handleGeminiStatus`). A 5 s fallback covers the rare case where
        // `.ready` never fires — capture still starts so we can show the
        // blue icon and diagnose whether audio is flowing.
        awaitingAudioStart = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.awaitingAudioStart else { return }
            DebugLog.write("AppCoordinator: ready-not-received fallback firing after 5 s")
            self.beginAudioCaptureIfRunning()
        }
    }

    func stop(reason: StopReason) {
        capture?.stop()
        capture = nil
        gemini?.stop()
        gemini = nil
        pipeline.reset()
        awaitingAudioStart = false
        silenceDemotionTimer?.cancel()
        silenceDemotionTimer = nil
        pendingTranscriptionWork?.cancel()
        pendingTranscriptionWork = nil
        pendingTranscription = nil
        DispatchQueue.main.async { [weak self] in
            self?.subtitleBuffer.reset()
            self?.subtitleWindow.hide()
        }
        runState = .stopped
        lastStatusText = reason == .languageChanged ? "Switching language…" : "Stopped"
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
    private func scheduleTranscriptionUpdate(_ text: String) {
        pendingTranscription = text
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
        subtitleWindow.update(text: text, isFinal: false)
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
            if self.runState == .active {
                self.runState = .receivingAudio
            }
            if self.runState == .receivingAudio {
                self.lastStatusText = "Listening · \(Languages.name(forCode: self.currentTargetLanguage))"
                self.armSilenceDemotionTimer()
            }
        }
    }

    /// (Re)start the 3 s timer. On fire, demote `.receivingAudio → .active`
    /// so the icon goes blue → green when audio stops flowing (e.g. user
    /// pauses the video).
    private func armSilenceDemotionTimer() {
        silenceDemotionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + silenceDemotionSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.runState == .receivingAudio else { return }
            self.runState = .active
            self.lastStatusText = "Running · \(Languages.name(forCode: self.currentTargetLanguage))"
            // Audio has gone silent — clear and hide the OSD so the last line
            // doesn't linger on screen.
            self.subtitleBuffer.reset()
            self.subtitleWindow.hide()
        }
        timer.resume()
        silenceDemotionTimer = timer
    }

    private func handleGeminiStatus(_ status: GeminiClient.Status) {
        switch status {
        case .ready:
            runState = .active
            lastStatusText = "Running · \(Languages.name(forCode: currentTargetLanguage))"
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
            if runState != .stopped {
                runState = .stopped
                lastStatusText = "Disconnected"
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
            try capture?.start()
        } catch {
            DebugLog.write("AppCoordinator.beginAudioCaptureIfRunning FAILED: \(error.localizedDescription)")
            handleAudioError(error)
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
}
