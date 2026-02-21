import Foundation
import os

enum FileChangeType {
    case added, modified, deleted, renamed, untracked

    var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        }
    }
}

struct GitFileChange {
    let path: String
    let type: FileChangeType

    /// Short display name: last 2 path components for nested files, full path otherwise.
    var displayName: String {
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }
}

/// Git repository context detected from the active terminal.
struct GitContext {
    let repoName: String
    let branch: String
    let ownerAndRepo: String?
    let gitHubURL: String?
    let stagedFiles: [GitFileChange]
    let unstagedFiles: [GitFileChange]
    let branchFiles: [GitFileChange]
    let aheadBehind: AheadBehind?
    let lastCommit: LastCommit?
    let stashCount: Int
    let diffPreviews: [DiffPreview]
    let ciStatus: CIStatus?
    let prInfo: PRInfo?
}

struct AheadBehind {
    let ahead: Int
    let behind: Int
}

struct LastCommit {
    let message: String
    let relativeTime: String
}

enum CIState {
    case success, failure, pending, cancelled, unknown
}

struct CIStatus {
    let state: CIState
    let name: String
}

struct PRInfo {
    let number: Int
    let title: String
    let reviewDecision: String?
}

struct DiffLine {
    enum Kind { case added, removed, context }
    let kind: Kind
    let text: String
}

struct DiffPreview {
    let fileName: String
    let lines: [DiffLine]
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

            let (staged, unstaged) = parseGitStatus(cwd: repoRoot)
            let branchFiles = parseBranchDiff(branch: branch, cwd: repoRoot)
            let aheadBehind = parseAheadBehind(branch: branch, cwd: repoRoot)
            let lastCommit = parseLastCommit(cwd: repoRoot)
            let stashCount = countStashes(cwd: repoRoot)
            let diffPreviews = parseDiffPreviews(unstagedFiles: unstaged, cwd: repoRoot)
            let ciStatus = queryCIStatus(branch: branch, cwd: repoRoot)
            let prInfo = queryPRInfo(branch: branch, cwd: repoRoot)

            logger.info("Detected git context: \(repoName) @ \(branch) — \(staged.count) staged, \(unstaged.count) unstaged, \(branchFiles.count) branch")
            return GitContext(
                repoName: repoName, branch: branch,
                ownerAndRepo: ownerAndRepo, gitHubURL: gitHubURL,
                stagedFiles: staged, unstagedFiles: unstaged, branchFiles: branchFiles,
                aheadBehind: aheadBehind, lastCommit: lastCommit, stashCount: stashCount,
                diffPreviews: diffPreviews, ciStatus: ciStatus, prInfo: prInfo
            )
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

    /// Parses `git status --porcelain` into staged and unstaged file changes.
    private static func parseGitStatus(cwd: String) -> (staged: [GitFileChange], unstaged: [GitFileChange]) {
        guard let output = git(["status", "--porcelain"], cwd: cwd) else { return ([], []) }

        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 4 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))

            // Renames: "old -> new" — show the new path
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }

            if x != " " && x != "?" {
                staged.append(GitFileChange(path: path, type: charToChangeType(x)))
            }

            if y != " " {
                let type: FileChangeType = (x == "?") ? .untracked : charToChangeType(y)
                unstaged.append(GitFileChange(path: path, type: type))
            }
        }

        return (staged, unstaged)
    }

    private static func charToChangeType(_ c: Character) -> FileChangeType {
        switch c {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "?": return .untracked
        default:  return .modified
        }
    }

    /// Files changed on this branch compared to the default branch (main/master).
    private static func parseBranchDiff(branch: String, cwd: String) -> [GitFileChange] {
        let defaultBranches = ["main", "master"]
        guard !defaultBranches.contains(branch) else { return [] }

        let base = defaultBranches.lazy.compactMap { git(["merge-base", $0, "HEAD"], cwd: cwd) }.first
        guard let base else { return [] }

        guard let output = git(["diff", "--name-status", base], cwd: cwd) else { return [] }

        var files: [GitFileChange] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { continue }
            let statusChar = parts[0].first ?? "M"
            let path = parts.count > 2 ? String(parts[2]) : String(parts[1])
            files.append(GitFileChange(path: path, type: charToChangeType(statusChar)))
        }
        return files
    }

    private static func parseAheadBehind(branch: String, cwd: String) -> AheadBehind? {
        guard let output = git(["rev-list", "--left-right", "--count", "origin/\(branch)...HEAD"], cwd: cwd) else { return nil }
        let parts = output.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return nil }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    private static func parseLastCommit(cwd: String) -> LastCommit? {
        guard let message = git(["log", "-1", "--format=%s"], cwd: cwd),
              let relTime = git(["log", "-1", "--format=%ar"], cwd: cwd) else { return nil }
        let short = relTime
            .replacingOccurrences(of: " seconds? ago", with: "s ago", options: .regularExpression)
            .replacingOccurrences(of: " minutes? ago", with: "m ago", options: .regularExpression)
            .replacingOccurrences(of: " hours? ago", with: "h ago", options: .regularExpression)
            .replacingOccurrences(of: " days? ago", with: "d ago", options: .regularExpression)
            .replacingOccurrences(of: " weeks? ago", with: "w ago", options: .regularExpression)
            .replacingOccurrences(of: " months? ago", with: "mo ago", options: .regularExpression)
            .replacingOccurrences(of: " years? ago", with: "y ago", options: .regularExpression)
        return LastCommit(message: message, relativeTime: short)
    }

    private static func countStashes(cwd: String) -> Int {
        guard let output = git(["stash", "list"], cwd: cwd) else { return 0 }
        return output.split(separator: "\n").count
    }

    private static func parseDiffPreviews(unstagedFiles: [GitFileChange], cwd: String) -> [DiffPreview] {
        let modifiedFiles = unstagedFiles.filter { $0.type == .modified }
        var previews: [DiffPreview] = []

        for file in modifiedFiles {
            guard let output = git(["diff", "-U3", "--no-color", "--", file.path], cwd: cwd) else { continue }

            var lines: [DiffLine] = []
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
                } else if line.hasPrefix(" ") && !lines.isEmpty {
                    lines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
                }
                if lines.count >= 8 { break }
            }
            if !lines.isEmpty {
                previews.append(DiffPreview(fileName: file.displayName, lines: lines))
            }
        }
        return previews
    }

    // MARK: - GitHub CLI

    private static func findGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func queryCIStatus(branch: String, cwd: String) -> CIStatus? {
        guard let gh = findGH(),
              let output = run(gh, args: ["run", "list", "--branch", branch, "--limit", "1",
                                          "--json", "status,conclusion,name"], cwd: cwd, timeout: 5) else { return nil }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let name = first["name"] as? String else { return nil }

        let status = first["status"] as? String ?? ""
        let conclusion = first["conclusion"] as? String

        let state: CIState
        if status == "completed" {
            switch conclusion {
            case "success": state = .success
            case "failure": state = .failure
            case "cancelled": state = .cancelled
            default: state = .unknown
            }
        } else if ["in_progress", "queued", "waiting", "requested", "pending"].contains(status) {
            state = .pending
        } else {
            state = .unknown
        }

        return CIStatus(state: state, name: name)
    }

    private static func queryPRInfo(branch: String, cwd: String) -> PRInfo? {
        guard let gh = findGH(),
              let output = run(gh, args: ["pr", "list", "--head", branch, "--limit", "1",
                                          "--json", "number,title,reviewDecision"], cwd: cwd, timeout: 5) else { return nil }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let number = first["number"] as? Int,
              let title = first["title"] as? String else { return nil }

        return PRInfo(number: number, title: title, reviewDecision: first["reviewDecision"] as? String)
    }

    private static func git(_ args: [String], cwd: String) -> String? {
        run("/usr/bin/git", args: args, cwd: cwd)
    }

    private static let processEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // macOS apps don't inherit the user's shell PATH, so gh/git may not be found.
        // Ensure standard binary paths are included.
        let requiredPaths = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/bin", "/usr/sbin"]
        let currentPath = env["PATH"] ?? ""
        let existingPaths = Set(currentPath.split(separator: ":").map(String.init))
        let missing = requiredPaths.filter { !existingPaths.contains($0) }
        if !missing.isEmpty {
            env["PATH"] = (missing + [currentPath]).joined(separator: ":")
        }
        return env
    }()

    private static func run(_ executable: String, args: [String], cwd: String? = nil, checkExit: Bool = true, timeout: TimeInterval = 0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = processEnvironment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            if timeout > 0 {
                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }
                try process.run()
                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    return nil
                }
            } else {
                try process.run()
                process.waitUntilExit()
            }
            if checkExit { guard process.terminationStatus == 0 else { return nil } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output?.isEmpty == true) ? nil : output
        } catch {
            return nil
        }
    }
}
