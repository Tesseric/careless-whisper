# Persistent Git Status Overlay — Design

**Date:** 2026-06-13
**Status:** Approved design, ready for implementation planning

## Summary

Add a second, **persistent** git-status overlay that the user can toggle on. Unlike the
existing recording HUD (screen-anchored, visible only while recording), this overlay:

- Pins to the **upper-right corner of the focused terminal window** and tracks it as the
  window moves/resizes (via Accessibility window-frame lookup).
- Is **always visible** while enabled and a tracked terminal window is frontmost.
- **Collapsed** by default: a small GitHub-style diffstat pill — `+added −removed · N files`
  plus a red/green ratio bar.
- **Expands on click** into a detailed view: diffstat header, a Tests/Functional/Other line
  breakdown, the reused git detail view (commit, CI/PR, file sections), and an agent-filled
  annotation zone (change summary + risk badge). Click again to collapse; close button hides it.
- Can be **enhanced by the coding agent** via a new typed HTTP endpoint, and the agent is
  encouraged to do so through an updated overlay skill.

The overarching constraint, set by the user: **share code with the existing git overlay
wherever possible.** This design extends and extracts existing components rather than
building a parallel implementation.

## Decisions (from brainstorming)

1. **Diff scope:** Both **Branch-vs-base (incl. uncommitted)** and **Working-tree (vs HEAD)**,
   switchable via a Branch/Working toggle in the expanded view. Default: Branch.
2. **Anchoring:** Follow the **focused terminal window**, pin to its upper-right corner.
3. **Collapsed look:** GitHub-style diffstat pill (number line + 5-square red/green ratio bar).
4. **Agent enhancement channel:** New typed endpoint `POST /git-overlay/annotate`,
   rendered natively in SwiftUI (not the HTML widget system).
5. **Test classification heuristics:** path-segment rule + filename suffix/prefix rule, plus a
   third **Other** bucket for docs/config/lockfiles. (Fixtures/snapshots/mocks are *not* a
   separate rule; they fall out of the path/filename rules or land in functional/other.)
6. **Expanded lower section:** Reuse the existing git detail view **trimmed** — keep commit,
   CI/PR, and file sections; **drop the inline multi-line diff previews** to keep it shorter.

## Reuse Map

### Reused as-is or extended (no reimplementation)
| Existing | File | How it's used |
|---|---|---|
| `GitContext` model | `Git/GitContextService.swift` | Extended with `diffStats: DiffStats?` |
| `GitContextService` detection (CWD/Kitty/`git`/`gh`, `run`/`git` helpers) | `Git/GitContextService.swift` | Add ~2 `git --numstat` calls inside existing `detectSync` |
| `GitContextView`, `GitStatusView`, `CIBadgeView`, `PRBadgeView`, `DiffPreviewView`, `PulseModifier` | `UI/RecordingOverlay.swift` (currently `private`) | **Extracted** to `UI/GitContextView.swift`, made `internal`, rendered by both overlays |
| `SizeObservingHostingView` + resize-to-content logic | `UI/RecordingOverlay.swift` | **Extracted** to `UI/OverlayPanelSupport.swift`, shared by both controllers |
| Git polling (`pollGitContext`, 10s timer, activation observer, `lastPolledTerminalPID`) | `App/AppState.swift` | Persistent overlay rides the same `$gitContext` publisher — **no second polling loop** |
| `OverlayServer` (bearer-token HTTP) | `Server/OverlayServer.swift` | Extended with `/git-overlay/annotate` routes |
| `AgentSkillInstaller` (skill install + content-hash versioning) | `Server/AgentSkillInstaller.swift` | Skill content + CLI extended with `git-annotate`; hash auto-bumps → auto-reinstall |

The existing recording HUD must render **identically** after the extraction — only access
level changes (`private` → `internal`) and one new optional parameter with a default.

### New units (small, focused, independently testable)
| New | File | Purpose |
|---|---|---|
| `ChangeClassifier` | `Git/ChangeClassifier.swift` | Pure path → `ChangeBucket` (test/functional/other) |
| `DiffStats` + numstat parser | `Git/DiffStats.swift` | Per-bucket added/removed/files for working + branch scopes |
| `DiffStatPill` | `UI/DiffStatPill.swift` | Collapsed pill (option B look) |
| `GitOverlayExpandedView` | `UI/GitOverlayExpandedView.swift` | Expanded layout, wraps reused `GitContextView` |
| `GitAnnotationView` | `UI/GitAnnotationView.swift` | Renders agent summary + risk badge + highlights |
| `WindowTrackingOverlayController` | `UI/WindowTrackingOverlay.swift` | Own `NSPanel`, pins to AX terminal-window frame |
| `GitAnnotation` model + endpoint wiring | `Server/WidgetModels.swift` / `Server/OverlayServer.swift` | Typed annotation transport |

## Components & Data Flow

### 1. Data layer — `DiffStats` (new) + `GitContext` extension

```
enum ChangeBucket { case functional, test, other }

struct LineCount { let added: Int; let removed: Int; let files: Int }   // zero-initable, +=

struct DiffStatScope {
    let functional: LineCount
    let test: LineCount
    let other: LineCount
    var total: LineCount { functional + test + other }   // convenience
}

struct DiffStats {
    let working: DiffStatScope          // git diff --numstat HEAD   (staged+unstaged, tracked)
    let branch: DiffStatScope?          // git diff --numstat <merge-base>; nil on main/master
}
```

`GitContext` gains one field: `let diffStats: DiffStats?`.

**Computation** (inside the existing `detectSync`, reusing `git`/`run`):
- Working: `git diff --numstat HEAD`
- Branch: reuse the `base` already computed by `parseBranchDiff` (`merge-base` vs main/master);
  `git diff --numstat <base>`. `nil` when on the default branch (matches existing behavior).

**Numstat parsing** is extracted into a pure function for testing:
`DiffStats.parseScope(numstat: String, classify: (String) -> ChangeBucket) -> DiffStatScope`.
Handles: tab-separated `added \t removed \t path`; binary files (`-\t-` → 0 added/0 removed but
still counts the file); rename forms (`a => b`, `dir/{a => b}/c`) — extract the final path for
classification. Best-effort: unparseable → that file skipped; whole-command failure → scope of zeros.

**Known limitation (documented, not blocking):** untracked new files don't appear in
`git diff --numstat HEAD`, so their lines aren't counted in the working scope. The file-count
shown comes from numstat (tracked changes). Acceptable for MVP; can be revisited with
`--intent-to-add` if needed.

### 2. `ChangeClassifier` (new, pure)

`static func bucket(for path: String) -> ChangeBucket`, evaluated in order:

1. **Test** if either:
   - **Path segment** (case-insensitive) is one of: `tests`, `test`, `spec`, `__tests__`, `e2e`.
   - **Filename** matches a test pattern: `*Test.<ext>`, `*Tests.<ext>`, `*_test.<ext>`,
     `*.test.<ext>`, `*.spec.<ext>`, `test_*.py`, `*_spec.rb`.
2. **Other** if non-code: extension in `{md, markdown, txt, rst, lock, yml, yaml, toml, cfg,
   ini, plist, gitignore, gitattributes}` **or** filename in `{Package.resolved, Dockerfile,
   Makefile, LICENSE, .gitignore}` (list lives in one place, easy to tweak). `json` is treated
   as functional by default (too often source/config of record) — revisit if noisy.
3. **Functional** otherwise.

Ordering matters: a `.json` fixture under `__tests__/` is **test** (rule 1 wins over rule 2).

### 3. Rendering — extraction + new views

**Extraction (`UI/GitContextView.swift`):** move `GitContextView` and its private
sub-views out of `RecordingOverlay.swift`, change `private` → `internal`. Add:
`GitContextView(context:, showDiffPreviews: Bool = true)`. The recording HUD calls it with
the default (previews on); the persistent overlay passes `showDiffPreviews: false` (trimmed).

**Collapsed — `DiffStatPill`:** branch name header, `+A −R · N files`, a 5-cell ratio bar
colored by added/removed proportion. Tapping toggles `appState.gitOverlayExpanded`.

**Expanded — `GitOverlayExpandedView`** stacks:
1. Header: branch · `Branch | Working` toggle (`appState.gitOverlayDiffScope`) · collapse + close.
2. Diffstat line + ratio bar (driven by the selected scope).
3. **Tests / Functional / Other** — three proportional bars, each with its own `+/−` counts,
   from the selected scope's `DiffStatScope`.
4. Reused `GitContextView(context:, showDiffPreviews: false)` — commit, CI/PR, file sections, stash.
5. `GitAnnotationView` — agent zone (hidden when no annotation).

**`GitAnnotationView`:** purple-bordered card; risk badge (low=green, medium=yellow,
high=red), summary text, optional `highlights` lines (⚠ prefix). Hidden entirely when
`gitOverlayAnnotation == nil`.

### 4. `WindowTrackingOverlayController` (new)

Owns its own `NSPanel` configured like `OverlayController`'s
(`.nonactivatingPanel`/`.hudWindow`, `.floating`, clear background, `canJoinAllSpaces`),
hosting `DiffStatPill` or `GitOverlayExpandedView` (per `gitOverlayExpanded`) in the shared
`SizeObservingHostingView`.

**Positioning (AX):** reuse `AppState.lastPolledTerminalPID`.
`AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `kAXPositionAttribute` +
`kAXSizeAttribute`. Convert AX coordinates (top-left origin, y-flipped) to Cocoa screen
coordinates and pin the panel's **top-right** to the window's top-right, inset a few px inside.

**Tracking updates:** primary = AX observer on the focused window for
`kAXWindowMovedNotification` / `kAXWindowResizedNotification` / `kAXFocusedWindowChangedNotification`;
plus reposition on each git poll tick and on `didActivateApplication`. Fallback: a lightweight
timer only while the overlay is visible if AX observers prove unreliable for a given terminal.

**Fallback positioning:** if no AX frame is available (permission missing, or a terminal that
doesn't expose AX windows), pin to the **screen** upper-right corner and log it.

**Visibility:** shown when `persistentGitOverlayEnabled && gitContext != nil` **and** a tracked
terminal is frontmost; hidden when the user switches away from the terminal (the overlay is
conceptually attached to that window). Coexists with the recording HUD (different anchor);
overlap is possible but acceptable.

### 5. Agent annotation — endpoint + skill

**Model (`Server/WidgetModels.swift`):**
```
enum RiskLevel: String, Codable { case low, medium, high }
struct GitAnnotation: Codable, Equatable {
    var summary: String?
    var risk: RiskLevel?
    var highlights: [String]?
}
```

**Endpoints (`OverlayServer`, bearer auth reused):**
- `POST /git-overlay/annotate` — body is `GitAnnotation`; invalid `risk` → 400.
- `POST /git-overlay/annotate/clear` — clears it.
Wired via a new `onSetGitAnnotation` callback, mirroring existing `onSetWidgets`/`onUpsertWidget`.

**AppState:** `@Published var gitOverlayAnnotation: GitAnnotation?`. **Cleared automatically
when the repo or branch changes** (so a summary for one branch doesn't bleed into another),
detected in `pollGitContext` by comparing the new `gitContext.branch`/`repoName` to the prior.

**Skill (`AgentSkillInstaller`):** add a documented `git-annotate` command to `overlay-cli`
and a section to `SKILL.md` encouraging the agent to post a short change summary + risk
assessment after substantial edits. The SHA-256 content hash bumps automatically → existing
auto-reinstall path picks it up.

### 6. Toggle, settings, state wiring

- `@AppStorage("persistentGitOverlayEnabled") var persistentGitOverlayEnabled = false`
- `@Published var gitOverlayExpanded = false`
- `@Published var gitOverlayDiffScope: DiffScope = .branch`  (`enum DiffScope { case branch, working }`)
- `@Published var gitOverlayAnnotation: GitAnnotation?`
- **StatusBarController:** new checkable menu item "Show Git Overlay" toggling
  `persistentGitOverlayEnabled`.
- **SettingsView:** new "Git Overlay" section — enable toggle + one-line note that it follows
  the focused terminal window and needs Accessibility permission (already requested by the app).
- **AppState lifecycle:** observing `persistentGitOverlayEnabled` → create/start or
  tear down `WindowTrackingOverlayController`. Gated on accessibility permission (reuse
  existing `PermissionChecker`); if missing, the Settings note points the user to grant it.

## Error Handling

- Follows the existing convention: detection/parse paths return optionals and degrade
  (numstat failure → `diffStats == nil` → pill shows file counts only / dashes for lines).
- New throwing surface is minimal; the annotation endpoint validates and returns HTTP 400 on
  bad input, consistent with `OverlayServer`'s existing error responses.
- AX frame lookup failures fall back to the screen corner and log via a new `os.Logger`
  category `"GitOverlay"` under subsystem `com.carelesswhisper`.

## Testing (TDD)

- **`ChangeClassifierTests`** — table-driven: test dir paths, colocated `*_test`/`*.spec`
  filenames, docs/config → other, source → functional, and the ordering case (`__tests__/x.json`
  → test).
- **`DiffStatsTests`** — feed sample `--numstat` text (normal, binary `-\t-`, rename forms,
  paths with spaces) into the pure `parseScope`, assert per-bucket totals and file counts.
- **Annotation decoding** — valid payloads decode; invalid `risk` rejected.
- **Regression** — existing test suite stays green after the `GitContextView` extraction
  (compile + behavior unchanged for the recording HUD).

## Out of Scope (YAGNI)

- Counting untracked-file line additions in the working scope (documented limitation).
- Per-file expandable diffs in the persistent overlay (the recording HUD keeps previews).
- Persisting annotations across app restarts.
- Configurable corner (locked to upper-right of the terminal window per the requirement).

## Key Files

- `Sources/CarelessWhisper/Git/GitContextService.swift` — add numstat calls + `diffStats` field
- `Sources/CarelessWhisper/Git/ChangeClassifier.swift` — **new**
- `Sources/CarelessWhisper/Git/DiffStats.swift` — **new**
- `Sources/CarelessWhisper/UI/GitContextView.swift` — **new** (extracted from RecordingOverlay)
- `Sources/CarelessWhisper/UI/OverlayPanelSupport.swift` — **new** (extracted sizing helpers)
- `Sources/CarelessWhisper/UI/DiffStatPill.swift` — **new**
- `Sources/CarelessWhisper/UI/GitOverlayExpandedView.swift` — **new**
- `Sources/CarelessWhisper/UI/GitAnnotationView.swift` — **new**
- `Sources/CarelessWhisper/UI/WindowTrackingOverlay.swift` — **new**
- `Sources/CarelessWhisper/UI/RecordingOverlay.swift` — remove extracted views, call shared ones
- `Sources/CarelessWhisper/App/AppState.swift` — new state, overlay lifecycle, annotation clear-on-branch-change
- `Sources/CarelessWhisper/App/StatusBarController.swift` — toggle menu item
- `Sources/CarelessWhisper/UI/SettingsView.swift` — Git Overlay settings section
- `Sources/CarelessWhisper/Server/OverlayServer.swift` — annotate endpoints
- `Sources/CarelessWhisper/Server/WidgetModels.swift` — `GitAnnotation`, `RiskLevel`
- `Sources/CarelessWhisper/Server/AgentSkillInstaller.swift` — `git-annotate` CLI + SKILL.md
- `Tests/CarelessWhisperTests/ChangeClassifierTests.swift` — **new**
- `Tests/CarelessWhisperTests/DiffStatsTests.swift` — **new**
