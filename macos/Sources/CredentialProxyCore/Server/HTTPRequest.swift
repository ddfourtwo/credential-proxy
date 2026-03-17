import Foundation

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]  // lowercase keys for case-insensitive lookup
    public var body: Data?
    public var params: [String: String] = [:]

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data?, params: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.params = params
    }

    public var bodyString: String? {
        guard let body else { return nil }
        return String(data: body, encoding: .utf8)
    }

    public static func parse(from data: Data) -> HTTPRequest? {
        guard let headerEnd = findHeaderEnd(in: data) else { return nil }

        let headerData = data[data.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        // Parse request line: METHOD /path?query HTTP/1.1
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let rawURI = String(parts[1])

        // Split path and query
        let (path, query) = parseURI(rawURI)

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Parse body based on Content-Length
        let bodyStart = headerEnd + 4  // skip \r\n\r\n
        var body: Data?
        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr),
           contentLength > 0 {
            let available = data.count - bodyStart
            guard available >= contentLength else { return nil }  // incomplete
            body = data[bodyStart..<(bodyStart + contentLength)]
        }

        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    /// Returns the byte offset of the start of \r\n\r\n in data, or nil if not found
    public static func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]  // \r\n\r\n
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[data.startIndex + i] == separator[0] &&
               data[data.startIndex + i + 1] == separator[1] &&
               data[data.startIndex + i + 2] == separator[2] &&
               data[data.startIndex + i + 3] == separator[3] {
                return data.startIndex + i
            }
        }
        return nil
    }

    /// Returns the total expected size of the request (headers + body), or nil if headers incomplete
    public static func expectedSize(of data: Data) -> Int? {
        guard let headerEnd = findHeaderEnd(in: data) else { return nil }
        let headerString = String(data: data[data.startIndex..<headerEnd], encoding: .utf8) ?? ""
        let lines = headerString.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let cl = Int(value) {
                    return headerEnd + 4 + cl
                }
            }
        }
        return headerEnd + 4  // no body
    }

    private static func parseURI(_ uri: String) -> (path: String, query: [String: String]) {
        guard let questionMark = uri.firstIndex(of: "?") else {
            return (uri, [:])
        }
        let path = String(uri[uri.startIndex..<questionMark])
        let queryString = String(uri[uri.index(after: questionMark)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                query[key] = value
            } else if kv.count == 1 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                query[key] = ""
            }
        }
        return (path, query)
    }
}
