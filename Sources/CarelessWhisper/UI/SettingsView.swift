import SwiftUI
import ServiceManagement
import HotKey
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("selectedModel") private var selectedModel: String = WhisperModel.baseEn.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("completionSound") private var completionSound = true
    @State private var isRecordingHotkey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hotkeySection
                modelSection
                audioSection
                optionsSection
                permissionsSection
            }
            .padding(20)
        }
        .frame(width: 420, height: 480)
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Push-to-Talk Hotkey", systemImage: "keyboard")
                .font(.headline)

            Text("Hold to record, release to transcribe")
                .font(.caption)
                .foregroundStyle(.secondary)

            HotKeyRecorderView(
                keyCombo: appState.hotKeyManager.keyCombo,
                isRecording: $isRecordingHotkey
            ) { newCombo in
                applyKeyCombo(newCombo)
            }

            Text("Presets:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 8) {
                ForEach(HotKeyPreset.allCases) { preset in
                    Button(preset.label) {
                        applyPreset(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Whisper Model", systemImage: "brain")
                .font(.headline)

            ForEach(WhisperModel.allCases) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                        Text(model.sizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.modelManager.isModelDownloaded(model) {
                        if model.rawValue == selectedModel {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Select") {
                                selectedModel = model.rawValue
                                Task { await appState.loadModel() }
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button("Download") {
                            selectedModel = model.rawValue
                            Task { await appState.loadModel() }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Device", systemImage: "waveform")
                .font(.headline)

            let devices = appState.audioCaptureService.availableInputDevices()
            if devices.isEmpty {
                Text("No input devices found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { appState.audioCaptureService.selectedDeviceID ?? 0 },
                    set: { appState.audioCaptureService.selectedDeviceID = $0 == 0 ? nil : $0 }
                )) {
                    Text("System Default").tag(UInt32(0))
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Options", systemImage: "gear")
                .font(.headline)

            Toggle("Play sound on completion", isOn: $completionSound)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        appState.errorMessage = "Failed to update login item: \(error.localizedDescription)"
                    }
                }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permissions", systemImage: "lock.shield")
                .font(.headline)

            HStack {
                Image(systemName: "mic.fill").frame(width: 20)
                Text("Microphone")
                Spacer()
                Image(systemName: appState.permissionChecker.hasMicrophonePermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(appState.permissionChecker.hasMicrophonePermission ? .green : .red)
            }

            HStack {
                Image(systemName: "accessibility").frame(width: 20)
                Text("Accessibility")
                Spacer()
                Image(systemName: appState.permissionChecker.hasAccessibilityPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(appState.permissionChecker.hasAccessibilityPermission ? .green : .red)
            }

            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
            .controlSize(.small)
        }
    }

    private func applyPreset(_ preset: HotKeyPreset) {
        applyKeyCombo(preset.keyCombo)
    }

    private func applyKeyCombo(_ combo: KeyCombo) {
        appState.hotKeyManager.keyCombo = combo
        appState.hotKeyManager.register()
        appState.updateHotkeyDescription()
        UserDefaults.standard.set(Int(combo.carbonKeyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(Int(combo.carbonModifiers), forKey: "hotkeyModifiers")
    }
}

// MARK: - Hotkey Presets

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionGrave
    case f5
    case ctrlShiftSpace
    case f19

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionGrave: return "Option+`"
        case .f5: return "F5"
        case .ctrlShiftSpace: return "Ctrl+Shift+Space"
        case .f19: return "F19"
        }
    }

    var keyCombo: KeyCombo {
        switch self {
        case .optionGrave: return KeyCombo(key: .grave, modifiers: [.option])
        case .f5: return KeyCombo(key: .f5, modifiers: [])
        case .ctrlShiftSpace: return KeyCombo(key: .space, modifiers: [.control, .shift])
        case .f19: return KeyCombo(key: .f19, modifiers: [])
        }
    }
}

// MARK: - Hotkey Recorder

struct HotKeyRecorderView: NSViewRepresentable {
    let keyCombo: KeyCombo
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.keyCombo = keyCombo
        view.onRecord = onRecord
        view.isRecordingBinding = $isRecording
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderNSView, context: Context) {
        if !isRecording {
            nsView.keyCombo = keyCombo
            nsView.updateDisplay()
        }
    }
}

final class HotKeyRecorderNSView: NSView {
    var keyCombo: KeyCombo = KeyCombo(key: .grave, modifiers: [.option])
    var onRecord: ((KeyCombo) -> Void)?
    var isRecordingBinding: Binding<Bool>?

    private let label = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private var localMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recordButton.title = "Record"
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)

        let stack = NSStackView(views: [label, recordButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        updateDisplay()
    }

    func updateDisplay() {
        label.stringValue = describeKeyCombo(keyCombo)
    }

    @objc private func toggleRecording() {
        if localMonitor != nil {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recordButton.title = "Press keys..."
        label.stringValue = "Waiting..."
        isRecordingBinding?.wrappedValue = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if let key = Key(carbonKeyCode: UInt32(event.keyCode)) {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let keyCombo = KeyCombo(key: key, modifiers: flags)
                self.keyCombo = keyCombo
                self.onRecord?(keyCombo)
                self.stopRecording()
            }

            return nil // Swallow the event
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        recordButton.title = "Record"
        isRecordingBinding?.wrappedValue = false
        updateDisplay()
    }

    private func describeKeyCombo(_ combo: KeyCombo) -> String {
        var parts: [String] = []

        let mods = combo.modifiers
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.option) { parts.append("Option") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.command) { parts.append("Cmd") }

        parts.append(combo.key?.description ?? "?")

        return parts.joined(separator: " + ")
    }
}
