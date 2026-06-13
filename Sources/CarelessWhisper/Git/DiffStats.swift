import Foundation

/// Added/removed line counts and file count for one bucket of changes.
struct LineCount: Equatable {
    var added: Int
    var removed: Int
    var files: Int

    static let zero = LineCount(added: 0, removed: 0, files: 0)

    static func + (lhs: LineCount, rhs: LineCount) -> LineCount {
        LineCount(added: lhs.added + rhs.added,
                  removed: lhs.removed + rhs.removed,
                  files: lhs.files + rhs.files)
    }
}

/// Per-bucket line counts for a single diff scope (working tree or branch).
struct DiffStatScope: Equatable {
    var functional: LineCount = .zero
    var test: LineCount = .zero
    var other: LineCount = .zero

    var total: LineCount { functional + test + other }
}

/// Line-change statistics for both the working tree and the branch-vs-base diff.
struct DiffStats: Equatable {
    /// Working tree vs HEAD (`git diff --numstat HEAD`).
    let working: DiffStatScope
    /// Branch vs merge-base with default branch; nil when on the default branch.
    let branch: DiffStatScope?

    /// Parses `git --numstat` output into a per-bucket scope.
    /// Each line is `added\tremoved\tpath`; binary files use `-` for counts.
    static func parseScope(
        numstat: String,
        classify: (String) -> ChangeBucket = ChangeClassifier.bucket(for:)
    ) -> DiffStatScope {
        var scope = DiffStatScope()

        for rawLine in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let added = Int(parts[0]) ?? 0       // "-" (binary) → 0
            let removed = Int(parts[1]) ?? 0
            let path = finalPath(from: String(parts[2]))

            let delta = LineCount(added: added, removed: removed, files: 1)
            switch classify(path) {
            case .functional: scope.functional = scope.functional + delta
            case .test:       scope.test = scope.test + delta
            case .other:      scope.other = scope.other + delta
            }
        }
        return scope
    }

    /// Resolves the post-rename path from a numstat path field.
    /// Handles "old => new" and brace form "dir/{old => new}/file".
    static func finalPath(from field: String) -> String {
        guard field.contains("=>") else { return field }

        if let braceOpen = field.firstIndex(of: "{"),
           let braceClose = field.firstIndex(of: "}"),
           braceOpen < braceClose {
            let prefix = String(field[field.startIndex..<braceOpen])
            let suffix = String(field[field.index(after: braceClose)...])
            let inner = String(field[field.index(after: braceOpen)..<braceClose])
            let newInner = inner.components(separatedBy: "=>").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return (prefix + newInner + suffix).replacingOccurrences(of: "//", with: "/")
        }

        // Plain "old => new".
        return field.components(separatedBy: "=>").last?
            .trimmingCharacters(in: .whitespaces) ?? field
    }
}
