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

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: skillFileURL.path)
    }

    static func install() {
        let dir = skillDirectoryURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try skillContent.write(to: skillFileURL, atomically: true, encoding: .utf8)
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

    You can push rich HTML content to a floating macOS overlay via the Careless Whisper local HTTP API.

    ### Discovery

    Read `~/.careless-whisper/server.json` to get connection info:
    ```json
    { "port": 32451, "token": "<uuid>", "pid": 12345 }
    ```

    If the file doesn't exist or the PID is not running, the overlay is unavailable.

    ### Endpoints

    All requests require `Authorization: Bearer <token>` header. All responses are JSON.

    **Show widgets** — `POST /overlay/show`
    Replace all widgets and show the overlay.
    Write JSON to a temp file (avoids shell escaping issues with HTML quotes), then POST it:
    ```bash
    cat <<'EOF' > /tmp/overlay-show.json
    {"widgets":[{"id":"status","title":"Build Status","html":"<h2>Passing</h2>","priority":0}]}
    EOF
    curl -s --max-time 5 -X POST http://127.0.0.1:$PORT/overlay/show \\
      -H "Authorization: Bearer $TOKEN" \\
      -H "Content-Type: application/json" \\
      -d @/tmp/overlay-show.json
    ```

    **Update one widget** — `POST /overlay/update`
    Upsert a single widget by ID.
    ```bash
    cat <<'EOF' > /tmp/overlay-update.json
    {"widget":{"id":"status","title":"Build","html":"<p>Step 3/5</p>","priority":0}}
    EOF
    curl -s --max-time 5 -X POST http://127.0.0.1:$PORT/overlay/update \\
      -H "Authorization: Bearer $TOKEN" \\
      -H "Content-Type: application/json" \\
      -d @/tmp/overlay-update.json
    ```

    **Dismiss all** — `POST /overlay/dismiss`
    Clear all widgets and hide the overlay.

    **Dismiss one** — `POST /overlay/dismiss/:id`
    Remove a single widget by ID.

    **Health check** — `GET /health` (no auth required)

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

    ### Guidelines

    - Use the overlay to show progress, status, or visualizations — not for critical information the user must read before continuing.
    - Keep widgets concise. The overlay is ~420px wide.
    - Dismiss widgets when they're no longer relevant.
    - The overlay coexists with recording — if the user is recording, your widgets appear below the recording indicator.
    """
}
