import Foundation
import os

// MARK: - Kitty IPC Text Injection
//
// Injects transcribed text (and optionally an Enter key) into the active Kitty
// terminal window using `kitten @` remote control commands over a Unix socket.
//
// ## Architecture
//
// Text is sent with `kitten @ send-text` and the Enter key with
// `kitten @ send-key enter`. These are two fundamentally different mechanisms:
//
//   • send-text  – writes raw bytes into the pty (like typing characters).
//   • send-key   – generates a key *event* that flows through kitty's keyboard
//                   protocol, including progressive enhancement (CSI u).
//
// ## Why send-key for Enter (not send-text)
//
// Programs that opt into kitty's progressive keyboard enhancement protocol
// (e.g. GitHub Copilot CLI) receive key events as structured escape sequences,
// not raw bytes. A raw CR byte (0x0d) injected via send-text is silently
// ignored by these programs. Additionally, kitten's send-text interprets
// arguments with Python escaping rules, so a Swift "\r" (byte 0x0d) is not
// the same as the two-character escape sequence "\\r" — the raw byte may be
// dropped entirely. Using `send-key enter` avoids both problems.
//
// ## Timing
//
// A 200ms delay is inserted between the text injection and the Enter key.
// Without this, the target program may not have finished reading/rendering
// the injected text from the pty, causing the Enter key event to be lost.
//
// ## Socket Discovery
//
// When launched from a Kitty terminal, the app inherits `KITTY_LISTEN_ON`
// and uses it directly. When launched from Finder/Spotlight (no env var),
// it scans /tmp for `kitty-<pid>` Unix sockets owned by the current user.
// The `--to` flag is required for `kitten @` when running outside Kitty.
//
// ## kitty.conf Requirements
//
//   allow_remote_control socket-only
//   listen_on unix:/tmp/kitty-{kitty_pid}
//
// ## Silent Failures
//
// Both send-text and send-key always exit 0 even if no text/key was
// delivered. Errors (wrong window match, unsupported key mode) are not
// reported. The only detectable failures are socket/connection errors.

final class KittyIPC: TextInjector {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "KittyIPC")

    func injectText(_ text: String, pressEnter: Bool) async throws {
        let kittenPath = try findKitten()
        let socketArgs = socketArguments()

        if socketArgs.isEmpty {
            throw KittyIPCError.noSocket
        }

        logger.info("Sending text via kitten at: \(kittenPath) with socket args: \(socketArgs)")

        try await runKitten(kittenPath: kittenPath, socketArgs: socketArgs, text: text)

        if pressEnter {
            // Delay to let the target program process the injected text.
            // Programs like GitHub Copilot CLI need time to read and render
            // the text from the pty before they can accept a key event.
            // Longer text requires more processing time.
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            logger.info("Sending Enter key via send-key")
            try await sendEnterKey(kittenPath: kittenPath, socketArgs: socketArgs)
            logger.info("Enter key sent via send-key")
        }

        logger.info("Text sent via Kitty IPC successfully")
    }

    private func runKitten(kittenPath: String, socketArgs: [String], text: String) async throws {
        let result: (status: Int32, output: String) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kittenPath)
            process.arguments = ["@"] + socketArgs + ["send-text", "--match", "recent:0", "--", text]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value

        if result.status != 0 {
            logger.error("kitten failed (\(result.status)): \(result.output)")

            if result.output.contains("allow_remote_control") || result.output.contains("Remote control") {
                throw KittyIPCError.remoteControlDisabled
            }
            throw KittyIPCError.kittenFailed(result.output)
        }
    }

    /// Sends an Enter key event via `kitten @ send-key`.
    /// Unlike send-text, send-key generates actual key events that are
    /// delivered through kitty's keyboard protocol, which is required for
    /// programs using progressive keyboard enhancement (e.g. GitHub Copilot CLI).
    private func sendEnterKey(kittenPath: String, socketArgs: [String]) async throws {
        let result: (status: Int32, output: String) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kittenPath)
            process.arguments = ["@"] + socketArgs + ["send-key", "--match", "recent:0", "enter"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value

        if result.status != 0 {
            logger.warning("Failed to send Enter key via Kitty IPC: \(result.output)")
        }
    }

    /// Build --to= argument if we can find the Kitty socket.
    private func socketArguments() -> [String] {
        if let socketURL = KittyRemoteControl.findSocket() {
            logger.info("Found Kitty socket: \(socketURL)")
            return ["--to", socketURL]
        }

        logger.info("No Kitty socket found")
        return []
    }

    private func findKitten() throws -> String {
        guard let path = KittyRemoteControl.findKittenBinary() else {
            throw KittyIPCError.kittenNotFound
        }
        return path
    }
}

enum KittyIPCError: LocalizedError {
    case kittenNotFound
    case kittenFailed(String)
    case remoteControlDisabled
    case noSocket

    var errorDescription: String? {
        switch self {
        case .kittenNotFound:
            return "Could not find 'kitten' binary. Is Kitty installed?"
        case .kittenFailed(let message):
            return "kitten command failed: \(message)"
        case .remoteControlDisabled:
            return "Kitty remote control is not enabled. Add 'allow_remote_control yes' to your kitty.conf"
        case .noSocket:
            return "No Kitty socket found. Add 'allow_remote_control socket-only' and 'listen_on unix:/tmp/kitty-{kitty_pid}' to your kitty.conf"
        }
    }
}
