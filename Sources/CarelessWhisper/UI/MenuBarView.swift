import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            statusSection

            Divider()

            // Last transcription
            if !appState.lastTranscription.isEmpty {
                lastTranscriptionSection
                Divider()
            }

            // Model download progress
            if let progress = appState.modelDownloadProgress {
                downloadProgressSection(progress: progress)
                Divider()
            }

            // Error message
            if let error = appState.errorMessage {
                errorSection(error: error)
                Divider()
            }

            // Recent transcriptions
            if !appState.recentTranscriptions.isEmpty {
                recentSection
                Divider()
            }

            // Actions
            actionsSection
        }
        .padding(12)
        .frame(width: 320)
    }

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.headline)

            Spacer()

            if appState.recordingState == .recording {
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last transcription")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.lastTranscription)
                .font(.body)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func downloadProgressSection(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.downloadLabel ?? "Downloading...")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: progress)

            Text("\(Int(progress * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func errorSection(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(appState.recentTranscriptions.prefix(5).enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 4) {
            Button {
                if appState.recordingState == .idle {
                    appState.startRecording()
                } else if appState.recordingState == .recording {
                    appState.stopRecordingAndTranscribe()
                }
            } label: {
                Label(
                    appState.recordingState == .recording ? "Stop Recording" : "Start Recording",
                    systemImage: appState.recordingState == .recording ? "stop.fill" : "mic.fill"
                )
            }
            .disabled(appState.recordingState == .transcribing || !appState.isModelLoaded)

            Divider()

            Button("Settings...") {
                appState.openSettings()
            }

            Button("Quit Careless Whisper") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: return appState.isModelLoaded ? .green : .yellow
        case .recording: return .red
        case .transcribing: return .orange
        }
    }

    private var statusText: String {
        switch appState.recordingState {
        case .idle:
            if appState.modelDownloadProgress != nil { return appState.downloadLabel ?? "Downloading..." }
            return appState.isModelLoaded ? "Ready" : "Loading model..."
        case .recording: return "Listening"
        case .transcribing: return "Transcribing..."
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
