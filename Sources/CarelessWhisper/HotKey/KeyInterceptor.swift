import AppKit
import Carbon.HIToolbox
import os

/// Intercepts and suppresses the `1` key during recording via a CGEventTap.
/// Used to let the user confirm clipboard image attachment without the keystroke
/// reaching the terminal.
final class KeyInterceptor {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "KeyInterceptor")

    var onKeyIntercepted: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the tap is currently intercepting keys.
    /// Only accessed from the main run loop (where the CGEventTap callback fires).
    private var isActive = false

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Creates the CGEventTap on the main run loop. Initially disabled.
    /// Call once during app setup. Fails silently if accessibility is not granted.
    func install() {
        guard eventTap == nil else { return }

        // Store self pointer for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: keyInterceptorCallback,
            userInfo: selfPtr
        ) else {
            logger.warning("Failed to create CGEventTap — accessibility permission may be missing")
            return
        }

        // Start disabled
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.eventTap = tap
        self.runLoopSource = source
        logger.info("CGEventTap installed (disabled)")
    }

    /// Enable key interception. Call when recording starts and an image is detected.
    func activate() {
        guard let tap = eventTap else { return }
        isActive = true
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Key interceptor activated")
    }

    /// Disable key interception.
    func deactivate() {
        guard let tap = eventTap else { return }
        isActive = false
        CGEvent.tapEnable(tap: tap, enable: false)
        logger.info("Key interceptor deactivated")
    }

    /// Called from the CGEventTap callback on the main run loop.
    fileprivate func handleKeyEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        // Re-enable if macOS disabled the tap due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap, isActive {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.notice("Re-enabled event tap after timeout")
            }
            return event
        }

        guard isActive, type == .keyDown else { return event }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_ANSI_1) else { return event }

        // Suppress the keystroke and notify
        logger.info("Intercepted '1' key press")
        let callback = onKeyIntercepted
        DispatchQueue.main.async {
            callback?()
        }
        return nil
    }
}

/// C-function callback for CGEventTap. Bridges to the KeyInterceptor instance.
private func keyInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

    if let result = interceptor.handleKeyEvent(proxy, type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil  // Suppress the event
}
