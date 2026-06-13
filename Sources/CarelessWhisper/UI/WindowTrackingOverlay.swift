import SwiftUI
import AppKit
import ApplicationServices
import Combine
import os

/// Pure coordinate math for positioning the overlay relative to a terminal window.
/// Separated out so it can be unit-tested without AppKit/AX.
enum WindowFramePositioning {
    /// Converts an AX window frame (top-left origin, y-down, global coords) to the Cocoa
    /// (bottom-left origin) coordinate of the window's TOP-RIGHT corner.
    static func windowTopRightInCocoa(axOrigin: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: axOrigin.x + axSize.width,
                y: primaryScreenHeight - axOrigin.y)
    }

    /// Bottom-left origin for a panel of `panelSize` pinned `inset` points inside the window's
    /// top-right corner.
    static func panelOrigin(windowTopRightCocoa: CGPoint, panelSize: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(x: windowTopRightCocoa.x - inset - panelSize.width,
                y: windowTopRightCocoa.y - inset - panelSize.height)
    }
}

/// Floating panel that pins the persistent git overlay to the focused terminal window's
/// upper-right corner. Reuses `SizeObservingHostingView` for content-driven sizing.
@MainActor
final class WindowTrackingOverlayController {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "GitOverlay")
    private var panel: NSPanel?
    private var hostingView: SizeObservingHostingView<AnyView>?
    private weak var appState: AppState?

    private static let inset: CGFloat = 8

    func show(appState: AppState) {
        self.appState = appState
        guard panel == nil else { return }

        let content = AnyView(PersistentGitOverlayView().environmentObject(appState))
        let hosting = SizeObservingHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
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

        hosting.onIntrinsicSizeInvalidated = { [weak self] in
            DispatchQueue.main.async { self?.reposition() }
        }

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
        DispatchQueue.main.async { [weak self] in self?.reposition() }
        logger.notice("Persistent git overlay shown")
    }

    func dismiss() {
        hostingView?.onIntrinsicSizeInvalidated = nil
        hostingView = nil
        panel?.close()
        panel = nil
        logger.notice("Persistent git overlay dismissed")
    }

    var isVisible: Bool { panel != nil }

    /// Repositions the panel to the focused terminal window's upper-right corner.
    /// Falls back to the screen's upper-right when no AX frame is available.
    func reposition() {
        guard let panel, let hostingView else { return }
        let size = hostingView.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }

        if let pid = appState?.lastPolledTerminalPIDForOverlay,
           let frame = focusedWindowAXFrame(pid: pid),
           let primaryHeight = NSScreen.screens.first?.frame.height {
            let topRight = WindowFramePositioning.windowTopRightInCocoa(
                axOrigin: frame.origin, axSize: frame.size, primaryScreenHeight: primaryHeight)
            let origin = WindowFramePositioning.panelOrigin(
                windowTopRightCocoa: topRight, panelSize: size, inset: Self.inset)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let origin = CGPoint(x: vf.maxX - Self.inset - size.width,
                                 y: vf.maxY - Self.inset - size.height)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    /// Reads the focused window's frame (AX coords) for the given app PID.
    private func focusedWindowAXFrame(pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let windowElement = window as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// SwiftUI content for the persistent overlay: pill when collapsed, expanded view otherwise.
private struct PersistentGitOverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let context = appState.gitContext {
            if appState.gitOverlayExpanded {
                GitOverlayExpandedView(
                    context: context,
                    scope: appState.gitOverlayDiffScope,
                    annotation: appState.gitOverlayAnnotation,
                    onToggleScope: { appState.gitOverlayDiffScope = $0 },
                    onCollapse: { appState.gitOverlayExpanded = false },
                    onClose: { appState.persistentGitOverlayEnabled = false }
                )
            } else {
                DiffStatPill(
                    branch: context.branch,
                    scope: pillScope(context),
                    onTap: { appState.gitOverlayExpanded = true }
                )
            }
        } else {
            EmptyView()
        }
    }

    private func pillScope(_ context: GitContext) -> DiffStatScope {
        guard let stats = context.diffStats else { return DiffStatScope() }
        switch appState.gitOverlayDiffScope {
        case .working: return stats.working
        case .branch:  return stats.branch ?? stats.working
        }
    }
}
