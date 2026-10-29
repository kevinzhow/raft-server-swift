import Foundation

/// Reconnect, duplicate-key, migrated-key, and inbound-watchdog decisions from
/// `DaemonConnection` in `packages/daemon/src/connection.ts`
/// (raft-source v1.21.23-source.1).
///
/// `DaemonLink` is that loop driven by a clock the caller advances. It does
/// not open a socket. The one-shot handshake stays on `DaemonClient.connect`.
/// Outbound replay, proxy, and TLS are not in this slice.

public let daemonReconnectSpreadMs = 5_000
public let daemonInboundWatchdogMs = 70_000
public let daemonConnectTimeoutMs = 30_000
public let daemonMaxReconnectDelayMs = 30_000
public let daemonDuplicateReconnectDelayMs = 5 * 60_000
public let daemonDuplicateMemoryMs = 30 * 60_000
public let daemonDuplicateCloseCode = 4_003
public let daemonDuplicateCloseReason = "duplicate_machine_connection"
public let daemonDuplicateHeldCloseReason = "duplicate_machine_connection_held"
public let legacyMachineKeyMigratedReason = "legacy_machine_key_migrated"

/// `ws` ready states. Traces record these numbers.
public let webSocketConnecting = 0
public let webSocketOpen = 1
public let webSocketClosed = 3

/// `Math.floor(random() * max(backoffMs, RECONNECT_SPREAD_MS))`.
/// `random` is the unit interval `Math.random()` uses: `[0, 1)`.
public func jitteredReconnectDelay(backoffMs: Int, random: () -> Double) -> Int {
    let window = max(backoffMs, daemonReconnectSpreadMs)
    guard window > 0 else { return 0 }
    let scaled = random() * Double(window)
    guard scaled.isFinite else { return 0 }
    return Int(scaled.rounded(.down))
}

/// 401 plus the exact migrated-key reason. The caller normalizes the header first.
public func isTerminalMigratedKeyRejection(statusCode: Int, reason: String?) -> Bool {
    statusCode == 401 && reason == legacyMachineKeyMigratedReason
}

/// CloudFront `x-amz-cf-pop`. A short PoP code is kept. Anything else that is
/// non-empty becomes `invalid_header`. Absent or blank becomes nil.
public func normalizeCfPopHeader(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    guard trimmed.wholeMatch(of: /^[A-Za-z0-9-]{1,32}$/) != nil else {
        return "invalid_header"
    }
    return trimmed
}

/// Node reads only the first header value. An empty list is absent.
public func normalizeCfPopHeader(firstOf values: [String]?) -> String? {
    normalizeCfPopHeader(values?.first)
}

/// Age buckets shared by daemon connection traces and the server orchestrator.
/// A non-finite or negative age is `unknown`. Zero, including `-0`, is `"0"`.
public func durationMsBucket(_ ms: Double?) -> String {
    guard let ms, ms.isFinite, ms >= 0 else { return "unknown" }
    if ms == 0 { return "0" }
    if ms <= 1_000 { return "1s" }
    if ms <= 10_000 { return "1s-10s" }
    if ms <= 30_000 { return "10s-30s" }
    if ms <= 60_000 { return "30s-60s" }
    if ms <= 120_000 { return "60s-120s" }
    return "120s+"
}

public func durationMsBucket(_ ms: Int?) -> String {
    guard let ms else { return "unknown" }
    return durationMsBucket(Double(ms))
}

public struct DaemonConnectionTraceClassification: Equatable, Sendable {
    public var kind: String
    public var eventClass: String
    public var traceEvent: String
    public var shouldAffectRuntimeState: Bool

    public init(kind: String, eventClass: String, traceEvent: String, shouldAffectRuntimeState: Bool) {
        self.kind = kind
        self.eventClass = eventClass
        self.traceEvent = traceEvent
        self.shouldAffectRuntimeState = shouldAffectRuntimeState
    }
}

/// Control-plane reconnect is not a runtime failure.
/// `reconnecting` counts only as the boolean `true`.
/// `reconnectAttempt` counts only as a number greater than zero.
public func classifyDaemonConnectionTraceEvent(
    _ name: String,
    reconnecting: Bool? = nil,
    reconnectAttempt: Double? = nil
) -> DaemonConnectionTraceClassification? {
    let matches: Bool
    if name == "daemon.connection.reconnect_scheduled" {
        matches = true
    } else if name == "daemon.connection.disconnected" && reconnecting == true {
        matches = true
    } else if name == "daemon.connection.connected", let reconnectAttempt, reconnectAttempt > 0 {
        matches = true
    } else {
        matches = false
    }
    guard matches else { return nil }
    return DaemonConnectionTraceClassification(
        kind: "control_plane",
        eventClass: "control_plane_reconnect",
        traceEvent: name,
        shouldAffectRuntimeState: false
    )
}

public enum DaemonTraceValue: Equatable, Sendable {
    case int(Int)
    case bool(Bool)
    case string(String)
    case null
}

public struct DaemonTraceEvent: Equatable, Sendable {
    public var name: String
    public var status: String
    public var attributes: [String: DaemonTraceValue]

    public init(name: String, status: String, attributes: [String: DaemonTraceValue]) {
        self.name = name
        self.status = status
        self.attributes = attributes
    }
}

public struct DaemonHandshakeRejectionEvent: Equatable, Sendable {
    public var statusCode: Int
    public var reason: String?

    public init(statusCode: Int, reason: String?) {
        self.statusCode = statusCode
        self.reason = reason
    }
}

public struct DaemonSocket: Equatable, Sendable {
    public internal(set) var readyState: Int
    public internal(set) var terminated: Bool
    public internal(set) var closed: Bool
    public internal(set) var sent: [String]

    init(readyState: Int, terminated: Bool, closed: Bool, sent: [String]) {
        self.readyState = readyState
        self.terminated = terminated
        self.closed = closed
        self.sent = sent
    }
}

public struct DaemonLink: Sendable {
    public private(set) var nowMs: Int
    public private(set) var sockets: [DaemonSocket]
    public private(set) var cfPop: String?
    public private(set) var logs: [String]
    public private(set) var traceEvents: [DaemonTraceEvent]
    public private(set) var handshakeRejections: [DaemonHandshakeRejectionEvent]
    public private(set) var connectCount: Int
    public private(set) var disconnectCount: Int

    public let minReconnectDelayMs: Int
    public let inboundWatchdogMs: Int
    public let connectTimeoutMs: Int
    public var delayFor: @Sendable (Int) -> Int

    private var shouldConnect = false
    private var current: Int?
    private var reconnectDelay: Int
    private var reconnectAttempt = 0
    private var nextOverride: Int?
    private var duplicateClosedAt: Int?
    private var probeInFlight = false
    private var lastInboundAt: Int?
    private var lastInboundKind: String?
    private var connectStartedAt = 0
    private var alarms: [Alarm] = []
    private var alarmToken = 0

    public init(
        nowMs: Int = 0,
        minReconnectDelayMs: Int = 1_000,
        inboundWatchdogMs: Int = daemonInboundWatchdogMs,
        connectTimeoutMs: Int = daemonConnectTimeoutMs,
        delayFor: @escaping @Sendable (Int) -> Int = { backoff in
            jitteredReconnectDelay(backoffMs: backoff) { Double.random(in: 0..<1) }
        }
    ) {
        self.nowMs = nowMs
        self.minReconnectDelayMs = minReconnectDelayMs
        self.inboundWatchdogMs = inboundWatchdogMs
        self.connectTimeoutMs = connectTimeoutMs
        self.delayFor = delayFor
        self.reconnectDelay = minReconnectDelayMs
        self.sockets = []
        self.logs = []
        self.traceEvents = []
        self.handshakeRejections = []
        self.connectCount = 0
        self.disconnectCount = 0
    }

    public func traces(named name: String) -> [DaemonTraceEvent] {
        traceEvents.filter { $0.name == name }
    }

    public mutating func connect() {
        shouldConnect = true
        if has(.reconnect) { return }
        if let index = current, sockets[index].readyState != webSocketClosed { return }
        doConnect()
    }

    public mutating func disconnect() {
        shouldConnect = false
        clear(.watchdog)
        clear(.connectTimeout)
        clear(.reconnect)
        guard let index = current else { return }
        if sockets[index].terminated || sockets[index].closed {
            current = nil
            return
        }
        sockets[index].closed = true
        finishClose(index: index, code: 1_000, reason: "")
    }

    public mutating func advance(_ ms: Int) {
        let target = nowMs + ms
        var spins = 0
        while spins < 10_000, let next = nextDue(by: target) {
            spins += 1
            nowMs = next.deadline
            alarms.removeAll { $0.token == next.token }
            fire(next.kind)
        }
        nowMs = target
    }

    public mutating func emitUpgrade(socket: Int, cfPopHeader: String?) {
        guard socket == current else { return }
        cfPop = normalizeCfPopHeader(cfPopHeader)
    }

    public mutating func emitOpen(socket: Int) {
        guard socket == current else { return }
        sockets[socket].readyState = webSocketOpen
        guard shouldConnect else { return }
        clear(.connectTimeout)
        reconnectAttempt = 0
        reconnectDelay = minReconnectDelayMs
        markInbound("websocket_open")
        resetWatchdog()
        connectCount += 1
        logs.append("[Daemon] Connected to server\(cfPopLogField())")
    }

    public mutating func receive(socket: Int, type: String) {
        guard socket == current else { return }
        markInbound(type)
        resetWatchdog()
    }

    /// Outbound traffic does not move the inbound watchdog.
    public mutating func send(socket: Int, type: String) {
        guard socket == current, sockets[socket].readyState == webSocketOpen else { return }
        sockets[socket].sent.append("{\"type\":\(jsonQuoted(type))}")
    }

    public mutating func serverClose(socket: Int, code: Int = 1_000, reason: String = "") {
        guard sockets.indices.contains(socket) else { return }
        guard socket == current else {
            sockets[socket].readyState = webSocketClosed
            return
        }
        finishClose(index: socket, code: code, reason: reason)
    }

    public mutating func unexpectedResponse(statusCode: Int, slockReason: String?, cfPopHeader: String?) {
        guard current != nil else { return }
        clear(.connectTimeout)
        let reason = normalizeHandshakeReason(slockReason)
        cfPop = normalizeCfPopHeader(cfPopHeader)
        let reasonText = reason.map { ", slock_reason=\($0)" } ?? ""
        logs.append("[Daemon] WebSocket handshake rejected (status=\(statusCode)\(reasonText)\(cfPopLogField()))")
        trace("daemon.connection.handshake_rejected", [
            "status_code": .int(statusCode),
            "slock_reason_present": .bool(reason != nil),
            "slock_reason": reason.map(DaemonTraceValue.string) ?? .null,
            "cf_pop": cfPop.map(DaemonTraceValue.string) ?? .null,
        ], status: "error")
        if isTerminalMigratedKeyRejection(statusCode: statusCode, reason: reason) {
            shouldConnect = false
            logs.append(migratedKeyGuidance)
            trace("daemon.connection.reconnect_stopped", [
                "status_code": .int(statusCode),
                "slock_reason": reason.map(DaemonTraceValue.string) ?? .null,
                "terminal": .bool(true),
            ], status: "error")
        }
        handshakeRejections.append(DaemonHandshakeRejectionEvent(statusCode: statusCode, reason: reason))
        terminateCurrent()
    }

    private mutating func doConnect() {
        guard shouldConnect else { return }
        if let index = current, sockets[index].readyState != webSocketClosed { return }
        sockets.append(DaemonSocket(readyState: webSocketConnecting, terminated: false, closed: false, sent: []))
        current = sockets.count - 1
        cfPop = nil
        probeInFlight = false
        connectStartedAt = nowMs
        arm(.connectTimeout, after: connectTimeoutMs)
    }

    private mutating func terminateCurrent() {
        guard let index = current else { return }
        if sockets[index].terminated || sockets[index].closed { return }
        sockets[index].terminated = true
        finishClose(index: index, code: 1_006, reason: "")
    }

    private mutating func finishClose(index: Int, code: Int, reason: String) {
        guard index == current else { return }
        sockets[index].readyState = webSocketClosed
        if !sockets[index].terminated {
            sockets[index].closed = true
        }
        current = nil
        clear(.connectTimeout)
        clear(.watchdog)
        logs.append(
            "[Daemon] Disconnected from server (code=\(code), reason=\(jsonQuoted(reason)), reconnecting=\(shouldConnect)\(cfPopLogField()))"
        )
        trace("daemon.connection.disconnected", [
            "close_code": .int(code),
            "close_reason_present": .bool(!reason.isEmpty),
            "reconnecting": .bool(shouldConnect),
            "reconnect_attempt": .int(reconnectAttempt),
            "last_inbound_message_kind": lastInboundKind.map(DaemonTraceValue.string) ?? .null,
            "last_inbound_age_ms_bucket": .string(lastInboundAgeBucket()),
            "cf_pop": cfPop.map(DaemonTraceValue.string) ?? .null,
        ], status: shouldConnect ? "cancelled" : "ok")
        if code == daemonDuplicateCloseCode {
            noteDuplicate(reason: reason)
        }
        disconnectCount += 1
        scheduleReconnect()
    }

    private mutating func noteDuplicate(reason: String) {
        if reason == daemonDuplicateCloseReason {
            duplicateClosedAt = nowMs
            nextOverride = daemonDuplicateReconnectDelayMs
            let minutes = Int((Double(daemonDuplicateReconnectDelayMs) / 60_000).rounded())
            logs.append(
                "[Daemon] The server closed this connection: the same machine key is connected from another process. "
                    + "Stop the other daemon or give this one its own machine key. "
                    + "Reconnecting in \(minutes) minutes."
            )
        } else {
            let recent = duplicateClosedAt.map { nowMs - $0 < daemonDuplicateMemoryMs } ?? false
            logs.append(
                "[Daemon] The server refused this connection: another process holds this machine key"
                    + (recent ? "; keeping the long reconnect delay." : ".")
            )
            if recent {
                nextOverride = daemonDuplicateReconnectDelayMs
            }
        }
        let closeReason = reason == daemonDuplicateCloseReason ? "closed_as_duplicate" : "refused_held"
        trace("daemon.connection.duplicate_machine_close", [
            "close_reason": .string(closeReason),
            "long_delay": .bool(nextOverride != nil),
        ])
    }

    private mutating func scheduleReconnect() {
        guard shouldConnect, !has(.reconnect) else { return }
        reconnectAttempt += 1
        let override = nextOverride
        nextOverride = nil
        let backoff = reconnectDelay
        let delay = override ?? delayFor(backoff)
        logs.append("[Daemon] Reconnecting to server in \(delay)ms (attempt \(reconnectAttempt))")
        trace("daemon.connection.reconnect_scheduled", [
            "reconnect_attempt": .int(reconnectAttempt),
            "delay_ms": .int(delay),
            "backoff_ms": .int(backoff),
        ])
        arm(.reconnect, after: delay)
        let doubled = backoff > daemonMaxReconnectDelayMs / 2 ? daemonMaxReconnectDelayMs : backoff * 2
        reconnectDelay = min(doubled, daemonMaxReconnectDelayMs)
    }

    private mutating func markInbound(_ kind: String) {
        lastInboundAt = nowMs
        lastInboundKind = kind
    }

    private func lastInboundAgeBucket() -> String {
        durationMsBucket(lastInboundAt.map { nowMs - $0 })
    }

    private mutating func resetWatchdog() {
        clear(.watchdog)
        probeInFlight = false
        arm(.watchdog, after: inboundWatchdogMs)
    }

    private mutating func fire(_ kind: AlarmKind) {
        switch kind {
        case .reconnect:
            doConnect()
        case .connectTimeout:
            fireConnectTimeout()
        case .watchdog:
            fireWatchdog()
        }
    }

    private mutating func fireConnectTimeout() {
        guard let index = current, shouldConnect, sockets[index].readyState == webSocketConnecting else { return }
        trace("daemon.connection.handshake_timeout", [
            "connect_timeout_ms": .int(connectTimeoutMs),
            "reconnect_attempt": .int(reconnectAttempt),
            "connect_age_ms_bucket": .string(durationMsBucket(nowMs - connectStartedAt)),
            "ws_ready_state": .int(sockets[index].readyState),
            "reconnecting": .bool(shouldConnect),
        ], status: "error")
        logs.append("[Daemon] WebSocket connection attempt timed out after \(connectTimeoutMs)ms — forcing reconnect")
        terminateCurrent()
    }

    private mutating func fireWatchdog() {
        if !probeInFlight, let index = current, sockets[index].readyState == webSocketOpen {
            probeInFlight = true
            logs.append("[Daemon] No inbound traffic for \(inboundWatchdogMs / 1000)s — sending liveness probe")
            trace("daemon.connection.inbound_probe_sent", [
                "inbound_watchdog_ms": .int(inboundWatchdogMs),
                "last_inbound_message_kind": lastInboundKind.map(DaemonTraceValue.string) ?? .null,
                "last_inbound_age_ms_bucket": .string(lastInboundAgeBucket()),
                "ws_ready_state": .int(sockets[index].readyState),
                "reconnecting": .bool(shouldConnect),
                "cf_pop": cfPop.map(DaemonTraceValue.string) ?? .null,
            ])
            sockets[index].sent.append("{\"type\":\"ping\"}")
            arm(.watchdog, after: inboundWatchdogMs)
            return
        }
        logs.append("[Daemon] No inbound traffic after liveness probe — forcing reconnect\(cfPopLogField())")
        trace("daemon.connection.watchdog_timeout", [
            "inbound_watchdog_ms": .int(inboundWatchdogMs),
            "probe_in_flight": .bool(probeInFlight),
            "last_inbound_message_kind": lastInboundKind.map(DaemonTraceValue.string) ?? .null,
            "last_inbound_age_ms_bucket": .string(lastInboundAgeBucket()),
            "ws_ready_state": current.map { .int(sockets[$0].readyState) } ?? .null,
            "reconnecting": .bool(shouldConnect),
            "cf_pop": cfPop.map(DaemonTraceValue.string) ?? .null,
        ], status: "error")
        terminateCurrent()
    }

    private func cfPopLogField() -> String {
        cfPop.map { ", cf_pop=\($0)" } ?? ""
    }

    private mutating func trace(_ name: String, _ attributes: [String: DaemonTraceValue], status: String = "ok") {
        traceEvents.append(DaemonTraceEvent(name: name, status: status, attributes: attributes))
    }

    private func has(_ kind: AlarmKind) -> Bool {
        alarms.contains { $0.kind == kind }
    }

    private mutating func clear(_ kind: AlarmKind) {
        alarms.removeAll { $0.kind == kind }
    }

    private mutating func arm(_ kind: AlarmKind, after ms: Int) {
        clear(kind)
        alarmToken += 1
        alarms.append(Alarm(token: alarmToken, kind: kind, deadline: nowMs + ms))
    }

    private func nextDue(by target: Int) -> Alarm? {
        alarms.filter { $0.deadline <= target }.min { lhs, rhs in
            if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
            return lhs.token < rhs.token
        }
    }
}

private struct Alarm: Sendable {
    var token: Int
    var kind: AlarmKind
    var deadline: Int
}

private enum AlarmKind: Sendable {
    case reconnect
    case watchdog
    case connectTimeout
}

private let migratedKeyGuidance =
    "[Daemon] This legacy machine key was already migrated to Raft Computer. "
    + "Reconnects are stopped because this key cannot authenticate again.\n"
    + "Stop and disable this legacy raft-daemon process. In Raft, open this offline Computer and choose "
    + "\"raft-computer: command not found? Install or re-run setup\" to copy the install and setup commands for this server."

private func jsonQuoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\":
            out += "\\\\"
        case "\"":
            out += "\\\""
        case "\u{0008}":
            out += "\\b"
        case "\u{000c}":
            out += "\\f"
        case "\n":
            out += "\\n"
        case "\r":
            out += "\\r"
        case "\t":
            out += "\\t"
        case "\u{2028}":
            out += "\\u2028"
        case "\u{2029}":
            out += "\\u2029"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}
