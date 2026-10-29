import Foundation
import Testing
import RaftConnectAuth
import RaftMachineSocket
@testable import RaftDaemonClient

private struct ScriptedLookup: MachineCredentialLooking {
    var computer: ComputerAuthResolution = .denied(.computerNotFound)
    var machineById: MatchedMachine?
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { computer }
    func machine(id: String) async throws -> MatchedMachine? { machineById }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private struct ExplodingLookup: MachineCredentialLooking {
    struct Boom: Error {}
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { throw Boom() }
    func machine(id: String) async throws -> MatchedMachine? { throw Boom() }
    func serverExists(id: String) async throws -> Bool { throw Boom() }
    func machine(apiKey: String) async throws -> MatchedMachine? { throw Boom() }
}

@Test func clientMissingKeyIs401MissingKey() async throws {
    let rejection = try await rejectedUpgrade(lookup: ExplodingLookup(), apiKey: nil)
    #expect(rejection.statusCode == 401)
    #expect(rejection.reason == "missing_key")
    #expect(rejection.description == "WebSocket handshake rejected (status=401, slock_reason=missing_key)")
    #expect(rejection.localizedDescription == rejection.description)
}

@Test func clientBadKeyFormatIs401InvalidKeyFormat() async throws {
    let key = "not-a-real-key"
    let rejection = try await rejectedUpgrade(lookup: ExplodingLookup(), apiKey: key)
    #expect(rejection.statusCode == 401)
    #expect(rejection.reason == "invalid_key_format")
    #expect(rejection.description == "WebSocket handshake rejected (status=401, slock_reason=invalid_key_format)")
    #expect(!rejection.description.contains(key))
    #expect(!rejection.localizedDescription.contains(key))
}

@Test func clientRejectionDoesNotContainTheApiKey() async throws {
    let key = "sk_computer_SECRETVALUE"
    let rejection = try await rejectedUpgrade(lookup: ScriptedLookup(), apiKey: key)
    #expect(rejection.statusCode == 401)
    #expect(rejection.reason == "computer_not_found")
    #expect(!rejection.description.contains(key))
    #expect(!rejection.description.contains("sk_computer_"))
    #expect(!rejection.localizedDescription.contains(key))
}

@Test func clientBearerKeyReadsMachineContext() async throws {
    let handshake = try await acceptedUpgrade(apiKey: "sk_computer_live", keyPlacement: .authorizationHeader)
    #expect(handshake.serverCapabilities.contains("machine:runtime-detection-async-v1"))
    #expect(handshake.context.machineId == "m1")
    #expect(handshake.context.serverId == "s1")
    #expect(handshake.context.capabilities.contains("machine:runtime-detection-async-v1"))
}

@Test func clientLegacyQueryKeyReadsMachineContext() async throws {
    let handshake = try await acceptedUpgrade(apiKey: "sk_computer_live", keyPlacement: .query)
    #expect(handshake.serverCapabilities.contains("machine:runtime-detection-async-v1"))
    #expect(handshake.context.machineId == "m1")
    #expect(handshake.context.serverId == "s1")
}

@Test func upgradeRequestMatchesBearerAndLegacyQuery() throws {
    let bearer = try daemonUpgradeRequest(
        host: "127.0.0.1",
        port: 9,
        apiKey: "sk_computer_live",
        keyPlacement: .authorizationHeader,
        websocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
    )
    #expect(bearer.contains("GET /daemon/connect HTTP/1.1\r\n"))
    #expect(!bearer.contains("?key="))
    #expect(bearer.contains("Authorization: Bearer sk_computer_live\r\n"))

    let query = try daemonUpgradeRequest(
        host: "127.0.0.1",
        port: 9,
        apiKey: "a b",
        keyPlacement: .query,
        websocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
    )
    #expect(query.contains("GET /daemon/connect?key=a%20b HTTP/1.1\r\n"))
    #expect(!query.contains("Authorization:"))
    #expect(!query.contains("a b"))

    do {
        _ = try daemonUpgradeRequest(
            host: "127.0.0.1",
            port: 9,
            apiKey: "abc\ndef",
            keyPlacement: .authorizationHeader,
            websocketKey: "k"
        )
        Issue.record("a key with a newline must not be written")
    } catch let error as DaemonConnectError {
        #expect(error == .invalidKey)
        #expect(!error.description.contains("abc"))
        #expect(!error.localizedDescription.contains("abc"))
    }
}

@Test func parsersMatchConnectionTs() {
    #expect(parseServerCapabilitiesHeader(nil) == [])
    #expect(parseServerCapabilitiesHeader("  ") == [])
    #expect(parseServerCapabilitiesHeader("a,b a\tc") == ["a", "b", "c"])
    #expect(normalizeHandshakeReason(nil) == nil)
    #expect(normalizeHandshakeReason("   ") == nil)
    #expect(normalizeHandshakeReason(" missing_key ") == "missing_key")
    #expect(normalizeHandshakeReason("invalid_key_format") == "invalid_key_format")
    #expect(normalizeHandshakeReason("a:b") == "a:b")
    #expect(normalizeHandshakeReason("Bad Reason") == "invalid_header")
    #expect(normalizeHandshakeReason(String(repeating: "a", count: 80)) == String(repeating: "a", count: 80))
    #expect(normalizeHandshakeReason(String(repeating: "a", count: 81)) == "invalid_header")

    let missing = Array("HTTP/1.1 401 Unauthorized\r\nSlock-Reason: missing_key\r\n\r\n".utf8)
    #expect(interpretUpgradeBytes(missing, clientKey: "k") == .rejected(DaemonHandshakeRejection(statusCode: 401, reason: "missing_key")))
    let serverError = Array("HTTP/1.1 500 Internal Server Error\r\n\r\n".utf8)
    #expect(interpretUpgradeBytes(serverError, clientKey: "k") == .rejected(DaemonHandshakeRejection(statusCode: 500, reason: nil)))
    let weird = Array("HTTP/1.1 401 Unauthorized\r\nSlock-Reason: no way\r\n\r\n".utf8)
    guard case .rejected(let rejection) = interpretUpgradeBytes(weird, clientKey: "k") else {
        Issue.record("expected a normalized rejection")
        return
    }
    #expect(rejection.reason == "invalid_header")
    #expect(!rejection.description.contains("no way"))
}

@Test func clientFramesAreMasked() {
    let frame = websocketClientTextFrame("Hi", maskKey: [0x01, 0x02, 0x03, 0x04])
    #expect(frame == [0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x49, 0x6B])
    guard case .frame(let opcode, let fin, let payload, let next) = readServerWebSocketFrame(frame, offset: 0) else {
        Issue.record("masked frame did not parse")
        return
    }
    #expect(opcode == 0x1)
    #expect(fin)
    #expect(payload == Array("Hi".utf8))
    #expect(next == frame.count)

    let text = String(repeating: "a", count: 200)
    let long = websocketClientTextFrame(text, maskKey: [9, 8, 7, 6])
    #expect(long[1] & 0x80 == 0x80)
    guard case .frame(_, _, let longPayload, let longNext) = readServerWebSocketFrame(long, offset: 0) else {
        Issue.record("long masked frame did not parse")
        return
    }
    #expect(longPayload == Array(text.utf8))
    #expect(longNext == long.count)
}

@Test func splitUpgradeBytesStillYieldContext() {
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    let prelude = machineUpgradeSwitchingProtocols(
        clientKey: key,
        capabilities: [serverCapabilityRuntimeDetectionAsyncV1]
    )
    let json = machineContextJSON(
        machineId: "m1",
        serverId: "s1",
        capabilities: [serverCapabilityRuntimeDetectionAsyncV1],
        connectionEpochId: "epoch-1"
    )
    let bytes = Array(prelude.utf8) + websocketTextFrame(json)
    var accumulator = DaemonUpgradeAccumulator(clientKey: key)
    let split = bytes.count / 2
    #expect(accumulator.append(Array(bytes[..<split])) == .needMore)
    guard case .ready(let handshake) = accumulator.append(Array(bytes[split...])) else {
        Issue.record("expected the context frame")
        return
    }
    #expect(handshake.serverCapabilities == ["machine:runtime-detection-async-v1"])
    #expect(handshake.context.machineId == "m1")
    #expect(handshake.context.serverId == "s1")
    #expect(handshake.context.connectionEpochId == "epoch-1")
}

private func rejectedUpgrade(
    lookup: any MachineCredentialLooking,
    apiKey: String?,
    keyPlacement: DaemonAPIKeyPlacement = .authorizationHeader
) async throws -> DaemonHandshakeRejection {
    let server = try await MachineConnectServer.start(lookup: lookup)
    do {
        _ = try await DaemonClient.connect(port: server.port, apiKey: apiKey, keyPlacement: keyPlacement, timeout: .seconds(3))
        try? await server.close()
        Issue.record("expected handshake rejection")
        throw DaemonConnectError.incompleteResponse
    } catch let error as DaemonHandshakeRejection {
        try await server.close()
        return error
    } catch {
        try? await server.close()
        throw error
    }
}

private func acceptedUpgrade(apiKey: String, keyPlacement: DaemonAPIKeyPlacement) async throws -> DaemonHandshake {
    let machine = MatchedMachine(id: "m1", serverId: "s1")
    let server = try await MachineConnectServer.start(
        lookup: ScriptedLookup(computer: .linked(computerId: "c1", machineId: "m1"), machineById: machine)
    )
    do {
        let handshake = try await DaemonClient.connect(
            port: server.port,
            apiKey: apiKey,
            keyPlacement: keyPlacement,
            timeout: .seconds(3)
        )
        try await server.close()
        return handshake
    } catch {
        try? await server.close()
        throw error
    }
}
