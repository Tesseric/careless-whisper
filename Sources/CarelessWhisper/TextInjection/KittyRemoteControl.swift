import Foundation

/// Shared Kitty remote-control helpers used by both text injection (`KittyIPC`)
/// and git context detection (`GitContextService`).
///
/// Centralises kitten binary and Unix socket discovery so fixes only need
/// to be made in one place.
enum KittyRemoteControl {
    /// Finds the `kitten` binary on disk, checking common install locations.
    static func findKittenBinary() -> String? {
        let candidates = [
            "/Applications/kitty.app/Contents/MacOS/kitten",
            "/usr/local/bin/kitten",
            "/opt/homebrew/bin/kitten",
            NSHomeDirectory() + "/.local/bin/kitten",
            NSHomeDirectory() + "/.local/kitty.app/bin/kitten",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns the Kitty socket URL ready for `--to` (e.g. `unix:/tmp/kitty-1234`).
    ///
    /// Checks `KITTY_LISTEN_ON` first, then scans `/tmp` for `kitty-*` sockets.
    /// Caches the result for 30 seconds to avoid repeated `/tmp` scans during
    /// the 10-second git polling interval.
    static func findSocket() -> String? {
        if let listenOn = ProcessInfo.processInfo.environment["KITTY_LISTEN_ON"], !listenOn.isEmpty {
            return listenOn
        }

        // Return cached result if still fresh
        if let cached = cachedSocket, Date().timeIntervalSince(cachedSocketTime) < 30 {
            // Verify the cached socket still exists
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached.url
            }
            // Socket gone — invalidate
            cachedSocket = nil
        }

        guard let result = scanForSocket() else { return nil }
        cachedSocket = result
        cachedSocketTime = Date()
        return result.url
    }

    /// Invalidates the cached socket so the next call rescans.
    static func invalidateSocketCache() {
        cachedSocket = nil
    }

    // MARK: - Private

    private struct CachedSocket {
        let path: String  // raw path, e.g. /tmp/kitty-1234
        let url: String   // --to value, e.g. unix:/tmp/kitty-1234
    }

    private static var cachedSocket: CachedSocket?
    private static var cachedSocketTime: Date = .distantPast

    private static func scanForSocket() -> CachedSocket? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: "/tmp") else { return nil }
        let uid = getuid()

        let sockets = contents
            .filter { $0.hasPrefix("kitty-") }
            .map { "/tmp/\($0)" }
            .filter { path in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let ownerID = attrs[.ownerAccountID] as? UInt, ownerID == uid,
                      let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSocket else { return false }
                return true
            }
            .sorted { a, b in
                let aDate = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                let bDate = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                return aDate > bDate
            }

        guard let path = sockets.first else { return nil }
        return CachedSocket(path: path, url: "unix:\(path)")
    }
}
