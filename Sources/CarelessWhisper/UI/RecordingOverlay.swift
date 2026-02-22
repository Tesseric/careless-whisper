import SwiftUI
import AppKit
import Combine
import os

// MARK: - Size-Observing NSHostingView

/// NSHostingView subclass that notifies when its SwiftUI content's intrinsic size changes.
private class SizeObservingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

/// Floating HUD shown during recording or when agent widgets are present — non-activating so it doesn't steal focus.
@MainActor
final class OverlayController {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "OverlayController")
    private var panel: NSPanel?
    private var hostingView: SizeObservingHostingView<AnyView>?
    private var dualColumnSubscription: AnyCancellable?

    private static let gitColumnWidth: CGFloat = 260
    private static let gapWidth: CGFloat = 12
    private static let widgetColumnWidth: CGFloat = 420
    static let dualWidth: CGFloat = gitColumnWidth + gapWidth + widgetColumnWidth  // 692
    static let singleWidth: CGFloat = widgetColumnWidth  // 420

    /// The intended panel width (not the mid-animation value).
    private var targetPanelWidth: CGFloat = singleWidth

    func show(appState: AppState) {
        // Idempotent: if panel already exists, SwiftUI reactivity handles content changes
        guard panel == nil else { return }

        let overlayView = AnyView(
            OverlayContentView()
                .environmentObject(appState)
        )
        let hosting = SizeObservingHostingView(rootView: overlayView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // Position: top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 210
            let y = screenFrame.maxY - 20 - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            logger.notice("Initial panel: x=\(x, format: .fixed(precision: 0)), y=\(y, format: .fixed(precision: 0)), screen=\(Int(screenFrame.width))x\(Int(screenFrame.height))")
        }

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting

        // Resize panel whenever SwiftUI content's intrinsic size changes
        hosting.onIntrinsicSizeInvalidated = { [weak self] in
            // Defer to next run loop so intrinsicContentSize is fully updated
            DispatchQueue.main.async {
                self?.resizePanelToFitContent()
            }
        }

        // Also do an initial resize after the first layout pass
        DispatchQueue.main.async { [weak self] in
            self?.resizePanelToFitContent()
        }

        logger.notice("Panel shown, intrinsicSize=\(Int(hosting.intrinsicContentSize.width))x\(Int(hosting.intrinsicContentSize.height))")

        // Detect dual-column transitions
        dualColumnSubscription = Publishers.CombineLatest3(
            appState.$recordingState,
            appState.$gitContext,
            appState.$agentWidgets
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] recordingState, gitContext, agentWidgets in
            self?.updateDualColumnState(
                appState: appState,
                recordingState: recordingState,
                gitContext: gitContext,
                agentWidgets: agentWidgets
            )
        }
    }

    func dismiss() {
        logger.notice("Dismissing overlay")
        hostingView?.onIntrinsicSizeInvalidated = nil
        hostingView = nil
        dualColumnSubscription?.cancel()
        dualColumnSubscription = nil
        panel?.close()
        panel = nil
    }

    private func updateDualColumnState(
        appState: AppState,
        recordingState: RecordingState,
        gitContext: GitContext?,
        agentWidgets: [AgentWidget]
    ) {
        let shouldDual = recordingState != .idle && gitContext != nil && !agentWidgets.isEmpty

        guard shouldDual != appState.overlayDualColumn else { return }

        logger.notice("Dual column: \(shouldDual), widgets=\(agentWidgets.count)")

        if shouldDual {
            if let panel, let screen = panel.screen ?? NSScreen.main {
                let panelCenter = panel.frame.midX
                let screenCenter = screen.visibleFrame.midX
                appState.gitContextSide = panelCenter <= screenCenter ? .trailing : .leading
            } else {
                appState.gitContextSide = .trailing
            }
        }

        appState.overlayDualColumn = shouldDual
        animatePanelWidth(dual: shouldDual, side: appState.gitContextSide)
    }

    private func animatePanelWidth(dual: Bool, side: Edge) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let newWidth: CGFloat = dual ? Self.dualWidth : Self.singleWidth
        let delta = newWidth - targetPanelWidth
        targetPanelWidth = newWidth

        logger.notice("Width change: \(Int(newWidth)), delta=\(Int(delta)), side=\(side == .leading ? "L" : "R")")

        var frame = panel.frame
        let oldTop = frame.maxY

        if side == .leading && delta != 0 {
            frame.origin.x -= delta
            frame.origin.x = max(screen.visibleFrame.minX, frame.origin.x)
        }

        frame.size.width = newWidth
        frame.origin.y = oldTop - frame.size.height

        frame.origin.x = max(screen.visibleFrame.minX, frame.origin.x)
        frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.size.width)

        panel.setFrame(frame, display: true, animate: false)
    }

    /// Resize the panel to fit the hosting view's intrinsic content size.
    private func resizePanelToFitContent() {
        guard let panel, let hostingView else { return }
        let intrinsic = hostingView.intrinsicContentSize
        guard intrinsic.height > 0, intrinsic.width > 0 else {
            logger.notice("resizePanelToFitContent skipped: intrinsic=\(Int(intrinsic.width))x\(Int(intrinsic.height))")
            return
        }

        let screen = panel.screen ?? NSScreen.main
        let maxHeight: CGFloat = (screen?.visibleFrame.height ?? 840) - 40

        var frame = panel.frame
        let oldTop = frame.maxY
        let newHeight = min(intrinsic.height, maxHeight)
        frame.size.height = newHeight
        frame.size.width = targetPanelWidth
        frame.origin.y = oldTop - newHeight

        if let sf = screen?.visibleFrame {
            frame.origin.x = max(sf.minX, frame.origin.x)
            frame.origin.x = min(frame.origin.x, sf.maxX - frame.size.width)
            frame.origin.y = max(sf.minY, frame.origin.y)
        }

        logger.notice("Resize: intrinsic=\(Int(intrinsic.width))x\(Int(intrinsic.height)), panel=\(Int(frame.width))x\(Int(frame.height)) at y=\(Int(frame.origin.y))")
        panel.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Window Drag Handle

/// An NSView that initiates a window drag on mouseDown. Used as a background layer
/// so the overlay is draggable from any area not covered by interactive content.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragHandleView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Overlay Content View

struct OverlayContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var webViewHeight: CGFloat = 60

    private var overlayWidth: CGFloat {
        appState.overlayDualColumn ? OverlayController.dualWidth : OverlayController.singleWidth
    }

    var body: some View {
        ZStack {
            // Background drag handle — enables dragging from any non-interactive area
            WindowDragHandle()

            VStack(alignment: .leading, spacing: 8) {
                if appState.recordingState != .idle {
                    RecordingStatusBar(
                        recordingState: appState.recordingState,
                        duration: appState.recordingDuration
                    )
                    .padding(.trailing, appState.agentWidgets.isEmpty ? 0 : 20)
                }

                if !appState.agentWidgets.isEmpty {
                    // Widgets present: use HStack so git column can slide in/out
                    HStack(alignment: .top, spacing: 12) {
                        if appState.overlayDualColumn && appState.gitContextSide == .leading {
                            gitColumnView
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        widgetView

                        if appState.overlayDualColumn && appState.gitContextSide == .trailing {
                            gitColumnView
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .clipped()
                } else if appState.gitContext != nil {
                    // No widgets, recording only: standalone git context
                    GitContextView(context: appState.gitContext!)
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
        }
        .frame(width: overlayWidth, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if !appState.agentWidgets.isEmpty {
                Button {
                    appState.clearAgentWidgets()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var gitColumnView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            GitContextView(context: appState.gitContext!)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    private var widgetView: some View {
        // Use base agentWidgets (without param overrides) so the HTML hash stays stable
        // for param-only changes. Param updates go through JS injection via widgetBridge,
        // avoiding a full loadHTMLString reload that would cause flicker and break CSS transitions.
        let composed = HTMLComposer.compose(widgets: appState.agentWidgets)
        WidgetWebView(html: composed, contentHeight: $webViewHeight, bridge: appState.widgetBridge)
            .frame(height: webViewHeight)
            .onChange(of: webViewHeight) { _, newHeight in
                appState.widgetContentHeight = newHeight
            }
    }
}

// MARK: - Recording Status Bar

struct RecordingStatusBar: View {
    let recordingState: RecordingState
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recordingState == .recording ? .red : .orange)
                .frame(width: 12, height: 12)
                .overlay {
                    if recordingState == .recording {
                        Circle()
                            .fill(.red.opacity(0.4))
                            .frame(width: 20, height: 20)
                            .modifier(PulseModifier())
                    }
                }

            Text(recordingState == .recording ? "Listening" : "Transcribing...")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            if recordingState == .recording {
                Text(formatDuration(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Git Context View

private struct GitContextView: View {
    let context: GitContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Repo / branch + ahead/behind
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

                if let ab = context.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
                    Spacer()
                    HStack(spacing: 4) {
                        if ab.ahead > 0 {
                            Text("↑\(ab.ahead)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.7))
                        }
                        if ab.behind > 0 {
                            Text("↓\(ab.behind)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange.opacity(0.7))
                        }
                    }
                }
            }

            // Last commit
            if let commit = context.lastCommit {
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(commit.relativeTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            // CI + PR status
            if context.ciStatus != nil || context.prInfo != nil {
                HStack(spacing: 8) {
                    if let ci = context.ciStatus {
                        CIBadgeView(ci: ci)
                    }
                    if let pr = context.prInfo {
                        PRBadgeView(pr: pr)
                    }
                }
            }

            // File sections
            if !context.stagedFiles.isEmpty || !context.unstagedFiles.isEmpty || !context.branchFiles.isEmpty {
                GitStatusView(staged: context.stagedFiles, unstaged: context.unstagedFiles, branch: context.branchFiles)
            }

            // Stash count
            if context.stashCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("\(context.stashCount) stash\(context.stashCount == 1 ? "" : "es")")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            // Diff previews
            ForEach(Array(context.diffPreviews.enumerated()), id: \.offset) { _, diff in
                DiffPreviewView(preview: diff)
            }
        }
    }
}

// MARK: - Git Status View

private struct GitStatusView: View {
    let staged: [GitFileChange]
    let unstaged: [GitFileChange]
    let branch: [GitFileChange]

    private let maxFiles = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !branch.isEmpty {
                fileSection("Branch", files: branch, dotColor: .blue)
            }
            if !staged.isEmpty {
                fileSection("Staged", files: staged, dotColor: .green)
            }
            if !unstaged.isEmpty {
                fileSection("Changes", files: unstaged, dotColor: .orange)
            }
        }
    }

    private func fileSection(_ title: String, files: [GitFileChange], dotColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text("\(title) · \(files.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            ForEach(Array(files.prefix(maxFiles).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 6) {
                    Text(file.type.letter)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.type))
                        .frame(width: 12, alignment: .center)

                    Text(file.displayName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 11)
            }

            if files.count > maxFiles {
                Text("+\(files.count - maxFiles) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 11)
            }
        }
    }

    private func statusColor(_ type: FileChangeType) -> Color {
        switch type {
        case .added:     return .green
        case .modified:  return .cyan
        case .deleted:   return .red
        case .renamed:   return .purple
        case .untracked: return Color.white.opacity(0.4)
        }
    }
}

// MARK: - CI Badge

private struct CIBadgeView: View {
    let ci: CIStatus

    var body: some View {
        HStack(spacing: 3) {
            Text(icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch ci.state {
        case .success:   return "✓"
        case .failure:   return "✗"
        case .pending:   return "◉"
        case .cancelled: return "⊘"
        case .unknown:   return "●"
        }
    }

    private var label: String {
        switch ci.state {
        case .success:   return "CI passing"
        case .failure:   return "CI failing"
        case .pending:   return "CI running"
        case .cancelled: return "CI cancelled"
        case .unknown:   return "CI"
        }
    }

    private var color: Color {
        switch ci.state {
        case .success:   return .green
        case .failure:   return .red
        case .pending:   return .yellow
        case .cancelled: return .gray
        case .unknown:   return .gray
        }
    }
}

// MARK: - PR Badge

private struct PRBadgeView: View {
    let pr: PRInfo

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 9))
                .foregroundStyle(.purple.opacity(0.7))
            Text("#\(pr.number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(pr.title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            if let label = reviewLabel {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(reviewColor)
            }
        }
    }

    private var reviewLabel: String? {
        switch pr.reviewDecision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review needed"
        default: return nil
        }
    }

    private var reviewColor: Color {
        switch pr.reviewDecision {
        case "APPROVED": return .green.opacity(0.7)
        case "CHANGES_REQUESTED": return .orange.opacity(0.7)
        default: return .white.opacity(0.5)
        }
    }
}

// MARK: - Diff Preview

private struct DiffPreviewView: View {
    let preview: DiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.fileName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))

            ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                let prefix = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                let color: Color = line.kind == .added ? .green.opacity(0.7) : line.kind == .removed ? .red.opacity(0.7) : .white.opacity(0.35)
                Text("\(prefix) \(line.text)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pulse Animation

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
