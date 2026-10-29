import Foundation
import Testing
@testable import RaftDaemonClient

/// Behavior pinned by `packages/daemon/src/connection.ts` and
/// `connection.test.ts` at raft-source v1.21.23-source.1.
/// The loop is clock-driven. These tests do not open a socket.

private func pinnedLink(
    minReconnectDelayMs: Int = 1_000,
    inboundWatchdogMs: Int = daemonInboundWatchdogMs,
    connectTimeoutMs: Int = daemonConnectTimeoutMs
) -> DaemonLink {
    DaemonLink(
        minReconnectDelayMs: minReconnectDelayMs,
        inboundWatchdogMs: inboundWatchdogMs,
        connectTimeoutMs: connectTimeoutMs,
        delayFor: { $0 }
    )
}

private func delayMs(_ event: DaemonTraceEvent) -> Int? {
    guard case .int(let value) = event.attributes["delay_ms"] else { return nil }
    return value
}

private func delaysAfter(closes: [(code: Int, reason: String)]) -> (delays: [Int], duplicate: [DaemonTraceEvent]) {
    var link = pinnedLink(inboundWatchdogMs: 50_000_000, connectTimeoutMs: 50_000_000)
    link.connect()
    for close in closes {
        let index = link.sockets.count - 1
        link.emitOpen(socket: index)
        link.serverClose(socket: index, code: close.code, reason: close.reason)
        let delay = link.traces(named: "daemon.connection.reconnect_scheduled").last.flatMap(delayMs) ?? 0
        link.advance(delay)
    }
    return (
        link.traces(named: "daemon.connection.reconnect_scheduled").compactMap(delayMs),
        link.traces(named: "daemon.connection.duplicate_machine_close")
    )
}

@Test func durationBucketsMatchTheDaemonAndServerWindows() {
    #expect(durationMsBucket(Optional<Double>.none) == "unknown")
    #expect(durationMsBucket(Double.nan) == "unknown")
    #expect(durationMsBucket(Double.infinity) == "unknown")
    #expect(durationMsBucket(-Double.infinity) == "unknown")
    #expect(durationMsBucket(-1.0) == "unknown")
    #expect(durationMsBucket(-0.0) == "0")
    #expect(durationMsBucket(0.0) == "0")
    #expect(durationMsBucket(1.0) == "1s")
    #expect(durationMsBucket(1_000.0) == "1s")
    #expect(durationMsBucket(1_001.0) == "1s-10s")
    #expect(durationMsBucket(10_000.0) == "1s-10s")
    #expect(durationMsBucket(10_001.0) == "10s-30s")
    #expect(durationMsBucket(30_000.0) == "10s-30s")
    #expect(durationMsBucket(30_001.0) == "30s-60s")
    #expect(durationMsBucket(60_000.0) == "30s-60s")
    #expect(durationMsBucket(60_001.0) == "60s-120s")
    #expect(durationMsBucket(120_000.0) == "60s-120s")
    #expect(durationMsBucket(120_001.0) == "120s+")
    #expect(durationMsBucket(Optional<Int>.none) == "unknown")
}

@Test func cloudFrontPopHeaderKeepsAShortCode() {
    #expect(normalizeCfPopHeader(nil) == nil)
    #expect(normalizeCfPopHeader("   ") == nil)
    #expect(normalizeCfPopHeader(" NRT57-P7 ") == "NRT57-P7")
    #expect(normalizeCfPopHeader(String(repeating: "a", count: 32)) == String(repeating: "a", count: 32))
    #expect(normalizeCfPopHeader(String(repeating: "a", count: 33)) == "invalid_header")
    #expect(normalizeCfPopHeader("NRT57 <script>") == "invalid_header")
    #expect(normalizeCfPopHeader("NRT_57") == "invalid_header")
    #expect(normalizeCfPopHeader(firstOf: []) == nil)
    #expect(normalizeCfPopHeader(firstOf: [" NRT57-P7 ", "OTHER"]) == "NRT57-P7")
    #expect(normalizeCfPopHeader(firstOf: ["bad pop", "NRT57-P7"]) == "invalid_header")
}

@Test func fullJitterSpreadsAcrossTheLargerOfBackoffAndFiveSeconds() {
    #expect(jitteredReconnectDelay(backoffMs: 1_000, random: { 0 }) == 0)
    #expect(jitteredReconnectDelay(backoffMs: 1_000, random: { 0.5 }) == 2_500)
    #expect(jitteredReconnectDelay(backoffMs: 8_000, random: { 0.5 }) == 4_000)
    #expect(jitteredReconnectDelay(backoffMs: 5_000, random: { 0.5 }) == 2_500)
    #expect(jitteredReconnectDelay(backoffMs: -10, random: { 0.5 }) == 2_500)
    let almostOne = Double(4_999) / 5_000
    #expect(jitteredReconnectDelay(backoffMs: 1, random: { almostOne }) == 4_999)
}

@Test func migratedKeyRejectionIsOnlyThat401() {
    #expect(isTerminalMigratedKeyRejection(statusCode: 401, reason: legacyMachineKeyMigratedReason))
    #expect(!isTerminalMigratedKeyRejection(statusCode: 401, reason: "computer_revoked"))
    #expect(!isTerminalMigratedKeyRejection(statusCode: 403, reason: legacyMachineKeyMigratedReason))
    #expect(!isTerminalMigratedKeyRejection(statusCode: 401, reason: nil))
    #expect(!isTerminalMigratedKeyRejection(statusCode: 401, reason: " legacy_machine_key_migrated "))
}

@Test func controlPlaneReconnectDoesNotAffectRuntimeState() {
    let scheduled = classifyDaemonConnectionTraceEvent("daemon.connection.reconnect_scheduled", reconnectAttempt: 1)
    #expect(scheduled?.kind == "control_plane")
    #expect(scheduled?.eventClass == "control_plane_reconnect")
    #expect(scheduled?.traceEvent == "daemon.connection.reconnect_scheduled")
    #expect(scheduled?.shouldAffectRuntimeState == false)

    let disconnected = classifyDaemonConnectionTraceEvent(
        "daemon.connection.disconnected",
        reconnecting: true
    )
    #expect(disconnected?.eventClass == "control_plane_reconnect")
    #expect(disconnected?.shouldAffectRuntimeState == false)
    #expect(disconnected?.traceEvent == "daemon.connection.disconnected")

    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.connected", reconnectAttempt: 0) == nil)
    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.connected", reconnectAttempt: 1)?.traceEvent
        == "daemon.connection.connected")
    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.connected", reconnectAttempt: 1.5) != nil)
    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.disconnected", reconnecting: false) == nil)
    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.disconnected") == nil)
    #expect(classifyDaemonConnectionTraceEvent("daemon.connection.connected") == nil)
}

@Test func migratedLegacyKeyStopsReconnect() {
    var link = pinnedLink()
    link.connect()
    link.unexpectedResponse(statusCode: 401, slockReason: legacyMachineKeyMigratedReason, cfPopHeader: nil)
    link.advance(120_000)

    #expect(link.sockets.count == 1)
    #expect(link.traces(named: "daemon.connection.reconnect_scheduled").isEmpty)
    let stopped = link.traces(named: "daemon.connection.reconnect_stopped")
    #expect(stopped.count == 1)
    #expect(stopped[0].status == "error")
    #expect(stopped[0].attributes["status_code"] == .int(401))
    #expect(stopped[0].attributes["slock_reason"] == .string(legacyMachineKeyMigratedReason))
    #expect(stopped[0].attributes["terminal"] == .bool(true))
    let text = link.logs.joined(separator: "\n")
    #expect(text.contains("Reconnects are stopped because this key cannot authenticate again"))
    #expect(text.contains("raft-computer: command not found? Install or re-run setup"))
    #expect(!text.contains("sk_machine_migrated"))
}

@Test func otherHandshakeRejectionKeepsReconnectAndDropsTheRawReason() {
    var link = pinnedLink(minReconnectDelayMs: 60_000)
    link.connect()
    link.unexpectedResponse(statusCode: 401, slockReason: "computer_revoked", cfPopHeader: nil)
    #expect(link.handshakeRejections == [DaemonHandshakeRejectionEvent(statusCode: 401, reason: "computer_revoked")])
    #expect(link.logs.contains("[Daemon] WebSocket handshake rejected (status=401, slock_reason=computer_revoked)"))
    #expect(!link.logs.joined(separator: "\n").contains("sk_machine_secret_should_not_log"))
    let rejected = link.traces(named: "daemon.connection.handshake_rejected")
    #expect(rejected.count == 1)
    #expect(rejected[0].status == "error")
    #expect(rejected[0].attributes["slock_reason"] == .string("computer_revoked"))
    #expect(rejected[0].attributes["slock_reason_present"] == .bool(true))
    #expect(rejected[0].attributes["cf_pop"] == .null)
    #expect(!link.traces(named: "daemon.connection.reconnect_scheduled").isEmpty)
    #expect(link.traces(named: "daemon.connection.reconnect_stopped").isEmpty)

    link.disconnect()
    link.advance(120_000)
    #expect(link.sockets.count == 1)

    var weird = pinnedLink()
    weird.connect()
    weird.unexpectedResponse(statusCode: 401, slockReason: " no way ", cfPopHeader: nil)
    #expect(weird.handshakeRejections == [DaemonHandshakeRejectionEvent(statusCode: 401, reason: "invalid_header")])
    #expect(!weird.logs.joined(separator: "\n").contains("no way"))
}

@Test func duplicateCloseWaitsFiveMinutes() {
    let result = delaysAfter(closes: [(daemonDuplicateCloseCode, daemonDuplicateCloseReason)])
    #expect(result.delays == [daemonDuplicateReconnectDelayMs])
    #expect(result.duplicate.count == 1)
    #expect(result.duplicate[0].attributes["close_reason"] == .string("closed_as_duplicate"))
    #expect(result.duplicate[0].attributes["long_delay"] == .bool(true))
}

@Test func heldKeyWithoutAPriorDuplicateKeepsTheNormalBackoff() {
    let result = delaysAfter(closes: [(daemonDuplicateCloseCode, daemonDuplicateHeldCloseReason)])
    #expect(result.delays == [1_000])
    #expect(result.duplicate[0].attributes["close_reason"] == .string("refused_held"))
    #expect(result.duplicate[0].attributes["long_delay"] == .bool(false))
}

@Test func laterHeldRefusalsKeepTheLongDelay() {
    let result = delaysAfter(closes: [
        (daemonDuplicateCloseCode, daemonDuplicateCloseReason),
        (daemonDuplicateCloseCode, daemonDuplicateHeldCloseReason),
        (daemonDuplicateCloseCode, daemonDuplicateHeldCloseReason),
    ])
    #expect(result.delays == [
        daemonDuplicateReconnectDelayMs,
        daemonDuplicateReconnectDelayMs,
        daemonDuplicateReconnectDelayMs,
    ])
}

@Test func duplicateMemoryExpiresAtThirtyMinutes() {
    var link = pinnedLink(inboundWatchdogMs: 50_000_000, connectTimeoutMs: 50_000_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: daemonDuplicateCloseCode, reason: daemonDuplicateCloseReason)
    link.advance(daemonDuplicateReconnectDelayMs)
    link.emitOpen(socket: 1)
    link.advance(daemonDuplicateMemoryMs - link.nowMs - 1)
    link.serverClose(socket: 1, code: daemonDuplicateCloseCode, reason: daemonDuplicateHeldCloseReason)
    #expect(delayMs(link.traces(named: "daemon.connection.reconnect_scheduled").last!) == daemonDuplicateReconnectDelayMs)

    var expired = pinnedLink(inboundWatchdogMs: 50_000_000, connectTimeoutMs: 50_000_000)
    expired.connect()
    expired.emitOpen(socket: 0)
    expired.serverClose(socket: 0, code: daemonDuplicateCloseCode, reason: daemonDuplicateCloseReason)
    expired.advance(daemonDuplicateReconnectDelayMs)
    expired.emitOpen(socket: 1)
    expired.advance(daemonDuplicateMemoryMs - expired.nowMs)
    expired.serverClose(socket: 1, code: daemonDuplicateCloseCode, reason: daemonDuplicateHeldCloseReason)
    let held = expired.traces(named: "daemon.connection.duplicate_machine_close").last!
    #expect(held.attributes["long_delay"] == .bool(false))
    #expect(delayMs(expired.traces(named: "daemon.connection.reconnect_scheduled").last!) == 1_000)
}

@Test func otherCloseCodesKeepTheNormalBackoff() {
    let result = delaysAfter(closes: [(4_001, "computer_machine_unlinked")])
    #expect(result.delays == [1_000])
    #expect(result.duplicate.isEmpty)
}

@Test func reconnectBackoffDoublesAndCapsAtThirtySeconds() {
    var link = pinnedLink()
    link.connect()
    link.serverClose(socket: 0, code: 1006)
    let steps = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
    for (offset, step) in steps.enumerated() {
        link.advance(step - 1)
        #expect(link.sockets.count == offset + 1)
        link.advance(1)
        #expect(link.sockets.count == offset + 2)
        link.serverClose(socket: link.sockets.count - 1, code: 1006)
    }
}

@Test func successfulOpenResetsBackoff() {
    var link = pinnedLink()
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: 1006)
    link.advance(999)
    #expect(link.sockets.count == 1)
    link.advance(1)
    #expect(link.sockets.count == 2)
    link.serverClose(socket: 1, code: 1006)
    link.advance(1_999)
    #expect(link.sockets.count == 2)
    link.advance(1)
    #expect(link.sockets.count == 3)
    link.emitOpen(socket: 2)
    link.serverClose(socket: 2, code: 1006)
    link.advance(999)
    #expect(link.sockets.count == 3)
    link.advance(1)
    #expect(link.sockets.count == 4)
}

@Test func connectIsIdempotentWhileConnectingOpenOrWaiting() {
    var link = pinnedLink()
    link.connect()
    link.connect()
    #expect(link.sockets.count == 1)
    link.emitOpen(socket: 0)
    link.connect()
    #expect(link.sockets.count == 1)
    link.serverClose(socket: 0, code: 1006)
    link.connect()
    #expect(link.sockets.count == 1)
    link.advance(1_000)
    #expect(link.sockets.count == 2)
}

@Test func disconnectCancelsTheScheduledReconnect() {
    var link = pinnedLink()
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: 1006)
    link.disconnect()
    link.advance(5_000)
    #expect(link.sockets.count == 1)
}

@Test func staleCloseDoesNotDisturbTheReplacement() {
    var link = pinnedLink()
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: 1006)
    #expect(link.disconnectCount == 1)
    link.advance(1_000)
    link.emitOpen(socket: 1)
    link.serverClose(socket: 0, code: 1006)
    #expect(link.disconnectCount == 1)
    link.advance(1_000)
    #expect(link.sockets.count == 2)
}

@Test func firstDropIsAControlPlaneReconnect() {
    var link = pinnedLink()
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: 1006)
    let disconnected = link.traces(named: "daemon.connection.disconnected")[0]
    #expect(disconnected.status == "cancelled")
    #expect(disconnected.attributes["close_code"] == .int(1006))
    #expect(disconnected.attributes["reconnecting"] == .bool(true))
    let scheduled = link.traces(named: "daemon.connection.reconnect_scheduled")[0]
    #expect(scheduled.attributes["reconnect_attempt"] == .int(1))
    let classification = classifyDaemonConnectionTraceEvent(
        scheduled.name,
        reconnectAttempt: 1
    )
    #expect(classification?.eventClass == "control_plane_reconnect")
    #expect(classification?.shouldAffectRuntimeState == false)
}

@Test func watchdogProbesThenTerminates() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(69_999)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.isEmpty)
    link.advance(1)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.last == "{\"type\":\"ping\"}")
    #expect(link.disconnectCount == 0)
    link.advance(70_000)
    #expect(link.sockets[0].terminated == true)
    #expect(link.disconnectCount == 1)
}

@Test func watchdogAgeBucketsFollowTheLastInbound() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(40_000)
    link.receive(socket: 0, type: "ping")
    link.advance(69_999)
    #expect(link.sockets[0].terminated == false)
    link.advance(1)
    let probe = link.traces(named: "daemon.connection.inbound_probe_sent").last!
    #expect(probe.attributes["last_inbound_message_kind"] == .string("ping"))
    #expect(probe.attributes["last_inbound_age_ms_bucket"] == .string("60s-120s"))
    link.advance(70_000)
    let timeout = link.traces(named: "daemon.connection.watchdog_timeout").last!
    #expect(timeout.status == "error")
    #expect(timeout.attributes["probe_in_flight"] == .bool(true))
    #expect(timeout.attributes["last_inbound_message_kind"] == .string("ping"))
    #expect(timeout.attributes["last_inbound_age_ms_bucket"] == .string("120s+"))
    #expect(timeout.attributes["ws_ready_state"] == .int(webSocketOpen))
    let disconnect = link.traces(named: "daemon.connection.disconnected").last!
    #expect(disconnect.attributes["close_code"] == .int(1006))
    #expect(disconnect.attributes["last_inbound_age_ms_bucket"] == .string("120s+"))
}

@Test func inboundJustBeforeTheDeadlineExtendsTheWindow() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(69_999)
    link.receive(socket: 0, type: "ping")
    link.advance(69_999)
    #expect(link.sockets[0].terminated == false)
    link.advance(1)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.last == "{\"type\":\"ping\"}")
    link.advance(70_000)
    #expect(link.sockets[0].terminated == true)
}

@Test func answeredProbeKeepsTheIdleConnection() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(70_000)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.last == "{\"type\":\"ping\"}")
    link.receive(socket: 0, type: "ping")
    link.advance(69_999)
    #expect(link.sockets[0].terminated == false)
    link.advance(1)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.last == "{\"type\":\"ping\"}")
}

@Test func outboundTrafficDoesNotMaskAnInboundBlackHole() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(30_000)
    link.send(socket: 0, type: "pong")
    link.advance(30_000)
    link.send(socket: 0, type: "pong")
    link.advance(9_999)
    #expect(link.sockets[0].terminated == false)
    link.advance(1)
    #expect(link.sockets[0].terminated == false)
    #expect(link.sockets[0].sent.last == "{\"type\":\"ping\"}")
    link.advance(70_000)
    #expect(link.sockets[0].terminated == true)
}

@Test func staleInboundDoesNotResetTheActiveWatchdog() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.serverClose(socket: 0, code: 1006)
    link.advance(1_000)
    link.emitOpen(socket: 1)
    link.advance(69_999)
    link.receive(socket: 0, type: "ping")
    link.advance(1)
    #expect(link.sockets[1].terminated == false)
    #expect(link.sockets[1].sent.last == "{\"type\":\"ping\"}")
    link.advance(70_000)
    #expect(link.sockets[1].terminated == true)
}

@Test func replacementSocketStabilizesWhenInboundResumes() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitOpen(socket: 0)
    link.advance(70_000)
    #expect(link.sockets[0].terminated == false)
    link.advance(70_000)
    #expect(link.sockets[0].terminated == true)
    link.advance(1_000)
    #expect(link.sockets.count == 2)
    link.emitOpen(socket: 1)
    link.advance(69_999)
    link.receive(socket: 1, type: "ping")
    link.advance(69_999)
    #expect(link.sockets[1].terminated == false)
}

@Test func cloudFrontPopStaysOnThatConnectionOnly() {
    var link = pinnedLink(inboundWatchdogMs: 70_000)
    link.connect()
    link.emitUpgrade(socket: 0, cfPopHeader: "NRT57-P7")
    link.emitOpen(socket: 0)
    #expect(link.cfPop == "NRT57-P7")
    link.advance(140_000)
    #expect(link.traces(named: "daemon.connection.inbound_probe_sent").last?.attributes["cf_pop"] == .string("NRT57-P7"))
    #expect(link.traces(named: "daemon.connection.watchdog_timeout").last?.attributes["cf_pop"] == .string("NRT57-P7"))
    let disconnect = link.traces(named: "daemon.connection.disconnected").last!
    #expect(disconnect.attributes["close_code"] == .int(1006))
    #expect(disconnect.attributes["last_inbound_age_ms_bucket"] == .string("120s+"))
    #expect(disconnect.attributes["cf_pop"] == .string("NRT57-P7"))
    #expect(link.logs.contains { $0.contains("Connected to server, cf_pop=NRT57-P7") })
    #expect(link.logs.contains { $0.contains("Disconnected from server (code=1006") && $0.contains("cf_pop=NRT57-P7") })

    link.advance(1_000)
    #expect(link.sockets.count == 2)
    link.emitUpgrade(socket: 1, cfPopHeader: nil)
    link.emitOpen(socket: 1)
    #expect(link.cfPop == nil)
    link.serverClose(socket: 1, code: 1006)
    #expect(link.traces(named: "daemon.connection.disconnected").last?.attributes["cf_pop"] == .null)
    let lastDisconnect = link.logs.last { $0.contains("Disconnected from server") }
    #expect(lastDisconnect?.contains("cf_pop") == false)

    link.advance(2_000)
    link.emitUpgrade(socket: 2, cfPopHeader: "NRT57 <script>")
    link.emitOpen(socket: 2)
    #expect(link.cfPop == "invalid_header")
}

@Test func hungHandshakeUsesTheThirtySecondTimeout() {
    var link = pinnedLink(minReconnectDelayMs: 10)
    link.connect()
    #expect(link.sockets[0].readyState == webSocketConnecting)
    link.advance(29_999)
    link.connect()
    #expect(link.sockets.count == 1)
    #expect(link.sockets[0].terminated == false)
    link.advance(1)
    #expect(link.sockets[0].terminated == true)
    #expect(link.sockets[0].readyState == webSocketClosed)
    #expect(link.disconnectCount == 1)
    #expect(link.sockets.count == 1)
    let timeout = link.traces(named: "daemon.connection.handshake_timeout")[0]
    #expect(timeout.status == "error")
    #expect(timeout.attributes["connect_timeout_ms"] == .int(30_000))
    #expect(timeout.attributes["ws_ready_state"] == .int(webSocketConnecting))
    #expect(timeout.attributes["connect_age_ms_bucket"] == .string("10s-30s"))
    link.advance(10)
    #expect(link.sockets.count == 2)
}

@Test func openAndDisconnectClearTheConnectTimeout() {
    var opened = pinnedLink(minReconnectDelayMs: 10, inboundWatchdogMs: 1_000, connectTimeoutMs: 30)
    opened.connect()
    opened.advance(29)
    opened.emitOpen(socket: 0)
    opened.advance(100)
    #expect(opened.sockets[0].terminated == false)
    #expect(opened.sockets.count == 1)

    var stopped = pinnedLink(minReconnectDelayMs: 10, inboundWatchdogMs: 1_000, connectTimeoutMs: 30)
    stopped.connect()
    stopped.advance(10)
    stopped.disconnect()
    stopped.advance(100)
    #expect(stopped.sockets[0].closed == true)
    #expect(stopped.sockets[0].terminated == false)
    #expect(stopped.sockets.count == 1)
}
