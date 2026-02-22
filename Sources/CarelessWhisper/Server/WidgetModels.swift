import Foundation

struct AgentWidget: Codable, Identifiable, Equatable {
    let id: String
    var title: String?
    var html: String
    var priority: Int
    var params: [String: String]?
    var template: String?

    init(id: String, title: String? = nil, html: String = "", priority: Int = 0, params: [String: String]? = nil, template: String? = nil) {
        self.id = id
        self.title = title
        self.html = html
        self.priority = priority
        self.params = params
        self.template = template
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        html = try container.decodeIfPresent(String.self, forKey: .html) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        params = try container.decodeIfPresent([String: String].self, forKey: .params)
        template = try container.decodeIfPresent(String.self, forKey: .template)
    }
}

// MARK: - Request models

struct ShowOverlayRequest: Codable {
    var widgets: [AgentWidget]
}

struct UpdateWidgetRequest: Codable {
    var widget: AgentWidget
}

struct UpdateParamsRequest: Codable {
    let id: String?
    let params: [String: String]
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
