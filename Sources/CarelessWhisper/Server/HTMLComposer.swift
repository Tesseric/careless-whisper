import Foundation

enum HTMLComposer {
    /// Composes an array of widgets into a single HTML document with dark theme styling and CSP.
    static func compose(widgets: [AgentWidget]) -> String {
        let sorted = widgets.sorted { $0.priority < $1.priority }
        let cards = sorted.map { widget in
            let sanitized = sanitizeHTML(widget.html)
            let titleHTML: String
            if let title = widget.title {
                titleHTML = "<div class=\"widget-title\">\(escapeHTML(title))</div>"
            } else {
                titleHTML = ""
            }
            return """
            <div class="widget-card" data-widget-id="\(escapeHTML(widget.id))">
              \(titleHTML)
              <div class="widget-content">\(sanitized)</div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:;">
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              background: transparent;
              color: rgba(255, 255, 255, 0.9);
              padding: 8px;
              -webkit-user-select: none;
              user-select: none;
            }
            .widget-card {
              background: rgba(255, 255, 255, 0.06);
              border: 1px solid rgba(255, 255, 255, 0.1);
              border-radius: 8px;
              padding: 12px;
              margin-bottom: 8px;
            }
            .widget-card:last-child { margin-bottom: 0; }
            .widget-title {
              font-size: 11px;
              font-weight: 600;
              color: rgba(255, 255, 255, 0.5);
              text-transform: uppercase;
              letter-spacing: 0.5px;
              margin-bottom: 8px;
            }
            .widget-content {
              font-size: 13px;
              line-height: 1.4;
              color: rgba(255, 255, 255, 0.85);
            }
            .widget-content h1 { font-size: 18px; margin-bottom: 8px; }
            .widget-content h2 { font-size: 15px; margin-bottom: 6px; }
            .widget-content h3 { font-size: 13px; margin-bottom: 4px; }
            .widget-content p { margin-bottom: 6px; }
            .widget-content ul, .widget-content ol { padding-left: 20px; margin-bottom: 6px; }
            .widget-content code {
              font-family: "SF Mono", Menlo, monospace;
              font-size: 12px;
              background: rgba(255, 255, 255, 0.08);
              padding: 1px 4px;
              border-radius: 3px;
            }
            .widget-content pre {
              background: rgba(0, 0, 0, 0.3);
              padding: 8px;
              border-radius: 6px;
              overflow-x: auto;
              margin-bottom: 6px;
            }
            .widget-content pre code { background: none; padding: 0; }
            .widget-content table { border-collapse: collapse; width: 100%; margin-bottom: 6px; }
            .widget-content th, .widget-content td {
              border: 1px solid rgba(255, 255, 255, 0.1);
              padding: 4px 8px;
              text-align: left;
              font-size: 12px;
            }
            .widget-content th { background: rgba(255, 255, 255, 0.05); font-weight: 600; }
          </style>
        </head>
        <body>
          \(cards)
        </body>
        </html>
        """
    }

    // MARK: - Sanitization

    /// Tags stripped from agent-provided HTML. Script tags are allowed (CSP `script-src
    /// 'unsafe-inline'` permits inline JS for charts/animations while blocking external loads).
    private static let forbiddenTags: Set<String> = [
        "iframe", "object", "embed", "form", "link", "meta", "base"
    ]

    static func sanitizeHTML(_ html: String) -> String {
        var result = html
        // Remove forbidden tags and their content for void/dangerous elements
        for tag in forbiddenTags {
            // Remove self-closing tags: <tag ... />
            let selfClosingPattern = "<\(tag)\\b[^>]*/>"
            if let regex = try? NSRegularExpression(pattern: selfClosingPattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
            // Remove open+close tag pairs and content between them
            let pairedPattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pairedPattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
            // Remove unclosed tags: <tag ...>
            let unclosedPattern = "<\(tag)\\b[^>]*>"
            if let regex = try? NSRegularExpression(pattern: unclosedPattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        return result
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
