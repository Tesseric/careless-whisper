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
        let components = path.split(separator: "/").map(String.init)
        let filename = components.last ?? path

        // 1. Test — directory segment (case-insensitive) or filename pattern (wins over everything).
        let lowerComponents = components.map { $0.lowercased() }
        if lowerComponents.dropLast().contains(where: { testDirSegments.contains($0) }) {
            return .test
        }
        if isTestFilename(filename) {
            return .test
        }

        // 2. Other — docs/config/lockfiles.
        let lowerFilename = filename.lowercased()
        if otherFilenames.contains(lowerFilename) {
            return .other
        }
        let ext = (lowerFilename as NSString).pathExtension
        if !ext.isEmpty, otherExtensions.contains(ext) {
            return .other
        }
        // Dotfiles like ".gitignore" have no pathExtension; check the leading-dot name too.
        if lowerFilename.hasPrefix("."), otherExtensions.contains(String(lowerFilename.dropFirst())) {
            return .other
        }

        // 3. Functional.
        return .functional
    }

    /// Matches test filename conventions:
    /// PascalCase `*Test`/`*Tests`, snake `*_test(s)`, dotted `*.test`/`*.spec`,
    /// python `test_*.py`, ruby `*_spec.rb`. Uses original case to detect the
    /// PascalCase boundary (a bare lowercase "...test" like `latest` is NOT a test).
    private static func isTestFilename(_ filename: String) -> Bool {
        let nsName = filename as NSString
        let base = nsName.deletingPathExtension          // original case, e.g. "AppStateTests" or "button.test"
        let ext = nsName.pathExtension.lowercased()
        let lowerBase = base.lowercased()

        if base.hasSuffix("Test") || base.hasSuffix("Tests") { return true }   // PascalCase: AppStateTests, FooTest
        if lowerBase.hasSuffix("_test") || lowerBase.hasSuffix("_tests") { return true }  // snake_case
        if lowerBase.hasSuffix(".test") || lowerBase.hasSuffix(".spec") { return true }   // button.test.tsx -> base "button.test"
        if lowerBase.hasPrefix("test_") && ext == "py" { return true }
        if lowerBase.hasSuffix("_spec") && ext == "rb" { return true }
        return false
    }
}
