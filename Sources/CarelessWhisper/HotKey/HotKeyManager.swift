import AppKit
import Carbon.HIToolbox
import HotKey
import os

final class HotKeyManager {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "HotKeyManager")

    var onHotKeyPressed: (() -> Void)?
    var onHotKeyReleased: (() -> Void)?

    private var hotKey: HotKey?
    private var isHolding = false

    var keyCombo: KeyCombo

    init() {
        // One-time migration: prior versions wrote Carbon modifier masks under
        // "hotkeyModifiers" but read them back as Cocoa NSEvent.ModifierFlags,
        // producing a garbage combo on every relaunch. Clear the stale value so
        // affected users fall back to the default once, then re-pick if desired.
        let migrationKey = "hotkeyModifiersV2Migrated"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        // Load saved hotkey or use default (Option + `)
        if let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int,
           let key = Key(carbonKeyCode: UInt32(keyCode)) {
            let modifiersRaw = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiersRaw))
            self.keyCombo = KeyCombo(key: key, modifiers: flags)
        } else {
            self.keyCombo = KeyCombo(key: .grave, modifiers: [.option])
        }
    }

    func register() {
        unregister()

        let hk = HotKey(keyCombo: keyCombo)

        hk.keyDownHandler = { [weak self] in
            guard let self, !self.isHolding else { return }
            self.isHolding = true
            self.logger.info("Push-to-talk: key down")
            self.onHotKeyPressed?()
        }

        hk.keyUpHandler = { [weak self] in
            guard let self, self.isHolding else { return }
            self.isHolding = false
            self.logger.info("Push-to-talk: key up")
            self.onHotKeyReleased?()
        }

        self.hotKey = hk
        logger.info("Hotkey registered: \(String(describing: self.keyCombo))")
    }

    func unregister() {
        hotKey = nil
        isHolding = false
    }
}
