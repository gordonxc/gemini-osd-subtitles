import Foundation

/// WebSocket client for the Gemini Live bidi stream. Ported from
/// `translation-bridge.ts` connect/reconnect/send logic (lines 201-354,
/// 272-326, 579-617), replacing `ws` with `URLSessionWebSocketTask`.
///
/// Responsibilities:
///   - Open the WS, send the `setup` message, await `setupComplete`.
///   - Run a receive loop, dispatching transcription callbacks.
///   - Drop audio sends while not ready (port of translation-bridge.ts:580-586).
///   - Reconnect 1s after an unexpected close while in the active state.
final class GeminiClient {

    // MARK: Callbacks

    /// Emitted on every `outputTranscription.text` chunk.
    /// Parameters: `(text, isFinal, original)` where `original` is the
    /// source-language transcript when bilingual mode is enabled, else nil.
    var onTranscription: ((String, Bool, String?) -> Void)?
    /// Emitted on transport-level errors or non-recoverable close codes.
    var onError: ((Error) -> Void)?
    /// Emitted when the client lifecycle state changes.
    var onStatusChange: ((Status) -> Void)?

    enum Status: Equatable {
        case idle
        case connecting
        case ready
        case closed
    }

    /// Counts audio chunks sent for diagnostics.
    private var audioChunksSent: UInt64 = 0

    // MARK: Internals

    private let endpoint = URL(string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )!

    private let session: URLSession
    private let apiKey: String
    private let targetLanguage: String
    /// When true, setup enables `inputAudioTranscription` and parsed events
    /// carry an `original` field.
    private let bilingual: Bool

    private var task: URLSessionWebSocketTask?
    private var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }

    /// True once `setupComplete` has been received from the server.
    private var setupComplete = false
    /// True while the user wants the stream alive (controls reconnect logic).
    private var running = false
    /// Counts consecutive reconnect failures; resets on a clean setup.
    private var consecutiveReconnectFailures = 0

    /// Most recent source-language transcript waiting to be paired with the
    /// next translation frame. Bilingual mode only; Gemini sends input and
    /// output transcripts as separate frames so we buffer the latest input
    /// and attach it to the next output. Reset on stop / reconnect.
    private var pendingOriginal: String?

    private let setupTimeout: TimeInterval = 15
    private let reconnectDelay: TimeInterval = 1
    private let maxReconnectAttempts = 3

    init(apiKey: String, targetLanguage: String, bilingual: Bool = false, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        self.bilingual = bilingual
        if let session {
            self.session = session
        } else {
            // Dedicated session: disable cookie storage (Gemini's Set-Cookie
            // uses an unusual "S==..." name that can trip the parser) and
            // constrain to HTTP/1.1/2 only — WebSocket upgrades are HTTP/1.1.
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .never
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Lifecycle

    /// Opens the WebSocket and resolves once `setupComplete` is received
    /// (or errors on timeout / close-before-setup).
    func start() {
        guard !running else { return }
        running = true
        consecutiveReconnectFailures = 0
        openConnection()
    }

    /// Cancels the WebSocket and disables reconnect. Safe to call repeatedly.
    func stop() {
        running = false
        setupComplete = false
        pendingOriginal = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .closed
    }

    var isReady: Bool { status == .ready && setupComplete }

    /// Sends a base64-encoded PCM audio chunk. Drops silently if not ready,
    /// mirroring translation-bridge.ts:580-586.
    ///
    /// Send-completion errors are logged but NOT surfaced via `onError`:
    /// the receive loop is the authority on connection death, and it
    /// silently schedules a reconnect (surfacing `onError` only on
    /// exhaustion). Firing `onError` per transient send failure would
    /// spam the user with error notifications the reconnect logic was
    /// designed to suppress.
    func sendAudio(base64PCM: String) {
        guard isReady else {
            if audioChunksSent == 0 {
                DebugLog.write("GeminiClient.sendAudio DROPPED (not ready, status=\(status), setupComplete=\(setupComplete))")
            }
            return
        }
        guard let task, task.closeCode == .invalid else { return }
        let message = GeminiProtocol.realtimeAudioMessage(base64PCM: base64PCM)
        guard let payload = try? GeminiProtocol.encodeJSON(message) else { return }
        audioChunksSent &+= 1
        if audioChunksSent % 20 == 1 {
            DebugLog.write("GeminiClient.sendAudio #\(audioChunksSent) (\(base64PCM.count) b64 chars)")
        }
        task.send(.string(payload)) { error in
            if let error {
                // Transient — the receive loop will detect the close and
                // trigger the silent-reconnect path. See method doc above.
                DebugLog.write("GeminiClient.sendAudio transient failure (will be picked up by receive loop): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Connect / reconnect

    private func openConnection() {
        guard running else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let url = components.url!

        DebugLog.write("GeminiClient.openConnection url=\(url.absoluteString.replacingOccurrences(of: apiKey, with: "<redacted:\(apiKey.count)chars>"))")
        let newTask = session.webSocketTask(with: url)
        self.task = newTask
        self.status = .connecting
        self.setupComplete = false
        self.pendingOriginal = nil
        newTask.resume()

        // Kick off the receive loop immediately; the setup message is sent
        // on first receive-open below. URLSessionWebSocketTask has no explicit
        // "open" callback, so we probe by attempting a receive.
        sendSetup()
        startSetupWatchdog()
        receiveLoop()
    }

    private func sendSetup() {
        guard let task else { return }
        guard let payload = try? GeminiProtocol.encodeJSON(
            GeminiProtocol.setupMessage(targetLanguage: targetLanguage, bilingual: bilingual)
        ) else { return }
        DebugLog.write("GeminiClient.sendSetup \(payload)")
        task.send(.string(payload)) { error in
            if let error {
                DebugLog.write("GeminiClient.sendSetup FAILED: \(error.localizedDescription)")
            } else {
                DebugLog.write("GeminiClient.sendSetup OK")
            }
        }
    }

    /// Mirrors the 15s setup timeout in translation-bridge.ts:258-264.
    private func startSetupWatchdog() {
        let deadline = DispatchTime.now() + setupTimeout
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.running, !self.setupComplete else { return }
            DebugLog.write("GeminiClient.setupWatchdog FIRED (no setupComplete after \(self.setupTimeout)s)")
            self.onError?(GeminiError.setupTimeout)
            self.task?.cancel(with: .policyViolation, reason: nil)
            // Trigger the reconnect path through didClose.
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            // The receive completion fires on a URLSession delegate queue,
            // not main. Every state mutation below (`setupComplete`,
            // `pendingOriginal`, `consecutiveReconnectFailures`, `status`,
            // `running`) must be confined to main to avoid racing with
            // `start`/`stop`/`openConnection` (which run on main). Chain
            // the next receive on main too — `task.receive` is async so the
            // actual wait still happens on the URLSession thread, not the
            // main run loop.
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    self.handleIncoming(message)
                    if self.running { self.receiveLoop() }
                case .failure(let error):
                    var closeInfo = ""
                    let mirror = Mirror(reflecting: task)
                    for child in mirror.children where child.label == "closeCode" {
                        closeInfo += " closeCode=\(child.value)"
                    }
                    DebugLog.write("GeminiClient.receiveLoop FAILURE: \(error.localizedDescription)\(closeInfo) (nsError=\(error as NSError))")
                    self.handleTransportError(error)
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:
            DebugLog.write("GeminiClient.handleIncoming unknown message type")
            return
        }
        DebugLog.write("GeminiClient.handleIncoming \(text.prefix(300))")
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLog.write("GeminiClient.handleIncoming could not parse JSON")
            return
        }

        if GeminiProtocol.isSetupComplete(json) {
            DebugLog.write("GeminiClient setupComplete received ✓")
            setupComplete = true
            consecutiveReconnectFailures = 0
            status = .ready
            return
        }

        if GeminiProtocol.isGoAway(json) {
            DebugLog.write("GeminiClient server sent goAway; will reconnect on close")
            // The subsequent close event will drive reconnect.
            return
        }

        if let event = GeminiProtocol.parseTranscription(from: json) {
            // Pair the buffered source-language transcript (if any) with this
            // translation frame, then clear it so the next input frame starts
            // fresh. This is what makes bilingual mode actually display the
            // original — input and output arrive as separate frames.
            // Gate on `bilingual`: the server can emit inputTranscription
            // frames even when not requested via setup, so the flag is the
            // authoritative guard for whether the original reaches the OSD.
            let original = bilingual ? pendingOriginal : nil
            pendingOriginal = nil
            onTranscription?(event.text, event.isFinal, original)
        } else if bilingual, let inputText = GeminiProtocol.parseInputTranscription(from: json) {
            // Input-only frame: stash for the next output frame. Overwrite
            // any prior pending text because Gemini emits growing fragments
            // and the latest one is the most complete for the current segment.
            pendingOriginal = inputText
        }
    }

    private func handleTransportError(_ error: Error) {
        // Translation-bridge.ts treats transport failures / abnormal closes as
        // silent: it just reconnects. Only surface onError on exhaustion (see
        // scheduleReconnectIfNeeded) so transient blips don't notify the user.
        DebugLog.write("GeminiClient.handleTransportError (silent reconnect path)")
        scheduleReconnectIfNeeded()
    }

    /// Translation-bridge.ts:272-326 reconnect. Called from the receive-failure
    /// path; only reconnects if `running` is true and we haven't exhausted
    /// attempts.
    private func scheduleReconnectIfNeeded() {
        guard running else {
            status = .closed
            return
        }
        consecutiveReconnectFailures += 1
        if consecutiveReconnectFailures > maxReconnectAttempts {
            DebugLog.write("GeminiClient RECONNECT EXHAUSTED (\(consecutiveReconnectFailures))")
            onError?(GeminiError.reconnectExhausted)
            running = false
            status = .closed
            return
        }
        DebugLog.write("GeminiClient reconnecting in \(reconnectDelay)s (attempt \(consecutiveReconnectFailures))")
        status = .connecting
        let when = DispatchTime.now() + reconnectDelay
        DispatchQueue.main.asyncAfter(deadline: when) { [weak self] in
            self?.openConnection()
        }
    }
}

// MARK: Errors

enum GeminiError: Error, LocalizedError {
    case setupTimeout
    case reconnectExhausted
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .setupTimeout: return "Gemini setup timed out"
        case .reconnectExhausted: return "Could not reconnect to Gemini after multiple attempts"
        case .unauthorized: return "Invalid Gemini API key"
        }
    }
}
