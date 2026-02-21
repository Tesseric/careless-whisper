import Foundation
import Network
import os

/// Handles a single HTTP connection: parses the request, dispatches to handler, writes response.
final class HTTPConnection: Hashable {
    private let connection: NWConnection
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "HTTPConnection")
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let id = UUID()

    /// Called when the connection is finished (response sent or error).
    var onComplete: (() -> Void)?

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    static func == (lhs: HTTPConnection, rhs: HTTPConnection) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.logger.warning("Connection failed: \(error)")
                self?.connection.cancel()
                self?.onComplete?()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest()
    }

    private func receiveRequest() {
        // Read up to 1MB — sufficient for widget HTML payloads
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.warning("Receive error: \(error)")
                self.connection.cancel()
                self.onComplete?()
                return
            }

            guard let data, let raw = String(data: data, encoding: .utf8) else {
                self.sendResponse(HTTPResponse(status: 400, body: ["error": "Invalid request"]))
                return
            }

            guard let request = self.parseRequest(raw, rawData: data) else {
                self.sendResponse(HTTPResponse(status: 400, body: ["error": "Malformed HTTP request"]))
                return
            }

            Task {
                let response = await self.handler(request)
                self.sendResponse(response)
            }
        }
    }

    private func parseRequest(_ raw: String, rawData: Data) -> HTTPRequest? {
        // Split headers from body at \r\n\r\n
        guard let headerEndRange = raw.range(of: "\r\n\r\n") else { return nil }
        let headerSection = String(raw[raw.startIndex..<headerEndRange.lowerBound])
        let bodyString = String(raw[headerEndRange.upperBound...])

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0].uppercased()
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let body = bodyString.isEmpty ? nil : Data(bodyString.utf8)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func sendResponse(_ response: HTTPResponse) {
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: response.body, options: [])
        } catch {
            jsonData = Data("{\"error\":\"Internal error\"}".utf8)
        }

        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }

        let header = [
            "HTTP/1.1 \(response.status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(jsonData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var responseData = Data(header.utf8)
        responseData.append(jsonData)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.warning("Send error: \(error)")
            }
            self?.connection.cancel()
            self?.onComplete?()
        })
    }
}

// MARK: - Request / Response types

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let status: Int
    let body: [String: Any]
}
