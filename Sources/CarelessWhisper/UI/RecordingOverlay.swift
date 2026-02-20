import SwiftUI
import AppKit

/// Floating HUD shown during recording — non-activating so it doesn't steal focus.
@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?

    func show(appState: AppState) {
        guard panel == nil else { return }

        let overlayView = RecordingOverlayView()
            .environmentObject(appState)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 60)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position: top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 160
            let y = screenFrame.maxY - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

struct RecordingOverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(appState.recordingState == .recording ? .red : .orange)
                    .frame(width: 12, height: 12)
                    .overlay {
                        if appState.recordingState == .recording {
                            Circle()
                                .fill(.red.opacity(0.4))
                                .frame(width: 20, height: 20)
                                .modifier(PulseModifier())
                        }
                    }

                Text(appState.recordingState == .recording ? "Recording" : "Transcribing...")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if appState.recordingState == .recording {
                    Text(formatDuration(appState.recordingDuration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if let context = appState.gitContext {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))

                    Text(context.repoName)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    Text("/")
                        .foregroundStyle(.white.opacity(0.4))

                    Text(context.branch)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            if appState.recordingState == .recording, !appState.liveTranscription.isEmpty {
                Text(appState.liveTranscription)
                    .font(.system(.caption))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.0 : 0.6)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
