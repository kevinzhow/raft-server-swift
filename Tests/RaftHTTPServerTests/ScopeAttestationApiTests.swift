import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ScopeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001097001"
    let ownerId = "11111111-1111-4111-8111-000001097001"
    var machineId = ""
    var otherMachineId = ""
    var apiKey = ""
    var otherApiKey = ""
    var agentId = ""
    var otherAgentId = ""
    var foreignAgentId = ""
    let slug = "daemon-scope"

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "daemon-scope-owner@scope.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Daemon Scope", ownerId: ownerId)
        machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "daemon-scope-machine")
        otherMachineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "daemon-scope-machine-2")
        apiKey = accounts.machineAPIKey(machineId: machineId) ?? ""
        otherApiKey = accounts.machineAPIKey(machineId: otherMachineId) ?? ""
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "scope-agent", creatorUserId: ownerId, runtime: "claude")
        otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "scope-agent-2", creatorUserId: ownerId, runtime: "claude")
        foreignAgentId = accounts.oauth.createAgent(serverId: serverId, name: "scope-agent-3", creatorUserId: ownerId, runtime: "claude")
        accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
        accounts.assignAgentMachineForTesting(agentId: otherAgentId, machineId: otherMachineId)
        accounts.assignAgentMachineForTesting(agentId: foreignAgentId, machineId: otherMachineId)
    }
}

private func attest(_ client: any Client, _ fixture: ScopeFixture, _ payload: [String: Any], apiKey: String? = nil) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let apiKey { headers[.authorization] = "Bearer \(apiKey)" }
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/machine/scope-attestation")) { request in
        request.body = .init(string: String(decoding: data, as: UTF8.self))
    }
    return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
}

private func tracePayload(_ extra: [String: Any]) -> [String: Any] {
    var metadata: [String: Any] = [
        "bundleId": "bundle-1", "bundleSha256": String(repeating: "a", count: 64), "bundleSizeBytes": 1234,
    ]
    metadata.merge(extra) { _, new in new }
    return ["scope": "daemon-trace-bundle:create", "metadata": metadata]
}

private func scopeClaims(_ token: String, secret: String = "daemon-scope-test-secret") -> [String: Any] {
    // Mirror the pinned worker's published payload.signature verification over
    // the encoded payload bytes; never accept an unsigned decoded JWT payload.
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts.contains(where: { $0.isEmpty || $0.contains("=") }) else { return [:] }
    func decode(_ value: Substring) -> Data? {
        var encoded = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        return Data(base64Encoded: encoded)
    }
    guard let signature = decode(parts[1]),
          HMAC<SHA256>.isValidAuthenticationCode(
              signature, authenticating: Data(parts[0].utf8), using: SymmetricKey(data: Data(secret.utf8))
          ),
          let data = decode(parts[0]),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let expires = object["exp"] as? Int, expires > Int(Date().timeIntervalSince1970)
    else { return [:] }
    return object
}

@Test func scopeAttestationSignsCapabilitiesForMachineAndComputerCredentials() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let capability = try await attest(client, fixture, ["scope": "feedback-report:create"], apiKey: fixture.apiKey)
            #expect(capability.status == .ok)
            #expect(capability.body["scope"] as? String == "feedback-report:create")
            #expect(capability.body["audience"] as? String == "feedback-worker")
            #expect(capability.body["resource"] as? String == "servers/\(fixture.serverId)/machines/\(fixture.machineId)/feedback-reports")
            let claims = scopeClaims(try #require(capability.body["attestation"] as? String))
            #expect(claims["sub"] as? String == "machine:\(fixture.machineId)")
            #expect(claims["actorType"] as? String == "machine")
            #expect(claims["machineId"] as? String == fixture.machineId)
            #expect(claims["serverId"] as? String == fixture.serverId)
            #expect(claims["serverSlug"] as? String == fixture.slug)
            #expect(claims["scope"] as? String == "feedback-report:create")
            #expect(claims["aud"] as? String == "feedback-worker")
            #expect(claims["jti"] != nil)
            #expect(claims["nonce"] != nil)
            #expect((claims["exp"] as? Int ?? 0) <= Int(Date().timeIntervalSince1970) + 120)

            let attachment = try await client.send(.post, headers: { var h = HTTPFields(); h[.authorization] = "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId))"; h[.contentType] = "application/json"; return h }(), to: URI(string: "/api/computer/attach")) { request in
                request.body = .init(string: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"adopted-computer\"}")
            }
            #expect(attachment.status == .created)
            let attached = (try? JSONSerialization.jsonObject(with: Data((attachment.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let computerKey = try #require(attached["apiKey"] as? String)
            let computerMachineId = try #require(attached["machineId"] as? String)
            let computerCapability = try await attest(client, fixture, tracePayload([:]), apiKey: computerKey)
            #expect(computerCapability.status == .ok)
            #expect(computerCapability.body["audience"] as? String == "trace-ingest-worker")
            #expect(computerCapability.body["resource"] as? String == "servers/\(fixture.serverId)/machines/\(computerMachineId)/trace-bundles")
            let computerClaims = scopeClaims(try #require(computerCapability.body["attestation"] as? String))
            #expect(computerClaims["sub"] as? String == "machine:\(computerMachineId)")
        }
    }
}

@Test func machineScopeAttestationHTTPMatchesNodeWorkerUTF8HMACAndClaims() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    let secret = "scope-test-only-é-🔐-independent-signing-key"
    fixture.accounts.setScopeAttestationSecretForTesting(secret)
    fixture.accounts.setDeploymentEnvironmentForTesting("staging")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let requestedAt = Int(Date().timeIntervalSince1970)
            let result = try await attest(client, fixture, tracePayload([
                "bundleId": "bundle-é-😀", "rawTranscriptExcerpt": "must-not-be-signed",
            ]), apiKey: fixture.apiKey)
            try #require(result.status == .ok)
            let token = try #require(result.body["attestation"] as? String)
            #expect(token.split(separator: ".", omittingEmptySubsequences: false).count == 2)
            #expect(!token.contains("="))
            #expect(token.utf8.count <= 16 * 1024)
            let claims = scopeClaims(token, secret: secret)
            try #require(!claims.isEmpty)
            #expect(Set(claims.keys) == Set([
                "v", "typ", "scope", "sub", "actorType", "machineId", "serverId", "serverSlug",
                "aud", "resource", "metadata", "nonce", "jti", "exp",
            ]))
            #expect(claims["v"] as? Int == 1)
            #expect(claims["typ"] as? String == "scope-attestation")
            #expect(claims["scope"] as? String == "daemon-trace-bundle:create")
            #expect(claims["sub"] as? String == "machine:\(fixture.machineId)")
            #expect(claims["actorType"] as? String == "machine")
            #expect(claims["machineId"] as? String == fixture.machineId)
            #expect(claims["serverId"] as? String == fixture.serverId)
            #expect(claims["serverSlug"] as? String == fixture.slug)
            #expect(claims["aud"] as? String == "trace-ingest-worker")
            #expect(claims["resource"] as? String == "servers/\(fixture.serverId)/machines/\(fixture.machineId)/trace-bundles")
            #expect(UUID(uuidString: claims["nonce"] as? String ?? "") != nil)
            #expect(UUID(uuidString: claims["jti"] as? String ?? "") != nil)
            let expires = try #require(claims["exp"] as? Int)
            #expect(expires >= requestedAt + 120)
            #expect(expires <= Int(Date().timeIntervalSince1970) + 120)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiresAt = try #require(result.body["expiresAt"] as? String)
            #expect(formatter.date(from: expiresAt) == Date(timeIntervalSince1970: TimeInterval(expires)))
            let metadata = try #require(claims["metadata"] as? [String: Any])
            let echoed = try #require(result.body["metadata"] as? [String: Any])
            #expect(NSDictionary(dictionary: metadata).isEqual(to: echoed))
            #expect(metadata["bundleId"] as? String == "bundle-é-😀")
            #expect(metadata["rawTranscriptExcerpt"] == nil)
            #expect(metadata["deploymentEnvironment"] as? String == "staging")
            #expect(scopeClaims(token, secret: "different-test-key").isEmpty)
            let parts = token.split(separator: ".").map(String.init)
            #expect(scopeClaims("\(parts[0])A.\(parts[1])", secret: secret).isEmpty)
            #expect(scopeClaims("e30.\(token)", secret: secret).isEmpty)
        }
    }
}

@Test func scopeAttestationRejectsAuthScopeAndDerivedFieldOverrides() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            #expect(try await attest(client, fixture, ["scope": "feedback-report:create"], apiKey: nil).status == .unauthorized)
            let unsupported = try await attest(client, fixture, ["scope": "admin-machine:delete"], apiKey: fixture.apiKey)
            #expect(unsupported.status == .badRequest)
            #expect(unsupported.body["error"] as? String == "Unsupported scope: admin-machine:delete")
            let audience = try await attest(client, fixture, ["scope": "feedback-report:create", "audience": "attacker-worker"], apiKey: fixture.apiKey)
            #expect(audience.status == .badRequest)
            #expect(audience.body["error"] as? String == "audience is derived from scope")
            let resource = try await attest(client, fixture, ["scope": "feedback-report:create", "resource": "attacker-prefix"], apiKey: fixture.apiKey)
            #expect(resource.status == .badRequest)
            #expect(resource.body["error"] as? String == "resource is derived from scope")
        }
    }
    fixture.accounts.setScopeAttestationSecretForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let unconfigured = try await attest(client, fixture, ["scope": "feedback-report:create"], apiKey: fixture.apiKey)
            #expect(unconfigured.status == .serviceUnavailable)
            #expect((unconfigured.body["error"] as? String)?.contains("not configured") == true)
        }
    }
}

@Test func traceBundleAttestationNormalizesMetadataAndDeploymentEnvironment() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    fixture.accounts.setDeploymentEnvironmentForTesting("staging")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let transcript: [String: Any] = [
                "feedbackReportTimeSource": "web_report_bundle",
                "feedbackTranscriptFirstEventAt": "2026-07-20T16:20:00.000Z",
                "feedbackTranscriptLastEventAt": "2026-07-20T16:39:38.024Z",
                "feedbackTranscriptTruncated": "true",
                "feedbackTranscriptTruncationDirection": "tail",
                "feedbackTranscriptWindowCoverage": "covered",
            ]
            var payload = tracePayload(transcript)
            var metadata = payload["metadata"] as? [String: Any] ?? [:]
            metadata["feedbackReportGeneratedAt"] = "2026-07-20T16:40:04.797Z"
            metadata["feedbackReportWindowStartAt"] = "2026-07-20T16:25:04.797Z"
            metadata["feedbackTranscriptWindowToleranceMs"] = 900_000
            metadata["rawTranscriptExcerpt"] = "must-not-pass-through"
            payload["metadata"] = metadata
            let response = try await attest(client, fixture, payload, apiKey: fixture.apiKey)
            #expect(response.status == .ok)
            #expect(response.body["scope"] as? String == "daemon-trace-bundle:create")
            #expect(response.body["audience"] as? String == "trace-ingest-worker")
            #expect(response.body["resource"] as? String == "servers/\(fixture.serverId)/machines/\(fixture.machineId)/trace-bundles")
            let signed = try #require(response.body["metadata"] as? [String: Any])
            #expect(signed["bundleId"] as? String == "bundle-1")
            #expect(signed["bundleSizeBytes"] as? Int == 1234)
            #expect(signed["maxBytes"] as? Int == 50 * 1024 * 1024)
            #expect(signed["bundleContentType"] as? String == "application/x-ndjson")
            #expect(signed["bundleContentEncoding"] as? String == "gzip")
            #expect(signed["deploymentEnvironment"] as? String == "staging")
            #expect(signed["feedbackTranscriptFirstEventAt"] as? String == "2026-07-20T16:20:00.000Z")
            #expect(signed["feedbackTranscriptWindowToleranceMs"] as? Int == 900_000)
            #expect(signed["rawTranscriptExcerpt"] == nil)
            #expect((signed["objectKey"] as? String)?.wholeMatch(of: /^trace-bundles\/[0-9a-f-]+\/[0-9a-f-]+\/.+\.jsonl\.gz$/) != nil)
            #expect(scopeClaims(try #require(response.body["attestation"] as? String))["metadata"] != nil)

            let dev = try await attest(client, fixture, tracePayload(["deploymentEnvironment": "dev"]), apiKey: fixture.apiKey)
            #expect(dev.status == .ok)
            #expect((dev.body["metadata"] as? [String: Any])?["deploymentEnvironment"] as? String == "dev")
            let unknown = try await attest(client, fixture, tracePayload(["deploymentEnvironment": "attacker-env"]), apiKey: fixture.apiKey)
            #expect(unknown.status == .badRequest)
            #expect(((unknown.body["error"] as? String) ?? "").contains("not in the allowed producer set"))
        }
    }
    fixture.accounts.setDeploymentEnvironmentForTesting("production")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let rejected = try await attest(client, fixture, tracePayload(["deploymentEnvironment": "dev"]), apiKey: fixture.apiKey)
            #expect(rejected.status == .badRequest)
            #expect(((rejected.body["error"] as? String) ?? "").contains("inconsistent with server deployment"))
            let fallback = try await attest(client, fixture, tracePayload([:]), apiKey: fixture.apiKey)
            #expect(fallback.status == .ok)
            #expect((fallback.body["metadata"] as? [String: Any])?["deploymentEnvironment"] as? String == "production")
        }
    }
}

@Test func traceTailCountersUUIDsAndOversizeStringsAreEnforced() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let tail = try await attest(client, fixture, tracePayload([
                "feedbackAttachmentKind": "machine_log_tail",
                "feedbackMachineLogTailLineCount": 120,
                "feedbackMachineLogTailSourceLineCount": 4000,
                "feedbackMachineLogTailLinesOutsideWindow": 3800,
                "feedbackMachineLogTailUndatedLines": 2,
                "feedbackMachineLogTailTruncated": "true",
                "feedbackMachineLogTailIncludesOtherAgents": "true",
            ]), apiKey: fixture.apiKey)
            #expect(tail.status == .ok)
            let tailMetadata = try #require(tail.body["metadata"] as? [String: Any])
            #expect(tailMetadata["feedbackMachineLogTailLinesOutsideWindow"] as? Int == 3800)
            #expect(tailMetadata["feedbackMachineLogTailUndatedLines"] as? Int == 2)
            #expect(tailMetadata["feedbackAttachmentKind"] as? String == "machine_log_tail")
            #expect(tailMetadata["feedbackMachineLogTailTruncated"] as? String == "true")

            let unknownKind = try await attest(client, fixture, tracePayload([
                "feedbackAttachmentKind": "shell_history",
                "feedbackMachineLogTailLineCount": -1,
                "feedbackMachineLogTailTruncated": "yes",
            ]), apiKey: fixture.apiKey)
            #expect(unknownKind.status == .ok)
            let unknownMetadata = try #require(unknownKind.body["metadata"] as? [String: Any])
            #expect(unknownMetadata["feedbackAttachmentKind"] == nil)
            #expect(unknownMetadata["feedbackMachineLogTailLineCount"] == nil)
            #expect(unknownMetadata["feedbackMachineLogTailTruncated"] == nil)

            let wrongKind = try await attest(client, fixture, tracePayload([
                "feedbackAttachmentKind": "session_transcript",
                "feedbackMachineLogTailLineCount": 5,
            ]), apiKey: fixture.apiKey)
            let wrongMetadata = try #require(wrongKind.body["metadata"] as? [String: Any])
            #expect(wrongMetadata["feedbackMachineLogTailLineCount"] == nil)

            for extra: [String: Any] in [["bundleContentType": String(repeating: "t", count: 129)], ["bundleContentEncoding": String(repeating: "g", count: 65)]] {
                #expect(try await attest(client, fixture, tracePayload(extra), apiKey: fixture.apiKey).status == .badRequest)
            }

            let reportId = UUID().uuidString.lowercased()
            let validIds = try await attest(client, fixture, tracePayload(["feedbackReportId": reportId, "agentId": reportId]), apiKey: fixture.apiKey)
            #expect(validIds.status == .ok)
            for bad in ["../x", "\(reportId)/../x", "..", "report-1", String(repeating: "r", count: 129), "\(reportId) ", 7] as [Any] {
                for field in ["feedbackReportId", "agentId"] {
                    #expect(try await attest(client, fixture, tracePayload([field: bad]), apiKey: fixture.apiKey).status == .badRequest)
                }
            }
        }
    }
}

@Test func machineEvidenceKindBindsAgentAndUsesItsOwnObjectPrefix() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let reportId = UUID().uuidString.lowercased()
            func evidence(_ extra: [String: Any]) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                var payload = tracePayload([
                    "feedbackAttachmentKind": "machine_evidence",
                    "feedbackReportId": reportId,
                    "agentId": fixture.agentId,
                ])
                var metadata = payload["metadata"] as? [String: Any] ?? [:]
                metadata.merge(extra) { _, new in new }
                payload["metadata"] = metadata
                return try await attest(client, fixture, payload, apiKey: fixture.apiKey)
            }
            let ok = try await evidence([:])
            #expect(ok.status == .ok)
            let signed = try #require(ok.body["metadata"] as? [String: Any])
            #expect(signed["feedbackAttachmentKind"] as? String == "machine_evidence")
            #expect(signed["agentId"] as? String == fixture.agentId)
            #expect(signed["feedbackReportId"] as? String == reportId)
            #expect(signed["bundleContentType"] as? String == "application/json")
            #expect(signed["bundleContentEncoding"] as? String == "gzip")
            #expect((signed["objectKey"] as? String)?.wholeMatch(of: /^feedback-machine-evidence\/[0-9a-f-]+\/[0-9a-f-]+\/[0-9a-f-]+\.json\.gz$/) != nil)
            #expect((signed["maxBytes"] as? Int ?? 999999) <= 256 * 1024 + 4096)
            #expect(signed["machineId"] == nil)
            #expect(signed["serverId"] == nil)
            #expect(try await evidence(["bundleSizeBytes": 50 * 1024 * 1024]).status == .badRequest)
            #expect(try await evidence(["agentId": fixture.otherAgentId]).status == .forbidden)
            #expect(try await evidence(["agentId": UUID().uuidString]).status == .forbidden)
        }
    }
}

@Test func traceBundleStripsUnsignedDiagnosticsAndStaysWithinBudget() async throws {
    var fixture = ScopeFixture()
    fixture.seed()
    fixture.accounts.setScopeAttestationSecretForTesting("daemon-scope-test-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            var hugeMetadata: [String: Any] = [
                "bundleId": "bundle-diag",
                "bundleSha256": String(repeating: "e", count: 64),
                "bundleSizeBytes": 50 * 1024 * 1024,
                "observedFailureSummary": ["failures": Array(repeating: ["span": "daemon.connection.error", "count": 1], count: 64)],
                "feedbackTraceTail": ["records": Array(repeating: ["span": "daemon.runtime.process.exit"], count: 500)],
                "feedbackMachineState": ["daemonVersion": "1.0.27"],
            ]
            hugeMetadata["feedbackReportId"] = UUID().uuidString.lowercased()
            hugeMetadata["agentId"] = UUID().uuidString.lowercased()
            let payload: [String: Any] = ["scope": "daemon-trace-bundle:create", "metadata": hugeMetadata]
            let signed = try await attest(client, fixture, payload, apiKey: fixture.apiKey)
            #expect(signed.status == .ok)
            let metadata = try #require(signed.body["metadata"] as? [String: Any])
            for key in ["observedFailureSummary", "feedbackTraceTail", "feedbackMachineState"] {
                #expect(metadata[key] == nil, Comment(rawValue: key))
            }
            #expect((try #require(signed.body["attestation"] as? String)).count <= 16 * 1024)

            var malformed = hugeMetadata
            malformed["observedFailureSummary"] = "not-an-object"
            malformed["feedbackTraceTail"] = ["records": "nope"]
            malformed["feedbackMachineState"] = 42
            let malformedSigned = try await attest(client, fixture, ["scope": "daemon-trace-bundle:create", "metadata": malformed], apiKey: fixture.apiKey)
            #expect(malformedSigned.status == .ok)
            let malformedMetadata = try #require(malformedSigned.body["metadata"] as? [String: Any])
            #expect(malformedMetadata["observedFailureSummary"] == nil)
        }
    }
}
