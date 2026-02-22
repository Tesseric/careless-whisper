import AppKit
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.carelesswhisper", category: "StatusBarController")

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    // Menu items we need to update dynamically
    private var statusMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var lastTranscriptionMenuItem: NSMenuItem?
    private var copyTranscriptionMenuItem: NSMenuItem?

    func setup(appState: AppState) {
        self.appState = appState

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Careless Whisper")
        }

        let menu = NSMenu()
        menu.delegate = self

        // Status line
        let statusItem2 = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        statusItem2.isEnabled = false
        menu.addItem(statusItem2)
        self.statusMenuItem = statusItem2

        // Last transcription
        let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        lastItem.isHidden = true
        menu.addItem(lastItem)
        self.lastTranscriptionMenuItem = lastItem

        // Copy Last Transcription
        let copyItem = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscription), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isHidden = true
        menu.addItem(copyItem)
        self.copyTranscriptionMenuItem = copyItem

        menu.addItem(.separator())

        // Record toggle
        let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordItem.target = self
        menu.addItem(recordItem)
        self.recordMenuItem = recordItem

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Report Issue
        let reportItem = NSMenuItem(title: "Report Issue...", action: #selector(reportIssue), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        // About
        let aboutItem = NSMenuItem(title: "About Careless Whisper", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Careless Whisper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem

        // Observe state changes
        appState.$recordingState.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateMenu()
        }.store(in: &cancellables)

        appState.$lastTranscription.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateMenu()
        }.store(in: &cancellables)

        appState.$isModelLoaded.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateMenu()
        }.store(in: &cancellables)

        appState.$modelDownloadProgress.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateMenu()
        }.store(in: &cancellables)
    }

    func updateIcon(_ iconName: String) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "Careless Whisper"
        )
    }

    private func updateMenu() {
        guard let appState else { return }

        // Update icon
        updateIcon(appState.menuBarIcon)

        // Status line
        switch appState.recordingState {
        case .idle:
            if let progress = appState.modelDownloadProgress {
                let label = appState.downloadLabel ?? "Downloading..."
                statusMenuItem?.title = "\(label) \(Int(progress * 100))%"
            } else if appState.isModelLoaded {
                statusMenuItem?.title = "Ready — hold \(appState.hotkeyDescription) to record"
            } else {
                statusMenuItem?.title = "Loading model..."
            }
        case .recording:
            let secs = Int(appState.recordingDuration)
            statusMenuItem?.title = "Recording... \(secs / 60):\(String(format: "%02d", secs % 60))"
        case .transcribing:
            statusMenuItem?.title = "Transcribing..."
        }

        // Record button
        switch appState.recordingState {
        case .idle:
            recordMenuItem?.title = "Start Recording"
            recordMenuItem?.isEnabled = appState.isModelLoaded
        case .recording:
            recordMenuItem?.title = "Stop Recording"
            recordMenuItem?.isEnabled = true
        case .transcribing:
            recordMenuItem?.title = "Transcribing..."
            recordMenuItem?.isEnabled = false
        }

        // Last transcription
        if appState.lastTranscription.isEmpty {
            lastTranscriptionMenuItem?.isHidden = true
            copyTranscriptionMenuItem?.isHidden = true
        } else {
            lastTranscriptionMenuItem?.isHidden = false
            copyTranscriptionMenuItem?.isHidden = false
            let text = appState.lastTranscription
            let truncated = text.count > 60 ? String(text.prefix(60)) + "..." : text
            lastTranscriptionMenuItem?.title = truncated
        }
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        guard let appState else { return }
        if appState.recordingState == .idle {
            appState.startRecording()
        } else if appState.recordingState == .recording {
            appState.stopRecordingAndTranscribe()
        }
    }

    @objc private func openSettings() {
        guard let appState else { return }
        logger.info("Opening settings")
        appState.openSettings()
    }

    @objc private func copyLastTranscription() {
        guard let appState, !appState.lastTranscription.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.lastTranscription, forType: .string)
    }

    @objc private func reportIssue() {
        if let url = URL(string: "https://github.com/Tesseric/careless-whisper/issues/new/choose") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "100% local voice-to-text for macOS\nhttps://github.com/Tesseric/careless-whisper",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            updateMenu()
        }
    }
}
