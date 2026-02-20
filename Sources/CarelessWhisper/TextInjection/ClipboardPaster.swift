import AppKit
import Carbon.HIToolbox
import os

final class ClipboardPaster: TextInjector {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "ClipboardPaster")

    /// Delay before restoring clipboard contents (milliseconds)
    private let restoreDelay: UInt64 = 500_000_000 // 500ms in nanoseconds

    func injectText(_ text: String, pressEnter: Bool) async throws {
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

        if pressEnter {
            // Small delay before pressing Enter
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            simulateReturnKey()
        }

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

    private func simulateReturnKey() {
        // Use .privateState so we don't pick up lingering modifier keys
        // from the hotkey that triggered transcription (e.g. ctrl+shift
        // would turn Enter into ctrl+shift+enter → new pane in Kitty).
        let source = CGEventSource(stateID: .privateState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            logger.error("Failed to create CGEvent for Return key")
            return
        }

        keyDown.flags = []
        keyUp.flags = []

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
