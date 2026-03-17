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
        guard routeSegments.count == requestSegments.count else { return false }
        for (route, request) in zip(routeSegments, requestSegments) {
            if route.hasPrefix(":") { continue }
            if route != request { return false }
        }
        return true
    }

    private func extractParams(routeSegments: [String], requestSegments: [String]) -> [String: String] {
        var params: [String: String] = [:]
        for (route, request) in zip(routeSegments, requestSegments) {
            if route.hasPrefix(":") {
                let paramName = String(route.dropFirst())
                params[paramName] = request
            }
        }
        return params
    }
}
