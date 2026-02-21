import Foundation
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

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: skillFileURL.path)
    }

    static func install() {
        let dir = skillDirectoryURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try skillContent.write(to: skillFileURL, atomically: true, encoding: .utf8)
            try cliScriptContent.write(to: cliScriptURL, atomically: true, encoding: .utf8)
            // Make the CLI script executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: cliScriptURL.path
            )
            logger.info("Installed Claude Code skill at \(skillFileURL.path)")
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

    **Show widgets** — replace all widgets and show the overlay.
    First write JSON using the Write tool (no shell approval needed), then pass the file path:
    ```bash
    # Write {"widgets":[...]} to /tmp/overlay-widgets.json using the Write tool, then:
    ~/.claude/skills/overlay/overlay-cli show /tmp/overlay-widgets.json
    ```

    **Update one widget** — upsert a single widget by ID:
    ```bash
    # Write {"widget":{...}} to /tmp/overlay-widget.json using the Write tool, then:
    ~/.claude/skills/overlay/overlay-cli update /tmp/overlay-widget.json
    ```

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
      "priority": 0
    }
    ```
    - `id`: Unique identifier. Namespace by agent (e.g., `claude:build`).
    - `title`: Optional header displayed above content.
    - `html`: HTML rendered in the overlay. Supports inline CSS and JS. Tags like `<iframe>`, `<object>`, `<embed>`, `<form>` are stripped.
    - `priority`: Sort order (lower = higher). Default 0.

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

    - Use the overlay to show progress, status, or visualizations — not for critical information the user must read before continuing.
    - Keep widgets concise. The overlay is ~420px wide.
    - Dismiss widgets when they're no longer relevant.
    - The overlay coexists with recording — if the user is recording, your widgets appear below the recording indicator.
    """

    // MARK: - CLI Script

    private static let cliScriptContent = """
    #!/bin/bash
    # Careless Whisper overlay CLI — wraps the local HTTP API.
    # Usage: overlay-cli <command> [file|args]
    #   show     [file.json]  — replace all widgets (file path or stdin)
    #   update   [file.json]  — upsert one widget (file path or stdin)
    #   dismiss  [widget-id]  — clear all or one widget
    #   health                — check server status
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
        echo "Usage: overlay-cli {show|update|dismiss|health}" >&2
        exit 1
        ;;
    esac
    """
}
