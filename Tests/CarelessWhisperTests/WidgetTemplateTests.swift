import XCTest
@testable import CarelessWhisper

final class WidgetTemplateTests: XCTestCase {

    // MARK: - Progress

    func testProgressRendersHTML() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "progress",
            params: ["label": "Building", "pct": "45%", "status": "Compiling..."]
        )
        XCTAssertTrue(html.contains("data-param=\"label\""))
        XCTAssertTrue(html.contains("Building"))
        XCTAssertTrue(html.contains("data-param=\"pct\""))
        XCTAssertTrue(html.contains("45%"))
        XCTAssertTrue(html.contains("data-param=\"status\""))
        XCTAssertTrue(html.contains("Compiling..."))
        XCTAssertTrue(html.contains("var(--pct)"))
    }

    // MARK: - Steps

    func testStepsRendersAllItems() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "steps",
            params: ["labels": "Build|Test|Deploy", "statuses": "done|running|pending"]
        )
        XCTAssertTrue(html.contains("Build"))
        XCTAssertTrue(html.contains("Test"))
        XCTAssertTrue(html.contains("Deploy"))
        XCTAssertTrue(html.contains("#50fa7b")) // done color
        XCTAssertTrue(html.contains("#8be9fd")) // running color
    }

    func testStepsWithDetails() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "steps",
            params: ["labels": "Build|Test", "statuses": "done|running", "details": "1m 12s|in progress"]
        )
        XCTAssertTrue(html.contains("1m 12s"))
        XCTAssertTrue(html.contains("in progress"))
    }

    // MARK: - Metrics

    func testMetricsRendersCards() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "metrics",
            params: ["values": "98%|1.2s|247", "labels": "Tests|Build|Commits"]
        )
        XCTAssertTrue(html.contains("98%"))
        XCTAssertTrue(html.contains("1.2s"))
        XCTAssertTrue(html.contains("247"))
        XCTAssertTrue(html.contains("Tests"))
        XCTAssertTrue(html.contains("Build"))
        XCTAssertTrue(html.contains("Commits"))
        XCTAssertTrue(html.contains("grid"))
    }

    // MARK: - Table

    func testTableRendersHeadersAndRows() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "table",
            params: ["headers": "Name|Version", "rows": "SwiftWhisper,1.2|HotKey,0.2"]
        )
        XCTAssertTrue(html.contains("<th"))
        XCTAssertTrue(html.contains("Name"))
        XCTAssertTrue(html.contains("Version"))
        XCTAssertTrue(html.contains("SwiftWhisper"))
        XCTAssertTrue(html.contains("1.2"))
        XCTAssertTrue(html.contains("HotKey"))
        XCTAssertTrue(html.contains("<td"))
    }

    // MARK: - Status List

    func testStatusListRendersItems() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "status-list",
            params: ["labels": "Lint|Tests", "statuses": "ok|fail"]
        )
        XCTAssertTrue(html.contains("Lint"))
        XCTAssertTrue(html.contains("Tests"))
        XCTAssertTrue(html.contains("#50fa7b")) // ok color
        XCTAssertTrue(html.contains("#ff5555")) // fail color
    }

    func testStatusListWithDetails() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "status-list",
            params: ["labels": "Lint|Tests", "statuses": "ok|running", "details": "No issues|43/100"]
        )
        XCTAssertTrue(html.contains("No issues"))
        XCTAssertTrue(html.contains("43/100"))
    }

    // MARK: - Message

    func testMessageRendersTypes() throws {
        for type in ["info", "success", "warning", "error"] {
            let html = try WidgetTemplateRegistry.render(
                template: "message",
                params: ["text": "Test message", "type": type]
            )
            XCTAssertTrue(html.contains("Test message"), "Message text missing for type: \(type)")
            XCTAssertTrue(html.contains("data-param=\"text\""), "data-param missing for type: \(type)")
        }
    }

    func testMessageWithDetail() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "message",
            params: ["text": "Done", "type": "success", "detail": "All passed"]
        )
        XCTAssertTrue(html.contains("All passed"))
        XCTAssertTrue(html.contains("data-param=\"detail\""))
    }

    // MARK: - Key-Value

    func testKeyValueRendersPairs() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "key-value",
            params: ["keys": "Branch|Commit", "values": "main|abc123"]
        )
        XCTAssertTrue(html.contains("Branch"))
        XCTAssertTrue(html.contains("main"))
        XCTAssertTrue(html.contains("Commit"))
        XCTAssertTrue(html.contains("abc123"))
    }

    // MARK: - Bar Chart

    func testBarChartRendersSVG() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "bar-chart",
            params: ["labels": "A|B|C", "values": "100|200|150"]
        )
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("<rect"))
        XCTAssertTrue(html.contains("100"))
        XCTAssertTrue(html.contains("200"))
        XCTAssertTrue(html.contains("150"))
        XCTAssertTrue(html.contains("A"))
        XCTAssertTrue(html.contains("B"))
        XCTAssertTrue(html.contains("C"))
    }

    // MARK: - Error Handling

    func testUnknownTemplateThrows() {
        XCTAssertThrowsError(
            try WidgetTemplateRegistry.render(template: "nonexistent", params: [:])
        ) { error in
            guard let templateError = error as? WidgetTemplateError,
                  case .unknownTemplate(let name) = templateError else {
                XCTFail("Expected unknownTemplate error")
                return
            }
            XCTAssertEqual(name, "nonexistent")
        }
    }

    func testMissingRequiredParamsThrows() {
        XCTAssertThrowsError(
            try WidgetTemplateRegistry.render(template: "progress", params: ["label": "Build"])
        ) { error in
            guard let templateError = error as? WidgetTemplateError,
                  case .missingRequiredParams(let template, let missing) = templateError else {
                XCTFail("Expected missingRequiredParams error")
                return
            }
            XCTAssertEqual(template, "progress")
            XCTAssertTrue(missing.contains("pct"))
            XCTAssertTrue(missing.contains("status"))
        }
    }

    func testMissingAllParamsThrows() {
        XCTAssertThrowsError(
            try WidgetTemplateRegistry.render(template: "progress", params: nil)
        ) { error in
            guard let templateError = error as? WidgetTemplateError,
                  case .missingRequiredParams = templateError else {
                XCTFail("Expected missingRequiredParams error")
                return
            }
        }
    }

    // MARK: - HTML Escaping

    func testHTMLEscapingInParams() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "message",
            params: ["text": "<script>alert('xss')</script>", "type": "info"]
        )
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testHTMLEscapingInTableCells() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "table",
            params: ["headers": "Name", "rows": "<b>bold</b>"]
        )
        XCTAssertTrue(html.contains("&lt;b&gt;bold&lt;/b&gt;"))
    }

    // MARK: - Integration with HTMLComposer

    func testTemplateOutputComposesCorrectly() throws {
        let html = try WidgetTemplateRegistry.render(
            template: "progress",
            params: ["label": "Test", "pct": "50%", "status": "Running"]
        )
        let widget = AgentWidget(id: "test", title: "Progress", html: html, params: ["label": "Test", "pct": "50%", "status": "Running"])
        let composed = HTMLComposer.compose(widgets: [widget])

        XCTAssertTrue(composed.contains("<!DOCTYPE html>"))
        XCTAssertTrue(composed.contains("data-widget-id"))
        XCTAssertTrue(composed.contains("Running"))
    }
}
