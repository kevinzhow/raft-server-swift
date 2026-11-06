import Crypto
import Foundation

/// The signed attestation claims `metadata` object of the machine route.
///
/// Every member is optional: the legacy builder inserted a key only when its
/// source value passed, and the sorted-key encoder omits the rest. The members
/// are the complete published key set, so `JSONEncoder` with sorted keys prints
/// the same bytes the retired untyped sorted-key serializer did.
struct ScopeAttestationMetadata: Encodable, Equatable, Sendable {
    var bundleId: String?
    var bundleSha256: String?
    var bundleSizeBytes: Int?
    var bundleContentType: String?
    var bundleContentEncoding: String?
    var feedbackReportId: String?
    var agentId: String?
    var feedbackAttachmentKind: String?
    var deploymentEnvironment: String?
    var feedbackMachineLogTailLineCount: Int?
    var feedbackMachineLogTailSourceLineCount: Int?
    var feedbackMachineLogTailLinesOutsideWindow: Int?
    var feedbackMachineLogTailUndatedLines: Int?
    var feedbackMachineLogTailTruncated: String?
    var feedbackMachineLogTailIncludesOtherAgents: String?
    var feedbackTranscriptRequestId: String?
    var objectKey: String?
    var maxBytes: Int?
    var feedbackReportGeneratedAt: String?
    var feedbackReportWindowStartAt: String?
    var feedbackTranscriptFirstEventAt: String?
    var feedbackTranscriptLastEventAt: String?
    var feedbackReportTimeSource: String?
    var feedbackTranscriptWindowCoverage: String?
    var feedbackTranscriptTruncationDirection: String?
    var feedbackTranscriptTruncated: String?
    var feedbackTranscriptWindowToleranceMs: Int?
    var feedbackTranscriptContent: String?
    var feedbackTranscriptSourceBytes: Int?
    var feedbackTranscriptBytes: Int?
}

/// The claims a machine attestation signs.
private struct MachineScopeClaims: Encodable {
    var sub: String
    var actorType: String
    var machineId: String
    var serverId: String
    var serverSlug: String
    var scope: String
    var aud: String
    var resource: String
    var jti: String
    var nonce: String
    var exp: Int
    var metadata: ScopeAttestationMetadata?
}

/// The claims a user (server-route) attestation signs.
private struct ServerScopeClaims: Encodable {
    var scope: String
    var actorType: String
    var sub: String
    var serverId: String
    var aud: String
    var resource: String
    var exp: Int
}

private struct JWTHeader: Encodable {
    var alg: String
    var typ: String
}

/// `POST /machine/scope-attestation` and `POST /api/servers/:id/scope-attestation`.
///
/// Both mint an HS256 token over sorted-key claims. The claims JSON and the
/// response `metadata` member are produced by the same encoder, so the signed
/// payload and the echoed object carry identical bytes.
extension ServerProfileAndOrderService {

    // MARK: - Machine route

    private static let supportedMachineScopes: [String: (audience: String, suffix: String)] = [
        "feedback-report:create": ("feedback-worker", "feedback-reports"),
        "daemon-trace-bundle:create": ("trace-ingest-worker", "trace-bundles"),
        "machine_log_tail:create": ("trace-ingest-worker", "trace-bundles"),
        "machine_evidence:create": ("trace-ingest-worker", "trace-bundles"),
    ]

    public func machineScopeAttestation(
        authorization: String?,
        body: MachineScopeAttestationRequest?
    ) throws -> ScopeAttestationResponse {
        guard let machineId = dependencies.machineIdForCredential(authorization) else {
            throw ServerProfileAndOrderError.machineUnauthorized
        }
        let secretOverride = dependencies.profiles.scopeAttestationSecretOverride
        let deploymentOverride = dependencies.profiles.deploymentEnvironmentOverride
        let environment = dependencies.environment()
        let secretValue: String?
        if let secretOverride { secretValue = secretOverride } else {
            secretValue = environment["SCOPE_ATTESTATION_SECRET"]
        }
        guard let secret = secretValue,
              !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServerProfileAndOrderError.scopeAttestationNotConfigured
        }
        guard let body, let scope = body.scope else {
            throw ServerProfileAndOrderError.invalidAttestationRequest
        }
        if body.hasAudience { throw ServerProfileAndOrderError.audienceDerived }
        if body.hasResource { throw ServerProfileAndOrderError.resourceDerived }
        guard let scopeContract = Self.supportedMachineScopes[scope] else {
            throw ServerProfileAndOrderError.unsupportedScope(scope)
        }
        let serverId = dependencies.machines.machines.first { $0.id == machineId }?.serverId ?? ""
        let serverSlug = dependencies.oauth.serverProfile(id: serverId)?.slug ?? ""
        guard !serverId.isEmpty else {
            throw ServerProfileAndOrderError.machineUnauthorized
        }
        let resource = "servers/\(serverId)/machines/\(machineId)/\(scopeContract.suffix)"
        var metadata: ScopeAttestationMetadata?
        if scope == "daemon-trace-bundle:create" || scope == "machine_log_tail:create"
            || scope == "machine_evidence:create" {
            metadata = try bundleMetadata(
                raw: body.metadata,
                serverId: serverId,
                machineId: machineId,
                deploymentOverride: deploymentOverride,
                environment: environment
            )
        }
        let expires = Int(dependencies.now().timeIntervalSince1970) + 120
        let claims = MachineScopeClaims(
            sub: "machine:\(machineId)",
            actorType: "machine",
            machineId: machineId,
            serverId: serverId,
            serverSlug: serverSlug,
            scope: scope,
            aud: scopeContract.audience,
            resource: resource,
            jti: dependencies.makeUUID(),
            nonce: dependencies.makeUUID(),
            exp: expires,
            metadata: metadata
        )
        let attestation = Self.signHS256(claims: Self.encodeSorted(claims), secret: secret)
        return ScopeAttestationResponse(
            attestation: attestation,
            scope: scope,
            audience: scopeContract.audience,
            resource: resource,
            expiresAt: Self.fractionalISO(Date(timeIntervalSince1970: TimeInterval(expires))),
            metadata: ScopeAttestationMetadataBody(renderedObject: metadata.map(Self.encodeSorted))
        )
    }

    /// Validates and copies the raw metadata of a trace-bundle style scope. The
    /// checks run in the published order; the first failing one is the refusal.
    private func bundleMetadata(
        raw: [String: JSONScalarValue],
        serverId: String,
        machineId: String,
        deploymentOverride: String??,
        environment: [String: String]
    ) throws -> ScopeAttestationMetadata {
        var metadata = ScopeAttestationMetadata()
        guard let bundleId = Self.string(raw["bundleId"]), !bundleId.isEmpty, bundleId.count <= 128,
              let bundleSha256 = Self.string(raw["bundleSha256"]), bundleSha256.count == 64,
              let bundleSizeBytes = Self.nonNegativeInt(raw["bundleSizeBytes"])
        else {
            throw ServerProfileAndOrderError.invalidAttestationRequest
        }
        metadata.bundleId = bundleId
        metadata.bundleSha256 = bundleSha256
        metadata.bundleSizeBytes = bundleSizeBytes
        if let contentType = Self.string(raw["bundleContentType"]), contentType.count > 128 {
            throw ServerProfileAndOrderError.bundleContentTypeTooLong
        }
        if let encoding = Self.string(raw["bundleContentEncoding"]), encoding.count > 64 {
            throw ServerProfileAndOrderError.bundleContentEncodingTooLong
        }
        if let reportId = raw["feedbackReportId"] {
            guard case .string(let text) = reportId, ServerScope.isUUID(text) else {
                throw ServerProfileAndOrderError.feedbackReportIdNotUUID
            }
            metadata.feedbackReportId = text
        }
        if let agentId = raw["agentId"] {
            guard case .string(let text) = agentId, ServerScope.isUUID(text) else {
                throw ServerProfileAndOrderError.agentIdNotUUID
            }
            metadata.agentId = text
        }
        if let requestedKind = Self.string(raw["feedbackAttachmentKind"]),
           ["session_transcript", "transcript_outcome", "machine_log_tail", "machine_evidence"]
            .contains(requestedKind) {
            metadata.feedbackAttachmentKind = requestedKind
        }
        let kind = metadata.feedbackAttachmentKind ?? "session_transcript"
        let envValue: String?
        if let deploymentOverride { envValue = deploymentOverride } else {
            envValue = environment["DEPLOYMENT_ENV"]
        }
        let serverEnv = (envValue ?? "production").lowercased()
        if let producerEnv = Self.string(raw["deploymentEnvironment"]) {
            guard ["dev", "development", "staging", "production"].contains(producerEnv) else {
                throw ServerProfileAndOrderError.deploymentEnvironmentNotAllowed(producerEnv)
            }
            if serverEnv != producerEnv,
               !(serverEnv == "staging" && (producerEnv == "dev" || producerEnv == "development")) {
                throw ServerProfileAndOrderError.deploymentEnvironmentInconsistent(
                    "deploymentEnvironment \(producerEnv) is inconsistent with server deployment \"\(serverEnv)\""
                )
            }
            metadata.deploymentEnvironment = producerEnv
        } else {
            metadata.deploymentEnvironment = serverEnv
        }
        if kind == "machine_log_tail" {
            func count(_ key: String) -> Int? {
                Self.nonNegativeInt(raw[key]).flatMap { $0 <= 10_000_000 ? $0 : nil }
            }
            metadata.feedbackMachineLogTailLineCount = count("feedbackMachineLogTailLineCount")
            metadata.feedbackMachineLogTailSourceLineCount = count("feedbackMachineLogTailSourceLineCount")
            metadata.feedbackMachineLogTailLinesOutsideWindow = count("feedbackMachineLogTailLinesOutsideWindow")
            metadata.feedbackMachineLogTailUndatedLines = count("feedbackMachineLogTailUndatedLines")
            metadata.feedbackMachineLogTailTruncated = Self.booleanText(raw["feedbackMachineLogTailTruncated"])
            metadata.feedbackMachineLogTailIncludesOtherAgents =
                Self.booleanText(raw["feedbackMachineLogTailIncludesOtherAgents"])
        }
        if kind == "machine_evidence" {
            guard let agentId = metadata.agentId, let reportId = metadata.feedbackReportId else {
                throw ServerProfileAndOrderError.invalidAttestationRequest
            }
            try requireAgentOnMachine(agentId: agentId, serverId: serverId, machineId: machineId)
            let maxBytes = 256 * 1024
            guard bundleSizeBytes <= maxBytes else {
                throw ServerProfileAndOrderError.evidenceBundleTooLarge
            }
            metadata.feedbackReportId = reportId
            metadata.feedbackAttachmentKind = kind
            metadata.objectKey = "feedback-machine-evidence/\(serverId)/\(machineId)/\(dependencies.makeUUID()).json.gz"
            metadata.bundleContentType = "application/json"
            metadata.bundleContentEncoding = "gzip"
            metadata.maxBytes = maxBytes
        } else if kind == "transcript_outcome" {
            guard let agentId = metadata.agentId,
                  metadata.feedbackReportId != nil,
                  let requestId = Self.string(raw["feedbackTranscriptRequestId"]),
                  requestId.wholeMatch(of: /^[^\s]{1,128}$/) != nil
            else {
                throw ServerProfileAndOrderError.invalidAttestationRequest
            }
            try requireAgentOnMachine(agentId: agentId, serverId: serverId, machineId: machineId)
            let maxBytes = 2048
            guard bundleSizeBytes <= maxBytes else {
                throw ServerProfileAndOrderError.outcomeBundleTooLarge
            }
            metadata.feedbackTranscriptRequestId = requestId
            metadata.objectKey = "feedback-transcript-outcomes/\(serverId)/\(machineId)/\(dependencies.makeUUID()).json.gz"
            metadata.bundleContentType = "application/json"
            metadata.bundleContentEncoding = "gzip"
            metadata.maxBytes = maxBytes
        } else {
            metadata.bundleContentType = Self.string(raw["bundleContentType"]) ?? "application/x-ndjson"
            metadata.bundleContentEncoding = Self.string(raw["bundleContentEncoding"]) ?? "gzip"
            metadata.maxBytes = 50 * 1024 * 1024
            metadata.objectKey = "trace-bundles/\(serverId)/\(machineId)/\(dependencies.makeUUID()).jsonl.gz"
        }
        func timeText(_ key: String) -> String? {
            Self.string(raw[key]).flatMap { !$0.isEmpty && $0.count <= 64 ? $0 : nil }
        }
        metadata.feedbackReportGeneratedAt = timeText("feedbackReportGeneratedAt")
        metadata.feedbackReportWindowStartAt = timeText("feedbackReportWindowStartAt")
        metadata.feedbackTranscriptFirstEventAt = timeText("feedbackTranscriptFirstEventAt")
        metadata.feedbackTranscriptLastEventAt = timeText("feedbackTranscriptLastEventAt")
        if let source = Self.string(raw["feedbackReportTimeSource"]),
           ["web_report_bundle", "computer_clock", "unknown"].contains(source) {
            metadata.feedbackReportTimeSource = source
        }
        if let coverage = Self.string(raw["feedbackTranscriptWindowCoverage"]),
           ["timestamps_available", "timestamps_unavailable", "covered"].contains(coverage) {
            metadata.feedbackTranscriptWindowCoverage = coverage
        }
        if let direction = Self.string(raw["feedbackTranscriptTruncationDirection"]),
           ["window", "size", "tail"].contains(direction) {
            metadata.feedbackTranscriptTruncationDirection = direction
        }
        if let truncated = raw["feedbackTranscriptTruncated"] {
            if let boolean = Self.legacyBoolean(truncated) {
                metadata.feedbackTranscriptTruncated = boolean ? "true" : "false"
            } else if case .string(let text) = truncated, text == "true" || text == "false" {
                metadata.feedbackTranscriptTruncated = text
            }
        }
        if let tolerance = Self.nonNegativeInt(raw["feedbackTranscriptWindowToleranceMs"]),
           tolerance <= 24 * 60 * 60 * 1000 {
            metadata.feedbackTranscriptWindowToleranceMs = tolerance
        }
        if kind != "transcript_outcome",
           let content = Self.string(raw["feedbackTranscriptContent"]),
           ["native_session_file", "native_state_file"].contains(content) {
            metadata.feedbackTranscriptContent = content
        }
        if let value = Self.nonNegativeInt(raw["feedbackTranscriptSourceBytes"]) {
            metadata.feedbackTranscriptSourceBytes = value
        }
        if let value = Self.nonNegativeInt(raw["feedbackTranscriptBytes"]) {
            metadata.feedbackTranscriptBytes = value
        }
        if let requestId = Self.string(raw["feedbackTranscriptRequestId"]),
           requestId.wholeMatch(of: /^[^\s]{1,128}$/) != nil {
            metadata.feedbackTranscriptRequestId = requestId
        }
        return metadata
    }

    /// The agent must belong to the server and be bound to the calling machine.
    private func requireAgentOnMachine(agentId: String, serverId: String, machineId: String) throws {
        let agent = dependencies.oauth.agentRuntimeInfo(id: agentId)
        let boundMachine = dependencies.agents.agentMachineIds[agentId]
        guard agent?.serverId == serverId, boundMachine == machineId else {
            throw ServerProfileAndOrderError.agentNotOnMachine
        }
    }

    // MARK: - Server route

    public func serverScopeAttestation(
        authorization: String?,
        serverId: String,
        body: ServerScopeAttestationRequest?
    ) throws -> ScopeAttestationResponse {
        let userId = try requireUser(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        guard let scope = body?.scope else {
            throw ServerProfileAndOrderError.invalidScopeAttestationRequest
        }
        let audience: String
        let resource: String
        switch scope {
        case "web-trace-batch:create":
            audience = "trace-ingest-worker"
            resource = "servers/\(serverId)/web-traces"
        case "feedback-report:create":
            guard role == "owner" || role == "admin" else {
                throw ServerProfileAndOrderError.forbidden
            }
            audience = "feedback-worker"
            resource = "servers/\(serverId)/feedback-reports"
        default:
            throw ServerProfileAndOrderError.unknownScope
        }
        let expiresAt = dependencies.now().addingTimeInterval(300)
        let claims = ServerScopeClaims(
            scope: scope,
            actorType: "user",
            sub: userId,
            serverId: serverId,
            aud: audience,
            resource: resource,
            exp: Int(expiresAt.timeIntervalSince1970)
        )
        let secret = dependencies.environment()["SCOPE_ATTESTATION_SECRET"]
            ?? "scope-attestation-default-secret"
        return ScopeAttestationResponse(
            attestation: Self.signHS256(claims: Self.encodeSorted(claims), secret: secret),
            scope: scope,
            audience: audience,
            resource: resource,
            expiresAt: Self.fractionalISO(expiresAt),
            metadata: nil
        )
    }

    // MARK: - Encoding and signing

    private static func encodeSorted<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func signHS256(claims claimsJSON: String, secret: String) -> String {
        func base64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let headerJSON = encodeSorted(JWTHeader(alg: "HS256", typ: "JWT"))
        let signingInput = "\(base64url(Data(headerJSON.utf8))).\(base64url(Data(claimsJSON.utf8)))"
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        ))
        return "\(signingInput).\(base64url(mac))"
    }

    private static func fractionalISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Legacy scalar reads
    //
    // The retired parser read each metadata member with an `as?` cast over the
    // bridged `NSNumber`/`String` values. These keep those casts: a JSON boolean
    // or number is a number for the integer reads, and the numbers 0 and 1 read
    // as booleans.

    private static func string(_ value: JSONScalarValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    /// `attestationInt`: a whole, non-negative number up to 2^53 - 1.
    private static func nonNegativeInt(_ value: JSONScalarValue?) -> Int? {
        let double: Double
        switch value {
        case .bool(let boolean)?:
            double = boolean ? 1 : 0
        case .integer(let integer)?:
            double = Double(integer)
        case .number(let number)?:
            double = number
        case .null?, .string?, .other?, nil:
            return nil
        }
        guard double.rounded() == double, double >= 0, double <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }

    /// `as? Bool` over a JSON boolean or the numbers 0 and 1.
    private static func legacyBoolean(_ value: JSONScalarValue) -> Bool? {
        switch value {
        case .bool(let boolean):
            boolean
        case .integer(let integer):
            integer == 1 ? true : (integer == 0 ? false : nil)
        case .number(let number):
            number == 1 ? true : (number == 0 ? false : nil)
        case .null, .string, .other:
            nil
        }
    }

    /// The `"true"`/`"false"` text of a string member; any other value is nil.
    private static func booleanText(_ value: JSONScalarValue?) -> String? {
        if case .string(let text)? = value, text == "true" || text == "false" { return text }
        return nil
    }
}
