import SwiftUI
import WebKit

/// Holds a weak reference to the WKWebView so that AppState can inject JavaScript
/// for param-only updates without triggering a full HTML reload.
@MainActor
final class WidgetWebViewBridge {
    weak var webView: WKWebView?

    func updateParams(widgetId: String, params: [String: String]) {
        guard let webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let json = String(data: data, encoding: .utf8) else { return }
        let escapedId = widgetId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("_updateWidgetParams('\(escapedId)', \(json))") { _, error in
            if let error {
                // Silently ignore — page may not be loaded yet; next full compose will include latest params
                _ = error
            }
        }
    }
}

struct WidgetWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    var bridge: WidgetWebViewBridge?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.hasVerticalScroller = false

        context.coordinator.currentHash = html.hashValue
        context.coordinator.heightBinding = $contentHeight
        bridge?.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        bridge?.webView = webView
        let newHash = html.hashValue
        guard newHash != context.coordinator.currentHash else { return }
        context.coordinator.currentHash = newHash
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentHash: Int = 0
        var heightBinding: Binding<CGFloat>?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.heightBinding?.wrappedValue = height
                    }
                }
            }
        }
    }
}
