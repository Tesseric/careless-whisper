import SwiftUI
import AppKit
import os

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
}

@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "AppState")

    @Published var recordingState: RecordingState = .idle
    @Published var lastTranscription: String = ""
    @Published var recentTranscriptions: [String] = []
    @Published var errorMessage: String?
    @Published var modelDownloadProgress: Double?
    @Published var downloadLabel: String?
    @Published var isModelLoaded = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasCompletedOnboarding = false
    @Published var hotkeyDescription: String = ""
    @Published var liveTranscription: String = ""
    @Published var gitContext: GitContext?
    @Published var agentWidgets: [AgentWidget] = []
    @Published var overlayServerPort: UInt16 = 0
    @Published var widgetContentHeight: CGFloat = 0

    let audioCaptureService = AudioCaptureService()
    let whisperService = WhisperService()
    let modelManager = ModelManager()
    let hotKeyManager = HotKeyManager()
    let textInjector = TextInjectorCoordinator()
    let permissionChecker = PermissionChecker()
    private let overlayController = OverlayController()
    let overlayServer = OverlayServer()
    let settingsWindowController = SettingsWindowController()

    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var targetBundleID: String?
    private var pendingChunks: [[Float]] = []
    private var isProcessingChunk = false

    @AppStorage("selectedModel") var selectedModelRaw: String = WhisperModel.baseEn.rawValue
    @AppStorage("completionSound") var completionSoundEnabled: Bool = true
    @AppStorage("selectedInputDevice") var selectedInputDeviceID: Int = 0
    @AppStorage("autoEnter") var autoEnter: Bool = false
    @AppStorage("agentOverlayEnabled") var agentOverlayEnabled: Bool = false

    var selectedModel: WhisperModel {
        WhisperModel(rawValue: selectedModelRaw) ?? .baseEn
    }

    var shouldShowOverlay: Bool {
        recordingState != .idle || !agentWidgets.isEmpty
    }

    var menuBarIcon: String {
        switch recordingState {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "ellipsis.circle"
        }
    }

    init() {
        updateHotkeyDescription()

        hotKeyManager.onPushToTalkStarted = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotKeyManager.onPushToTalkEnded = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }
    }

    func updateHotkeyDescription() {
        let combo = hotKeyManager.keyCombo
        var parts: [String] = []
        let mods = combo.modifiers
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.option) { parts.append("Option") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.command) { parts.append("Cmd") }
        parts.append(combo.key?.description ?? "?")
        hotkeyDescription = parts.joined(separator: "+")
    }

    func setup() async {
        logger.info("Setting up CarelessWhisper")

        if !permissionChecker.hasMicrophonePermission {
            let granted = await permissionChecker.requestMicrophonePermission()
            if !granted {
                errorMessage = "Microphone permission is required for voice transcription."
                return
            }
        }

        permissionChecker.checkAccessibilityPermission()

        await loadModel()
        hotKeyManager.register()

        // Restore persisted audio input device
        if selectedInputDeviceID != 0 {
            audioCaptureService.selectedDeviceID = UInt32(selectedInputDeviceID)
        }

        hasCompletedOnboarding = true
    }

    func openSettings() {
        logger.info("Opening settings window")
        settingsWindowController.open(appState: self)
    }

    // MARK: - Agent Overlay Lifecycle

    func enableAgentOverlay() {
        agentOverlayEnabled = true
        startOverlayServer()
        AgentSkillInstaller.install()
    }

    func disableAgentOverlay() {
        agentOverlayEnabled = false
        overlayServer.stop()
        overlayServerPort = 0
        clearAgentWidgets()
        AgentSkillInstaller.uninstall()
    }

    func startOverlayServer() {
        guard !overlayServer.isRunning else { return }
        overlayServer.onSetWidgets = { [weak self] widgets in
            self?.setAgentWidgets(widgets)
        }
        overlayServer.onUpsertWidget = { [weak self] widget in
            self?.upsertAgentWidget(widget)
        }
        overlayServer.onRemoveWidget = { [weak self] id in
            self?.removeAgentWidget(id: id)
        }
        overlayServer.onClearWidgets = { [weak self] in
            self?.clearAgentWidgets()
        }
        overlayServer.getWidgetCount = { [weak self] in
            self?.agentWidgets.count ?? 0
        }
        overlayServer.getOverlayVisible = { [weak self] in
            self?.shouldShowOverlay ?? false
        }
        overlayServer.onReady = { [weak self] port in
            self?.overlayServerPort = port
        }
        overlayServer.start()
    }

    // MARK: - Agent Widget CRUD

    func setAgentWidgets(_ widgets: [AgentWidget]) {
        agentWidgets = widgets
        updateOverlayVisibility()
    }

    func upsertAgentWidget(_ widget: AgentWidget) {
        if let index = agentWidgets.firstIndex(where: { $0.id == widget.id }) {
            agentWidgets[index] = widget
        } else {
            agentWidgets.append(widget)
        }
        updateOverlayVisibility()
    }

    func removeAgentWidget(id: String) {
        agentWidgets.removeAll { $0.id == id }
        updateOverlayVisibility()
    }

    func clearAgentWidgets() {
        agentWidgets.removeAll()
        updateOverlayVisibility()
    }

    // MARK: - Overlay Lifecycle

    func updateOverlayVisibility() {
        if shouldShowOverlay {
            overlayController.show(appState: self)
        } else {
            overlayController.dismiss()
        }
    }

    func loadModel() async {
        let model = selectedModel
        isModelLoaded = false

        // Download GGML model if needed
        if !modelManager.isModelDownloaded(model) {
            logger.info("Downloading model: \(model.name)")
            downloadLabel = "Downloading \(model.name)..."
            modelDownloadProgress = 0

            do {
                try await modelManager.downloadModel(model) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelDownloadProgress = progress
                    }
                }
            } catch {
                logger.error("Failed to download model: \(error)")
                errorMessage = "Failed to download model: \(error.localizedDescription)"
                modelDownloadProgress = nil
                downloadLabel = nil
                return
            }
        }

        // Download CoreML encoder if needed
        if !modelManager.isCoreMLModelDownloaded(model) {
            logger.info("Downloading CoreML encoder for: \(model.name)")
            downloadLabel = "Downloading CoreML encoder..."
            modelDownloadProgress = 0

            do {
                try await modelManager.downloadCoreMLModel(model) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelDownloadProgress = progress
                    }
                }
            } catch {
                // CoreML is optional — log warning but continue with CPU
                logger.warning("Failed to download CoreML encoder (will use CPU): \(error)")
            }
        }

        modelDownloadProgress = nil
        downloadLabel = nil

        do {
            let modelPath = modelManager.modelPath(for: model)
            try whisperService.loadModel(path: modelPath)
            isModelLoaded = true
            logger.info("Model loaded successfully")
        } catch {
            logger.error("Failed to load model: \(error)")
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    func startRecording() {
        guard recordingState == .idle, isModelLoaded else { return }

        logger.info("Starting recording")
        targetBundleID = textInjector.captureFrontmostApp()

        // Detect git context asynchronously if the frontmost app is a terminal
        gitContext = nil
        if GitContextService.isTerminal(bundleID: targetBundleID),
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Task {
                let context = await GitContextService.detect(terminalPID: pid)
                if self.recordingState != .idle {
                    self.gitContext = context
                }
            }
        }

        do {
            audioCaptureService.onSpeechChunkReady = { [weak self] chunk in
                Task { @MainActor in
                    self?.handleSpeechChunk(chunk)
                }
            }
            try audioCaptureService.startCapture()
            recordingState = .recording
            recordingStartTime = Date()
            recordingDuration = 0
            liveTranscription = ""
            pendingChunks = []
            isProcessingChunk = false
            updateOverlayVisibility()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartTime else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                    if self.recordingDuration > 60 {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            logger.error("Failed to start recording: \(error)")
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func handleSpeechChunk(_ samples: [Float]) {
        pendingChunks.append(samples)
        processNextChunk()
    }

    private func processNextChunk() {
        guard !isProcessingChunk, !pendingChunks.isEmpty, recordingState == .recording else { return }
        isProcessingChunk = true
        let chunk = pendingChunks.removeFirst()

        Task {
            do {
                let text = try await whisperService.transcribe(samples: chunk)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !Self.isNonSpeechHallucination(trimmed) {
                    if liveTranscription.isEmpty {
                        liveTranscription = trimmed
                    } else {
                        liveTranscription += " " + trimmed
                    }
                }
            } catch {
                logger.warning("Chunk transcription failed: \(error)")
            }
            isProcessingChunk = false
            processNextChunk()
        }
    }

    func stopRecordingAndTranscribe() {
        guard recordingState == .recording else { return }

        audioCaptureService.onSpeechChunkReady = nil
        recordingTimer?.invalidate()
        recordingTimer = nil

        let duration = recordingDuration
        logger.info("Stopping recording after \(duration, format: .fixed(precision: 1))s")

        let samples = audioCaptureService.stopCapture()
        let remainingChunk = audioCaptureService.flushRemainingChunk()

        if duration < 0.3 || samples.isEmpty {
            logger.info("Recording too short, discarding")
            recordingState = .idle
            updateOverlayVisibility()
            return
        }

        // Gather any unprocessed chunks + remaining audio after last pause
        var finalChunkSamples: [Float] = []
        for chunk in pendingChunks {
            finalChunkSamples.append(contentsOf: chunk)
        }
        pendingChunks.removeAll()
        finalChunkSamples.append(contentsOf: remainingChunk)

        recordingState = .transcribing

        Task {
            // Wait for any in-flight chunk transcription to finish
            while isProcessingChunk {
                try? await Task.sleep(for: .milliseconds(50))
            }

            // Transcribe any remaining audio after the last pause boundary
            if finalChunkSamples.count > Int(AudioCaptureService.targetSampleRate * 0.3) {
                do {
                    let text = try await whisperService.transcribe(samples: finalChunkSamples)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !Self.isNonSpeechHallucination(trimmed) {
                        if liveTranscription.isEmpty {
                            liveTranscription = trimmed
                        } else {
                            liveTranscription += " " + trimmed
                        }
                    }
                } catch {
                    logger.warning("Final chunk transcription failed: \(error)")
                }
            }

            let finalText = liveTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !finalText.isEmpty else {
                logger.info("Empty transcription result")
                recordingState = .idle
                updateOverlayVisibility()
                return
            }

            lastTranscription = finalText
            recentTranscriptions.insert(finalText, at: 0)
            if recentTranscriptions.count > 20 {
                recentTranscriptions.removeLast()
            }

            logger.info("Transcription: \(finalText)")

            recordingState = .idle
            updateOverlayVisibility()

            let bundleID = targetBundleID
            await textInjector.injectText(finalText, targetBundleID: bundleID, pressEnter: autoEnter)

            if completionSoundEnabled {
                NSSound.tink?.play()
            }
        }
    }

    /// Whisper hallucinates non-speech content in various forms: bracketed/parenthesized/
    /// asterisk-wrapped sound descriptions (e.g., "[wind]", "(music)", "*sighs*"), music
    /// note symbols, bare ambient sound words, and repetitive filler phrases. Filter all
    /// of these so we only inject actual spoken words.
    nonisolated static func isNonSpeechHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Structural: entire text wrapped in brackets, parens, or asterisks
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
            (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) ||
            (trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && trimmed.count > 1) {
            return true
        }

        // Music note symbols
        if trimmed.contains("♪") || trimmed.contains("🎵") || trimmed.contains("🎶") {
            return true
        }

        // Strip brackets/parens/asterisks and punctuation, then exact-match
        let stripped = trimmed.lowercased()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        return nonSpeechMarkers.contains(stripped)
    }

    private nonisolated static let nonSpeechMarkers: Set<String> = [
        // Silence / blank
        "silence", "blank audio", "blank_audio", "no speech", "no audio",
        "inaudible",
        // Environmental sounds
        "noise", "background noise", "static", "white noise",
        "wind", "wind blowing", "wind howling", "wind noise",
        "thunder", "rain", "rain falling", "rain sounds",
        "water", "water running", "water dripping", "water flowing",
        "birds", "birds chirping", "birds singing", "bird sounds",
        "dog barking", "dogs barking",
        "crickets", "insects",
        // Human non-speech sounds
        "breathing", "heavy breathing", "deep breathing",
        "footsteps", "typing", "clicking", "tapping",
        "coughing", "cough", "snoring", "snore",
        "sigh", "sighs", "sighing",
        "laugh", "laughs", "laughing", "laughter",
        "gasp", "gasps", "gasping",
        "groan", "groans", "groaning",
        "yawn", "yawns", "yawning",
        "sneeze", "sneezes", "sneezing",
        "clears throat", "throat clearing",
        "applause", "clapping",
        // Music descriptions
        "music", "music playing", "background music",
        "eerie music", "soft music", "dramatic music", "upbeat music",
        "piano music", "sad music", "intense music", "suspenseful music",
        "ominous music", "cheerful music", "gentle music", "classical music",
        "haunting music", "somber music", "tense music", "light music",
        // Mechanical / urban sounds
        "phone ringing", "bell ringing", "bell",
        "door closing", "door opening", "door slam",
        "engine", "engine running", "car horn", "siren",
        "beep", "beeping", "buzzing", "buzz", "humming", "hum",
        "whistling", "whistle",
        // Crowd / chatter
        "crowd noise", "crowd cheering", "crowd",
        "chatter", "indistinct chatter", "indistinct talking",
        "chanting",
        // Common Whisper silence hallucinations (repetitive filler)
        "thank you", "thanks for watching", "thanks for listening",
        "subscribe", "like and subscribe",
    ]
}

extension NSSound {
    static let tink = NSSound(named: "Tink")
}
