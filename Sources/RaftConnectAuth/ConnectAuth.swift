import Crypto
import Foundation

/// Wire header on the `/daemon/connect` 101 response.
/// Source: `RAFT_SERVER_CAPABILITIES_HEADER` in raft-source `packages/shared`.
public let raftServerCapabilitiesHeader = "raft-server-capabilities"

/// Source: `SERVER_CAPABILITY_RUNTIME_DETECTION_ASYNC_V1`.
public let serverCapabilityRuntimeDetectionAsyncV1 = "machine:runtime-detection-async-v1"

public enum PrincipalKind: String, Sendable, Equatable, Codable {
    case unknown
    case computer
    case legacyMachine = "legacy_machine"
}

/// Closed set copied from `AuthDenyReason` plus `ComputerAuthDenyReason`
/// in `packages/server/src/routes/daemon.ts`.
public enum AuthDenyReason: String, Sendable, Equatable, Codable {
    case missingKey = "missing_key"
    case invalidKeyFormat = "invalid_key_format"
    case computerNotFound = "computer_not_found"
    case computerRevoked = "computer_revoked"
    case computerMachineUnlinked = "computer_machine_unlinked"
    case computerKeyHashMismatch = "computer_key_hash_mismatch"
    case serverNotFound = "server_not_found"
    case machineNotFound = "machine_not_found"
    case machineKeyInvalid = "machine_key_invalid"
    case legacyMachineKeyMigrated = "legacy_machine_key_migrated"
    case exception
}

public enum AuthStage: String, Sendable, Equatable, Codable {
    case format
    case computerLookup = "computer_lookup"
    case machineLookup = "machine_lookup"
    case legacyMigration = "legacy_migration"
    case serverLookup = "server_lookup"
    case exception
}

public struct MatchedMachine: Sendable, Equatable, Codable {
    public var id: String
    public var serverId: String
    public var legacyKeyMigratedAt: Date?

    public init(id: String, serverId: String, legacyKeyMigratedAt: Date? = nil) {
        self.id = id
        self.serverId = serverId
        self.legacyKeyMigratedAt = legacyKeyMigratedAt
    }
}

public enum ComputerAuthResolution: Sendable, Equatable {
    case linked(computerId: String, machineId: String)
    case denied(AuthDenyReason)
}

public protocol MachineCredentialLooking: Sendable {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution
    func machine(id: String) async throws -> MatchedMachine?
    func serverExists(id: String) async throws -> Bool
    func machine(apiKey: String) async throws -> MatchedMachine?
}

public enum UpgradeAuthResult: Sendable, Equatable {
    case accepted(principal: PrincipalKind, machine: MatchedMachine, computerId: String?)
    case rejected(principal: PrincipalKind, reason: AuthDenyReason, stage: AuthStage)
}

public struct ConnectTrace: Sendable, Equatable, Codable {
    public var requestHostClass: String
    public var requestHostPresent: Bool
    public var cohort: String
    public var outcome: String
    public var reason: String?
    public var authStage: String?
    public var principalKind: String
    public var apiKeyFingerprint: String?
    public var machineId: String?
    public var serverId: String?
    public var computerId: String?

    public init(
        requestHostClass: String,
        requestHostPresent: Bool,
        cohort: String,
        outcome: String,
        reason: String?,
        authStage: String?,
        principalKind: String,
        apiKeyFingerprint: String?,
        machineId: String?,
        serverId: String?,
        computerId: String?
    ) {
        self.requestHostClass = requestHostClass
        self.requestHostPresent = requestHostPresent
        self.cohort = cohort
        self.outcome = outcome
        self.reason = reason
        self.authStage = authStage
        self.principalKind = principalKind
        self.apiKeyFingerprint = apiKeyFingerprint
        self.machineId = machineId
        self.serverId = serverId
        self.computerId = computerId
    }
}

public struct UpgradeDecision: Sendable, Equatable {
    public var result: UpgradeAuthResult
    public var trace: ConnectTrace

    public init(result: UpgradeAuthResult, trace: ConnectTrace) {
        self.result = result
        self.trace = trace
    }
}

public enum UpgradeAuth {
    /// Decision copied from `resolveUpgradeAuth` in `packages/server/src/routes/daemon.ts`.
    /// A thrown lookup becomes the caller's 500 path; this function does not catch it.
    public static func resolve(
        apiKey: String?,
        hostHeader: String?,
        environment: [String: String] = [:],
        lookup: any MachineCredentialLooking
    ) async throws -> UpgradeDecision {
        let host = classifyConnectHost(hostHeader, environment: environment)
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        guard let key else {
            return decision(
                .rejected(principal: .unknown, reason: .missingKey, stage: .format),
                host: host,
                fingerprint: nil,
                machine: nil,
                computerId: nil
            )
        }
        let fingerprint = apiKeyFingerprint(key)
        let isComputer = key.hasPrefix("sk_computer_")
        let principal: PrincipalKind = if isComputer {
            .computer
        } else if key.hasPrefix("sk_machine_") || key.hasPrefix("sk_daemon_") {
            .legacyMachine
        } else {
            .unknown
        }
        if principal == .unknown {
            return decision(
                .rejected(principal: principal, reason: .invalidKeyFormat, stage: .format),
                host: host,
                fingerprint: fingerprint,
                machine: nil,
                computerId: nil
            )
        }

        if isComputer {
            let lookupResult = try await lookup.findComputer(apiKey: key)
            switch lookupResult {
            case .denied(let reason):
                let stage: AuthStage = reason == .computerMachineUnlinked ? .machineLookup : .computerLookup
                return decision(
                    .rejected(principal: principal, reason: reason, stage: stage),
                    host: host,
                    fingerprint: fingerprint,
                    machine: nil,
                    computerId: nil
                )
            case .linked(let computerId, let machineId):
                guard let machine = try await lookup.machine(id: machineId) else {
                    return decision(
                        .rejected(principal: principal, reason: .machineNotFound, stage: .machineLookup),
                        host: host,
                        fingerprint: fingerprint,
                        machine: nil,
                        computerId: computerId
                    )
                }
                guard try await lookup.serverExists(id: machine.serverId) else {
                    return decision(
                        .rejected(principal: principal, reason: .serverNotFound, stage: .serverLookup),
                        host: host,
                        fingerprint: fingerprint,
                        machine: machine,
                        computerId: computerId
                    )
                }
                return decision(
                    .accepted(principal: principal, machine: machine, computerId: computerId),
                    host: host,
                    fingerprint: fingerprint,
                    machine: machine,
                    computerId: computerId
                )
            }
        }

        guard let machine = try await lookup.machine(apiKey: key) else {
            return decision(
                .rejected(principal: principal, reason: .machineKeyInvalid, stage: .machineLookup),
                host: host,
                fingerprint: fingerprint,
                machine: nil,
                computerId: nil
            )
        }
        if machine.legacyKeyMigratedAt != nil {
            return decision(
                .rejected(principal: principal, reason: .legacyMachineKeyMigrated, stage: .legacyMigration),
                host: host,
                fingerprint: fingerprint,
                machine: machine,
                computerId: nil
            )
        }
        guard try await lookup.serverExists(id: machine.serverId) else {
            return decision(
                .rejected(principal: principal, reason: .serverNotFound, stage: .serverLookup),
                host: host,
                fingerprint: fingerprint,
                machine: machine,
                computerId: nil
            )
        }
        return decision(
            .accepted(principal: principal, machine: machine, computerId: nil),
            host: host,
            fingerprint: fingerprint,
            machine: machine,
            computerId: nil
        )
    }

    private static func decision(
        _ result: UpgradeAuthResult,
        host: ConnectHost,
        fingerprint: String?,
        machine: MatchedMachine?,
        computerId: String?
    ) -> UpgradeDecision {
        let rejected = switch result {
        case .rejected(let principal, let reason, let stage):
            (outcome: "rejected", principal: principal, reason: Optional(reason.rawValue), stage: Optional(stage.rawValue))
        case .accepted(let principal, _, _):
            (outcome: "accepted", principal: principal, reason: Optional<String>.none, stage: Optional<String>.none)
        }
        let trace = ConnectTrace(
            requestHostClass: host.requestHostClass,
            requestHostPresent: host.requestHostPresent,
            cohort: host.cohort,
            outcome: rejected.outcome,
            reason: rejected.reason,
            authStage: rejected.stage,
            principalKind: rejected.principal.rawValue,
            apiKeyFingerprint: fingerprint,
            machineId: machine?.id,
            serverId: machine?.serverId,
            computerId: computerId
        )
        return UpgradeDecision(result: result, trace: trace)
    }
}

/// `Authorization: Bearer <key>`, case-insensitive, full-string match.
/// Empty remainder is treated as no key. Source: `extractBearerToken`.
public func extractBearerToken(_ header: String?) -> String? {
    guard let header, let match = header.wholeMatch(of: /^Bearer\s+(.+)$/.ignoresCase()) else {
        return nil
    }
    let token = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

/// Header wins. Query `key` remains for older daemons. Source: the upgrade handler.
public func presentedApiKey(authorization: String?, queryKey: String?) -> String? {
    if let bearer = extractBearerToken(authorization) {
        return bearer
    }
    guard let queryKey, !queryKey.isEmpty else { return nil }
    return queryKey
}

/// sha256 hex, first 16 characters. Source: `extractApiKeyFingerprint`.
public func apiKeyFingerprint(_ apiKey: String) -> String {
    let digest = SHA256.hash(data: Data(apiKey.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// RFC 6455 accept value. `Insecure.SHA1` is the hash the handshake specifies.
public func secWebSocketAccept(_ clientKey: String) -> String {
    let material = Data((clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
    let digest = Insecure.SHA1.hash(data: material)
    return Data(digest).base64EncodedString()
}

/// `machine:context` JSON in `JSON.stringify` key order.
/// Source: `sendAuthenticatedMachineContext`. Epoch is omitted unless the
/// caller passes it, matching the flag-off server (`RUNTIME_OUTCOME_ACK_ENABLED` is false).
public func machineContextJSON(machineId: String, serverId: String, capabilities: [String], connectionEpochId: String? = nil) -> String {
    func json(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    var fields = [
        "\"type\":\"machine:context\"",
        "\"machineId\":\(json(machineId))",
        "\"serverId\":\(json(serverId))",
    ]
    if !capabilities.isEmpty {
        let list = capabilities.map(json).joined(separator: ",")
        fields.append("\"capabilities\":[\(list)]")
    }
    if let connectionEpochId {
        fields.append("\"connectionEpochId\":\(json(connectionEpochId))")
    }
    return "{\(fields.joined(separator: ","))}"
}

public func machineUpgradeSwitchingProtocols(clientKey: String, capabilities: [String]) -> String {
    var lines = [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Accept: \(secWebSocketAccept(clientKey))",
    ]
    if !capabilities.isEmpty {
        lines.append("\(raftServerCapabilitiesHeader): \(capabilities.joined(separator: " "))")
    }
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

public func websocketTextFrame(_ text: String) -> [UInt8] {
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
        frame.append(UInt8(payload.count))
    } else if payload.count <= Int(UInt16.max) {
        frame.append(126)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
    } else {
        frame.append(127)
        let length = UInt64(payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((length >> shift) & 0xff))
        }
    }
    frame.append(contentsOf: payload)
    return frame
}

/// Bytes written on the raw socket before it is destroyed.
/// Source: the 401 and 500 branches in `setupMachineWebSocket`.
public func machineUpgradeFailurePrelude(_ result: Result<UpgradeAuthResult, any Error>) -> String? {
    switch result {
    case .success(.rejected(_, let reason, _)):
        return "HTTP/1.1 401 Unauthorized\r\nSlock-Reason: \(reason.rawValue)\r\n\r\n"
    case .success(.accepted):
        return nil
    case .failure:
        return "HTTP/1.1 500 Internal Server Error\r\n\r\n"
    }
}

struct ConnectHost: Sendable, Equatable {
    var requestHostClass: String
    var requestHostPresent: Bool
    var cohort: String
}

func classifyConnectHost(_ hostHeader: String?, environment: [String: String]) -> ConnectHost {
    let normalized = normalizeHostHeader(hostHeader)
    return ConnectHost(
        requestHostClass: classifyRequestHost(normalized),
        requestHostPresent: normalized != nil,
        cohort: classifyRuntimeCohort(environment)
    )
}

func normalizeHostHeader(_ hostHeader: String?) -> String? {
    guard let hostHeader else { return nil }
    let trimmed = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return nil }
    if trimmed.hasPrefix("[") {
        guard let end = trimmed.firstIndex(of: "]"), trimmed.distance(from: trimmed.startIndex, to: end) > 1 else {
            return nil
        }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
    }
    let colonCount = trimmed.filter { $0 == ":" }.count
    if colonCount > 1 { return trimmed }
    return trimmed.split(separator: ":", maxSplits: 1).first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
}

func classifyRequestHost(_ host: String?) -> String {
    guard let host else { return "unknown" }
    if host == "api.raft.build" { return "api_raft_build" }
    if host == "api.slock.ai" { return "api_slock_ai" }
    if isDirectHost(host) { return "direct" }
    return "custom"
}

func isDirectHost(_ host: String) -> Bool {
    if host == "localhost" { return true }
    if host.hasSuffix(".fly.dev") || host.hasSuffix(".elb.amazonaws.com") { return true }
    if host.wholeMatch(of: /^\d{1,3}(?:\.\d{1,3}){3}$/) != nil { return true }
    if host == "::1" || host.contains(":") { return true }
    return false
}

func classifyRuntimeCohort(_ environment: [String: String]) -> String {
    if environment["FLY_APP_NAME"] != nil
        || environment["FLY_MACHINE_ID"] != nil
        || environment["FLY_ALLOC_ID"] != nil
        || environment["FLY_INSTANCE_ID"] != nil
    {
        return "fly"
    }
    if environment["ECS_CONTAINER_METADATA_URI_V4"] != nil
        || environment["ECS_CONTAINER_METADATA_URI"] != nil
        || environment["AWS_EXECUTION_ENV"]?.hasPrefix("AWS_ECS") == true
    {
        return "aws"
    }
    return "unknown"
}
