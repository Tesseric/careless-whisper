import AppKit
import Carbon.HIToolbox
import os

final class ClipboardPaster: TextInjector {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "ClipboardPaster")

    /// Delay before restoring clipboard contents (milliseconds)
    private let restoreDelay: UInt64 = 500_000_000 // 500ms in nanoseconds

    func injectText(_ text: String) async throws {
        logger.info("ClipboardPaster: injecting text, length=\(text.count)")
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedContents = saveClipboard(pasteboard)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+V
        logger.info("ClipboardPaster: simulating Cmd+V paste")
        simulatePaste()

        // Restore clipboard after delay
        try await Task.sleep(nanoseconds: restoreDelay)
        restoreClipboard(pasteboard, contents: savedContents)
        logger.info("ClipboardPaster: clipboard restored")
    }

    private func simulatePaste() {
        // Key down: Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func saveClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        var saved: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }
        return saved
    }

    private func restoreClipboard(_ pasteboard: NSPasteboard, contents: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !contents.isEmpty {
            pasteboard.writeObjects(contents)
        }
    }
}
