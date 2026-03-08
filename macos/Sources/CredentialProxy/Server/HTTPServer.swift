import Foundation
import Network

class HTTPServer {
    private let port: UInt16
    private let host: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "HTTPServer", attributes: .concurrent)

    var router: Router?

    private static let maxBodySize = 1024 * 1024  // 1 MB

    private static let corsHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
    ]

    init(port: UInt16, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }

    func start(router: Router) throws {
        self.router = router

        let params = NWParameters.tcp
        if let proto = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            proto.version = .v4
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }
        let listener = try NWListener(using: params, on: nwPort)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("credential-proxy HTTP server running at http://\(self.host):\(self.port)")
            case .failed(let error):
                print("Server failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(on: connection, buffer: Data())
    }

    private func receiveData(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("Connection error: \(error)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            // Check body size limit early
            if accumulated.count > Self.maxBodySize + 8192 {  // headers + body limit
                let response = self.addCORSHeaders(to: .error(413, "Request body too large"))
                self.send(response, on: connection)
                return
            }

            // Check if we have a complete request
            if let expectedSize = HTTPRequest.expectedSize(of: accumulated) {
                if expectedSize > Self.maxBodySize + 8192 {
                    let response = self.addCORSHeaders(to: .error(413, "Request body too large"))
                    self.send(response, on: connection)
                    return
                }
                if accumulated.count >= expectedSize {
                    self.processRequest(data: accumulated, on: connection)
                    return
                }
            }

            if isComplete {
                // Connection closed; try to parse what we have
                if HTTPRequest.findHeaderEnd(in: accumulated) != nil {
                    self.processRequest(data: accumulated, on: connection)
                } else {
                    connection.cancel()
                }
                return
            }

            // Need more data
            self.receiveData(on: connection, buffer: accumulated)
        }
    }

    private func processRequest(data: Data, on connection: NWConnection) {
        guard let request = HTTPRequest.parse(from: data) else {
            let response = addCORSHeaders(to: .error(400, "Malformed request"))
            send(response, on: connection)
            return
        }

        // Handle OPTIONS preflight
        if request.method == "OPTIONS" {
            var response = HTTPResponse(status: 204)
            response.headers = Self.corsHeaders
            send(response, on: connection)
            return
        }

        // Check body size
        if let body = request.body, body.count > Self.maxBodySize {
            let response = addCORSHeaders(to: .error(413, "Request body too large"))
            send(response, on: connection)
            return
        }

        guard let router else {
            let response = addCORSHeaders(to: .error(500, "No router configured"))
            send(response, on: connection)
            return
        }

        Task {
            let response = await router.handle(request)
            self.send(self.addCORSHeaders(to: response), on: connection)
        }
    }

    private func addCORSHeaders(to response: HTTPResponse) -> HTTPResponse {
        var r = response
        for (key, value) in Self.corsHeaders {
            r.headers[key] = value
        }
        return r
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum ServerError: Error {
    case invalidPort
}
