import Foundation
import CryptoKit
import os

enum AgentSkillInstaller {
    private static let logger = Logger(subsystem: "com.carelesswhisper", category: "AgentSkillInstaller")

    private static var skillDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
            .appendingPathComponent("overlay")
    }

    private static var skillFileURL: URL {
        skillDirectoryURL.appendingPathComponent("SKILL.md")
    }

    private static var cliScriptURL: URL {
        skillDirectoryURL.appendingPathComponent("overlay-cli")
    }

    private static var demoScriptURL: URL {
        skillDirectoryURL.appendingPathComponent("demo.sh")
    }

    private static var versionFileURL: URL {
        skillDirectoryURL.appendingPathComponent(".version")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: skillFileURL.path)
    }

    /// SHA-256 hash (first 16 hex chars) of all skill content, used to detect when files need updating.
    static var contentHash: String {
        let combined = skillContent + cliScriptContent + demoScriptContent
        let hash = SHA256.hash(data: Data(combined.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the installed skill files match the current app version.
    static var isUpToDate: Bool {
        guard isInstalled,
              let installed = try? String(contentsOf: versionFileURL, encoding: .utf8) else {
            return false
        }
        return installed.trimmingCharacters(in: .whitespacesAndNewlines) == contentHash
    }

    /// Installs the skill only if it's missing or outdated.
    static func installIfNeeded() {
        guard !isUpToDate else {
            logger.info("Claude Code skill is up to date (\(contentHash))")
            return
        }
        install()
    }

    static func install() {
        let dir = skillDirectoryURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try skillContent.write(to: skillFileURL, atomically: true, encoding: .utf8)
            try cliScriptContent.write(to: cliScriptURL, atomically: true, encoding: .utf8)
            try demoScriptContent.write(to: demoScriptURL, atomically: true, encoding: .utf8)
            try contentHash.write(to: versionFileURL, atomically: true, encoding: .utf8)
            // Make scripts executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: cliScriptURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: demoScriptURL.path
            )
            logger.info("Installed Claude Code skill at \(skillFileURL.path) (version \(contentHash))")
        } catch {
            logger.error("Failed to install skill: \(error)")
        }
    }

    static func uninstall() {
        let dir = skillDirectoryURL
        do {
            try FileManager.default.removeItem(at: dir)
            logger.info("Uninstalled Claude Code skill")
        } catch {
            logger.warning("Failed to remove skill directory: \(error)")
        }
    }

    // MARK: - Skill Content

    private static let skillContent = """
    ---
    name: overlay
    description: Show rich HTML widgets in the Careless Whisper floating overlay. Use this to display build status, dashboards, questions, or visualizations to the user while they work.
    ---

    ## Careless Whisper Overlay API

    Push rich HTML content to a floating macOS overlay using the `overlay-cli` script (installed alongside this skill).

    ### CLI Usage

    All commands go through `~/.claude/skills/overlay/overlay-cli`. Once the user allows `Bash(~/.claude/skills/overlay/overlay-cli:*)`, all subsequent calls work without re-prompting.

    **IMPORTANT:** Always use the Write tool to create JSON files — NEVER use cat, echo, heredoc, or any Bash command to write files. The Write tool requires no user approval, keeping the workflow frictionless.

    **Show widgets** — replace all widgets and show the overlay.
    Step 1: Use the Write tool to write `{"widgets":[...]}` to `/tmp/overlay-widgets.json`
    Step 2: Run the CLI:
    ```bash
    ~/.claude/skills/overlay/overlay-cli show /tmp/overlay-widgets.json
    ```

    **Update one widget** — upsert a single widget by ID:
    Step 1: Use the Write tool to write `{"widget":{...}}` to `/tmp/overlay-widget.json`
    Step 2: Run the CLI:
    ```bash
    ~/.claude/skills/overlay/overlay-cli update /tmp/overlay-widget.json
    ```

    **Update widget params** — update dynamic values without rewriting the whole widget:
    Step 1: Use the Write tool to write `{"id":"widget-id","params":{"key":"value"}}` to `/tmp/overlay-params.json`
    Step 2: Run the CLI:
    ```bash
    ~/.claude/skills/overlay/overlay-cli set-params /tmp/overlay-params.json
    ```
    This updates the widget's parameters in-place via JavaScript injection — no flicker. See "Parameterized Widgets" below.

    **Dismiss** — clear all widgets or remove one by ID:
    ```bash
    ~/.claude/skills/overlay/overlay-cli dismiss
    ~/.claude/skills/overlay/overlay-cli dismiss my-widget-id
    ```

    **Health check** — verify the overlay server is running:
    ```bash
    ~/.claude/skills/overlay/overlay-cli health
    ```

    ### Widget Schema

    ```json
    {
      "id": "unique-id",
      "title": "Optional Title",
      "html": "<p>Any HTML content</p>",
      "priority": 0,
      "params": {"key": "value"},
      "template": "progress"
    }
    ```
    - `id`: Unique identifier. Namespace by agent (e.g., `claude:build`).
    - `title`: Optional header displayed above content.
    - `html`: HTML rendered in the overlay. Supports inline CSS and JS. Tags like `<iframe>`, `<object>`, `<embed>`, `<form>` are stripped. Not needed when using `template`.
    - `priority`: Sort order (lower = higher). Default 0.
    - `params`: Optional dictionary of named parameters. Values are substituted into `{{key}}` placeholders in the HTML template and can be updated live via `set-params`. Required when using `template`.
    - `template`: Optional template name. When set, the server generates the HTML from the template + params automatically. See "Pre-Built Templates" below.

    ### Pre-Built Templates

    Templates let you create rich widgets without writing HTML. Set `template` and `params` — the server generates the HTML. Live updates via `set-params` work just like raw HTML widgets.

    **Quick start — template vs raw HTML:**
    ```json
    // With template (compact):
    {"id":"claude:build","template":"progress","params":{"label":"Building","pct":"45%","status":"Compiling..."}}

    // Equivalent raw HTML (verbose):
    {"id":"claude:build","html":"<div style='...'><div style='width:45%;...'></div></div><p>Compiling...</p>","params":{"pct":"45%","status":"Compiling..."}}
    ```

    **Available templates:**

    #### `progress` — Progress bar with label
    Required params: `label`, `pct`, `status`
    All params are live-updatable via `set-params`.
    ```json
    {"id":"claude:build","template":"progress","title":"Build","params":{"label":"Compiling","pct":"60%","status":"Building module 3/5..."}}
    ```

    #### `steps` — Vertical pipeline/timeline
    Required params: `labels` (pipe-delimited), `statuses` (pipe-delimited: done/running/failed/pending/skipped)
    Optional: `details` (pipe-delimited). `statuses` and `details` are live-updatable.
    ```json
    {"id":"claude:pipeline","template":"steps","title":"Deploy","params":{"labels":"Build|Test|Package|Deploy","statuses":"done|done|running|pending","details":"1m 12s|247 passed|bundling...|"}}
    ```

    #### `metrics` — Grid of metric cards
    Required params: `values` (pipe-delimited), `labels` (pipe-delimited)
    `values` are live-updatable.
    ```json
    {"id":"claude:stats","template":"metrics","title":"Dashboard","params":{"values":"98%|1.2s|247|0","labels":"Tests Pass|Build Time|Commits|Failures"}}
    ```

    #### `table` — Data table
    Required params: `headers` (pipe-delimited), `rows` (pipe-delimited rows, comma-separated cells)
    Use `update` to replace the whole widget for new data.
    ```json
    {"id":"claude:deps","template":"table","title":"Dependencies","params":{"headers":"Package|Version|Status","rows":"SwiftWhisper,1.2.0,ok|HotKey,0.2.0,ok|Alamofire,5.9.0,outdated"}}
    ```

    #### `status-list` — Items with status badges
    Required params: `labels` (pipe-delimited), `statuses` (pipe-delimited: ok/running/warning/fail/skip)
    Optional: `details` (pipe-delimited). `statuses` and `details` are live-updatable.
    ```json
    {"id":"claude:checks","template":"status-list","title":"Checks","params":{"labels":"Lint|Types|Tests|Coverage","statuses":"ok|ok|running|pending","details":"No issues|0 errors|43/100|"}}
    ```

    #### `message` — Notification card
    Required params: `text`, `type` (info/success/warning/error)
    Optional: `detail`. `text` and `detail` are live-updatable.
    ```json
    {"id":"claude:msg","template":"message","params":{"text":"Build succeeded","type":"success","detail":"247 tests passed in 1.2s"}}
    ```

    #### `key-value` — Key-value pairs
    Required params: `keys` (pipe-delimited), `values` (pipe-delimited)
    Use `update` to replace the whole widget for new data.
    ```json
    {"id":"claude:info","template":"key-value","title":"Project","params":{"keys":"Branch|Commit|Swift|Platform","values":"main|a1b2c3d|5.9|macOS 14+"}}
    ```

    #### `bar-chart` — SVG bar chart
    Required params: `labels` (pipe-delimited), `values` (pipe-delimited numbers)
    Use `update` to replace the whole widget for new data.
    ```json
    {"id":"claude:perf","template":"bar-chart","title":"Test Duration (ms)","params":{"labels":"Audio|Transcription|Injection|Git|Server","values":"548|351|698|249|451"}}
    ```

    **Delimiter convention:** List params use `|` as delimiter (e.g., `"Build|Test|Deploy"`). Table rows use `|` between rows and `,` between cells within a row.

    ### Parameterized Widgets

    Use `params` to create widgets with dynamic values that update without rewriting the full HTML.

    **Step 1: Define a widget with `params` and template placeholders.**
    Use `{{key}}` in the HTML for initial rendering. For values that will update live, also add `data-param="key"` on the element:

    ```json
    {
      "id": "claude:build",
      "title": "Build Progress",
      "html": "<div style='overflow:hidden;border-radius:4px;background:rgba(255,255,255,0.1)'><div data-param='bar' style='width:{{pct}}%;height:20px;background:#50fa7b;transition:width 0.3s'></div></div><p data-param='status' style='text-align:center;margin-top:6px'>{{status}}</p>",
      "params": {"pct": "0", "status": "Starting build...", "bar": ""}
    }
    ```

    **Step 2: Update params later:**
    Use the Write tool to write to `/tmp/overlay-params.json`, then run the CLI:
    ```json
    {"id": "claude:build", "params": {"pct": "50", "status": "Compiling..."}}
    ```
    ```bash
    ~/.claude/skills/overlay/overlay-cli set-params /tmp/overlay-params.json
    ```
    The CLI command is always the same path, so it auto-approves after the first allow. Only the JSON file contents change (written with the Write tool, which needs no approval).

    **How it works:**
    - `{{key}}` placeholders in the `html` field are replaced with param values on initial render.
    - `data-param="key"` elements have their text content updated live via JavaScript when `set-params` is called. This avoids a full page reload, so CSS transitions animate smoothly.
    - CSS custom properties `var(--key)` are also set on each widget container, so you can use `style="width: var(--pct)"` for dynamic CSS values.

    **Tips for parameterized widgets:**
    - Use `data-param` on a `<span>` or `<p>` for text that changes (status messages, counts, labels).
    - Use CSS `var(--key)` for styling values (widths, colors, opacity). Set the initial value via `{{key}}` in an inline style or rely on the CSS custom property.
    - Add `transition` CSS properties so value changes animate smoothly (e.g., `transition: width 0.3s`).
    - When `data-param` is used for an element whose width or style depends on the param value, set the style via CSS custom properties rather than the text content.

    ### Visualization Tips

    The overlay renders full HTML/CSS/SVG. Use these techniques for rich widgets:

    - **Progress bars**: A `div` with `overflow:hidden;border-radius` containing an inner `div` with `width:%` and `background:linear-gradient(...)`.
    - **Metric cards**: Use `display:flex;gap` with bordered `div`s (`border:1px solid rgba(...)`) for stat grids.
    - **SVG charts**: Inline `<svg>` for sparklines (`<polyline>`), radar charts (`<polygon>`), bar charts, and node graphs. Use `<linearGradient>` for fills.
    - **Animated SVG**: Use `<animate>` on SVG attributes (e.g., bouncing equalizer bars, pulsing indicators). CSS `@keyframes` also work.
    - **Timelines**: Vertical lines with positioned dot markers using `position:relative/absolute`.
    - **Heatmaps**: Grid of small `div`s with varying `background` opacity, using `display:flex;flex-direction:column;gap`.
    - **Color palette**: Use Dracula-inspired colors for dark backgrounds: green `#50fa7b`, cyan `#8be9fd`, purple `#bd93f9`, pink `#ff79c6`, yellow `#f1fa8c`, orange `#ffb86c`, red `#ff5555`.
    - **Typography**: Use `font-family:-apple-system,system-ui,sans-serif` and `SF Mono,monospace` for code. Keep body text 11-13px, labels 9-10px.

    ### Guidelines

    - **Prefer templates over raw HTML.** If a pre-built template fits your use case, always use it — it's faster, uses fewer tokens, and produces consistent styling. Only fall back to raw `html` for visualizations templates can't express (e.g., sparklines, radar charts, heatmaps, custom SVG, image swatches). You can mix both in the same `show` request — some widgets using templates and others using raw HTML.
    - Use the overlay to show progress, status, or visualizations — not for critical information the user must read before continuing.
    - Keep widgets concise. The overlay is ~420px wide.
    - Prefer `set-params` over `update` when only values change — it's faster and flicker-free.
    - **Dismiss before replacing:** When switching to a completely different visualization (e.g., from a build dashboard to a test report), always dismiss old widgets first (`overlay-cli dismiss`) before showing new ones. This prevents stale widgets from lingering if the new set uses different IDs.
    - **Clean up when done:** When your task is finished and the overlay is no longer needed, dismiss all widgets. Don't leave widgets visible after the work they relate to is complete.
    - The overlay coexists with recording — if the user is recording, your widgets appear below the recording indicator.

    ### Demo

    Run `~/.claude/skills/overlay/demo.sh` to cycle through all visualization types.
    Options: `--delay 5` for slower pacing, or `demo.sh sparkline` to show just one.
    """

    // MARK: - CLI Script

    private static let cliScriptContent = """
    #!/bin/bash
    # Careless Whisper overlay CLI — wraps the local HTTP API.
    # Usage: overlay-cli <command> [file|args]
    #   show       [file.json]  — replace all widgets (file path or stdin)
    #   update     [file.json]  — upsert one widget (file path or stdin)
    #   set-params [file.json]  — update widget params (file path or stdin)
    #   dismiss    [widget-id]  — clear all or one widget
    #   health                  — check server status
    set -euo pipefail

    SERVER_JSON="$HOME/.careless-whisper/server.json"

    if [ ! -f "$SERVER_JSON" ]; then
      echo '{"error":"server.json not found — is Careless Whisper running?"}' >&2
      exit 1
    fi

    # Parse server.json: try jq first, fall back to python3
    if command -v jq >/dev/null 2>&1; then
      PORT=$(jq -r '.port' "$SERVER_JSON")
      TOKEN=$(jq -r '.token' "$SERVER_JSON")
      PID=$(jq -r '.pid' "$SERVER_JSON")
    else
      PORT=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["port"])' "$SERVER_JSON")
      TOKEN=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["token"])' "$SERVER_JSON")
      PID=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["pid"])' "$SERVER_JSON")
    fi

    # Verify the server process is alive
    if ! kill -0 "$PID" 2>/dev/null; then
      echo '{"error":"Careless Whisper is not running (stale server.json)"}' >&2
      exit 1
    fi

    BASE="http://127.0.0.1:${PORT}"
    AUTH="Authorization: Bearer ${TOKEN}"
    CMD="${1:-help}"
    shift || true

    case "$CMD" in
      show)
        INPUT="${1:--}"
        curl -sf --max-time 5 -X POST "$BASE/overlay/show" \\
          -H "$AUTH" -H "Content-Type: application/json" -d "@$INPUT"
        ;;
      update)
        INPUT="${1:--}"
        curl -sf --max-time 5 -X POST "$BASE/overlay/update" \\
          -H "$AUTH" -H "Content-Type: application/json" -d "@$INPUT"
        ;;
      set-params)
        INPUT="${1:--}"
        curl -sf --max-time 5 -X POST "$BASE/overlay/params" \\
          -H "$AUTH" -H "Content-Type: application/json" -d "@$INPUT"
        ;;
      dismiss)
        if [ $# -gt 0 ]; then
          curl -sf --max-time 5 -X POST "$BASE/overlay/dismiss/$1" -H "$AUTH"
        else
          curl -sf --max-time 5 -X POST "$BASE/overlay/dismiss" -H "$AUTH"
        fi
        ;;
      health)
        curl -sf --max-time 5 "$BASE/health"
        ;;
      *)
        echo "Usage: overlay-cli {show|update|set-params|dismiss|health}" >&2
        exit 1
        ;;
    esac
    """

    // MARK: - Demo Script

    private static let demoScriptContent = """
    #!/bin/bash
    # Careless Whisper overlay demo — cycles through visualization types.
    # Usage: demo.sh [--delay N] [demo-name]
    #   --delay N   Seconds between demos (default: 3)
    #   demo-name   Run only the named demo (progress|metrics|sparkline|equalizer|timeline|heatmap|multi|barchart|t-progress|t-steps|t-metrics|t-status-list|t-message|t-table|t-key-value|t-bar-chart)
    set -euo pipefail

    CLI="$HOME/.claude/skills/overlay/overlay-cli"
    TMP="/tmp/overlay-demo.json"
    DELAY=3
    ONLY=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --delay) DELAY="$2"; shift 2 ;;
        --delay=*) DELAY="${1#*=}"; shift ;;
        *) ONLY="$1"; shift ;;
      esac
    done

    show_json() { printf '%s' "$1" > "$TMP"; "$CLI" show "$TMP"; }
    set_params() { printf '%s' "$1" > "$TMP"; "$CLI" set-params "$TMP"; }

    cleanup() { "$CLI" dismiss 2>/dev/null; rm -f "$TMP"; }
    trap cleanup EXIT

    # Health check
    if ! "$CLI" health >/dev/null 2>&1; then
      echo "Error: Careless Whisper overlay is not running." >&2
      exit 1
    fi

    run_demo() {
      local name="$1"
      if [[ -n "$ONLY" && "$ONLY" != "$name" ]]; then return; fi
      echo "▶ $name"
      "$CLI" dismiss 2>/dev/null || true
      sleep 0.3
    }

    # --- 1. progress ---
    run_demo progress
    if [[ -z "$ONLY" || "$ONLY" == "progress" ]]; then
      show_json '{"widgets":[{"id":"demo:progress","title":"Build Progress","priority":0,"html":"<div style=\\\"margin-bottom:8px\\\"><div style=\\\"display:flex;justify-content:space-between;margin-bottom:4px\\\"><span style=\\\"font-size:11px;color:#8be9fd;font-family:-apple-system,sans-serif\\\">Compiling modules</span><span data-param=\\\"pct-label\\\" style=\\\"font-size:11px;color:#f8f8f2;font-family:SF Mono,monospace\\\">{{pct-label}}</span></div><div style=\\\"overflow:hidden;border-radius:6px;background:rgba(255,255,255,0.08);height:14px\\\"><div style=\\\"width:var(--pct);height:100%;background:linear-gradient(90deg,#50fa7b,#8be9fd);transition:width 0.4s ease;border-radius:6px\\\"></div></div></div><p data-param=\\\"status\\\" style=\\\"margin:8px 0 0;font-size:11px;color:#6272a4;font-family:-apple-system,sans-serif;text-align:center\\\">{{status}}</p>","params":{"pct":"0%","pct-label":"0%","status":"Starting build…"}}]}'
      sleep 0.8
      set_params '{"id":"demo:progress","params":{"pct":"25%","pct-label":"25%","status":"Resolving dependencies…"}}'
      sleep 0.8
      set_params '{"id":"demo:progress","params":{"pct":"60%","pct-label":"60%","status":"Compiling Swift modules…"}}'
      sleep 0.8
      set_params '{"id":"demo:progress","params":{"pct":"100%","pct-label":"100%","status":"✓ Build complete"}}'
      sleep "$DELAY"
    fi

    # --- 2. metrics ---
    run_demo metrics
    if [[ -z "$ONLY" || "$ONLY" == "metrics" ]]; then
      show_json '{"widgets":[{"id":"demo:metrics","title":"System Dashboard","priority":0,"html":"<div style=\\\"display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px;margin-bottom:8px\\\"><div style=\\\"border:1px solid rgba(80,250,123,0.3);border-radius:8px;padding:8px;text-align:center;background:rgba(80,250,123,0.05)\\\"><div style=\\\"font-size:20px;font-weight:700;color:#50fa7b;font-family:SF Mono,monospace\\\">98%</div><div style=\\\"font-size:9px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px\\\">Tests Pass</div></div><div style=\\\"border:1px solid rgba(139,233,253,0.3);border-radius:8px;padding:8px;text-align:center;background:rgba(139,233,253,0.05)\\\"><div style=\\\"font-size:20px;font-weight:700;color:#8be9fd;font-family:SF Mono,monospace\\\">1.2s</div><div style=\\\"font-size:9px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px\\\">Build Time</div></div><div style=\\\"border:1px solid rgba(189,147,249,0.3);border-radius:8px;padding:8px;text-align:center;background:rgba(189,147,249,0.05)\\\"><div style=\\\"font-size:20px;font-weight:700;color:#bd93f9;font-family:SF Mono,monospace\\\">247</div><div style=\\\"font-size:9px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px\\\">Commits</div></div></div><div style=\\\"display:grid;grid-template-columns:1fr 1fr;gap:6px\\\"><div style=\\\"border:1px solid rgba(255,184,108,0.3);border-radius:8px;padding:8px;text-align:center;background:rgba(255,184,108,0.05)\\\"><div style=\\\"font-size:20px;font-weight:700;color:#ffb86c;font-family:SF Mono,monospace\\\">3</div><div style=\\\"font-size:9px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px\\\">Open PRs</div></div><div style=\\\"border:1px solid rgba(255,85,85,0.3);border-radius:8px;padding:8px;text-align:center;background:rgba(255,85,85,0.05)\\\"><div style=\\\"font-size:20px;font-weight:700;color:#ff5555;font-family:SF Mono,monospace\\\">0</div><div style=\\\"font-size:9px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px\\\">Failures</div></div></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 3. sparkline ---
    run_demo sparkline
    if [[ -z "$ONLY" || "$ONLY" == "sparkline" ]]; then
      show_json '{"widgets":[{"id":"demo:chart","title":"Response Time (ms)","priority":0,"html":"<svg width=\\\"100%\\\" height=\\\"80\\\" viewBox=\\\"0 0 380 80\\\" style=\\\"overflow:visible\\\"><defs><linearGradient id=\\\"sparkfill\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#8be9fd\\\" stop-opacity=\\\"0.3\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#8be9fd\\\" stop-opacity=\\\"0\\\"/></linearGradient></defs><polygon points=\\\"0,65 38,50 76,58 114,30 152,42 190,18 228,35 266,22 304,40 342,15 380,28 380,80 0,80\\\" fill=\\\"url(#sparkfill)\\\"/><polyline points=\\\"0,65 38,50 76,58 114,30 152,42 190,18 228,35 266,22 304,40 342,15 380,28\\\" fill=\\\"none\\\" stroke=\\\"#8be9fd\\\" stroke-width=\\\"2\\\" stroke-linejoin=\\\"round\\\" stroke-linecap=\\\"round\\\"/><circle cx=\\\"380\\\" cy=\\\"28\\\" r=\\\"4\\\" fill=\\\"#8be9fd\\\"/><text x=\\\"380\\\" y=\\\"20\\\" text-anchor=\\\"middle\\\" fill=\\\"#8be9fd\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">142ms</text><line x1=\\\"0\\\" y1=\\\"80\\\" x2=\\\"380\\\" y2=\\\"80\\\" stroke=\\\"rgba(255,255,255,0.1)\\\" stroke-width=\\\"1\\\"/></svg><div style=\\\"display:flex;justify-content:space-between;margin-top:4px\\\"><span style=\\\"font-size:9px;color:#6272a4;font-family:-apple-system,sans-serif\\\">30m ago</span><span style=\\\"font-size:9px;color:#6272a4;font-family:-apple-system,sans-serif\\\">now</span></div><div style=\\\"display:flex;gap:12px;margin-top:6px\\\"><span style=\\\"font-size:10px;font-family:SF Mono,monospace;color:#50fa7b\\\">avg 38ms</span><span style=\\\"font-size:10px;font-family:SF Mono,monospace;color:#ffb86c\\\">p95 142ms</span><span style=\\\"font-size:10px;font-family:SF Mono,monospace;color:#ff5555\\\">max 201ms</span></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 4. equalizer ---
    run_demo equalizer
    if [[ -z "$ONLY" || "$ONLY" == "equalizer" ]]; then
      show_json '{"widgets":[{"id":"demo:animated","title":"Recording in Progress","priority":0,"html":"<div style=\\\"display:flex;align-items:center;gap:16px;padding:4px 0\\\"><svg width=\\\"48\\\" height=\\\"40\\\" viewBox=\\\"0 0 48 40\\\"><rect x=\\\"2\\\" y=\\\"8\\\" width=\\\"6\\\" height=\\\"32\\\" rx=\\\"3\\\" fill=\\\"#50fa7b\\\"><animate attributeName=\\\"height\\\" values=\\\"32;12;28;8;36;16;32\\\" dur=\\\"1.1s\\\" repeatCount=\\\"indefinite\\\"/><animate attributeName=\\\"y\\\" values=\\\"8;20;12;24;4;18;8\\\" dur=\\\"1.1s\\\" repeatCount=\\\"indefinite\\\"/></rect><rect x=\\\"11\\\" y=\\\"4\\\" width=\\\"6\\\" height=\\\"36\\\" rx=\\\"3\\\" fill=\\\"#50fa7b\\\"><animate attributeName=\\\"height\\\" values=\\\"36;24;8;32;14;36;20;36\\\" dur=\\\"0.8s\\\" repeatCount=\\\"indefinite\\\"/><animate attributeName=\\\"y\\\" values=\\\"4;12;28;4;22;4;16;4\\\" dur=\\\"0.8s\\\" repeatCount=\\\"indefinite\\\"/></rect><rect x=\\\"20\\\" y=\\\"12\\\" width=\\\"6\\\" height=\\\"28\\\" rx=\\\"3\\\" fill=\\\"#50fa7b\\\"><animate attributeName=\\\"height\\\" values=\\\"28;36;16;28;8;24;28\\\" dur=\\\"1.3s\\\" repeatCount=\\\"indefinite\\\"/><animate attributeName=\\\"y\\\" values=\\\"12;4;20;12;28;14;12\\\" dur=\\\"1.3s\\\" repeatCount=\\\"indefinite\\\"/></rect><rect x=\\\"29\\\" y=\\\"6\\\" width=\\\"6\\\" height=\\\"34\\\" rx=\\\"3\\\" fill=\\\"#50fa7b\\\"><animate attributeName=\\\"height\\\" values=\\\"34;14;30;8;26;34;18;34\\\" dur=\\\"0.9s\\\" repeatCount=\\\"indefinite\\\"/><animate attributeName=\\\"y\\\" values=\\\"6;20;8;28;12;6;18;6\\\" dur=\\\"0.9s\\\" repeatCount=\\\"indefinite\\\"/></rect><rect x=\\\"38\\\" y=\\\"10\\\" width=\\\"6\\\" height=\\\"30\\\" rx=\\\"3\\\" fill=\\\"#50fa7b\\\"><animate attributeName=\\\"height\\\" values=\\\"30;36;10;28;18;36;30\\\" dur=\\\"1.2s\\\" repeatCount=\\\"indefinite\\\"/><animate attributeName=\\\"y\\\" values=\\\"10;4;26;8;20;4;10\\\" dur=\\\"1.2s\\\" repeatCount=\\\"indefinite\\\"/></rect></svg><div><div style=\\\"font-size:14px;font-weight:600;color:#f8f8f2;font-family:-apple-system,sans-serif\\\">Listening…</div><div style=\\\"font-size:11px;color:#6272a4;margin-top:2px;font-family:-apple-system,sans-serif\\\">Hold hotkey and speak</div></div></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 5. timeline ---
    run_demo timeline
    if [[ -z "$ONLY" || "$ONLY" == "timeline" ]]; then
      show_json '{"widgets":[{"id":"demo:timeline","title":"Deploy Pipeline","priority":0,"html":"<div style=\\\"position:relative;padding-left:24px;font-family:-apple-system,sans-serif\\\"><div style=\\\"position:absolute;left:7px;top:6px;bottom:6px;width:2px;background:linear-gradient(to bottom,#50fa7b,#8be9fd,#bd93f9,rgba(98,114,164,0.3))\\\"></div><div style=\\\"position:relative;margin-bottom:12px\\\"><div style=\\\"position:absolute;left:-20px;top:2px;width:10px;height:10px;border-radius:50%;background:#50fa7b;box-shadow:0 0 6px #50fa7b\\\"></div><div style=\\\"font-size:11px;font-weight:600;color:#50fa7b\\\">Build</div><div style=\\\"font-size:10px;color:#6272a4;margin-top:1px\\\">swift build -c release · 1m 12s</div></div><div style=\\\"position:relative;margin-bottom:12px\\\"><div style=\\\"position:absolute;left:-20px;top:2px;width:10px;height:10px;border-radius:50%;background:#8be9fd;box-shadow:0 0 6px #8be9fd\\\"></div><div style=\\\"font-size:11px;font-weight:600;color:#8be9fd\\\">Test</div><div style=\\\"font-size:10px;color:#6272a4;margin-top:1px\\\">swift test · 247/247 passed · 43s</div></div><div style=\\\"position:relative;margin-bottom:12px\\\"><div style=\\\"position:absolute;left:-20px;top:2px;width:10px;height:10px;border-radius:50%;background:#bd93f9;box-shadow:0 0 6px #bd93f9\\\"></div><div style=\\\"font-size:11px;font-weight:600;color:#bd93f9\\\">Package</div><div style=\\\"font-size:10px;color:#6272a4;margin-top:1px\\\">bundle.sh --release · 18s</div></div><div style=\\\"position:relative\\\"><div style=\\\"position:absolute;left:-20px;top:2px;width:10px;height:10px;border-radius:50%;background:rgba(98,114,164,0.4);border:1px solid rgba(98,114,164,0.6)\\\"></div><div style=\\\"font-size:11px;font-weight:600;color:#6272a4\\\">Deploy</div><div style=\\\"font-size:10px;color:#6272a4;margin-top:1px\\\">waiting…</div></div></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 6. heatmap ---
    run_demo heatmap
    if [[ -z "$ONLY" || "$ONLY" == "heatmap" ]]; then
      show_json '{"widgets":[{"id":"demo:heatmap","title":"Commit Activity (last 8 weeks)","priority":0,"html":"<div style=\\\"font-family:-apple-system,sans-serif\\\"><div style=\\\"display:flex;gap:3px;margin-bottom:4px\\\"><div style=\\\"display:flex;flex-direction:column;gap:3px;margin-right:4px\\\"><div style=\\\"height:12px;font-size:8px;color:#6272a4;line-height:12px\\\">M</div><div style=\\\"height:12px;font-size:8px;color:#6272a4;line-height:12px\\\">W</div><div style=\\\"height:12px;font-size:8px;color:#6272a4;line-height:12px\\\">F</div></div><div style=\\\"display:flex;gap:3px\\\"><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.15)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.05)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.4)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.6)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.3)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.1)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.05)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.8)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.9)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.4)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.2)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.5)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.7)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.3)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.1)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.2)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,1.0)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.6)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.5)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.4)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.8)\\\"></div></div><div style=\\\"display:flex;flex-direction:column;gap:3px\\\"><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.9)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.2)\\\"></div><div style=\\\"width:12px;height:12px;border-radius:2px;background:rgba(80,250,123,0.3)\\\"></div></div></div></div><div style=\\\"display:flex;align-items:center;gap:4px;margin-top:4px\\\"><span style=\\\"font-size:9px;color:#6272a4\\\">less</span><div style=\\\"width:10px;height:10px;border-radius:2px;background:rgba(80,250,123,0.05)\\\"></div><div style=\\\"width:10px;height:10px;border-radius:2px;background:rgba(80,250,123,0.25)\\\"></div><div style=\\\"width:10px;height:10px;border-radius:2px;background:rgba(80,250,123,0.5)\\\"></div><div style=\\\"width:10px;height:10px;border-radius:2px;background:rgba(80,250,123,0.75)\\\"></div><div style=\\\"width:10px;height:10px;border-radius:2px;background:rgba(80,250,123,1.0)\\\"></div><span style=\\\"font-size:9px;color:#6272a4\\\">more</span></div></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 7. multi ---
    run_demo multi
    if [[ -z "$ONLY" || "$ONLY" == "multi" ]]; then
      show_json '{"widgets":[{"id":"demo:git","title":"Git Status","priority":0,"html":"<div style=\\\"font-family:SF Mono,monospace;font-size:11px\\\"><div style=\\\"color:#50fa7b;margin-bottom:3px\\\">● main — 3 ahead</div><div style=\\\"color:#ffb86c\\\">M Sources/App/AppState.swift</div><div style=\\\"color:#ffb86c\\\">M Sources/Server/HTMLComposer.swift</div><div style=\\\"color:#8be9fd\\\">? Sources/UI/NewView.swift</div></div>"},{"id":"demo:ci","title":"CI / GitHub","priority":1,"html":"<div style=\\\"font-family:-apple-system,sans-serif;font-size:11px\\\"><div style=\\\"display:flex;align-items:center;gap:6px;margin-bottom:4px\\\"><svg width=\\\"10\\\" height=\\\"10\\\" viewBox=\\\"0 0 10 10\\\"><circle cx=\\\"5\\\" cy=\\\"5\\\" r=\\\"4\\\" fill=\\\"#50fa7b\\\"/></svg><span style=\\\"color:#f8f8f2\\\">CI passing</span><span style=\\\"color:#6272a4;margin-left:auto\\\">2m ago</span></div><div style=\\\"display:flex;align-items:center;gap:6px\\\"><svg width=\\\"10\\\" height=\\\"10\\\" viewBox=\\\"0 0 10 10\\\"><circle cx=\\\"5\\\" cy=\\\"5\\\" r=\\\"4\\\" fill=\\\"none\\\" stroke=\\\"#ffb86c\\\" stroke-width=\\\"2\\\"/></svg><span style=\\\"color:#f8f8f2\\\">PR #12 — review requested</span></div></div>"}]}'
      sleep "$DELAY"
    fi

    # --- 8. barchart ---
    run_demo barchart
    if [[ -z "$ONLY" || "$ONLY" == "barchart" ]]; then
      show_json '{"widgets":[{"id":"demo:bars","title":"Test Duration by Module (ms)","priority":0,"html":"<svg width=\\\"100%\\\" height=\\\"110\\\" viewBox=\\\"0 0 380 110\\\"><defs><linearGradient id=\\\"b1\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#8be9fd\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#8be9fd\\\" stop-opacity=\\\"0.5\\\"/></linearGradient><linearGradient id=\\\"b2\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#50fa7b\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#50fa7b\\\" stop-opacity=\\\"0.5\\\"/></linearGradient><linearGradient id=\\\"b3\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#bd93f9\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#bd93f9\\\" stop-opacity=\\\"0.5\\\"/></linearGradient><linearGradient id=\\\"b4\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#ffb86c\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#ffb86c\\\" stop-opacity=\\\"0.5\\\"/></linearGradient><linearGradient id=\\\"b5\\\" x1=\\\"0\\\" y1=\\\"0\\\" x2=\\\"0\\\" y2=\\\"1\\\"><stop offset=\\\"0%\\\" stop-color=\\\"#ff79c6\\\"/><stop offset=\\\"100%\\\" stop-color=\\\"#ff79c6\\\" stop-opacity=\\\"0.5\\\"/></linearGradient></defs><line x1=\\\"0\\\" y1=\\\"85\\\" x2=\\\"380\\\" y2=\\\"85\\\" stroke=\\\"rgba(255,255,255,0.1)\\\" stroke-width=\\\"1\\\"/><rect x=\\\"10\\\" y=\\\"30\\\" width=\\\"52\\\" height=\\\"55\\\" rx=\\\"4\\\" fill=\\\"url(#b1)\\\"/><rect x=\\\"82\\\" y=\\\"50\\\" width=\\\"52\\\" height=\\\"35\\\" rx=\\\"4\\\" fill=\\\"url(#b2)\\\"/><rect x=\\\"154\\\" y=\\\"15\\\" width=\\\"52\\\" height=\\\"70\\\" rx=\\\"4\\\" fill=\\\"url(#b3)\\\"/><rect x=\\\"226\\\" y=\\\"60\\\" width=\\\"52\\\" height=\\\"25\\\" rx=\\\"4\\\" fill=\\\"url(#b4)\\\"/><rect x=\\\"298\\\" y=\\\"40\\\" width=\\\"52\\\" height=\\\"45\\\" rx=\\\"4\\\" fill=\\\"url(#b5)\\\"/><text x=\\\"36\\\" y=\\\"25\\\" text-anchor=\\\"middle\\\" fill=\\\"#8be9fd\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">548</text><text x=\\\"108\\\" y=\\\"45\\\" text-anchor=\\\"middle\\\" fill=\\\"#50fa7b\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">351</text><text x=\\\"180\\\" y=\\\"10\\\" text-anchor=\\\"middle\\\" fill=\\\"#bd93f9\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">698</text><text x=\\\"252\\\" y=\\\"55\\\" text-anchor=\\\"middle\\\" fill=\\\"#ffb86c\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">249</text><text x=\\\"324\\\" y=\\\"35\\\" text-anchor=\\\"middle\\\" fill=\\\"#ff79c6\\\" font-size=\\\"10\\\" font-family=\\\"SF Mono,monospace\\\">451</text><text x=\\\"36\\\" y=\\\"98\\\" text-anchor=\\\"middle\\\" fill=\\\"#6272a4\\\" font-size=\\\"9\\\" font-family=\\\"-apple-system,sans-serif\\\">Audio</text><text x=\\\"108\\\" y=\\\"98\\\" text-anchor=\\\"middle\\\" fill=\\\"#6272a4\\\" font-size=\\\"9\\\" font-family=\\\"-apple-system,sans-serif\\\">Transc.</text><text x=\\\"180\\\" y=\\\"98\\\" text-anchor=\\\"middle\\\" fill=\\\"#6272a4\\\" font-size=\\\"9\\\" font-family=\\\"-apple-system,sans-serif\\\">Inject</text><text x=\\\"252\\\" y=\\\"98\\\" text-anchor=\\\"middle\\\" fill=\\\"#6272a4\\\" font-size=\\\"9\\\" font-family=\\\"-apple-system,sans-serif\\\">Git</text><text x=\\\"324\\\" y=\\\"98\\\" text-anchor=\\\"middle\\\" fill=\\\"#6272a4\\\" font-size=\\\"9\\\" font-family=\\\"-apple-system,sans-serif\\\">Server</text></svg>"}]}'
      sleep "$DELAY"
    fi

    # ========================================
    # Template-based demos
    # ========================================

    # --- 9. t-progress (template) ---
    run_demo t-progress
    if [[ -z "$ONLY" || "$ONLY" == "t-progress" ]]; then
      show_json '{"widgets":[{"id":"demo:t-progress","title":"Template: Progress","template":"progress","params":{"label":"Compiling modules","pct":"0%","status":"Starting build…"}}]}'
      sleep 0.8
      set_params '{"id":"demo:t-progress","params":{"label":"Compiling modules","pct":"40%","status":"Resolving dependencies…"}}'
      sleep 0.8
      set_params '{"id":"demo:t-progress","params":{"label":"Compiling modules","pct":"80%","status":"Linking…"}}'
      sleep 0.8
      set_params '{"id":"demo:t-progress","params":{"label":"Compiling modules","pct":"100%","status":"✓ Build complete"}}'
      sleep "$DELAY"
    fi

    # --- 10. t-steps (template) ---
    run_demo t-steps
    if [[ -z "$ONLY" || "$ONLY" == "t-steps" ]]; then
      show_json '{"widgets":[{"id":"demo:t-steps","title":"Template: Steps","template":"steps","params":{"labels":"Build|Test|Package|Deploy","statuses":"done|done|running|pending","details":"1m 12s|247 passed|bundling…|"}}]}'
      sleep "$DELAY"
    fi

    # --- 11. t-metrics (template) ---
    run_demo t-metrics
    if [[ -z "$ONLY" || "$ONLY" == "t-metrics" ]]; then
      show_json '{"widgets":[{"id":"demo:t-metrics","title":"Template: Metrics","template":"metrics","params":{"values":"98%|1.2s|247|3|0","labels":"Tests Pass|Build Time|Commits|Open PRs|Failures"}}]}'
      sleep "$DELAY"
    fi

    # --- 12. t-status-list (template) ---
    run_demo t-status-list
    if [[ -z "$ONLY" || "$ONLY" == "t-status-list" ]]; then
      show_json '{"widgets":[{"id":"demo:t-status","title":"Template: Status List","template":"status-list","params":{"labels":"Lint|Types|Tests|Coverage","statuses":"ok|ok|running|pending","details":"No issues|0 errors|43/100|"}}]}'
      sleep "$DELAY"
    fi

    # --- 13. t-message (template) ---
    run_demo t-message
    if [[ -z "$ONLY" || "$ONLY" == "t-message" ]]; then
      show_json '{"widgets":[{"id":"demo:t-msg","template":"message","params":{"text":"Build succeeded","type":"success","detail":"247 tests passed in 1.2s"}}]}'
      sleep "$DELAY"
    fi

    # --- 14. t-table (template) ---
    run_demo t-table
    if [[ -z "$ONLY" || "$ONLY" == "t-table" ]]; then
      show_json '{"widgets":[{"id":"demo:t-table","title":"Template: Table","template":"table","params":{"headers":"Package|Version|Status","rows":"SwiftWhisper,1.2.0,ok|HotKey,0.2.0,ok|Alamofire,5.9.0,outdated"}}]}'
      sleep "$DELAY"
    fi

    # --- 15. t-key-value (template) ---
    run_demo t-key-value
    if [[ -z "$ONLY" || "$ONLY" == "t-key-value" ]]; then
      show_json '{"widgets":[{"id":"demo:t-kv","title":"Template: Key-Value","template":"key-value","params":{"keys":"Branch|Commit|Swift|Platform","values":"main|a1b2c3d|5.9|macOS 14+"}}]}'
      sleep "$DELAY"
    fi

    # --- 16. t-bar-chart (template) ---
    run_demo t-bar-chart
    if [[ -z "$ONLY" || "$ONLY" == "t-bar-chart" ]]; then
      show_json '{"widgets":[{"id":"demo:t-bars","title":"Template: Bar Chart","template":"bar-chart","params":{"labels":"Audio|Transc.|Inject|Git|Server","values":"548|351|698|249|451"}}]}'
      sleep "$DELAY"
    fi

    echo "✓ Demo complete"
    """
}
