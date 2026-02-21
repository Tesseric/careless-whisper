import Foundation

struct AgentWidget: Codable, Identifiable, Equatable {
    let id: String
    var title: String?
    var html: String
    var priority: Int

    init(id: String, title: String? = nil, html: String, priority: Int = 0) {
        self.id = id
        self.title = title
        self.html = html
        self.priority = priority
    }
}

// MARK: - Request models

struct ShowOverlayRequest: Codable {
    let widgets: [AgentWidget]
}

struct UpdateWidgetRequest: Codable {
    let widget: AgentWidget
}

// MARK: - Response model

struct OverlayResponse: Codable {
    let ok: Bool
    let widgetCount: Int
    let overlayVisible: Bool
}

// MARK: - Server discovery file

struct ServerInfo: Codable {
    let port: UInt16
    let token: String
    let pid: Int32
}
