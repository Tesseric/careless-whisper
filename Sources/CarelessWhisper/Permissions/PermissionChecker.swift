import AVFoundation
import AppKit
import os

final class PermissionChecker {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "Permissions")

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            logger.warning("Microphone permission denied")
            return false
        @unknown default:
            return false
        }
    }

    func checkAccessibilityPermission() {
        if !hasAccessibilityPermission {
            logger.info("Requesting accessibility permission")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
