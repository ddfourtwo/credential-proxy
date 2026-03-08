import Foundation

// MARK: - Proxy Request

struct ProxyRequestInput: Codable {
    let method: String
    let url: String
    var headers: [String: String]?
    var body: ProxyBody?
    var timeout: Int?
}

/// Handles JSON body as either a string or a dictionary.
enum ProxyBody: Codable {
    case string(String)
    case dict([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(
                ProxyBody.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or object for body")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
}

/// Type-erased JSON value for arbitrary dictionary bodies.
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .dict(let dict): try container.encode(dict)
        }
    }
}

struct ProxyRequestOutput: Codable {
    let status: Int
    let statusText: String
    let headers: [String: String]
    let body: String
    let redacted: Bool
}

enum ProxyRequestErrorType: String, Codable {
    case secretNotFound = "SECRET_NOT_FOUND"
    case secretDomainBlocked = "SECRET_DOMAIN_BLOCKED"
    case secretPlacementBlocked = "SECRET_PLACEMENT_BLOCKED"
    case requestFailed = "REQUEST_FAILED"
}

struct ProxyRequestError: Codable {
    let error: ProxyRequestErrorType
    let message: String
    var hint: String?
    var secret: String?
    var requestedDomain: String?
    var allowedDomains: [String]?
    var requestedPlacement: String?
    var allowedPlacements: [String]?
    var cause: String?
}

// MARK: - Proxy Exec

struct ProxyExecInput: Codable {
    let command: [String]
    var env: [String: String]?
    var cwd: String?
    var timeout: Int?
    var stdin: String?
}

struct ProxyExecOutput: Codable {
    let exitCode: Int
    let stdout: String
    let stderr: String
    let redacted: Bool
    let timedOut: Bool
}

enum ProxyExecErrorType: String, Codable {
    case secretNotFound = "SECRET_NOT_FOUND"
    case secretCommandBlocked = "SECRET_COMMAND_BLOCKED"
    case secretPlacementBlocked = "SECRET_PLACEMENT_BLOCKED"
    case execFailed = "EXEC_FAILED"
}

struct ProxyExecError: Codable {
    let error: ProxyExecErrorType
    let message: String
    var hint: String?
    var secret: String?
    var requestedCommand: String?
    var allowedCommands: [String]?
    var requestedPlacement: String?
    var allowedPlacements: [String]?
    var cause: String?
}
