import Foundation
import os

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
        // 1. Check KITTY_LISTEN_ON env var
        if let listenOn = ProcessInfo.processInfo.environment["KITTY_LISTEN_ON"], !listenOn.isEmpty {
            logger.info("Using KITTY_LISTEN_ON: \(listenOn)")
            return ["--to", listenOn]
        }

        // 2. Scan /tmp for kitty-* unix socket files (named by PID, e.g. /tmp/kitty-12345)
        if let socket = findKittySocket() {
            let socketURL = "unix:\(socket)"
            logger.info("Found Kitty socket: \(socketURL)")
            return ["--to", socketURL]
        }

        // 3. No socket found — cannot use kitten from a GUI app without --to
        logger.info("No Kitty socket found")
        return []
    }

    private func findKittySocket() -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: "/tmp") else { return nil }

        let uid = getuid()
        // Kitty creates sockets at /tmp/kitty-<pid> owned by the current user
        let sockets = contents
            .filter { $0.hasPrefix("kitty-") }
            .map { "/tmp/\($0)" }
            .filter { path in
                // Must be a socket (exists but is not a directory or regular file)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
                // Must be owned by us
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let ownerID = attrs[.ownerAccountID] as? UInt, ownerID == uid else { return false }
                // Verify it's a socket via file type
                guard let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSocket else { return false }
                return true
            }
            .sorted { a, b in
                let aDate = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                let bDate = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                return aDate > bDate
            }

        return sockets.first
    }

    private func findKitten() throws -> String {
        let candidates = [
            "/Applications/kitty.app/Contents/MacOS/kitten",
            "/usr/local/bin/kitten",
            "/opt/homebrew/bin/kitten",
            NSHomeDirectory() + "/.local/bin/kitten",
            NSHomeDirectory() + "/.local/kitty.app/bin/kitten",
        ]

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw KittyIPCError.kittenNotFound
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
