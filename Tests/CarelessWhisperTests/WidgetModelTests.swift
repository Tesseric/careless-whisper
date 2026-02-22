import XCTest
@testable import CarelessWhisper

final class WidgetModelTests: XCTestCase {

    // MARK: - AgentWidget

    func testAgentWidgetEncodeDecode() throws {
        let widget = AgentWidget(id: "test-1", title: "Build Status", html: "<h2>OK</h2>", priority: 1)
        let data = try JSONEncoder().encode(widget)
        let decoded = try JSONDecoder().decode(AgentWidget.self, from: data)

        XCTAssertEqual(decoded.id, "test-1")
        XCTAssertEqual(decoded.title, "Build Status")
        XCTAssertEqual(decoded.html, "<h2>OK</h2>")
        XCTAssertEqual(decoded.priority, 1)
    }

    func testAgentWidgetDefaultPriority() throws {
        let widget = AgentWidget(id: "w", html: "<p>hi</p>")
        XCTAssertEqual(widget.priority, 0)
        XCTAssertNil(widget.title)
        XCTAssertNil(widget.params)
    }

    func testAgentWidgetOptionalTitle() throws {
        let json = """
        {"id":"x","html":"<b>bold</b>","priority":0}
        """
        let widget = try JSONDecoder().decode(AgentWidget.self, from: Data(json.utf8))
        XCTAssertNil(widget.title)
    }

    func testAgentWidgetEquatable() {
        let a = AgentWidget(id: "a", title: "T", html: "<p>1</p>", priority: 0)
        let b = AgentWidget(id: "a", title: "T", html: "<p>1</p>", priority: 0)
        let c = AgentWidget(id: "a", title: "T", html: "<p>2</p>", priority: 0)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ShowOverlayRequest

    func testShowOverlayRequestDecode() throws {
        let json = """
        {
          "widgets": [
            {"id":"s1","title":"Status","html":"<div>ok</div>","priority":0},
            {"id":"s2","html":"<span>2</span>","priority":1}
          ]
        }
        """
        let request = try JSONDecoder().decode(ShowOverlayRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.widgets.count, 2)
        XCTAssertEqual(request.widgets[0].id, "s1")
        XCTAssertEqual(request.widgets[1].title, nil)
    }

    // MARK: - UpdateWidgetRequest

    func testUpdateWidgetRequestDecode() throws {
        let json = """
        {"widget":{"id":"u1","title":"Update","html":"<p>new</p>","priority":2}}
        """
        let request = try JSONDecoder().decode(UpdateWidgetRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.widget.id, "u1")
        XCTAssertEqual(request.widget.priority, 2)
    }

    // MARK: - OverlayResponse

    func testOverlayResponseEncode() throws {
        let response = OverlayResponse(ok: true, widgetCount: 3, overlayVisible: true)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(OverlayResponse.self, from: data)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.widgetCount, 3)
        XCTAssertTrue(decoded.overlayVisible)
    }

    // MARK: - Params

    func testAgentWidgetWithParams() throws {
        let widget = AgentWidget(
            id: "pw",
            html: "<p>{{msg}}</p>",
            params: ["msg": "hello", "count": "5"]
        )
        let data = try JSONEncoder().encode(widget)
        let decoded = try JSONDecoder().decode(AgentWidget.self, from: data)
        XCTAssertEqual(decoded.params?["msg"], "hello")
        XCTAssertEqual(decoded.params?["count"], "5")
    }

    func testAgentWidgetOptionalParams() throws {
        let json = """
        {"id":"x","html":"<b>bold</b>","priority":0}
        """
        let widget = try JSONDecoder().decode(AgentWidget.self, from: Data(json.utf8))
        XCTAssertNil(widget.params)
    }

    func testUpdateParamsRequestDecode() throws {
        let json = """
        {"id":"claude:build","params":{"pct":"75","status":"Building..."}}
        """
        let request = try JSONDecoder().decode(UpdateParamsRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.id, "claude:build")
        XCTAssertEqual(request.params["pct"], "75")
        XCTAssertEqual(request.params["status"], "Building...")
    }

    func testUpdateParamsRequestDecodeWithoutId() throws {
        let json = """
        {"params":{"pct":"75"}}
        """
        let request = try JSONDecoder().decode(UpdateParamsRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.id)
        XCTAssertEqual(request.params["pct"], "75")
    }

    // MARK: - ServerInfo

    func testServerInfoEncodeDecode() throws {
        let info = ServerInfo(port: 32451, token: "abc-123", pid: 9999)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(decoded.port, 32451)
        XCTAssertEqual(decoded.token, "abc-123")
        XCTAssertEqual(decoded.pid, 9999)
    }
}
