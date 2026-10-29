import Foundation

/// Read-only responses from `packages/server/src/app.ts` at raft-source
/// v1.21.23-source.1: `/robots.txt`, `/livez`, `/health`, and the JSON 404.
///
/// Every one of these responses carries `X-Robots-Tag: noindex, nofollow`.
/// Helmet, CORS, and the seq-headroom tripwire are not part of this slice.
/// The tripwire, when it lands, must stay off the health verdict.

public enum HealthResult: Equatable, Sendable {
    case ok
    case databaseUnreachable
}

public enum HealthCheck {
    public static func run(_ ping: @Sendable () async throws -> Void) async -> HealthResult {
        do {
            try await ping()
            return .ok
        } catch {
            return .databaseUnreachable
        }
    }
}

public struct HTTPReply: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String

    public init(status: Int, headers: [String: String], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func value(for header: String) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(header) == .orderedSame {
            return value
        }
        return nil
    }
}

public enum AppFallback {
    public static let robotsTag = "noindex, nofollow"
    public static let jsonContentType = "application/json; charset=utf-8"
    public static let textContentType = "text/plain; charset=utf-8"

    /// The four lines in `app.ts`, joined with `\n`, including the trailing empty line.
    public static let robotsBody = [
        "# Raft API host: authenticated API surface with no indexable public pages.",
        "User-agent: *",
        "Disallow: /",
        "",
    ].joined(separator: "\n")

    /// Pathname the way Express `req.path` exposes it: no query, percent-decoded.
    /// A bad `%` escape is left unchanged, matching `decodeURIComponent` failure.
    public static func requestPath(_ target: String) -> String {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return decodeURIComponent(raw) ?? raw
    }

    public static func notFoundJSON(path: String) -> String {
        "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\(jsonString(path))}"
    }

    public static func healthJSON(_ result: HealthResult) -> String {
        switch result {
        case .ok:
            return "{\"status\":\"ok\"}"
        case .databaseUnreachable:
            return "{\"status\":\"error\",\"detail\":\"database unreachable\"}"
        }
    }

    /// `status` is the HTTP word (`ok` / `error`). The verdict fields follow,
    /// in the order Express builds `{ status, ...verdict }`.
    public static func livezJSON(httpStatus: Int, verdict: LivenessVerdict) -> String {
        let word = httpStatus == 200 ? "ok" : "error"
        let age: String
        if let ms = verdict.msSinceDbSuccess {
            age = String(ms)
        } else {
            age = "null"
        }
        let ok = verdict.ok ? "true" : "false"
        return "{\"status\":\"\(word)\",\"ok\":\(ok),\"db\":\"\(verdict.db.rawValue)\",\"msSinceDbSuccess\":\(age)}"
    }

    public static func reply(
        method: String,
        target: String,
        nodeEnv: String,
        health: HealthResult,
        livez: LivenessVerdict
    ) -> HTTPReply {
        let verb = method.uppercased()
        let path = requestPath(target)
        if verb == "GET" || verb == "HEAD" {
            if path == "/robots.txt" {
                return transmit(status: 200, contentType: textContentType, body: robotsBody, method: verb)
            }
            if path == "/livez" {
                let status = livezStatus(livez, nodeEnv: nodeEnv)
                return transmit(status: status, contentType: jsonContentType, body: livezJSON(httpStatus: status, verdict: livez), method: verb)
            }
            if path == "/health" {
                let status = health == .ok ? 200 : 503
                return transmit(status: status, contentType: jsonContentType, body: healthJSON(health), method: verb)
            }
        }
        return transmit(status: 404, contentType: jsonContentType, body: notFoundJSON(path: path), method: verb)
    }

    public static func respond(
        method: String,
        target: String,
        nodeEnv: String,
        tracker: DbLivenessTracker,
        pingDatabase: @escaping @Sendable () async throws -> Void
    ) async -> HTTPReply {
        let verb = method.uppercased()
        let path = requestPath(target)
        let health: HealthResult
        let livez: LivenessVerdict
        if (verb == "GET" || verb == "HEAD") && path == "/health" {
            health = await HealthCheck.run(pingDatabase)
            livez = .unmonitored
        } else if (verb == "GET" || verb == "HEAD") && path == "/livez" {
            health = .ok
            livez = await tracker.verdict()
        } else {
            health = .ok
            livez = .unmonitored
        }
        return reply(method: verb, target: target, nodeEnv: nodeEnv, health: health, livez: livez)
    }

    private static func transmit(status: Int, contentType: String, body: String, method: String) -> HTTPReply {
        let length = Data(body.utf8).count
        return HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": robotsTag,
                "Content-Type": contentType,
                "Content-Length": String(length),
            ],
            body: method == "HEAD" ? "" : body
        )
    }
}

private func jsonString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\":
            out += "\\\\"
        case "\"":
            out += "\\\""
        case "\u{0008}":
            out += "\\b"
        case "\u{000C}":
            out += "\\f"
        case "\n":
            out += "\\n"
        case "\r":
            out += "\\r"
        case "\t":
            out += "\\t"
        case "\u{2028}", "\u{2029}":
            out += String(format: "\\u%04x", scalar.value)
        case let scalar where scalar.value < 0x20:
            out += String(format: "\\u%04x", scalar.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}

/// `decodeURIComponent`. Returns nil when an escape is malformed or the bytes
/// are not UTF-8, so the caller can keep the raw pathname.
private func decodeURIComponent(_ value: String) -> String? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(value.utf8.count)
    var index = value.startIndex
    while index < value.endIndex {
        if value[index] == "%" {
            guard let hexStart = value.index(index, offsetBy: 1, limitedBy: value.endIndex),
                  let hexEnd = value.index(hexStart, offsetBy: 2, limitedBy: value.endIndex)
            else { return nil }
            guard let byte = UInt8(value[hexStart..<hexEnd], radix: 16) else { return nil }
            bytes.append(byte)
            index = hexEnd
        } else {
            for scalar in value[index].unicodeScalars {
                bytes.append(contentsOf: String(scalar).utf8)
            }
            index = value.index(after: index)
        }
    }
    return String(bytes: bytes, encoding: .utf8)
}
