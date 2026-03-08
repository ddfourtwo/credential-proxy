import Foundation

struct HTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: Data?

    private static let statusTexts: [Int: String] = [
        200: "OK",
        201: "Created",
        204: "No Content",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        413: "Payload Too Large",
        500: "Internal Server Error",
    ]

    init(status: Int, statusText: String? = nil, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.statusText = statusText ?? Self.statusTexts[status] ?? "Unknown"
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return error(500, "Failed to encode response")
        }
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        return json(status, ["error": message])
    }

    static func ok(_ value: some Encodable) -> HTTPResponse {
        return json(200, value)
    }

    func serialize() -> Data {
        var result = "HTTP/1.1 \(status) \(statusText)\r\n"

        var allHeaders = headers
        if let body, allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = "close"
        }

        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"

        var data = Data(result.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}
