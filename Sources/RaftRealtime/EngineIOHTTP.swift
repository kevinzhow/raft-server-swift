import Foundation
import NIOCore

/// HTTP/1.1 request head as seen by the SwiftNIO socket listener. The event
/// parser only needs the request line and headers; bodies are framed by
/// `Content-Length`, matching engine.io's polling transport.
struct EngineIOHTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var version: String
    private var headers: [String: String]

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(split[0])
        var query: [String: String] = [:]
        if split.count == 2 {
            for pair in split[1].split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(item[0]).removingPercentEncoding ?? String(item[0])
                let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
                query[name] = value
            }
        }
        self.query = query
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var contentLength: Int? {
        guard let raw = header("content-length") else { return nil }
        return Int(raw)
    }

    var keepsConnectionAlive: Bool {
        guard let connection = header("connection")?.lowercased() else {
            return version != "HTTP/1.0"
        }
        return !connection.contains("close")
    }
}

/// `socket.io` configures `cors` with the same origin option as the HTTP API.
/// A single origin is emitted as a fixed value, several origins reflect an
/// allowed request `Origin`, and `*` allows every origin, exactly like the
/// pinned `cors` middleware.
struct EngineIOCORS: Sendable {
    let origins: [String]

    init(origins: [String]) {
        self.origins = origins
    }

    var isEnabled: Bool { !origins.isEmpty }

    func actualResponseHeaders(origin: String?) -> [String] {
        guard isEnabled else { return [] }
        var headers: [String] = []
        if origins == ["*"] {
            headers.append("Access-Control-Allow-Origin: *")
        } else if origins.count == 1 {
            headers.append("Access-Control-Allow-Origin: \(origins[0])")
            headers.append("Vary: Origin")
        } else {
            if let origin, origins.contains(origin) {
                headers.append("Access-Control-Allow-Origin: \(origin)")
            }
            headers.append("Vary: Origin")
        }
        headers.append("Access-Control-Allow-Credentials: true")
        return headers
    }

    func preflightResponseHeaders(origin: String?, requestedHeaders: String?) -> [String] {
        guard isEnabled else { return [] }
        var headers: [String] = []
        if origins == ["*"] {
            headers.append("Access-Control-Allow-Origin: *")
        } else if origins.count == 1 {
            headers.append("Access-Control-Allow-Origin: \(origins[0])")
        } else if let origin, origins.contains(origin) {
            headers.append("Access-Control-Allow-Origin: \(origin)")
        }
        var vary = ["Origin"]
        headers.append("Access-Control-Allow-Credentials: true")
        headers.append("Access-Control-Allow-Methods: GET,HEAD,PUT,PATCH,POST,DELETE")
        if let requestedHeaders, !requestedHeaders.isEmpty {
            headers.append("Access-Control-Allow-Headers: \(requestedHeaders)")
            vary.append("Access-Control-Request-Headers")
        }
        headers.append("Vary: \(vary.joined(separator: ", "))")
        return headers
    }
}

private func isLegacyInternetExplorer(_ userAgent: String) -> Bool {
    userAgent.contains(";MSIE") || userAgent.contains("Trident/")
}

private func engineIOHTTPDate() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: Date())
}

private func engineIOHTTPConnectionHeaders(keepAlive: Bool) -> [String] {
    if keepAlive {
        return ["Connection: keep-alive", "Keep-Alive: timeout=5"]
    }
    return ["Connection: close"]
}

func engineIOHTTPResponseBytes(
    status: String,
    headers: [String],
    body: [UInt8],
    keepAlive: Bool,
    chunked: Bool,
    contentLength: Bool
) -> [UInt8] {
    var lines = ["HTTP/1.1 \(status)"]
    lines.append(contentsOf: headers)
    var tail = [UInt8]()
    if chunked {
        lines.append("Transfer-Encoding: chunked")
    } else if contentLength {
        lines.append("Content-Length: \(body.count)")
    }
    lines.append("Date: \(engineIOHTTPDate())")
    lines.append(contentsOf: engineIOHTTPConnectionHeaders(keepAlive: keepAlive))
    tail.append(contentsOf: Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    if chunked {
        if body.isEmpty {
            tail.append(contentsOf: Array("0\r\n\r\n".utf8))
        } else {
            tail.append(contentsOf: Array(String(body.count, radix: 16).utf8))
            tail.append(contentsOf: Array("\r\n".utf8))
            tail.append(contentsOf: body)
            tail.append(contentsOf: Array("\r\n0\r\n\r\n".utf8))
        }
    } else {
        tail.append(contentsOf: body)
    }
    return tail
}

/// A normal polling payload: `200`, `text/plain; charset=UTF-8`, an explicit
/// body length, and the engine.io cache-suppression header.
func engineIOPollResponseBytes(
    body: String, cors: EngineIOCORS, origin: String?, userAgent: String?, keepAlive: Bool
) -> [UInt8] {
    var headers = cors.actualResponseHeaders(origin: origin)
    if let userAgent, isLegacyInternetExplorer(userAgent) {
        headers.append("X-XSS-Protection: 0")
    }
    headers.append("Content-Type: text/plain; charset=UTF-8")
    headers.append("cache-control: no-store")
    return engineIOHTTPResponseBytes(
        status: "200 OK", headers: headers, body: Array(body.utf8),
        keepAlive: keepAlive, chunked: false, contentLength: true
    )
}

/// The POST acknowledgement in `Polling.onEnd`: `text/html` and the literal
/// `ok`, not a JSON document.
func engineIOPostAckBytes(
    cors: EngineIOCORS, origin: String?, userAgent: String?, keepAlive: Bool
) -> [UInt8] {
    var headers = cors.actualResponseHeaders(origin: origin)
    if let userAgent, isLegacyInternetExplorer(userAgent) {
        headers.append("X-XSS-Protection: 0")
    }
    headers.append("Content-Type: text/html")
    headers.append("cache-control: no-store")
    return engineIOHTTPResponseBytes(
        status: "200 OK", headers: headers, body: Array("ok".utf8),
        keepAlive: keepAlive, chunked: false, contentLength: true
    )
}

/// `abortRequest`: JSON code/message with a chunked body (Node does not set a
/// length for these), including the CORS headers the socket.io middleware
/// already wrote.
func engineIOErrorResponseBytes(code: Int, message: String, cors: EngineIOCORS, origin: String?, keepAlive: Bool) -> [UInt8] {
    var headers = cors.actualResponseHeaders(origin: origin)
    headers.append("Content-Type: application/json")
    return engineIOHTTPResponseBytes(
        status: "400 Bad Request", headers: headers,
        body: Array(engineIOErrorBody(code: code, message: message).utf8),
        keepAlive: keepAlive, chunked: true, contentLength: false
    )
}

/// Polling overlap and binary-body refusals call `res.writeHead(...).end()`
/// with no content type and no body.
func engineIOEmptyErrorResponseBytes(status: String, cors: EngineIOCORS, origin: String?, keepAlive: Bool) -> [UInt8] {
    engineIOHTTPResponseBytes(
        status: status, headers: cors.actualResponseHeaders(origin: origin), body: [],
        keepAlive: keepAlive, chunked: true, contentLength: false
    )
}

func engineIOPreflightResponseBytes(cors: EngineIOCORS, origin: String?, requestedHeaders: String?) -> [UInt8] {
    var headers = cors.preflightResponseHeaders(origin: origin, requestedHeaders: requestedHeaders)
    headers.append("Content-Length: 0")
    // `cors` sets the status and length then ends without a cache directive.
    return engineIOHTTPResponseBytes(
        status: "204 No Content", headers: headers, body: [],
        keepAlive: true, chunked: false, contentLength: false
    )
}

/// `abortUpgrade` in engine.io 6.6.11: a plain-text 400 with `Connection:
/// close` before the WebSocket handshake completes.
func engineIOWebSocketAbortBytes(message: String) -> [UInt8] {
    let body = Array(message.utf8)
    let head = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-type: text/html\r\nContent-Length: \(body.count)\r\n\r\n"
    return Array(head.utf8) + body
}

func engineIOWrite(_ bytes: [UInt8], to channel: any Channel, closeAfterWrite: Bool) {
    guard !bytes.isEmpty else {
        if closeAfterWrite { channel.close(promise: nil) }
        return
    }
    var buffer = channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    if closeAfterWrite {
        channel.writeAndFlush(buffer).whenComplete { _ in
            channel.close(promise: nil)
        }
    } else {
        channel.writeAndFlush(buffer, promise: nil)
    }
}
