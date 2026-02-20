import AppKit
import Carbon.HIToolbox
import os

/// Injects text into the focused UI element using the macOS Accessibility API.
///
/// This avoids clipboard manipulation by directly setting the value of the
/// focused text field via `AXUIElementSetAttributeValue`. Falls back with a
/// thrown error so the coordinator can try the clipboard path.
final class AccessibilityInjector: TextInjector {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "AccessibilityInjector")

    /// Roles whose `AXValue` attribute is a settable string.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        "AXSearchField",
    ]

    func injectText(_ text: String, pressEnter: Bool) async throws {
        let element = try focusedTextElement()

        // Read existing value so we can append at the insertion point.
        let existingValue = try? currentValue(of: element)
        let insertionLocation = try? insertionPointLocation(of: element)

        let newValue: String
        if let existing = existingValue, let location = insertionLocation {
            let idx = existing.index(existing.startIndex, offsetBy: min(location, existing.count))
            var mutable = existing
            mutable.insert(contentsOf: text, at: idx)
            newValue = mutable
        } else if let existing = existingValue {
            newValue = existing + text
        } else {
            newValue = text
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        guard result == .success else {
            throw AXInjectionError.setValueFailed(result)
        }

        // Move the insertion point to the end of the inserted text.
        let newLocation = (insertionLocation ?? (existingValue?.count ?? 0)) + text.count
        var range = CFRangeMake(newLocation, 0)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        logger.info("Text injected via Accessibility API, length=\(text.count)")

        if pressEnter {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            simulateReturnKey()
        }
    }

    // MARK: - Private helpers

    private func focusedTextElement() throws -> AXUIElement {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AXInjectionError.noFrontmostApp
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard result == .success, let focused = focusedValue else {
            throw AXInjectionError.noFocusedElement(result)
        }

        let element = focused as! AXUIElement

        // Verify the element is a text-input role.
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        guard Self.textRoles.contains(role) else {
            throw AXInjectionError.notATextField(role)
        }

        // Verify the value attribute is settable.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else {
            throw AXInjectionError.valueNotSettable
        }

        return element
    }

    private func currentValue(of element: AXUIElement) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let str = value as? String else {
            throw AXInjectionError.readValueFailed(result)
        }
        return str
    }

    private func insertionPointLocation(of element: AXUIElement) throws -> Int {
        var rangeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard result == .success, let axValue = rangeValue else {
            throw AXInjectionError.noInsertionPoint
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else {
            throw AXInjectionError.noInsertionPoint
        }
        return range.location
    }

    private func simulateReturnKey() {
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
}

enum AXInjectionError: LocalizedError {
    case noFrontmostApp
    case noFocusedElement(AXError)
    case notATextField(String)
    case valueNotSettable
    case setValueFailed(AXError)
    case readValueFailed(AXError)
    case noInsertionPoint

    var errorDescription: String? {
        switch self {
        case .noFrontmostApp:
            return "No frontmost application found"
        case .noFocusedElement(let err):
            return "No focused UI element (AXError \(err.rawValue))"
        case .notATextField(let role):
            return "Focused element is not a text field (role: \(role))"
        case .valueNotSettable:
            return "Focused text field value is not settable"
        case .setValueFailed(let err):
            return "Failed to set text field value (AXError \(err.rawValue))"
        case .readValueFailed(let err):
            return "Failed to read text field value (AXError \(err.rawValue))"
        case .noInsertionPoint:
            return "Could not determine insertion point"
        }
    }
}
