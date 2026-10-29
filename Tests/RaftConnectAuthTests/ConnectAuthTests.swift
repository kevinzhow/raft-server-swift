import Foundation
import Testing
@testable import RaftConnectAuth

/// Behavior pinned by `packages/server/src/routes/daemon.wsAuth.test.ts`
/// at raft-source v1.21.23-source.1. These tests drive `UpgradeAuth.resolve`
/// with a scripted lookup where the Node suite uses Postgres.

struct ScriptedLookup: MachineCredentialLooking {
    var computer: ComputerAuthResolution = .denied(.computerNotFound)
    var machineById: MatchedMachine?
    var machineByKey: MatchedMachine?
    var serverLive = true

    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { computer }
    func machine(id: String) async throws -> MatchedMachine? { machineById }
    func serverExists(id: String) async throws -> Bool { serverLive }
    func machine(apiKey: String) async throws -> MatchedMachine? { machineByKey }
}

struct ExplodingLookup: MachineCredentialLooking {
    struct Boom: Error {}
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { throw Boom() }
    func machine(id: String) async throws -> MatchedMachine? { throw Boom() }
    func serverExists(id: String) async throws -> Bool { throw Boom() }
    func machine(apiKey: String) async throws -> MatchedMachine? { throw Boom() }
}

private func rejected(_ decision: UpgradeDecision) -> (PrincipalKind, AuthDenyReason, AuthStage) {
    guard case .rejected(let principal, let reason, let stage) = decision.result else {
        Issue.record("expected a rejection, got \(decision.result)")
        return (.unknown, .exception, .exception)
    }
    return (principal, reason, stage)
}

@Test func missingKeyIs401MissingKey() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: nil,
        hostHeader: "127.0.0.1",
        lookup: ExplodingLookup()
    )
    let (principal, reason, stage) = rejected(decision)
    #expect(principal == .unknown)
    #expect(reason == .missingKey)
    #expect(stage == .format)
    #expect(decision.trace.requestHostClass == "direct")
    #expect(decision.trace.requestHostPresent == true)
    #expect(decision.trace.cohort == "unknown")
    #expect(decision.trace.outcome == "rejected")
    #expect(decision.trace.authStage == "format")
    #expect(machineUpgradeFailurePrelude(.success(decision.result)) == "HTTP/1.1 401 Unauthorized\r\nSlock-Reason: missing_key\r\n\r\n")
}

@Test func unrecognizedKeyFormatIs401() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: "not-a-real-key",
        hostHeader: "127.0.0.1",
        lookup: ExplodingLookup()
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .invalidKeyFormat)
    #expect(stage == .format)
    #expect(machineUpgradeFailurePrelude(.success(decision.result)) == "HTTP/1.1 401 Unauthorized\r\nSlock-Reason: invalid_key_format\r\n\r\n")
}

@Test func computerKeyWithNoRowIsComputerNotFound() async throws {
    let key = "sk_computer_0123456789abcdef"
    let decision = try await UpgradeAuth.resolve(
        apiKey: key,
        hostHeader: "127.0.0.1",
        lookup: ScriptedLookup()
    )
    let (principal, reason, stage) = rejected(decision)
    #expect(principal == .computer)
    #expect(reason == .computerNotFound)
    #expect(stage == .computerLookup)
    let encoded = try JSONEncoder().encode(decision.trace)
    let dump = String(decoding: encoded, as: UTF8.self)
    #expect(!dump.contains(key))
    #expect(!dump.contains("sk_computer_"))
    #expect(decision.trace.apiKeyFingerprint == apiKeyFingerprint(key))
}

@Test func revokedComputerIsComputerRevoked() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_revoked",
        hostHeader: nil,
        lookup: ScriptedLookup(computer: .denied(.computerRevoked))
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .computerRevoked)
    #expect(stage == .computerLookup)
}

@Test func hashMismatchStaysOnComputerLookup() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_mismatch",
        hostHeader: "api.slock.ai",
        lookup: ScriptedLookup(computer: .denied(.computerKeyHashMismatch))
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .computerKeyHashMismatch)
    #expect(stage == .computerLookup)
    #expect(decision.trace.requestHostClass == "api_slock_ai")
}

@Test func unlinkedComputerUsesMachineLookupStage() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_unlinked",
        hostHeader: "127.0.0.1:8080",
        lookup: ScriptedLookup(computer: .denied(.computerMachineUnlinked))
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .computerMachineUnlinked)
    #expect(stage == .machineLookup)
    #expect(decision.trace.requestHostClass == "direct")
}

@Test func linkedComputerWhoseMachineDisappeared() async throws {
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_race",
        hostHeader: "127.0.0.1",
        lookup: ScriptedLookup(computer: .linked(computerId: "c1", machineId: "m-missing"), machineById: nil)
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .machineNotFound)
    #expect(stage == .machineLookup)
}

@Test func liveComputerWhoseServerIsGone() async throws {
    let machine = MatchedMachine(id: "m1", serverId: "s1")
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_noserver",
        hostHeader: "api.raft.build",
        lookup: ScriptedLookup(
            computer: .linked(computerId: "c1", machineId: "m1"),
            machineById: machine,
            serverLive: false
        )
    )
    let (_, reason, stage) = rejected(decision)
    #expect(reason == .serverNotFound)
    #expect(stage == .serverLookup)
    #expect(decision.trace.requestHostClass == "api_raft_build")
}

@Test func validComputerAttachmentIsAccepted() async throws {
    let machine = MatchedMachine(id: "m1", serverId: "s1")
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_computer_live",
        hostHeader: "api.slock.ai",
        lookup: ScriptedLookup(
            computer: .linked(computerId: "c1", machineId: "m1"),
            machineById: machine
        )
    )
    guard case .accepted(let principal, let acceptedMachine, let computerId) = decision.result else {
        Issue.record("expected accept")
        return
    }
    #expect(principal == .computer)
    #expect(acceptedMachine == machine)
    #expect(computerId == "c1")
    #expect(decision.trace.outcome == "accepted")
    #expect(decision.trace.machineId == "m1")
    #expect(decision.trace.computerId == "c1")
    #expect(machineUpgradeFailurePrelude(.success(decision.result)) == nil)
}

@Test func legacyMigratedKeyIsRejected() async throws {
    let machine = MatchedMachine(id: "m1", serverId: "s1", legacyKeyMigratedAt: Date(timeIntervalSince1970: 1))
    let decision = try await UpgradeAuth.resolve(
        apiKey: "sk_machine_old",
        hostHeader: "127.0.0.1",
        lookup: ScriptedLookup(machineByKey: machine)
    )
    let (principal, reason, stage) = rejected(decision)
    #expect(principal == .legacyMachine)
    #expect(reason == .legacyMachineKeyMigrated)
    #expect(stage == .legacyMigration)
}

@Test func legacyQueryKeyIsAccepted() async throws {
    let machine = MatchedMachine(id: "m1", serverId: "s1")
    let key = presentedApiKey(authorization: nil, queryKey: "sk_daemon_legacy")
    let decision = try await UpgradeAuth.resolve(
        apiKey: key,
        hostHeader: "127.0.0.1",
        lookup: ScriptedLookup(machineByKey: machine)
    )
    guard case .accepted(let principal, _, let computerId) = decision.result else {
        Issue.record("expected accept")
        return
    }
    #expect(principal == .legacyMachine)
    #expect(computerId == nil)
}

@Test func bearerWinsOverQuery() {
    let key = presentedApiKey(authorization: "bearer sk_machine_from_header", queryKey: "sk_machine_from_query")
    #expect(key == "sk_machine_from_header")
}

@Test func blankBearerFallsThroughToQuery() {
    #expect(presentedApiKey(authorization: "Bearer    ", queryKey: "sk_machine_q") == "sk_machine_q")
    #expect(extractBearerToken("NotBearer sk_machine_x") == nil)
}

@Test func lookupThrowIs500WithoutTheKey() async {
    let key = "sk_computer_boom"
    do {
        _ = try await UpgradeAuth.resolve(apiKey: key, hostHeader: "127.0.0.1", lookup: ExplodingLookup())
        Issue.record("lookup must throw")
    } catch {
        let prelude = machineUpgradeFailurePrelude(.failure(error))
        #expect(prelude == "HTTP/1.1 500 Internal Server Error\r\n\r\n")
        #expect(prelude?.contains(key) == false)
        #expect(prelude?.contains("sk_computer_") == false)
    }
}

@Test func hostClassesAndCohorts() {
    #expect(classifyRequestHost(normalizeHostHeader("API.SLOCK.AI:443")) == "api_slock_ai")
    #expect(classifyRequestHost(normalizeHostHeader("[::1]:443")) == "direct")
    #expect(classifyRequestHost(normalizeHostHeader("localhost")) == "direct")
    #expect(classifyRequestHost(normalizeHostHeader("chat.example.com")) == "custom")
    #expect(classifyRequestHost(normalizeHostHeader("   ")) == "unknown")
    #expect(classifyRuntimeCohort(["FLY_APP_NAME": "raft"]) == "fly")
    #expect(classifyRuntimeCohort(["AWS_EXECUTION_ENV": "AWS_ECS_FARGATE"]) == "aws")
    #expect(classifyRuntimeCohort([:]) == "unknown")
}

@Test func rfcWebSocketAcceptAndContextJSON() {
    #expect(secWebSocketAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    #expect(machineContextJSON(machineId: "m1", serverId: "s1", capabilities: [serverCapabilityRuntimeDetectionAsyncV1])
        == "{\"type\":\"machine:context\",\"machineId\":\"m1\",\"serverId\":\"s1\",\"capabilities\":[\"machine:runtime-detection-async-v1\"]}")
}

@Test func fingerprintMatchesSha256Prefix() {
    // hashlib.sha256(b"sk_machine_example").hexdigest()[:16]
    #expect(apiKeyFingerprint("sk_machine_example") == "2663b082cfdbe3f7")
}
