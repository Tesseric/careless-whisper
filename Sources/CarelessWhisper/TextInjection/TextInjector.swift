import Foundation
import AppKit
import os

protocol TextInjector {
    func injectText(_ text: String, pressEnter: Bool) async throws
}

@MainActor
final class TextInjectorCoordinator {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "TextInjector")
    private let kittyIPC = KittyIPC()
    private let clipboardPaster = ClipboardPaster()

    static let kittyBundleID = "net.kovidgoyal.kitty"

    /// Captures the frontmost app's bundle ID before recording starts.
    func captureFrontmostApp() -> String? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        logger.info("Captured frontmost app: \(bundleID ?? "unknown", privacy: .public)")
        return bundleID
    }

    func injectText(_ text: String, targetBundleID: String?, pressEnter: Bool = false) async {
        if targetBundleID == Self.kittyBundleID {
            do {
                try await kittyIPC.injectText(text, pressEnter: pressEnter)
                logger.info("Text injected via Kitty IPC")
                return
            } catch {
                logger.warning("Kitty IPC failed, falling back to clipboard: \(error, privacy: .public)")
            }
        }

        do {
            try await clipboardPaster.injectText(text, pressEnter: pressEnter)
            logger.info("Text injected via clipboard+paste")
        } catch {
            logger.error("Clipboard paste failed: \(error, privacy: .public)")
        }
    }
}
