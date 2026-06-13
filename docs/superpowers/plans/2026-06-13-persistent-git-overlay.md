# Persistent Git Status Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable, always-visible git-status overlay that pins to the focused terminal window's upper-right corner, showing a collapsed diffstat pill that expands into a detailed view (Tests/Functional/Other line breakdown + reused git detail + an agent-filled annotation zone).

**Architecture:** Extend the existing `GitContext`/`GitContextService` and reuse the existing `GitContextView` rendering (extracted to a shared `internal` file). New focused units: a pure `ChangeClassifier`, a pure `DiffStats` numstat parser, collapsed/expanded SwiftUI views, an AX-window-tracking `NSPanel` controller, and a typed `/git-overlay/annotate` HTTP endpoint. The overlay rides the existing 10-second `$gitContext` polling — no second polling loop.

**Tech Stack:** Swift 5.9, macOS 14+, SwiftUI hosted in AppKit `NSPanel`, Combine, Accessibility (AX) API, XCTest, Swift Package Manager.

**Reference:** Design spec at `docs/superpowers/specs/2026-06-13-persistent-git-overlay-design.md`.

**Conventions to follow (from CLAUDE.md):**
- `@MainActor` on UI/state classes; `async/await` throughout.
- `os.Logger` with subsystem `"com.carelesswhisper"` and a per-module category.
- Custom error enums with `LocalizedError` per module where a throwing API exists.
- Tests live in `Tests/CarelessWhisperTests/`, XCTest, run via `swift test`.

---

## File Structure

**New source files:**
- `Sources/CarelessWhisper/Git/ChangeClassifier.swift` — pure path → `ChangeBucket`.
- `Sources/CarelessWhisper/Git/DiffStats.swift` — `DiffStats`/`DiffStatScope`/`LineCount` + pure numstat parser.
- `Sources/CarelessWhisper/UI/OverlayPanelSupport.swift` — shared `SizeObservingHostingView`.
- `Sources/CarelessWhisper/UI/GitContextView.swift` — extracted git detail views (made `internal`, `showDiffPreviews` flag).
- `Sources/CarelessWhisper/UI/DiffStatPill.swift` — collapsed pill view.
- `Sources/CarelessWhisper/UI/GitOverlayExpandedView.swift` — expanded layout + `GitAnnotationView`.
- `Sources/CarelessWhisper/UI/WindowTrackingOverlay.swift` — AX-tracking `NSPanel` controller + pure coord helper.

**New test files:**
- `Tests/CarelessWhisperTests/ChangeClassifierTests.swift`
- `Tests/CarelessWhisperTests/DiffStatsTests.swift`
- `Tests/CarelessWhisperTests/GitAnnotationTests.swift`
- `Tests/CarelessWhisperTests/WindowFramePositioningTests.swift`

**Modified files:**
- `Sources/CarelessWhisper/Git/GitContextService.swift` — add `diffStats` field, `mergeBaseWithDefault` helper, numstat computation.
- `Sources/CarelessWhisper/UI/RecordingOverlay.swift` — remove extracted views; call shared ones.
- `Sources/CarelessWhisper/Server/WidgetModels.swift` — `RiskLevel`, `GitAnnotation`.
- `Sources/CarelessWhisper/Server/OverlayServer.swift` — annotate routes + callbacks.
- `Sources/CarelessWhisper/App/AppState.swift` — new state, annotation clear-on-branch-change, overlay lifecycle, server wiring.
- `Sources/CarelessWhisper/App/StatusBarController.swift` — toggle menu item.
- `Sources/CarelessWhisper/UI/SettingsView.swift` — Git Overlay settings section.
- `Sources/CarelessWhisper/Server/AgentSkillInstaller.swift` — `git-annotate` CLI subcommand + SKILL.md section.

**Verification note:** UI views and AppKit controllers can't be unit-tested headlessly in this SPM package, so those tasks verify via `swift build` plus a manual smoke checklist at the end (Task 15). Pure logic (classifier, numstat parser, annotation decode, coordinate math) is TDD'd.

---

### Task 1: `ChangeClassifier` — pure path → bucket

**Files:**
- Create: `Sources/CarelessWhisper/Git/ChangeClassifier.swift`
- Test: `Tests/CarelessWhisperTests/ChangeClassifierTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CarelessWhisperTests/ChangeClassifierTests.swift`:

```swift
import XCTest
@testable import CarelessWhisper

final class ChangeClassifierTests: XCTestCase {
    func testTestDirectorySegment() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Tests/DiffStatsTests.swift"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/__tests__/foo.js"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "app/spec/models/user.rb"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "e2e/login.ts"), .test)
    }

    func testTestFilenamePatterns() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Sources/App/AppStateTests.swift"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "pkg/parser_test.go"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "ui/button.test.tsx"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "ui/button.spec.ts"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "scripts/test_parser.py"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "models/user_spec.rb"), .test)
    }

    func testOtherBucket() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "README.md"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Package.resolved"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: ".gitignore"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "config/app.yml"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Cargo.lock"), .other)
    }

    func testFunctionalBucket() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Sources/App/AppState.swift"), .functional)
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/index.js"), .functional)
        XCTAssertEqual(ChangeClassifier.bucket(for: "data/schema.json"), .functional)
    }

    func testTestRuleWinsOverOther() {
        // A docs/config-extension file inside a test dir is still a test.
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/__tests__/fixtures/sample.json"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Tests/data/config.yml"), .test)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChangeClassifierTests`
Expected: FAIL — `cannot find 'ChangeClassifier' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CarelessWhisper/Git/ChangeClassifier.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChangeClassifierTests`
Expected: PASS (all 5 test methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/CarelessWhisper/Git/ChangeClassifier.swift Tests/CarelessWhisperTests/ChangeClassifierTests.swift
git commit -m "feat: add ChangeClassifier for test/functional/other path classification"
```

---

### Task 2: `DiffStats` model + pure numstat parser

**Files:**
- Create: `Sources/CarelessWhisper/Git/DiffStats.swift`
- Test: `Tests/CarelessWhisperTests/DiffStatsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CarelessWhisperTests/DiffStatsTests.swift`:

```swift
import XCTest
@testable import CarelessWhisper

final class DiffStatsTests: XCTestCase {
    func testParsesAddedRemovedAndFiles() {
        let numstat = """
        120\t12\tSources/App/AppState.swift
        64\t0\tTests/DiffStatsTests.swift
        3\t1\tREADME.md
        """
        let scope = DiffStats.parseScope(numstat: numstat)

        XCTAssertEqual(scope.functional.added, 120)
        XCTAssertEqual(scope.functional.removed, 12)
        XCTAssertEqual(scope.functional.files, 1)

        XCTAssertEqual(scope.test.added, 64)
        XCTAssertEqual(scope.test.files, 1)

        XCTAssertEqual(scope.other.added, 3)
        XCTAssertEqual(scope.other.removed, 1)
        XCTAssertEqual(scope.other.files, 1)

        XCTAssertEqual(scope.total.added, 187)
        XCTAssertEqual(scope.total.removed, 13)
        XCTAssertEqual(scope.total.files, 3)
    }

    func testBinaryFilesCountAsFileWithZeroLines() {
        let numstat = "-\t-\tassets/logo.png"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.total.added, 0)
        XCTAssertEqual(scope.total.removed, 0)
        XCTAssertEqual(scope.total.files, 1)
    }

    func testRenameUsesFinalPathForClassification() {
        // git --numstat rename form: "added removed old => new"
        let numstat = "10\t2\tsrc/old.js => Tests/new_test.js"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.test.added, 10)
        XCTAssertEqual(scope.test.files, 1)
        XCTAssertEqual(scope.functional.files, 0)
    }

    func testBraceRenameForm() {
        // git --numstat brace rename form: "src/{old => new}/file.swift"
        let numstat = "5\t5\tSources/{Old => New}/Service.swift"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.functional.added, 5)
        XCTAssertEqual(scope.functional.files, 1)
    }

    func testEmptyAndBlankInputYieldsZeros() {
        let scope = DiffStats.parseScope(numstat: "")
        XCTAssertEqual(scope.total.added, 0)
        XCTAssertEqual(scope.total.removed, 0)
        XCTAssertEqual(scope.total.files, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiffStatsTests`
Expected: FAIL — `cannot find 'DiffStats' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CarelessWhisper/Git/DiffStats.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiffStatsTests`
Expected: PASS (all 5 test methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/CarelessWhisper/Git/DiffStats.swift Tests/CarelessWhisperTests/DiffStatsTests.swift
git commit -m "feat: add DiffStats model and pure numstat parser"
```

---

### Task 3: Wire diff stats into `GitContextService`

**Files:**
- Modify: `Sources/CarelessWhisper/Git/GitContextService.swift`

- [ ] **Step 1: Add `diffStats` to the `GitContext` struct**

In `GitContextService.swift`, find the `struct GitContext { ... }` (around line 31-45) and add a field at the end (before the closing brace), after `let prInfo: PRInfo?`:

```swift
    let diffStats: DiffStats?
```

- [ ] **Step 2: Extract a reusable merge-base helper**

Find `parseBranchDiff(branch:cwd:)` (around line 336). Replace its merge-base lookup so it shares one helper. Replace these lines:

```swift
        let defaultBranches = ["main", "master"]
        guard !defaultBranches.contains(branch) else { return [] }

        let base = defaultBranches.lazy.compactMap { git(["merge-base", $0, "HEAD"], cwd: cwd) }.first
        guard let base else { return [] }
```

with:

```swift
        guard let base = mergeBaseWithDefault(branch: branch, cwd: cwd) else { return [] }
```

Then add this helper method just above `parseBranchDiff` (still inside the class):

```swift
    /// Merge-base of HEAD with the default branch (main/master). Nil on the default branch
    /// itself or when no merge-base exists.
    private static func mergeBaseWithDefault(branch: String, cwd: String) -> String? {
        let defaultBranches = ["main", "master"]
        guard !defaultBranches.contains(branch) else { return nil }
        return defaultBranches.lazy.compactMap { git(["merge-base", $0, "HEAD"], cwd: cwd) }.first
    }
```

- [ ] **Step 3: Add a diff-stats computation helper**

Add this method to the class (place it just below `parseBranchDiff`):

```swift
    /// Computes line-change stats for the working tree (vs HEAD) and the branch (vs merge-base).
    private static func computeDiffStats(branch: String, cwd: String) -> DiffStats {
        let workingRaw = git(["diff", "--numstat", "HEAD"], cwd: cwd) ?? ""
        let working = DiffStats.parseScope(numstat: workingRaw)

        var branchScope: DiffStatScope?
        if let base = mergeBaseWithDefault(branch: branch, cwd: cwd) {
            let branchRaw = git(["diff", "--numstat", base], cwd: cwd) ?? ""
            branchScope = DiffStats.parseScope(numstat: branchRaw)
        }
        return DiffStats(working: working, branch: branchScope)
    }
```

- [ ] **Step 4: Call it and pass it into the `GitContext` initializer**

In `detectSync`, find the block that computes context (around line 149-156). After the `let prInfo = queryPRInfo(...)` line, add:

```swift
            let diffStats = computeDiffStats(branch: branch, cwd: repoRoot)
```

Then in the `return GitContext(...)` call just below, add the new argument at the end (after `prInfo: prInfo`):

```swift
                ciStatus: ciStatus, prInfo: prInfo,
                diffStats: diffStats
            )
```

(Adjust the trailing comma on the `prInfo: prInfo` line so the argument list stays valid.)

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors. (If the compiler complains the `GitContext` initializer is missing `diffStats`, ensure Step 4's argument was added.)

- [ ] **Step 6: Run the full test suite (regression)**

Run: `swift test`
Expected: PASS — existing tests unaffected; `ChangeClassifierTests` and `DiffStatsTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CarelessWhisper/Git/GitContextService.swift
git commit -m "feat: compute working/branch diff stats in GitContextService"
```

---

### Task 4: Extract shared `SizeObservingHostingView`

**Files:**
- Create: `Sources/CarelessWhisper/UI/OverlayPanelSupport.swift`
- Modify: `Sources/CarelessWhisper/UI/RecordingOverlay.swift:8-16`

- [ ] **Step 1: Create the shared file**

Create `Sources/CarelessWhisper/UI/OverlayPanelSupport.swift`:

```swift
import SwiftUI
import AppKit

/// NSHostingView subclass that notifies when its SwiftUI content's intrinsic size changes.
/// Shared by the recording HUD and the persistent git overlay.
final class SizeObservingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}
```

- [ ] **Step 2: Remove the duplicate from `RecordingOverlay.swift`**

In `RecordingOverlay.swift`, delete the `private class SizeObservingHostingView<Content: View>: NSHostingView<Content>` declaration (lines 6-16, the `// MARK: - Size-Observing NSHostingView` block). Leave the `import` lines at the top intact.

- [ ] **Step 3: Build to verify the recording HUD still compiles**

Run: `swift build`
Expected: Builds cleanly. `OverlayController` now references the shared `SizeObservingHostingView` (same name, now `internal`).

- [ ] **Step 4: Commit**

```bash
git add Sources/CarelessWhisper/UI/OverlayPanelSupport.swift Sources/CarelessWhisper/UI/RecordingOverlay.swift
git commit -m "refactor: extract shared SizeObservingHostingView to OverlayPanelSupport"
```

---

### Task 5: Extract `GitContextView` into a shared file with `showDiffPreviews`

**Files:**
- Create: `Sources/CarelessWhisper/UI/GitContextView.swift`
- Modify: `Sources/CarelessWhisper/UI/RecordingOverlay.swift` (remove the moved views; update one call site)

- [ ] **Step 1: Move the git views into a new file**

Create `Sources/CarelessWhisper/UI/GitContextView.swift` with `import SwiftUI` at the top, then **cut** these declarations from `RecordingOverlay.swift` and paste them in, changing each from `private struct`/`private func` to `struct` (internal):
- `GitContextView` (around line 396-485)
- `GitStatusView` (around line 489-555)
- `CIBadgeView` (around line 559-...)
- `PRBadgeView`
- `DiffPreviewView`
- `PulseModifier` (around line 676; the `private struct PulseModifier: ViewModifier`)

Change `private struct GitContextView` → `struct GitContextView`, and likewise drop `private` on the others so the new overlay file can use them. (They were `private` to one file; they must become `internal`.)

- [ ] **Step 2: Add the `showDiffPreviews` flag to `GitContextView`**

In the moved `GitContextView`, add a stored property and default, and gate the diff-preview loop. Change the top of the struct from:

```swift
struct GitContextView: View {
    let context: GitContext

    var body: some View {
```

to:

```swift
struct GitContextView: View {
    let context: GitContext
    var showDiffPreviews: Bool = true

    var body: some View {
```

Then find the diff-previews loop near the end of `body`:

```swift
            // Diff previews
            ForEach(Array(context.diffPreviews.enumerated()), id: \.offset) { _, diff in
                DiffPreviewView(preview: diff)
            }
```

and wrap it in the flag:

```swift
            // Diff previews
            if showDiffPreviews {
                ForEach(Array(context.diffPreviews.enumerated()), id: \.offset) { _, diff in
                    DiffPreviewView(preview: diff)
                }
            }
```

- [ ] **Step 3: Verify the recording HUD call sites are unchanged**

In `RecordingOverlay.swift`, the two existing `GitContextView(context: appState.gitContext!)` call sites (around lines 255 and 290) need **no change** — they use the default `showDiffPreviews: true`. Confirm they still compile.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Builds cleanly. No visual change to the recording HUD.

- [ ] **Step 5: Run tests (regression)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CarelessWhisper/UI/GitContextView.swift Sources/CarelessWhisper/UI/RecordingOverlay.swift
git commit -m "refactor: extract GitContextView to shared file with showDiffPreviews flag"
```

---

### Task 6: `DiffStatPill` collapsed view

**Files:**
- Create: `Sources/CarelessWhisper/UI/DiffStatPill.swift`

- [ ] **Step 1: Create the collapsed pill view**

Create `Sources/CarelessWhisper/UI/DiffStatPill.swift`:

```swift
import SwiftUI

/// Collapsed, always-visible state of the persistent git overlay: a GitHub-style diffstat
/// pill (branch + "+A −R · N files" + a 5-cell red/green ratio bar). Tapping toggles expand.
struct DiffStatPill: View {
    let branch: String
    let scope: DiffStatScope
    let onTap: () -> Void

    private var added: Int { scope.total.added }
    private var removed: Int { scope.total.removed }
    private var files: Int { scope.total.files }

    /// Number of green cells out of 5, proportional to added/(added+removed).
    private var greenCells: Int {
        let denom = added + removed
        guard denom > 0 else { return 0 }
        return max(added > 0 ? 1 : 0, Int((Double(added) / Double(denom) * 5).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                Text(branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98)) // dracula purple
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text("+\(added)")
                    .foregroundStyle(.green)
                Text("−\(removed)")
                    .foregroundStyle(.red)
                Text("· \(files) file\(files == 1 ? "" : "s")")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))

            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cellColor(i))
                        .frame(width: 9, height: 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.157, green: 0.165, blue: 0.212)) // dracula bg #282a36
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func cellColor(_ index: Int) -> Color {
        if added == 0 && removed == 0 { return Color.white.opacity(0.18) }
        return index < greenCells ? .green : .red
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/CarelessWhisper/UI/DiffStatPill.swift
git commit -m "feat: add DiffStatPill collapsed overlay view"
```

---

### Task 7: `GitAnnotation` + `RiskLevel` models

**Files:**
- Modify: `Sources/CarelessWhisper/Server/WidgetModels.swift`
- Test: `Tests/CarelessWhisperTests/GitAnnotationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CarelessWhisperTests/GitAnnotationTests.swift`:

```swift
import XCTest
@testable import CarelessWhisper

final class GitAnnotationTests: XCTestCase {
    func testDecodesFullPayload() throws {
        let json = """
        {"summary":"Adds overlay","risk":"low","highlights":["Touches init order"]}
        """.data(using: .utf8)!
        let ann = try JSONDecoder().decode(GitAnnotation.self, from: json)
        XCTAssertEqual(ann.summary, "Adds overlay")
        XCTAssertEqual(ann.risk, .low)
        XCTAssertEqual(ann.highlights, ["Touches init order"])
    }

    func testDecodesPartialPayload() throws {
        let json = #"{"summary":"Just a note"}"#.data(using: .utf8)!
        let ann = try JSONDecoder().decode(GitAnnotation.self, from: json)
        XCTAssertEqual(ann.summary, "Just a note")
        XCTAssertNil(ann.risk)
        XCTAssertNil(ann.highlights)
    }

    func testInvalidRiskRejected() {
        let json = #"{"risk":"catastrophic"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GitAnnotation.self, from: json))
    }

    func testRiskLevelRawValues() {
        XCTAssertEqual(RiskLevel.medium.rawValue, "medium")
        XCTAssertEqual(RiskLevel(rawValue: "high"), .high)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitAnnotationTests`
Expected: FAIL — `cannot find 'GitAnnotation' in scope`.

- [ ] **Step 3: Add the models**

In `Sources/CarelessWhisper/Server/WidgetModels.swift`, add at the end of the file:

```swift
// MARK: - Git overlay annotation

/// Agent-assessed risk level for the persistent git overlay's annotation zone.
enum RiskLevel: String, Codable, Equatable {
    case low, medium, high
}

/// Agent-provided enhancement for the persistent git overlay: a short change summary,
/// an optional risk level, and optional highlight/warning lines. All fields optional.
struct GitAnnotation: Codable, Equatable {
    var summary: String?
    var risk: RiskLevel?
    var highlights: [String]?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GitAnnotationTests`
Expected: PASS (all 4 methods). Note: the invalid-risk case throws because `RiskLevel` is a `RawRepresentable` `Codable` enum — an unknown raw value fails decoding.

- [ ] **Step 5: Commit**

```bash
git add Sources/CarelessWhisper/Server/WidgetModels.swift Tests/CarelessWhisperTests/GitAnnotationTests.swift
git commit -m "feat: add GitAnnotation and RiskLevel models"
```

---

### Task 8: `GitOverlayExpandedView` + `GitAnnotationView`

**Files:**
- Create: `Sources/CarelessWhisper/UI/GitOverlayExpandedView.swift`

This view reads from `AppState`, so it depends on properties added in Task 9 (`gitOverlayDiffScope`, `gitOverlayAnnotation`, `DiffScope`, plus toggle/close actions). To keep this task self-contained and compilable, it takes plain inputs/closures rather than reaching into `AppState` directly; Task 11 wires it up.

- [ ] **Step 1: Create the expanded view and annotation view**

Create `Sources/CarelessWhisper/UI/GitOverlayExpandedView.swift`:

```swift
import SwiftUI

/// Which diff scope the expanded overlay is showing.
enum DiffScope: String { case branch, working }

/// Expanded state of the persistent git overlay: diffstat header + Tests/Functional/Other
/// breakdown + the reused (trimmed) GitContextView + the agent annotation zone.
struct GitOverlayExpandedView: View {
    let context: GitContext
    let scope: DiffScope
    let annotation: GitAnnotation?
    let onToggleScope: (DiffScope) -> Void
    let onCollapse: () -> Void
    let onClose: () -> Void

    /// The active scope's stats. Falls back to working when branch stats are absent
    /// (e.g. on the default branch).
    private var activeScope: DiffStatScope {
        guard let stats = context.diffStats else { return DiffStatScope() }
        switch scope {
        case .working: return stats.working
        case .branch:  return stats.branch ?? stats.working
        }
    }

    private var branchScopeAvailable: Bool { context.diffStats?.branch != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DiffStatHeaderView(scope: activeScope)
            TestFunctionalBreakdownView(scope: activeScope)
            Divider().overlay(Color.white.opacity(0.1))
            GitContextView(context: context, showDiffPreviews: false)
            if let annotation, hasContent(annotation) {
                GitAnnotationView(annotation: annotation)
            }
        }
        .padding(13)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.157, green: 0.165, blue: 0.212))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            Text(context.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98))
                .lineLimit(1)
            Spacer()
            if branchScopeAvailable {
                scopeToggle
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var scopeToggle: some View {
        HStack(spacing: 0) {
            segment("Branch", .branch)
            segment("Working", .working)
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.18)))
    }

    private func segment(_ label: String, _ value: DiffScope) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(scope == value ? Color(red: 0.74, green: 0.58, blue: 0.98) : .clear)
            .foregroundStyle(scope == value ? Color.black.opacity(0.85) : .white.opacity(0.45))
            .contentShape(Rectangle())
            .onTapGesture { onToggleScope(value) }
    }

    private func hasContent(_ a: GitAnnotation) -> Bool {
        (a.summary?.isEmpty == false) || a.risk != nil || (a.highlights?.isEmpty == false)
    }
}

/// The "+A −R · N files" line plus the 5-cell ratio bar (expanded header).
private struct DiffStatHeaderView: View {
    let scope: DiffStatScope

    var body: some View {
        let t = scope.total
        let denom = t.added + t.removed
        let green = denom > 0 ? max(t.added > 0 ? 1 : 0, Int((Double(t.added) / Double(denom) * 10).rounded())) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("+\(t.added)").foregroundStyle(.green)
                Text("−\(t.removed)").foregroundStyle(.red)
                Text("· \(t.files) file\(t.files == 1 ? "" : "s")").foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(denom == 0 ? Color.white.opacity(0.18) : (i < green ? .green : .red))
                        .frame(width: 11, height: 8)
                }
            }
        }
    }
}

/// Three proportional bars: Functional / Tests / Other, each with its own +/− counts.
private struct TestFunctionalBreakdownView: View {
    let scope: DiffStatScope

    var body: some View {
        let maxTotal = max(1, [scope.functional, scope.test, scope.other]
            .map { $0.added + $0.removed }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("TESTS vs FUNCTIONAL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            bar("Functional", scope.functional, .cyan, maxTotal)
            bar("Tests", scope.test, Color(red: 0.74, green: 0.58, blue: 0.98), maxTotal)
            bar("Other", scope.other, .orange, maxTotal)
        }
    }

    private func bar(_ label: String, _ count: LineCount, _ color: Color, _ maxTotal: Int) -> some View {
        let value = count.added + count.removed
        let frac = CGFloat(value) / CGFloat(maxTotal)
        return HStack(spacing: 7) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.8))
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 7)
            Text("+\(count.added) −\(count.removed)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 70, alignment: .trailing)
        }
    }
}

/// Agent annotation zone: risk badge + summary + highlight lines. Purple-bordered.
struct GitAnnotationView: View {
    let annotation: GitAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("◆ AGENT SUMMARY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98))
                Spacer()
                if let risk = annotation.risk {
                    Text("RISK: \(risk.rawValue.uppercased())")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(riskColor(risk).opacity(0.18))
                        .foregroundStyle(riskColor(risk))
                        .clipShape(Capsule())
                }
            }
            if let summary = annotation.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(annotation.highlights ?? [], id: \.self) { line in
                Text("⚠ \(line)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.74, green: 0.58, blue: 0.98).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(red: 0.74, green: 0.58, blue: 0.98), lineWidth: 1)
        )
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/CarelessWhisper/UI/GitOverlayExpandedView.swift
git commit -m "feat: add GitOverlayExpandedView with breakdown and annotation zone"
```

---

### Task 9: AppState — new state + annotation clear-on-branch-change

**Files:**
- Modify: `Sources/CarelessWhisper/App/AppState.swift`

- [ ] **Step 1: Add published/stored state**

In `AppState.swift`, after the existing `@Published var overlayDualColumn: Bool = false` (line 32), add:

```swift
    @Published var gitOverlayExpanded: Bool = false
    @Published var gitOverlayDiffScope: DiffScope = .branch
    @Published var gitOverlayAnnotation: GitAnnotation?
```

After the existing `@AppStorage("agentOverlayEnabled") ...` (line 71), add:

```swift
    @AppStorage("persistentGitOverlayEnabled") var persistentGitOverlayEnabled: Bool = false
```

- [ ] **Step 2: Track the last repo/branch for annotation clearing**

Near the other private stored vars (around line 56-61, where `recordingStartTime` etc. live), add:

```swift
    private var lastAnnotatedRepoBranch: String?
```

- [ ] **Step 3: Clear the annotation when repo/branch changes**

In `pollGitContext()` (line 294), find the completion block that assigns `gitContext`:

```swift
        Task { [weak self] in
            let context = await GitContextService.detect(terminalPID: pid, terminalBundleID: bundleID)
            await MainActor.run {
                self?.gitContext = context
            }
        }
```

Replace the `await MainActor.run { ... }` body with:

```swift
            await MainActor.run {
                guard let self else { return }
                let newKey = context.map { "\($0.repoName)#\($0.branch)" }
                if newKey != self.lastAnnotatedRepoBranch {
                    self.gitOverlayAnnotation = nil
                    self.lastAnnotatedRepoBranch = newKey
                }
                self.gitContext = context
            }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Builds cleanly. (`DiffScope` and `GitAnnotation` resolve from Tasks 8 and 7.)

- [ ] **Step 5: Commit**

```bash
git add Sources/CarelessWhisper/App/AppState.swift
git commit -m "feat: add persistent git overlay state and annotation clear-on-branch-change"
```

---

### Task 10: `WindowTrackingOverlayController` + pure coordinate helper

**Files:**
- Create: `Sources/CarelessWhisper/UI/WindowTrackingOverlay.swift`
- Test: `Tests/CarelessWhisperTests/WindowFramePositioningTests.swift`

- [ ] **Step 1: Write the failing test for the coordinate helper**

Create `Tests/CarelessWhisperTests/WindowFramePositioningTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import CarelessWhisper

final class WindowFramePositioningTests: XCTestCase {
    // AX coords: origin top-left, y grows downward. Cocoa: origin bottom-left, y grows up.
    func testTopRightConversionOnPrimaryScreen() {
        // Window at AX (100, 50), size 800x600, primary screen height 1000.
        // Top-right X = 100 + 800 = 900. Top edge AX y = 50 → Cocoa y = 1000 - 50 = 950.
        let p = WindowFramePositioning.windowTopRightInCocoa(
            axOrigin: CGPoint(x: 100, y: 50),
            axSize: CGSize(width: 800, height: 600),
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(p.x, 900, accuracy: 0.001)
        XCTAssertEqual(p.y, 950, accuracy: 0.001)
    }

    func testPanelOriginInsetsInsideWindow() {
        // Given the window's top-right Cocoa point, a panel of width 200/height 120 inset 8px
        // sits with its right edge 8px left of the window's right edge, top 8px below the top.
        let origin = WindowFramePositioning.panelOrigin(
            windowTopRightCocoa: CGPoint(x: 900, y: 950),
            panelSize: CGSize(width: 200, height: 120),
            inset: 8
        )
        XCTAssertEqual(origin.x, 900 - 8 - 200, accuracy: 0.001) // 692
        XCTAssertEqual(origin.y, 950 - 8 - 120, accuracy: 0.001) // 822
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WindowFramePositioningTests`
Expected: FAIL — `cannot find 'WindowFramePositioning' in scope`.

- [ ] **Step 3: Create the controller file with the pure helper + AX logic**

Create `Sources/CarelessWhisper/UI/WindowTrackingOverlay.swift`:

```swift
import SwiftUI
import AppKit
import ApplicationServices
import Combine
import os

/// Pure coordinate math for positioning the overlay relative to a terminal window.
/// Separated out so it can be unit-tested without AppKit/AX.
enum WindowFramePositioning {
    /// Converts an AX window frame (top-left origin, y-down, global coords) to the Cocoa
    /// (bottom-left origin) coordinate of the window's TOP-RIGHT corner.
    static func windowTopRightInCocoa(axOrigin: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: axOrigin.x + axSize.width,
                y: primaryScreenHeight - axOrigin.y)
    }

    /// Bottom-left origin for a panel of `panelSize` pinned `inset` points inside the window's
    /// top-right corner.
    static func panelOrigin(windowTopRightCocoa: CGPoint, panelSize: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(x: windowTopRightCocoa.x - inset - panelSize.width,
                y: windowTopRightCocoa.y - inset - panelSize.height)
    }
}

/// Floating panel that pins the persistent git overlay to the focused terminal window's
/// upper-right corner. Reuses `SizeObservingHostingView` for content-driven sizing.
@MainActor
final class WindowTrackingOverlayController {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "GitOverlay")
    private var panel: NSPanel?
    private var hostingView: SizeObservingHostingView<AnyView>?
    private weak var appState: AppState?

    private static let inset: CGFloat = 8

    func show(appState: AppState) {
        self.appState = appState
        guard panel == nil else { return }

        let content = AnyView(PersistentGitOverlayView().environmentObject(appState))
        let hosting = SizeObservingHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        hosting.onIntrinsicSizeInvalidated = { [weak self] in
            DispatchQueue.main.async { self?.reposition() }
        }

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
        DispatchQueue.main.async { [weak self] in self?.reposition() }
        logger.notice("Persistent git overlay shown")
    }

    func dismiss() {
        hostingView?.onIntrinsicSizeInvalidated = nil
        hostingView = nil
        panel?.close()
        panel = nil
        logger.notice("Persistent git overlay dismissed")
    }

    var isVisible: Bool { panel != nil }

    /// Repositions the panel to the focused terminal window's upper-right corner.
    /// Falls back to the screen's upper-right when no AX frame is available.
    func reposition() {
        guard let panel, let hostingView else { return }
        let size = hostingView.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }

        if let pid = appState?.lastPolledTerminalPIDForOverlay,
           let frame = focusedWindowAXFrame(pid: pid),
           let primaryHeight = NSScreen.screens.first?.frame.height {
            let topRight = WindowFramePositioning.windowTopRightInCocoa(
                axOrigin: frame.origin, axSize: frame.size, primaryScreenHeight: primaryHeight)
            let origin = WindowFramePositioning.panelOrigin(
                windowTopRightCocoa: topRight, panelSize: size, inset: Self.inset)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let origin = CGPoint(x: vf.maxX - Self.inset - size.width,
                                 y: vf.maxY - Self.inset - size.height)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    /// Reads the focused window's frame (AX coords) for the given app PID.
    private func focusedWindowAXFrame(pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let windowElement = window as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// SwiftUI content for the persistent overlay: pill when collapsed, expanded view otherwise.
private struct PersistentGitOverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let context = appState.gitContext {
            if appState.gitOverlayExpanded {
                GitOverlayExpandedView(
                    context: context,
                    scope: appState.gitOverlayDiffScope,
                    annotation: appState.gitOverlayAnnotation,
                    onToggleScope: { appState.gitOverlayDiffScope = $0 },
                    onCollapse: { appState.gitOverlayExpanded = false },
                    onClose: { appState.persistentGitOverlayEnabled = false }
                )
            } else {
                DiffStatPill(
                    branch: context.branch,
                    scope: pillScope(context),
                    onTap: { appState.gitOverlayExpanded = true }
                )
            }
        } else {
            EmptyView()
        }
    }

    private func pillScope(_ context: GitContext) -> DiffStatScope {
        guard let stats = context.diffStats else { return DiffStatScope() }
        switch appState.gitOverlayDiffScope {
        case .working: return stats.working
        case .branch:  return stats.branch ?? stats.working
        }
    }
}
```

- [ ] **Step 4: Expose the terminal PID for the overlay**

The controller reads `appState.lastPolledTerminalPIDForOverlay`, but the existing
`lastPolledTerminalPID` is `private`. In `AppState.swift`, add a public computed accessor.
Find the private declaration of `lastPolledTerminalPID` (search for `lastPolledTerminalPID`), and add near it:

```swift
    /// Read-only access to the last detected terminal PID, for window-tracking overlays.
    var lastPolledTerminalPIDForOverlay: pid_t? { lastPolledTerminalPID }
```

- [ ] **Step 5: Run the helper test**

Run: `swift test --filter WindowFramePositioningTests`
Expected: PASS (both methods).

- [ ] **Step 6: Build the whole package**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 7: Commit**

```bash
git add Sources/CarelessWhisper/UI/WindowTrackingOverlay.swift Sources/CarelessWhisper/App/AppState.swift Tests/CarelessWhisperTests/WindowFramePositioningTests.swift
git commit -m "feat: add WindowTrackingOverlayController with AX window-frame positioning"
```

---

### Task 11: Wire the overlay lifecycle into AppState

**Files:**
- Modify: `Sources/CarelessWhisper/App/AppState.swift`

- [ ] **Step 1: Own the controller and observe enable/git/expansion**

In `AppState.swift`, near `private let overlayController = OverlayController()` (line 52), add:

```swift
    private let gitOverlayController = WindowTrackingOverlayController()
    private var gitOverlayCancellables: Set<AnyCancellable> = []
```

- [ ] **Step 2: Add a visibility updater and reposition driver**

Add these methods to `AppState` (place them near `updateOverlayVisibility()` around line 325):

```swift
    /// Shows/hides the persistent git overlay based on the toggle + current git context.
    func updateGitOverlayVisibility() {
        let shouldShow = persistentGitOverlayEnabled && gitContext != nil
        if shouldShow {
            gitOverlayController.show(appState: self)
            gitOverlayController.reposition()
        } else {
            gitOverlayController.dismiss()
        }
    }

    /// Subscribes the persistent git overlay to the state that drives its visibility/position.
    /// Call once during setup.
    func startGitOverlayObservers() {
        // Visibility reacts to the toggle, git context presence, and expansion changes.
        Publishers.CombineLatest4($persistentGitOverlayEnabled, $gitContext, $gitOverlayExpanded, $gitOverlayAnnotation)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateGitOverlayVisibility()
            }
            .store(in: &gitOverlayCancellables)

        // Reposition when the user switches apps/windows (terminal moved/activated).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.gitOverlayController.reposition() }
        }
    }
```

Note: `$persistentGitOverlayEnabled` is published because `@AppStorage` properties on an
`ObservableObject` emit through `objectWillChange`; `CombineLatest4` on the `@Published`
wrappers here works because all four are `@Published`/`@AppStorage`-backed projected values.
If the compiler rejects `$persistentGitOverlayEnabled` (AppStorage's `$` projection isn't a
Combine publisher in some toolchains), fall back to driving visibility from the menu/settings action in Task 13 plus
the `$gitContext`/`$gitOverlayExpanded`/`$gitOverlayAnnotation` triple:

```swift
        Publishers.CombineLatest3($gitContext, $gitOverlayExpanded, $gitOverlayAnnotation)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateGitOverlayVisibility() }
            .store(in: &gitOverlayCancellables)
```

- [ ] **Step 3: Reposition on each git poll**

In `pollGitContext()`, inside the `await MainActor.run { ... }` block edited in Task 9, after
`self.gitContext = context`, add:

```swift
                self.gitOverlayController.reposition()
```

- [ ] **Step 4: Call `startGitOverlayObservers()` during setup**

Find where `startGitPolling()` is called during AppState setup (line 152). Add immediately after it:

```swift
        startGitOverlayObservers()
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Builds cleanly. If `$persistentGitOverlayEnabled` fails to compile, switch to the
`CombineLatest3` fallback shown in Step 2.

- [ ] **Step 6: Run tests (regression)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CarelessWhisper/App/AppState.swift
git commit -m "feat: wire persistent git overlay lifecycle into AppState"
```

---

### Task 12: OverlayServer annotate endpoints + AppState wiring

**Files:**
- Modify: `Sources/CarelessWhisper/Server/OverlayServer.swift`
- Modify: `Sources/CarelessWhisper/App/AppState.swift`

- [ ] **Step 1: Add callbacks to OverlayServer**

In `OverlayServer.swift`, near the other callbacks (lines 20-24), add:

```swift
    var onSetGitAnnotation: ((GitAnnotation) -> Void)?
    var onClearGitAnnotation: (() -> Void)?
```

- [ ] **Step 2: Add routes**

In `handleRequest`'s `switch (request.method, request.path)` (line 114), add these cases
before the `default:` case:

```swift
        case ("POST", "/git-overlay/annotate"):
            return await handleGitAnnotate(request)

        case ("POST", "/git-overlay/annotate/clear"):
            await MainActor.run { onClearGitAnnotation?() }
            return HTTPResponse(status: 200, body: ["ok": true])
```

- [ ] **Step 3: Add the handler**

Add this method near `handleDismissWidget` (around line 215):

```swift
    private func handleGitAnnotate(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse(status: 400, body: ["error": "Missing request body"])
        }
        guard let annotation = try? JSONDecoder().decode(GitAnnotation.self, from: body) else {
            return HTTPResponse(status: 400, body: ["error": "Invalid JSON — expected {\"summary\":\"...\",\"risk\":\"low|medium|high\",\"highlights\":[\"...\"]}"])
        }
        await MainActor.run { onSetGitAnnotation?(annotation) }
        return HTTPResponse(status: 200, body: ["ok": true])
    }
```

- [ ] **Step 4: Wire the callbacks in AppState**

In `AppState.startOverlayServer()` (line 185), after the existing `overlayServer.onClearWidgets = { ... }` block (around line 199-201), add:

```swift
        overlayServer.onSetGitAnnotation = { [weak self] annotation in
            self?.gitOverlayAnnotation = annotation
        }
        overlayServer.onClearGitAnnotation = { [weak self] in
            self?.gitOverlayAnnotation = nil
        }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 6: Manual endpoint smoke test (after a build/run)**

This is verified end-to-end in Task 15. For now, confirm the build only.

- [ ] **Step 7: Commit**

```bash
git add Sources/CarelessWhisper/Server/OverlayServer.swift Sources/CarelessWhisper/App/AppState.swift
git commit -m "feat: add /git-overlay/annotate endpoint and wire to AppState"
```

---

### Task 13: StatusBar toggle + Settings section

**Files:**
- Modify: `Sources/CarelessWhisper/App/StatusBarController.swift`
- Modify: `Sources/CarelessWhisper/UI/SettingsView.swift`

- [ ] **Step 1: Add a menu item field**

In `StatusBarController.swift`, near the other menu-item fields (lines 15-18), add:

```swift
    private var gitOverlayMenuItem: NSMenuItem?
```

- [ ] **Step 2: Add the menu item to the menu**

In the menu-building code, after the record toggle's separator (line 60, `menu.addItem(.separator())` following the record item), add:

```swift
        let gitOverlayItem = NSMenuItem(title: "Show Git Overlay", action: #selector(toggleGitOverlay), keyEquivalent: "")
        gitOverlayItem.target = self
        gitOverlayItem.state = appState.persistentGitOverlayEnabled ? .on : .off
        menu.addItem(gitOverlayItem)
        gitOverlayMenuItem = gitOverlayItem

        menu.addItem(.separator())
```

(`appState` is the controller's reference to the shared `AppState`; match how `toggleRecording`'s item accesses it. If the menu is built before `appState` is assigned, set the initial `.state` in the menu-delegate update method instead — see Step 4.)

- [ ] **Step 3: Add the action**

Near `@objc private func toggleRecording()` (line 164), add:

```swift
    @objc private func toggleGitOverlay() {
        appState.persistentGitOverlayEnabled.toggle()
        gitOverlayMenuItem?.state = appState.persistentGitOverlayEnabled ? .on : .off
    }
```

- [ ] **Step 4: Keep the checkmark in sync when the menu opens**

In the `NSMenuDelegate` `menuWillOpen`/`menuNeedsUpdate` method (the controller sets
`menu.delegate = self` at line 30; find the existing delegate update method that refreshes
titles), add:

```swift
        gitOverlayMenuItem?.state = appState.persistentGitOverlayEnabled ? .on : .off
```

- [ ] **Step 5: Add the Settings section**

In `SettingsView.swift`, add `gitOverlaySection` to the body's section list (line 19-24),
after `agentIntegrationSection`:

```swift
                agentIntegrationSection
                gitOverlaySection
                permissionsSection
```

Then add the section definition near `agentIntegrationSection` (line 169):

```swift
    // MARK: - Git Overlay

    private var gitOverlaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Git Overlay", systemImage: "chart.bar.xaxis")
                .font(.headline)

            Toggle("Show persistent git overlay", isOn: $appState.persistentGitOverlayEnabled)

            Text("Pins a live diffstat to the focused terminal window's upper-right corner. Click it to expand. Requires Accessibility permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: Builds cleanly. If `$appState.persistentGitOverlayEnabled` doesn't bind (AppStorage),
use the same explicit `Binding` pattern the agent toggle uses (lines 174-183), calling
`appState.persistentGitOverlayEnabled = newValue` in the setter.

- [ ] **Step 7: Commit**

```bash
git add Sources/CarelessWhisper/App/StatusBarController.swift Sources/CarelessWhisper/UI/SettingsView.swift
git commit -m "feat: add git overlay toggle to menu bar and settings"
```

---

### Task 14: Skill — `git-annotate` CLI subcommand + SKILL.md docs

**Files:**
- Modify: `Sources/CarelessWhisper/Server/AgentSkillInstaller.swift`

- [ ] **Step 1: Add the `git-annotate` case to the CLI script**

In `AgentSkillInstaller.swift`, in `cliScriptContent`, find the `health)` case (lines 367-369)
and add a new case immediately before it:

```bash
      git-annotate)
        INPUT="${1:--}"
        curl -sf --max-time 5 -X POST "$BASE/git-overlay/annotate" \\
          -H "$AUTH" -H "Content-Type: application/json" -d "@$INPUT"
        ;;
```

Then update the usage line in the `*)` default case (line 371) to include it:

```bash
        echo "Usage: overlay-cli {show|update|set-params|dismiss|git-annotate|health}" >&2
```

And update the header comment block (lines 308-312) to document it, adding after the `dismiss` line:

```bash
    #   git-annotate [file.json] — annotate the persistent git overlay (summary/risk/highlights)
```

- [ ] **Step 2: Add a SKILL.md section**

In `skillContent`, add a new documented section (place it near the end, before the final
guidelines/closing of the string — e.g. after the section that ends around line 292). Insert:

```markdown
    ## Git Overlay Annotation

    If the user has enabled the persistent Git Overlay (a live diffstat pinned to their
    terminal window), you can enrich its expanded view with a short change summary and a
    risk assessment. Do this after making substantial changes, so the user gets a glanceable
    take on what changed and how risky it is.

    ```bash
    cat > /tmp/git-annotate.json <<'JSON'
    {
      "summary": "Refactors auth into a service; adds token refresh and tests.",
      "risk": "medium",
      "highlights": ["Changes session-expiry handling", "Touches login redirect"]
    }
    JSON
    ~/.claude/skills/overlay/overlay-cli git-annotate /tmp/git-annotate.json
    ```

    Fields (all optional): `summary` (one or two sentences), `risk` (`low` | `medium` | `high`),
    `highlights` (array of short ⚠ warning lines). The annotation auto-clears when the branch
    or repo changes. To clear it manually, POST to `/git-overlay/annotate/clear`.
```

- [ ] **Step 3: Build (the content-hash bumps automatically)**

Run: `swift build`
Expected: Builds cleanly. Because `installedVersion` hashes `skillContent + cliScriptContent +
demoScriptContent`, changing these strings changes the hash, so `installIfNeeded()` will
re-install the skill on next launch (and the Settings "skill outdated" state will prompt it).

- [ ] **Step 4: Commit**

```bash
git add Sources/CarelessWhisper/Server/AgentSkillInstaller.swift
git commit -m "feat: document git-annotate in overlay skill and CLI"
```

---

### Task 15: Final integration build, test run, and manual smoke check

**Files:** none (verification only)

- [ ] **Step 1: Full clean build**

Run: `swift build`
Expected: Builds with no errors or warnings introduced by this work.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: All tests pass, including the four new test files
(`ChangeClassifierTests`, `DiffStatsTests`, `GitAnnotationTests`, `WindowFramePositioningTests`).

- [ ] **Step 3: Bundle and launch the app**

Run: `./scripts/bundle.sh && open "./build/Careless Whisper.app"`
Expected: App launches as a menu-bar accessory.

- [ ] **Step 4: Manual smoke checklist**

In a terminal sitting in this git repo (with uncommitted changes on a non-default branch):

1. Menu bar → **Show Git Overlay** (checkmark turns on). A small diffstat pill appears in the
   **upper-right of the terminal window**.
2. Move/resize the terminal window → the pill tracks the window's upper-right corner.
3. Click the pill → it **expands** showing diffstat, Tests/Functional/Other bars, the reused git
   detail (commit, CI/PR, file sections; **no inline diff previews**), and toggling
   **Branch/Working** changes the numbers.
4. Click the **chevron** → collapses back to the pill. Click **✕** → overlay hides and the menu
   checkmark turns off.
5. With the overlay enabled, run the annotate command and confirm the purple agent zone appears
   with a `RISK` badge:

   ```bash
   cat > /tmp/git-annotate.json <<'JSON'
   {"summary":"Test annotation from smoke check.","risk":"low","highlights":["Just a test"]}
   JSON
   ~/.claude/skills/overlay/overlay-cli git-annotate /tmp/git-annotate.json
   ```

6. `git checkout` a different branch (or commit) → confirm the annotation **auto-clears**.
7. Confirm the **recording HUD** still works unchanged: hold the hotkey, speak, and verify its
   git column and diff previews render exactly as before (regression check on the extraction).

- [ ] **Step 5: Final commit (if any manual fixes were needed)**

```bash
git add -A
git commit -m "fix: address persistent git overlay smoke-test findings"
```

(Skip if no fixes were necessary.)

---

## Self-Review Notes

- **Spec coverage:** Diff scope (both, switchable) → Tasks 2/8/9; window anchoring → Task 10;
  collapsed pill (option B) → Task 6; agent annotation (typed endpoint, native render) →
  Tasks 7/8/12/14; three-bucket test classification → Tasks 1/8; trimmed expanded view
  (`showDiffPreviews: false`) → Tasks 5/8; reuse of `GitContextView`/sizing/polling/server/skill
  → Tasks 4/5/9/11/12/14; toggle (menu + settings) → Task 13; tests → Tasks 1/2/7/10/15.
- **Type consistency:** `DiffStatScope`/`LineCount`/`DiffStats` (Task 2) used identically in
  Tasks 3/6/8/10; `GitAnnotation`/`RiskLevel` (Task 7) used in Tasks 8/12; `DiffScope` (Task 8)
  used in Tasks 9/10; `lastPolledTerminalPIDForOverlay` defined and consumed in Task 10;
  `WindowFramePositioning` defined and tested in Task 10.
- **Known limitation (documented in spec):** untracked files are not counted in the working
  scope (`git diff --numstat HEAD` only sees tracked changes). Not addressed here by design.
