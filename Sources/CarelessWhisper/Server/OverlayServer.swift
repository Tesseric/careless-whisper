import Foundation
import Network
import os

@MainActor
final class OverlayServer {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "OverlayServer")
    private var listener: NWListener?
    private let preferredPort: UInt16 = 32451
    private(set) var actualPort: UInt16 = 0
    private let token = UUID().uuidString
    private var activeConnections: Set<HTTPConnection> = []

    var isRunning: Bool { listener != nil }

    /// Called when the server is ready and listening.
    var onReady: ((UInt16) -> Void)?

    /// Callback invoked on the main actor when widgets change. Set by AppState.
    var onSetWidgets: (([AgentWidget]) -> Void)?
    var onUpsertWidget: ((AgentWidget) -> Void)?
    var onUpdateParams: ((String, [String: String]) -> Void)?
    var onRemoveWidget: ((String) -> Void)?
    var onClearWidgets: (() -> Void)?

    /// Returns the current overlay response info. Set by AppState.
    var getWidgetCount: (() -> Int)?
    var getOverlayVisible: (() -> Bool)?

    func start() {
        // Clean up any stale temp files from a previous session
        removeTempFiles()

        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: preferredPort)!)
            listener = try NWListener(using: params)
        } catch {
            logger.info("Preferred port \(self.preferredPort) unavailable, using OS-assigned port")
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                listener = try NWListener(using: params)
            } catch {
                logger.error("Failed to create listener: \(error)")
                return
            }
        }

        guard let listener else { return }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port {
                    let portValue = port.rawValue
                    Task { @MainActor in
                        self.actualPort = portValue
                        self.logger.info("Overlay server listening on 127.0.0.1:\(portValue)")
                        self.writePortFile()
                        self.onReady?(portValue)
                    }
                }
            case .failed(let error):
                self.logger.error("Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in
                let httpConn = HTTPConnection(connection: connection) { [weak self] request in
                    guard let self else {
                        return HTTPResponse(status: 503, body: ["error": "Server shutting down"])
                    }
                    return await self.handleRequest(request)
                }
                self.activeConnections.insert(httpConn)
                httpConn.onComplete = { [weak self, weak httpConn] in
                    guard let httpConn else { return }
                    Task { @MainActor in
                        self?.activeConnections.remove(httpConn)
                    }
                }
                httpConn.start()
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.removeAll()
        removePortFile()
        removeTempFiles()
    }

    // MARK: - Routing

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Auth check (skip for health)
        if request.path != "/health" {
            guard let auth = request.headers["authorization"],
                  auth == "Bearer \(token)" else {
                return HTTPResponse(status: 401, body: ["error": "Unauthorized"])
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return HTTPResponse(status: 200, body: ["status": "ok"])

        case ("POST", "/overlay/show"):
            return await handleShow(request)

        case ("POST", "/overlay/update"):
            return await handleUpdate(request)

        case ("POST", "/overlay/params"):
            return await handleUpdateParams(id: nil, request)

        case ("POST", let path) where path.hasPrefix("/overlay/params/"):
            let id = String(path.dropFirst("/overlay/params/".count))
            return await handleUpdateParams(id: id, request)

        case ("POST", "/overlay/dismiss"):
            return await handleDismiss()

        case ("POST", let path) where path.hasPrefix("/overlay/dismiss/"):
            let id = String(path.dropFirst("/overlay/dismiss/".count))
            return await handleDismissWidget(id: id)

        default:
            if request.method != "GET" && request.method != "POST" {
                return HTTPResponse(status: 405, body: ["error": "Method not allowed"])
            }
            return HTTPResponse(status: 404, body: ["error": "Not found"])
        }
    }

    private func handleShow(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse(status: 400, body: ["error": "Missing request body"])
        }
        guard var showRequest = try? JSONDecoder().decode(ShowOverlayRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: ["error": "Invalid JSON"])
        }

        for i in showRequest.widgets.indices {
            if let errorResponse = resolveTemplate(&showRequest.widgets[i]) {
                return errorResponse
            }
        }

        await MainActor.run {
            onSetWidgets?(showRequest.widgets)
        }

        return await makeOverlayResponse()
    }

    private func handleUpdate(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse(status: 400, body: ["error": "Missing request body"])
        }
        guard var updateRequest = try? JSONDecoder().decode(UpdateWidgetRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: ["error": "Invalid JSON"])
        }

        if let errorResponse = resolveTemplate(&updateRequest.widget) {
            return errorResponse
        }

        await MainActor.run {
            onUpsertWidget?(updateRequest.widget)
        }

        return await makeOverlayResponse()
    }

    private func handleUpdateParams(id: String?, _ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse(status: 400, body: ["error": "Missing request body"])
        }
        guard let paramsRequest = try? JSONDecoder().decode(UpdateParamsRequest.self, from: body) else {
            return HTTPResponse(status: 400, body: ["error": "Invalid JSON — expected {\"id\":\"...\",\"params\":{...}}"])
        }

        // ID from path takes precedence, then from body
        let resolvedId = (id.flatMap { $0.isEmpty ? nil : $0 }) ?? paramsRequest.id
        guard let widgetId = resolvedId, !widgetId.isEmpty else {
            return HTTPResponse(status: 400, body: ["error": "Missing widget ID"])
        }

        let decodedId = widgetId.removingPercentEncoding ?? widgetId
        await MainActor.run {
            onUpdateParams?(decodedId, paramsRequest.params)
        }

        return await makeOverlayResponse()
    }

    private func handleDismiss() async -> HTTPResponse {
        await MainActor.run {
            onClearWidgets?()
        }
        return await makeOverlayResponse()
    }

    private func handleDismissWidget(id: String) async -> HTTPResponse {
        await MainActor.run {
            onRemoveWidget?(id)
        }
        return await makeOverlayResponse()
    }

    private func makeOverlayResponse() async -> HTTPResponse {
        let count = await MainActor.run { getWidgetCount?() ?? 0 }
        let visible = await MainActor.run { getOverlayVisible?() ?? false }
        return HTTPResponse(status: 200, body: [
            "ok": true,
            "widgetCount": count,
            "overlayVisible": visible
        ])
    }

    // MARK: - Template Resolution

    /// Resolves a template-based widget into HTML. Returns an HTTP 400 response on error, nil on success.
    private func resolveTemplate(_ widget: inout AgentWidget) -> HTTPResponse? {
        guard let templateName = widget.template else {
            // No template — require html
            if widget.html.isEmpty {
                return HTTPResponse(status: 400, body: ["error": "Widget must have either 'template' or 'html'"])
            }
            return nil
        }

        do {
            widget.html = try WidgetTemplateRegistry.render(template: templateName, params: widget.params)
        } catch {
            return HTTPResponse(status: 400, body: ["error": error.localizedDescription])
        }
        return nil
    }

    // MARK: - Port file

    private static var portFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".careless-whisper")
            .appendingPathComponent("server.json")
    }

    private func writePortFile() {
        let dir = Self.portFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let info = ServerInfo(port: actualPort, token: token, pid: ProcessInfo.processInfo.processIdentifier)
        guard let data = try? JSONEncoder().encode(info) else {
            logger.error("Failed to encode server info")
            return
        }

        do {
            try data.write(to: Self.portFileURL, options: .atomic)
            // Restrict permissions to owner only (0600)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.portFileURL.path
            )
            logger.info("Wrote port file to \(Self.portFileURL.path)")
        } catch {
            logger.error("Failed to write port file: \(error)")
        }
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(at: Self.portFileURL)
        logger.info("Removed port file")
    }

    // MARK: - Temp file cleanup

    /// Remove stale `overlay-*.json` temp files left over from previous sessions.
    func removeTempFiles() {
        let fm = FileManager.default
        let tmpDir = "/tmp"
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for filename in contents where filename.hasPrefix("overlay-") && filename.hasSuffix(".json") {
            let path = "\(tmpDir)/\(filename)"
            try? fm.removeItem(atPath: path)
            logger.info("Removed stale temp file: \(path)")
        }
    }
}
