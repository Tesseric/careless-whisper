import Foundation

/// The category a changed file falls into for the tests-vs-functional breakdown.
enum ChangeBucket {
    case functional, test, other
}

/// Classifies a repo-relative file path into a `ChangeBucket` using path/name heuristics.
/// Pure and deterministic — no filesystem access.
enum ChangeClassifier {

    /// Directory segments that mark a path as a test path (case-insensitive).
    private static let testDirSegments: Set<String> = [
        "tests", "test", "spec", "__tests__", "e2e",
    ]

    /// Extensions treated as non-code "Other" (docs, config, lockfiles), lowercased, no dot.
    private static let otherExtensions: Set<String> = [
        "md", "markdown", "txt", "rst",
        "lock", "yml", "yaml", "toml", "cfg", "ini", "plist",
        "gitignore", "gitattributes",
    ]

    /// Whole filenames treated as "Other".
    private static let otherFilenames: Set<String> = [
        "package.resolved", "dockerfile", "makefile", "license", ".gitignore",
    ]

    static func bucket(for path: String) -> ChangeBucket {
        let lowerPath = path.lowercased()
        let components = lowerPath.split(separator: "/").map(String.init)
        let filename = components.last ?? lowerPath

        // 1. Test — directory segment or filename pattern (wins over everything).
        if components.dropLast().contains(where: { testDirSegments.contains($0) }) {
            return .test
        }
        if isTestFilename(filename) {
            return .test
        }

        // 2. Other — docs/config/lockfiles.
        if otherFilenames.contains(filename) {
            return .other
        }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, otherExtensions.contains(ext) {
            return .other
        }
        // Dotfiles like ".gitignore" have no pathExtension; check the leading-dot name too.
        if filename.hasPrefix("."), otherExtensions.contains(String(filename.dropFirst())) {
            return .other
        }

        // 3. Functional.
        return .functional
    }

    /// Matches test filename conventions: *Test(s).ext, *_test.ext, *.test.ext, *.spec.ext,
    /// test_*.py, *_spec.rb. `filename` is already lowercased.
    private static func isTestFilename(_ filename: String) -> Bool {
        let base = (filename as NSString).deletingPathExtension      // e.g. "button.test"
        let ext = (filename as NSString).pathExtension               // e.g. "tsx"

        if base.hasSuffix("test") || base.hasSuffix("tests") { return true }   // appstatetests, parser_test
        if base.hasSuffix(".test") || base.hasSuffix(".spec") { return true }  // button.test, button.spec
        if base.hasPrefix("test_") && ext == "py" { return true }
        if base.hasSuffix("_spec") && ext == "rb" { return true }
        return false
    }
}
