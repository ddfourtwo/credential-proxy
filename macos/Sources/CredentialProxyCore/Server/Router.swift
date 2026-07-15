import Foundation

public typealias RouteHandler = (HTTPRequest) async throws -> HTTPResponse

public class Router {
    private struct Route {
        let method: String
        let pattern: String
        let segments: [String]
        let handler: RouteHandler
    }

    private var routes: [Route] = []

    public init() {}

    public func route(_ method: String, _ pattern: String, _ handler: @escaping RouteHandler) {
        let segments = pattern.split(separator: "/").map(String.init)
        routes.append(Route(method: method.uppercased(), pattern: pattern, segments: segments, handler: handler))
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var pathMatched = false
        let requestSegments = request.path.split(separator: "/").map(String.init)

        for route in routes {
            guard matches(routeSegments: route.segments, requestSegments: requestSegments) else {
                continue
            }
            pathMatched = true

            guard route.method == request.method else {
                continue
            }

            // Extract params
            var req = request
            req.params = extractParams(routeSegments: route.segments, requestSegments: requestSegments)

            do {
                return try await route.handler(req)
            } catch {
                return .error(500, error.localizedDescription)
            }
        }

        if pathMatched {
            return HTTPResponse(
                status: 405,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"error\":\"Method not allowed\"}".utf8)
            )
        }

        return .error(404, "Unknown endpoint: \(request.method) \(request.path)")
    }

    private func matches(routeSegments: [String], requestSegments: [String]) -> Bool {
        // Trailing "*" matches the remainder of the path (>= 0 segments), captured as params["*"].
        if routeSegments.last == "*" {
            let prefix = routeSegments.dropLast()
            guard requestSegments.count >= prefix.count else { return false }
            for (route, request) in zip(prefix, requestSegments) {
                if route.hasPrefix(":") { continue }
                if route != request { return false }
            }
            return true
        }
        guard routeSegments.count == requestSegments.count else { return false }
        for (route, request) in zip(routeSegments, requestSegments) {
            if route.hasPrefix(":") { continue }
            if route != request { return false }
        }
        return true
    }

    private func extractParams(routeSegments: [String], requestSegments: [String]) -> [String: String] {
        var params: [String: String] = [:]
        let hasTail = routeSegments.last == "*"
        let named = hasTail ? Array(routeSegments.dropLast()) : routeSegments
        for (route, request) in zip(named, requestSegments) {
            if route.hasPrefix(":") {
                let paramName = String(route.dropFirst())
                params[paramName] = request
            }
        }
        if hasTail {
            params["*"] = requestSegments.dropFirst(named.count).joined(separator: "/")
        }
        return params
    }
}
