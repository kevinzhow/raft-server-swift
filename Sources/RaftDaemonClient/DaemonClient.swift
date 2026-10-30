import Foundation
import NIOCore
import NIOPosix
import RaftConnectAuth
import Synchronization

/// Where the daemon presents its api key on `GET /daemon/connect`.
/// `connection.ts` sends `Authorization: Bearer`. Older daemons use `?key=`,
/// which the server still accepts.
public enum DaemonAPIKeyPlacement: Sendable, Equatable {
    case authorizationHeader
    case query
}

/// HTTP upgrade was refused. `reason` is the normalized `Slock-Reason`
/// (`missing_key`, `invalid_key_format`, …) and is nil when the header is absent.
public struct DaemonHandshakeRejection: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var statusCode: Int
    public var reason: String?

    public init(statusCode: Int, reason: String?) {
        self.statusCode = statusCode
        self.reason = reason
    }

    public var description: String {
        if let reason {
            return "WebSocket handshake rejected (status=\(statusCode), slock_reason=\(reason))"
        }
        return "WebSocket handshake rejected (status=\(statusCode))"
    }

    public var errorDescription: String? { description }
}

public struct DaemonMachineContext: Sendable, Equatable {
    public var machineId: String
    public var serverId: String
    public var capabilities: [String]
    public var connectionEpochId: String?

    public init(machineId: String, serverId: String, capabilities: [String], connectionEpochId: String? = nil) {
        self.machineId = machineId
        self.serverId = serverId
        self.capabilities = capabilities
        self.connectionEpochId = connectionEpochId
    }
}

/// `raft-server-capabilities` from the 101 response, plus the first
/// `machine:context` text frame.
public struct DaemonHandshake: Sendable, Equatable {
    public var serverCapabilities: [String]
    public var context: DaemonMachineContext

    public init(serverCapabilities: [String], context: DaemonMachineContext) {
        self.serverCapabilities = serverCapabilities
        self.context = context
    }
}

public enum DaemonConnectError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case timedOut
    case acceptMismatch
    case incompleteResponse
    case badFrame
    case badContext
    case invalidKey

    public var description: String {
        switch self {
        case .timedOut:
            return "WebSocket connection attempt timed out"
        case .acceptMismatch:
            return "Sec-WebSocket-Accept did not match the client's key"
        case .incompleteResponse:
            return "WebSocket handshake ended before machine:context"
        case .badFrame:
            return "WebSocket frame was truncated or not a single text frame"
        case .badContext:
            return "WebSocket text frame was not machine:context JSON"
        case .invalidKey:
            return "api key was rejected before connect"
        }
    }

    public var errorDescription: String? { description }
}

/// Space- or comma-separated `raft-server-capabilities` header.
/// Duplicates are dropped; first-seen order is kept.
/// Source: `parseServerCapabilitiesHeader` in `connection.ts`.
public func parseServerCapabilitiesHeader(_ value: String?) -> [String] {
    guard let value else { return [] }
    var seen = Set<String>()
    var ordered: [String] = []
    var token = ""
    func flush() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        token = ""
        if trimmed.isEmpty || seen.contains(trimmed) { return }
        seen.insert(trimmed)
        ordered.append(trimmed)
    }
    for character in value {
        if character.isWhitespace || character == "," {
            flush()
        } else {
            token.append(character)
        }
    }
    flush()
    return ordered
}

/// `Slock-Reason` must be a short token. Anything else becomes `invalid_header`.
/// Source: `normalizeHandshakeReason` in `connection.ts`.
func normalizeHandshakeReason(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    guard trimmed.wholeMatch(of: /^[A-Za-z0-9_:-]{1,80}$/) != nil else {
        return "invalid_header"
    }
    return trimmed
}

/// RFC 6455 client-to-server text frame. The mask bit is set and the payload
/// is XOR'd with `maskKey`. The server writes the opposite, unmasked, direction.
func websocketClientTextFrame(_ text: String, maskKey: [UInt8]) -> [UInt8] {
    precondition(maskKey.count == 4, "RFC 6455 masking key is 4 bytes")
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
        frame.append(UInt8(payload.count) | 0x80)
    } else if payload.count <= Int(UInt16.max) {
        frame.append(126 | 0x80)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
    } else {
        frame.append(127 | 0x80)
        let length = UInt64(payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((length >> shift) & 0xff))
        }
    }
    frame.append(contentsOf: maskKey)
    for (index, byte) in payload.enumerated() {
        frame.append(byte ^ maskKey[index % 4])
    }
    return frame
}

enum ServerFrameRead: Equatable {
    case needMore
    case invalid
    case frame(opcode: UInt8, fin: Bool, payload: [UInt8], nextOffset: Int)
}

func readServerWebSocketFrame(_ bytes: [UInt8], offset: Int) -> ServerFrameRead {
    guard offset >= 0, bytes.count >= offset + 2 else { return .needMore }
    let first = bytes[offset]
    if first & 0x70 != 0 { return .invalid }
    let fin = first & 0x80 != 0
    let opcode = first & 0x0f
    if opcode >= 0x8 && !fin { return .invalid }
    let second = bytes[offset + 1]
    let masked = second & 0x80 != 0
    let len7 = Int(second & 0x7f)
    var cursor = offset + 2
    let length: Int
    if len7 == 126 {
        guard bytes.count >= cursor + 2 else { return .needMore }
        length = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
        cursor += 2
    } else if len7 == 127 {
        guard bytes.count >= cursor + 8 else { return .needMore }
        if bytes[cursor] & 0x80 != 0 { return .invalid }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[cursor + index])
        }
        if value > 1_048_576 { return .invalid }
        length = Int(value)
        cursor += 8
    } else {
        length = len7
    }
    if length > 1_048_576 || (opcode >= 0x8 && length > 125) { return .invalid }
    var mask = [UInt8](repeating: 0, count: 4)
    if masked {
        guard bytes.count >= cursor + 4 else { return .needMore }
        mask = Array(bytes[cursor..<(cursor + 4)])
        cursor += 4
    }
    guard bytes.count >= cursor + length else { return .needMore }
    var payload = Array(bytes[cursor..<(cursor + length)])
    if masked {
        for index in payload.indices {
            payload[index] ^= mask[index % 4]
        }
    }
    let next = cursor + length
    guard next > offset else { return .invalid }
    return .frame(opcode: opcode, fin: fin, payload: payload, nextOffset: next)
}

func daemonUpgradeRequest(
    host: String,
    port: Int,
    apiKey: String?,
    keyPlacement: DaemonAPIKeyPlacement,
    websocketKey: String
) throws -> String {
    let key = try validatedAPIKey(apiKey)
    var path = "/daemon/connect"
    if keyPlacement == .query, let key {
        guard let encoded = percentEncodeQueryComponent(key) else {
            throw DaemonConnectError.invalidKey
        }
        path += "?key=\(encoded)"
    }
    let hostValue = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    var lines = [
        "GET \(path) HTTP/1.1",
        "Host: \(hostValue)",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: \(websocketKey)",
    ]
    if keyPlacement == .authorizationHeader, let key {
        lines.append("Authorization: Bearer \(key)")
    }
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

enum DaemonUpgradeProgress: Equatable {
    case needMore
    case rejected(DaemonHandshakeRejection)
    case ready(DaemonHandshake)
    case failed(DaemonConnectError)
}

struct DaemonUpgradeAccumulator {
    private var bytes: [UInt8] = []
    let clientKey: String

    init(clientKey: String) {
        self.clientKey = clientKey
    }

    mutating func append(_ chunk: [UInt8]) -> DaemonUpgradeProgress {
        bytes.append(contentsOf: chunk)
        return current()
    }

    func current() -> DaemonUpgradeProgress {
        interpretUpgradeBytes(bytes, clientKey: clientKey)
    }
}

func interpretUpgradeBytes(_ bytes: [UInt8], clientKey: String) -> DaemonUpgradeProgress {
    if bytes.count > 1_048_576 { return .failed(.badFrame) }
    guard let bodyStart = headerBodyStart(bytes) else {
        if bytes.count > 65_536 { return .failed(.badFrame) }
        return .needMore
    }
    let headerBytes = bytes[..<(bodyStart - 4)]
    guard let headerText = String(bytes: headerBytes, encoding: .utf8) else {
        return .failed(.badFrame)
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let status = lines.first, status.hasPrefix("HTTP/") else {
        return .failed(.badFrame)
    }
    let parts = status.split(separator: " ")
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
        return .failed(.badFrame)
    }
    var headers: [String: [String]] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { continue }
        headers[name, default: []].append(String(value))
    }
    if statusCode != 101 {
        let reason = normalizeHandshakeReason(headers["slock-reason"]?.first)
        return .rejected(DaemonHandshakeRejection(statusCode: statusCode, reason: reason))
    }
    guard headers["sec-websocket-accept"]?.first == secWebSocketAccept(clientKey) else {
        return .failed(.acceptMismatch)
    }
    let capabilities = parseServerCapabilitiesHeader(headers[raftServerCapabilitiesHeader]?.joined(separator: " "))
    var offset = bodyStart
    while true {
        switch readServerWebSocketFrame(bytes, offset: offset) {
        case .needMore:
            return .needMore
        case .invalid:
            return .failed(.badFrame)
        case .frame(let opcode, let fin, let payload, let nextOffset):
            if nextOffset <= offset { return .failed(.badFrame) }
            offset = nextOffset
            if opcode == 0x9 || opcode == 0xA { continue }
            if opcode != 0x1 || !fin { return .failed(.badFrame) }
            guard let context = decodeMachineContext(payload) else {
                return .failed(.badContext)
            }
            return .ready(DaemonHandshake(serverCapabilities: capabilities, context: context))
        }
    }
}

/// Daemon-side `ws://host:port/daemon/connect` handshake.
/// Ported from `DaemonConnection.doConnect` in `packages/daemon/src/connection.ts`.
/// Returns when the first `machine:context` text frame arrives, then closes.
/// Reconnect, watchdog, duplicate-key, migrated-key, and outbound-replay
/// decisions live on `DaemonLink`. This call does not run that loop.
/// Proxy and TLS are not in this slice.
public enum DaemonClient {
    public static func connect(
        host: String = "127.0.0.1",
        port: Int,
        apiKey: String? = nil,
        keyPlacement: DaemonAPIKeyPlacement = .authorizationHeader,
        timeout: Duration = .seconds(30)
    ) async throws -> DaemonHandshake {
        let websocketKey = makeWebSocketKey()
        let request = try daemonUpgradeRequest(
            host: host,
            port: port,
            apiKey: apiKey,
            keyPlacement: keyPlacement,
            websocketKey: websocketKey
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let once = Once<DaemonHandshake>(group.any().makePromise(of: DaemonHandshake.self))
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            once.fail(DaemonConnectError.timedOut)
        }
        var channel: (any Channel)?
        var outcome: Result<DaemonHandshake, Error>?
        do {
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(nioTimeout(timeout))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(DaemonUpgradeHandler(clientKey: websocketKey, once: once))
                }
            let connected = try await bootstrap.connect(host: host, port: port).get()
            channel = connected
            let buffer = connected.allocator.buffer(bytes: Array(request.utf8))
            try await connected.writeAndFlush(buffer).get()
            outcome = .success(try await once.promise.futureResult.get())
        } catch {
            outcome = .failure(error)
        }
        timeoutTask.cancel()
        _ = try? await timeoutTask.value
        if case .success = outcome {
            // The handshake promise is already fulfilled.
        } else {
            once.fail(DaemonConnectError.incompleteResponse)
            _ = try? await once.promise.futureResult.get()
        }
        if let channel {
            try? await channel.close()
        }
        do {
            try await group.shutdownGracefully()
        } catch {
            if case .success = outcome { throw error }
        }
        switch outcome {
        case .success(let handshake):
            return handshake
        case .failure(let error):
            throw error
        case nil:
            throw DaemonConnectError.incompleteResponse
        }
    }
}

private func validatedAPIKey(_ apiKey: String?) throws -> String? {
    guard let apiKey, !apiKey.isEmpty else { return nil }
    if apiKey.contains(where: { $0.isNewline || $0 == "\0" }) {
        throw DaemonConnectError.invalidKey
    }
    return apiKey
}

private func percentEncodeQueryComponent(_ value: String) -> String? {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
}

private func makeWebSocketKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255)
    }
    return Data(bytes).base64EncodedString()
}

private func nioTimeout(_ duration: Duration) -> TimeAmount {
    let (seconds, attoseconds) = duration.components
    let millis = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    if millis <= 0 { return .milliseconds(1) }
    return .milliseconds(millis)
}

private func headerBodyStart(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    var index = 0
    while index + 3 < bytes.count {
        if bytes[index] == 0x0d && bytes[index + 1] == 0x0a && bytes[index + 2] == 0x0d && bytes[index + 3] == 0x0a {
            return index + 4
        }
        index += 1
    }
    return nil
}

private func decodeMachineContext(_ payload: [UInt8]) -> DaemonMachineContext? {
    guard let data = String(bytes: payload, encoding: .utf8)?.data(using: .utf8) else { return nil }
    struct Payload: Decodable {
        var type: String
        var machineId: String
        var serverId: String
        var capabilities: [String]?
        var connectionEpochId: String?
    }
    guard let decoded = try? JSONDecoder().decode(Payload.self, from: data), decoded.type == "machine:context" else {
        return nil
    }
    return DaemonMachineContext(
        machineId: decoded.machineId,
        serverId: decoded.serverId,
        capabilities: decoded.capabilities ?? [],
        connectionEpochId: decoded.connectionEpochId
    )
}

private final class Once<Success: Sendable>: Sendable {
    let promise: EventLoopPromise<Success>
    private let gate = Mutex(false)

    init(_ promise: EventLoopPromise<Success>) {
        self.promise = promise
    }

    func succeed(_ value: Success) {
        let won = gate.withLock { finished -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if won { promise.succeed(value) }
    }

    func fail(_ error: any Error) {
        let won = gate.withLock { finished -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if won { promise.fail(error) }
    }
}

private final class DaemonUpgradeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var accumulator: DaemonUpgradeAccumulator
    private let once: Once<DaemonHandshake>
    private var done = false

    init(clientKey: String, once: Once<DaemonHandshake>) {
        self.accumulator = DaemonUpgradeAccumulator(clientKey: clientKey)
        self.once = once
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        finish(accumulator.append(bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !done else { return }
        switch accumulator.current() {
        case .needMore:
            done = true
            once.fail(DaemonConnectError.incompleteResponse)
        default:
            finish(accumulator.current())
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !done else { return }
        switch accumulator.current() {
        case .needMore:
            done = true
            once.fail(error)
        default:
            finish(accumulator.current())
        }
    }

    private func finish(_ progress: DaemonUpgradeProgress) {
        switch progress {
        case .needMore:
            return
        case .rejected(let error):
            done = true
            once.fail(error)
        case .ready(let handshake):
            done = true
            once.succeed(handshake)
        case .failed(let error):
            done = true
            once.fail(error)
        }
    }
}
