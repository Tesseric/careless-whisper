import Foundation

enum WidgetTemplateError: LocalizedError {
    case unknownTemplate(String)
    case missingRequiredParams(template: String, missing: [String])

    var errorDescription: String? {
        switch self {
        case .unknownTemplate(let name):
            return "Unknown template '\(name)'. Available: progress, steps, metrics, table, status-list, message, key-value, bar-chart"
        case .missingRequiredParams(let template, let missing):
            return "Template '\(template)' missing required params: \(missing.joined(separator: ", "))"
        }
    }
}

enum WidgetTemplateRegistry {

    // MARK: - Public API

    static func render(template: String, params: [String: String]?) throws -> String {
        let p = params ?? [:]
        switch template {
        case "progress":
            try validateRequired(template: template, params: p, keys: ["label", "pct", "status"])
            return renderProgress(p)
        case "steps":
            try validateRequired(template: template, params: p, keys: ["labels", "statuses"])
            return renderSteps(p)
        case "metrics":
            try validateRequired(template: template, params: p, keys: ["values", "labels"])
            return renderMetrics(p)
        case "table":
            try validateRequired(template: template, params: p, keys: ["headers", "rows"])
            return renderTable(p)
        case "status-list":
            try validateRequired(template: template, params: p, keys: ["labels", "statuses"])
            return renderStatusList(p)
        case "message":
            try validateRequired(template: template, params: p, keys: ["text", "type"])
            return renderMessage(p)
        case "key-value":
            try validateRequired(template: template, params: p, keys: ["keys", "values"])
            return renderKeyValue(p)
        case "bar-chart":
            try validateRequired(template: template, params: p, keys: ["labels", "values"])
            return renderBarChart(p)
        default:
            throw WidgetTemplateError.unknownTemplate(template)
        }
    }

    // MARK: - Validation

    private static func validateRequired(template: String, params: [String: String], keys: [String]) throws {
        let missing = keys.filter { params[$0] == nil }
        if !missing.isEmpty {
            throw WidgetTemplateError.missingRequiredParams(template: template, missing: missing)
        }
    }

    // MARK: - Helpers

    private static func esc(_ s: String) -> String {
        HTMLComposer.escapeHTML(s)
    }

    private static func split(_ value: String) -> [String] {
        value.components(separatedBy: "|")
    }

    // Dracula palette
    private static let colors = ["#50fa7b", "#8be9fd", "#bd93f9", "#ffb86c", "#ff79c6", "#f1fa8c", "#ff5555", "#f8f8f2"]

    /// Muted text color for labels, details, and captions — uses white with alpha for reliable
    /// contrast on dark/transparent backgrounds (matches HTMLComposer's widget-title color).
    private static let mutedText = "rgba(255,255,255,0.5)"

    private static func color(at index: Int) -> String {
        colors[index % colors.count]
    }

    /// Script block for list-based templates that redistributes pipe-delimited param values
    /// to individual DOM elements on live `set-params` updates via MutationObserver.
    /// Observes the widget card's style attribute directly (where `_updateWidgetParams` sets
    /// CSS custom properties) and redistributes values to `[data-pipe]` elements.
    private static let pipeRedistributionScript = """
    <script>
    (function(){
      var root = document.currentScript.parentElement;
      if (!root) return;

      var card = root.closest('.widget-card') || root.parentElement;
      if (!card) return;

      function redistribute() {
        var style = card.getAttribute('style') || '';
        var pipeItems = root.querySelectorAll('[data-pipe]');
        if (!pipeItems.length) return;

        var groups = {};
        for (var i = 0; i < pipeItems.length; i++) {
          var item = pipeItems[i];
          if (!item.dataset || !item.dataset.pipe) continue;
          var key = item.dataset.pipe;
          if (!groups[key]) groups[key] = [];
          groups[key].push(item);
        }

        for (var key in groups) {
          if (!Object.prototype.hasOwnProperty.call(groups, key)) continue;
          var re = new RegExp('--' + key.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&') + '\\\\s*:\\\\s*([^;]+)');
          var match = style.match(re);
          if (!match) continue;
          var val = match[1].trim();
          var parts = val.split('|');
          var items = groups[key];
          for (var j = 0; j < items.length && j < parts.length; j++) {
            items[j].textContent = parts[j];
          }
        }
      }

      var obs = new MutationObserver(function(muts) {
        for (var i = 0; i < muts.length; i++) {
          var m = muts[i];
          if (m.type === 'attributes' && m.target === card && m.attributeName === 'style') {
            redistribute();
            break;
          }
        }
      });

      obs.observe(card, { attributes: true });
      redistribute();
    })();
    </script>
    """

    // MARK: - Template: progress

    private static func renderProgress(_ p: [String: String]) -> String {
        let label = esc(p["label"]!)
        let pct = esc(p["pct"]!)
        let status = esc(p["status"]!)
        return """
        <div style="margin-bottom:8px">
          <div style="display:flex;justify-content:space-between;margin-bottom:4px">
            <span data-param="label" style="font-size:11px;color:#8be9fd;font-family:-apple-system,sans-serif">\(label)</span>
            <span data-param="pct" style="font-size:11px;color:#f8f8f2;font-family:SF Mono,monospace">\(pct)</span>
          </div>
          <div style="overflow:hidden;border-radius:6px;background:rgba(255,255,255,0.08);height:14px">
            <div style="width:var(--pct);height:100%;background:linear-gradient(90deg,#50fa7b,#8be9fd);transition:width 0.4s ease;border-radius:6px"></div>
          </div>
        </div>
        <p data-param="status" style="margin:8px 0 0;font-size:11px;color:\(mutedText);font-family:-apple-system,sans-serif;text-align:center">\(status)</p>
        """
    }

    // MARK: - Template: steps

    private static func renderSteps(_ p: [String: String]) -> String {
        let labels = split(p["labels"]!)
        let statuses = split(p["statuses"]!)
        let details = p["details"].map { split($0) }

        var html = """
        <div style="position:relative;padding-left:24px;font-family:-apple-system,sans-serif">
          <div style="position:absolute;left:7px;top:6px;bottom:6px;width:2px;background:rgba(255,255,255,0.1)"></div>
        """

        for (i, label) in labels.enumerated() {
            let status = i < statuses.count ? statuses[i] : "pending"
            let detail = details.flatMap { i < $0.count ? $0[i] : nil }
            let (dotStyle, textColor) = stepStyle(for: status.trimmingCharacters(in: .whitespaces))
            let isLast = i == labels.count - 1
            let margin = isLast ? "" : "margin-bottom:12px;"

            html += """
              <div style="position:relative;\(margin)">
                <div style="position:absolute;left:-20px;top:2px;width:10px;height:10px;border-radius:50%;\(dotStyle)"></div>
                <div data-pipe="labels" style="font-size:11px;font-weight:600;color:\(textColor)">\(esc(label))</div>
            """
            if let detail, !detail.isEmpty {
                html += """
                    <div data-pipe="details" style="font-size:10px;color:\(mutedText);margin-top:1px">\(esc(detail))</div>
                """
            }
            html += "  </div>\n"
        }

        html += "</div>\n"
        html += pipeRedistributionScript
        return html
    }

    private static func stepStyle(for status: String) -> (dotStyle: String, textColor: String) {
        switch status.lowercased() {
        case "done", "complete", "completed", "passed", "pass", "success":
            return ("background:#50fa7b;box-shadow:0 0 6px #50fa7b", "#50fa7b")
        case "running", "active", "in-progress", "in_progress":
            return ("background:#8be9fd;box-shadow:0 0 6px #8be9fd", "#8be9fd")
        case "failed", "fail", "error":
            return ("background:#ff5555;box-shadow:0 0 6px #ff5555", "#ff5555")
        case "skipped", "skip":
            return ("background:rgba(255,255,255,0.12);border:1px solid rgba(255,255,255,0.2)", "rgba(255,255,255,0.4)")
        default: // pending
            return ("background:rgba(255,255,255,0.12);border:1px solid rgba(255,255,255,0.2)", "rgba(255,255,255,0.4)")
        }
    }

    // MARK: - Template: metrics

    private static func renderMetrics(_ p: [String: String]) -> String {
        let values = split(p["values"]!)
        let labels = split(p["labels"]!)
        let count = min(values.count, labels.count)

        let cols = count <= 2 ? count : (count <= 4 ? 2 : 3)
        var html = "<div style=\"display:grid;grid-template-columns:repeat(\(cols),1fr);gap:6px\">\n"

        for i in 0..<count {
            let c = color(at: i)
            html += """
              <div style="border:1px solid \(c)33;border-radius:8px;padding:8px;text-align:center;background:\(c)0d">
                <div data-pipe="values" style="font-size:20px;font-weight:700;color:\(c);font-family:SF Mono,monospace">\(esc(values[i]))</div>
                <div data-pipe="labels" style="font-size:9px;color:\(mutedText);margin-top:2px;font-family:-apple-system,sans-serif;text-transform:uppercase;letter-spacing:.5px">\(esc(labels[i]))</div>
              </div>
            """
        }

        html += "</div>\n"
        html += pipeRedistributionScript
        return html
    }

    // MARK: - Template: table

    private static func renderTable(_ p: [String: String]) -> String {
        let headers = split(p["headers"]!)
        let rowStrings = split(p["rows"]!)

        var html = "<table style=\"border-collapse:collapse;width:100%;font-family:-apple-system,sans-serif;font-size:12px\">\n<thead><tr>\n"

        for header in headers {
            html += "  <th style=\"border:1px solid rgba(255,255,255,0.1);padding:4px 8px;text-align:left;background:rgba(255,255,255,0.05);font-weight:600;color:#bd93f9\">\(esc(header))</th>\n"
        }
        html += "</tr></thead>\n<tbody>\n"

        // Rows are pipe-delimited, cells within a row are comma-delimited
        for row in rowStrings {
            let cells = row.components(separatedBy: ",")
            html += "<tr>\n"
            for cell in cells {
                html += "  <td style=\"border:1px solid rgba(255,255,255,0.1);padding:4px 8px;color:#f8f8f2\">\(esc(cell.trimmingCharacters(in: .whitespaces)))</td>\n"
            }
            html += "</tr>\n"
        }

        html += "</tbody>\n</table>"
        return html
    }

    // MARK: - Template: status-list

    private static func renderStatusList(_ p: [String: String]) -> String {
        let labels = split(p["labels"]!)
        let statuses = split(p["statuses"]!)
        let details = p["details"].map { split($0) }
        let count = min(labels.count, statuses.count)

        var html = "<div style=\"font-family:-apple-system,sans-serif\">\n"

        for i in 0..<count {
            let status = statuses[i].trimmingCharacters(in: .whitespaces)
            let (badgeColor, badgeText) = statusBadge(for: status)
            let detail = details.flatMap { i < $0.count ? $0[i] : nil }
            let isLast = i == count - 1
            let margin = isLast ? "" : "margin-bottom:8px;"

            html += """
              <div style="display:flex;align-items:center;gap:8px;\(margin)">
                <span data-pipe="statuses" style="font-size:9px;font-weight:600;color:\(badgeColor);background:\(badgeColor)1a;padding:2px 6px;border-radius:4px;min-width:48px;text-align:center">\(esc(badgeText))</span>
                <div style="flex:1">
                  <div data-pipe="labels" style="font-size:11px;color:#f8f8f2">\(esc(labels[i]))</div>
            """
            if let detail, !detail.isEmpty {
                html += "      <div data-pipe=\"details\" style=\"font-size:10px;color:\(mutedText);margin-top:1px\">\(esc(detail))</div>\n"
            }
            html += "    </div>\n  </div>\n"
        }

        html += "</div>\n"
        html += pipeRedistributionScript
        return html
    }

    private static func statusBadge(for status: String) -> (String, String) {
        switch status.lowercased() {
        case "done", "complete", "completed", "pass", "passed", "success", "ok":
            return ("#50fa7b", status)
        case "running", "active", "in-progress", "in_progress":
            return ("#8be9fd", status)
        case "warn", "warning":
            return ("#ffb86c", status)
        case "fail", "failed", "error":
            return ("#ff5555", status)
        case "skip", "skipped":
            return ("rgba(255,255,255,0.4)", status)
        default:
            return ("rgba(255,255,255,0.4)", status)
        }
    }

    // MARK: - Template: message

    private static func renderMessage(_ p: [String: String]) -> String {
        let text = esc(p["text"]!)
        let type = p["type"]!.lowercased()
        let detail = p["detail"]

        let (borderColor, icon) = messageStyle(for: type)

        var html = """
        <div style="border-left:3px solid \(borderColor);padding:8px 12px;font-family:-apple-system,sans-serif">
          <div style="display:flex;align-items:center;gap:6px">
            <span style="font-size:14px">\(icon)</span>
            <span data-param="text" style="font-size:12px;font-weight:500;color:#f8f8f2">\(text)</span>
          </div>
        """

        if let detail, !detail.isEmpty {
            html += "  <div data-param=\"detail\" style=\"font-size:11px;color:\(mutedText);margin-top:4px;padding-left:22px\">\(esc(detail))</div>\n"
        }

        html += "</div>"
        return html
    }

    private static func messageStyle(for type: String) -> (String, String) {
        switch type {
        case "success": return ("#50fa7b", "&#x2705;")
        case "error": return ("#ff5555", "&#x274C;")
        case "warning": return ("#ffb86c", "&#x26A0;&#xFE0F;")
        default: return ("#8be9fd", "&#x2139;&#xFE0F;") // info
        }
    }

    // MARK: - Template: key-value

    private static func renderKeyValue(_ p: [String: String]) -> String {
        let keys = split(p["keys"]!)
        let values = split(p["values"]!)
        let count = min(keys.count, values.count)

        var html = "<div style=\"font-family:-apple-system,sans-serif\">\n"

        for i in 0..<count {
            let isLast = i == count - 1
            let border = isLast ? "" : "border-bottom:1px solid rgba(255,255,255,0.06);"
            html += """
              <div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0;\(border)">
                <span style="font-size:11px;color:\(mutedText)">\(esc(keys[i]))</span>
                <span style="font-size:11px;color:#f8f8f2;font-family:SF Mono,monospace">\(esc(values[i]))</span>
              </div>
            """
        }

        html += "</div>"
        return html
    }

    // MARK: - Template: bar-chart

    private static func renderBarChart(_ p: [String: String]) -> String {
        let labels = split(p["labels"]!)
        let valueStrs = split(p["values"]!)
        let count = min(labels.count, valueStrs.count)
        guard count > 0 else { return "<p style=\"color:\(mutedText)\">No data</p>" }

        let numericValues = valueStrs.prefix(count).map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let maxVal = numericValues.max() ?? 1
        let normalizer = maxVal > 0 ? maxVal : 1

        // Unique prefix per render to avoid SVG gradient ID collisions across widgets
        let uid = String(UUID().uuidString.prefix(8))

        let svgWidth = 380
        let barAreaHeight = 70
        let svgHeight = 110
        let gap = 8
        let totalGaps = (count - 1) * gap
        let barWidth = max(10, (svgWidth - totalGaps - 20) / count)
        let totalBarsWidth = count * barWidth + totalGaps
        let startX = (svgWidth - totalBarsWidth) / 2

        var svg = "<svg width=\"100%\" height=\"\(svgHeight)\" viewBox=\"0 0 \(svgWidth) \(svgHeight)\">\n"
        svg += "<defs>\n"
        for i in 0..<count {
            let c = color(at: i)
            svg += """
              <linearGradient id="tbar\(uid)\(i)" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color="\(c)"/>
                <stop offset="100%" stop-color="\(c)" stop-opacity="0.5"/>
              </linearGradient>
            """
        }
        svg += "</defs>\n"
        svg += "<line x1=\"0\" y1=\"\(barAreaHeight + 5)\" x2=\"\(svgWidth)\" y2=\"\(barAreaHeight + 5)\" stroke=\"rgba(255,255,255,0.1)\" stroke-width=\"1\"/>\n"

        for i in 0..<count {
            let fraction = numericValues[i] / normalizer
            let barHeight = max(4, Int(Double(barAreaHeight) * fraction))
            let x = startX + i * (barWidth + gap)
            let y = barAreaHeight + 5 - barHeight
            let cx = x + barWidth / 2
            let c = color(at: i)

            svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(barWidth)\" height=\"\(barHeight)\" rx=\"4\" fill=\"url(#tbar\(uid)\(i))\"/>\n"
            svg += "<text x=\"\(cx)\" y=\"\(y - 5)\" text-anchor=\"middle\" fill=\"\(c)\" font-size=\"10\" font-family=\"SF Mono,monospace\">\(esc(valueStrs[i].trimmingCharacters(in: .whitespaces)))</text>\n"
            svg += "<text x=\"\(cx)\" y=\"\(barAreaHeight + 20)\" text-anchor=\"middle\" fill=\"\(mutedText)\" font-size=\"9\" font-family=\"-apple-system,sans-serif\">\(esc(labels[i].trimmingCharacters(in: .whitespaces)))</text>\n"
        }

        svg += "</svg>"
        return svg
    }
}
