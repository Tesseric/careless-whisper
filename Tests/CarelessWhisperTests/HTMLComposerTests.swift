import XCTest
@testable import CarelessWhisper

final class HTMLComposerTests: XCTestCase {

    // MARK: - Composition

    func testComposeEmptyWidgets() {
        let html = HTMLComposer.compose(widgets: [])
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        // CSS contains .widget-card class, but no actual widget card divs
        XCTAssertFalse(html.contains("data-widget-id"))
    }

    func testComposeSingleWidget() {
        let widget = AgentWidget(id: "test", title: "Hello", html: "<p>World</p>")
        let html = HTMLComposer.compose(widgets: [widget])

        XCTAssertTrue(html.contains("widget-card"))
        XCTAssertTrue(html.contains("widget-title"))
        XCTAssertTrue(html.contains("Hello"))
        XCTAssertTrue(html.contains("<p>World</p>"))
        XCTAssertTrue(html.contains("data-widget-id=\"test\""))
    }

    func testComposeMultipleWidgets() {
        let widgets = [
            AgentWidget(id: "a", html: "<p>A</p>"),
            AgentWidget(id: "b", html: "<p>B</p>"),
        ]
        let html = HTMLComposer.compose(widgets: widgets)

        XCTAssertTrue(html.contains("data-widget-id=\"a\""))
        XCTAssertTrue(html.contains("data-widget-id=\"b\""))
    }

    func testComposeSortsByPriority() {
        let widgets = [
            AgentWidget(id: "low", html: "<p>Low</p>", priority: 10),
            AgentWidget(id: "high", html: "<p>High</p>", priority: 0),
            AgentWidget(id: "mid", html: "<p>Mid</p>", priority: 5),
        ]
        let html = HTMLComposer.compose(widgets: widgets)

        // High priority (0) should appear before mid (5) before low (10)
        let highIndex = html.range(of: "data-widget-id=\"high\"")!.lowerBound
        let midIndex = html.range(of: "data-widget-id=\"mid\"")!.lowerBound
        let lowIndex = html.range(of: "data-widget-id=\"low\"")!.lowerBound

        XCTAssertLessThan(highIndex, midIndex)
        XCTAssertLessThan(midIndex, lowIndex)
    }

    func testComposeWidgetWithoutTitle() {
        let widget = AgentWidget(id: "notitle", html: "<span>content</span>")
        let html = HTMLComposer.compose(widgets: [widget])

        XCTAssertTrue(html.contains("<div class=\"widget-content\">"))
        // No title div should be rendered (CSS has .widget-title but no actual div)
        XCTAssertFalse(html.contains("<div class=\"widget-title\">"))
    }

    func testComposeIncludesCSP() {
        let html = HTMLComposer.compose(widgets: [])
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("style-src 'unsafe-inline'"))
        XCTAssertTrue(html.contains("script-src 'unsafe-inline'"))
        XCTAssertTrue(html.contains("img-src data:"))
    }

    // MARK: - Title Escaping

    func testComposeTitleIsEscaped() {
        let widget = AgentWidget(id: "esc", title: "<script>alert(1)</script>", html: "<p>safe</p>")
        let html = HTMLComposer.compose(widgets: [widget])

        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }

    // MARK: - Sanitization

    func testSanitizeRemovesIframe() {
        let input = "<p>Hello</p><iframe src=\"evil.com\"></iframe><p>World</p>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("iframe"))
        XCTAssertTrue(result.contains("<p>Hello</p>"))
        XCTAssertTrue(result.contains("<p>World</p>"))
    }

    func testSanitizeRemovesObject() {
        let input = "<object data=\"x\"></object>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("object"))
    }

    func testSanitizeRemovesEmbed() {
        let input = "<embed src=\"x\" />"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("embed"))
    }

    func testSanitizeRemovesForm() {
        let input = "<form action=\"x\"><input type=\"text\"></form>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("form"))
    }

    func testSanitizeRemovesLink() {
        let input = "<link rel=\"stylesheet\" href=\"evil.css\">"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("link"))
    }

    func testSanitizeRemovesMeta() {
        let input = "<meta http-equiv=\"refresh\" content=\"0;url=evil.com\">"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("meta"))
    }

    func testSanitizeRemovesBase() {
        let input = "<base href=\"evil.com\">"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("base href"))
    }

    func testSanitizeAllowsScript() {
        let input = "<script>console.log('chart')</script>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertTrue(result.contains("<script>"))
    }

    func testSanitizePreservesSafeHTML() {
        let input = "<h2>Title</h2><p>Content with <strong>bold</strong> and <em>italic</em></p>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertEqual(result, input)
    }

    func testSanitizeCaseInsensitive() {
        let input = "<IFRAME src=\"evil.com\"></IFRAME>"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.lowercased().contains("iframe"))
    }

    func testSanitizeSelfClosingForbiddenTag() {
        let input = "<embed src=\"x\" />"
        let result = HTMLComposer.sanitizeHTML(input)
        XCTAssertFalse(result.contains("embed"))
    }

    // MARK: - HTML Escaping

    func testEscapeHTML() {
        XCTAssertEqual(HTMLComposer.escapeHTML("<script>"), "&lt;script&gt;")
        XCTAssertEqual(HTMLComposer.escapeHTML("a & b"), "a &amp; b")
        XCTAssertEqual(HTMLComposer.escapeHTML("\"quoted\""), "&quot;quoted&quot;")
    }
}
