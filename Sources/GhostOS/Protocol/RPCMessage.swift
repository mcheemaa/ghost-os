// RPCMessage.swift — JSON-RPC request/response types for Ghost OS IPC

import Foundation

/// A JSON-RPC 2.0 style request
public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: RPCParams?
    public let id: Int

    public init(method: String, params: RPCParams? = nil, id: Int) {
        self.method = method
        self.params = params
        self.id = id
    }
}

/// Parameters for RPC methods — a flexible key-value container
public struct RPCParams: Codable, Sendable {
    public let query: String?
    public let role: String?
    public let target: String?
    public let text: String?
    public let key: String?
    public let keys: [String]?
    public let app: String?
    public let x: Double?
    public let y: Double?
    public let direction: String?
    public let amount: Double?
    public let action: String?
    public let depth: Int?

    public init(
        query: String? = nil,
        role: String? = nil,
        target: String? = nil,
        text: String? = nil,
        key: String? = nil,
        keys: [String]? = nil,
        app: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        direction: String? = nil,
        amount: Double? = nil,
        action: String? = nil,
        depth: Int? = nil
    ) {
        self.query = query
        self.role = role
        self.target = target
        self.text = text
        self.key = key
        self.keys = keys
        self.app = app
        self.x = x
        self.y = y
        self.direction = direction
        self.amount = amount
        self.action = action
        self.depth = depth
    }
}

/// A JSON-RPC 2.0 style response
public struct RPCResponse: Codable, Sendable {
    public let result: RPCResult?
    public let error: RPCError?
    public let id: Int

    public static func success(_ result: RPCResult, id: Int) -> RPCResponse {
        RPCResponse(result: result, error: nil, id: id)
    }

    public static func failure(_ error: RPCError, id: Int) -> RPCResponse {
        RPCResponse(result: nil, error: error, id: id)
    }
}

/// Successful result — wraps various return types
public enum RPCResult: Codable, Sendable {
    case state(ScreenState)
    case elements([ElementNode])
    case tree(ElementNode)
    case diff(StateDiff)
    case content([ContentItem])
    case app(AppInfo)
    case message(String)
    case bool(Bool)

    enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .state(state):
            try container.encode("state", forKey: .type)
            try container.encode(state, forKey: .data)
        case let .elements(elements):
            try container.encode("elements", forKey: .type)
            try container.encode(elements, forKey: .data)
        case let .tree(tree):
            try container.encode("tree", forKey: .type)
            try container.encode(tree, forKey: .data)
        case let .diff(diff):
            try container.encode("diff", forKey: .type)
            try container.encode(diff, forKey: .data)
        case let .content(items):
            try container.encode("content", forKey: .type)
            try container.encode(items, forKey: .data)
        case let .app(app):
            try container.encode("app", forKey: .type)
            try container.encode(app, forKey: .data)
        case let .message(msg):
            try container.encode("message", forKey: .type)
            try container.encode(msg, forKey: .data)
        case let .bool(val):
            try container.encode("bool", forKey: .type)
            try container.encode(val, forKey: .data)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "state":
            self = .state(try container.decode(ScreenState.self, forKey: .data))
        case "elements":
            self = .elements(try container.decode([ElementNode].self, forKey: .data))
        case "tree":
            self = .tree(try container.decode(ElementNode.self, forKey: .data))
        case "diff":
            self = .diff(try container.decode(StateDiff.self, forKey: .data))
        case "content":
            self = .content(try container.decode([ContentItem].self, forKey: .data))
        case "app":
            self = .app(try container.decode(AppInfo.self, forKey: .data))
        case "message":
            self = .message(try container.decode(String.self, forKey: .data))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown result type: \(type)")
        }
    }
}

/// Error in RPC response
public struct RPCError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func notFound(_ msg: String) -> RPCError {
        RPCError(code: -1, message: msg)
    }
    public static func invalidParams(_ msg: String) -> RPCError {
        RPCError(code: -2, message: msg)
    }
    public static func permissionDenied(_ msg: String) -> RPCError {
        RPCError(code: -3, message: msg)
    }
    public static func internalError(_ msg: String) -> RPCError {
        RPCError(code: -4, message: msg)
    }
    public static func methodNotFound(_ msg: String) -> RPCError {
        RPCError(code: -5, message: msg)
    }
}
