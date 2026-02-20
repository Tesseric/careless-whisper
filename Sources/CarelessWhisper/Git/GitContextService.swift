import Foundation
import os

/// Git repository context detected from the active terminal.
struct GitContext {
    let repoName: String
    let branch: String
    let ownerAndRepo: String?
    let gitHubURL: String?
}

/// Detects Git repository context from the active terminal's shell processes.
final class GitContextService {
    private static let logger = Logger(subsystem: "com.carelesswhisper", category: "GitContext")

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
    ]

    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Detects git repo/branch from the terminal's descendant processes (runs off main thread).
    static func detect(terminalPID: pid_t) async -> GitContext? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: detectSync(terminalPID: terminalPID))
            }
        }
    }

    // MARK: - Private

    private static func detectSync(terminalPID: pid_t) -> GitContext? {
        let cwds = findDescendantCWDs(rootPID: terminalPID)

        for cwd in cwds {
            guard let repoRoot = git(["rev-parse", "--show-toplevel"], cwd: cwd) else { continue }

            let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd) ?? "HEAD"
            let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent

            var ownerAndRepo: String?
            var gitHubURL: String?
            if let remote = git(["remote", "get-url", "origin"], cwd: cwd) {
                ownerAndRepo = parseGitHubOwnerRepo(remote)
                if let ownerAndRepo {
                    gitHubURL = "https://github.com/\(ownerAndRepo)"
                }
            }

            logger.info("Detected git context: \(repoName) @ \(branch)")
            return GitContext(repoName: repoName, branch: branch, ownerAndRepo: ownerAndRepo, gitHubURL: gitHubURL)
        }

        return nil
    }

    /// Finds unique working directories of all descendant processes of the given root PID.
    private static func findDescendantCWDs(rootPID: pid_t) -> [String] {
        guard let psOutput = run("/bin/ps", args: ["-axo", "pid=,ppid="]) else { return [] }

        // Build parent → children map
        var childrenMap: [pid_t: [pid_t]] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            childrenMap[ppid, default: []].append(pid)
        }

        // BFS to collect all descendants
        var descendants: [pid_t] = []
        var queue = childrenMap[rootPID] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            descendants.append(pid)
            queue.append(contentsOf: childrenMap[pid] ?? [])
        }

        guard !descendants.isEmpty else { return [] }

        // Get CWDs via lsof for all descendants in one call.
        // lsof returns exit code 1 when some PIDs are inaccessible (e.g. suid login),
        // but still outputs valid data for the rest — so we ignore the exit code.
        let pidList = descendants.map(String.init).joined(separator: ",")
        guard let lsofOutput = run("/usr/sbin/lsof", args: ["-a", "-d", "cwd", "-p", pidList, "-Fn"], checkExit: false) else { return [] }

        var cwds: [String] = []
        var seen: Set<String> = []
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path != "/" && seen.insert(path).inserted {
                cwds.append(path)
            }
        }
        return cwds
    }

    /// Extracts "owner/repo" from a GitHub remote URL (SSH or HTTPS).
    private static func parseGitHubOwnerRepo(_ remote: String) -> String? {
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)

        // SSH: git@github.com:owner/repo.git
        if r.hasPrefix("git@github.com:") {
            return String(r.dropFirst("git@github.com:".count))
                .replacingOccurrences(of: ".git", with: "")
        }

        // HTTPS: https://github.com/owner/repo.git
        if let url = URL(string: r), let host = url.host, host.hasSuffix("github.com") {
            var path = url.path
            if path.hasPrefix("/") { path = String(path.dropFirst()) }
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            return path.isEmpty ? nil : path
        }

        return nil
    }

    private static func git(_ args: [String], cwd: String) -> String? {
        run("/usr/bin/git", args: args, cwd: cwd)
    }

    private static func run(_ executable: String, args: [String], cwd: String? = nil, checkExit: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if checkExit { guard process.terminationStatus == 0 else { return nil } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output?.isEmpty == true) ? nil : output
        } catch {
            return nil
        }
    }
}
