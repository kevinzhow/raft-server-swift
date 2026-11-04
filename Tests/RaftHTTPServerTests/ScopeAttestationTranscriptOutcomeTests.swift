import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct OutcomeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001095001"
    let ownerId = "11111111-1111-4111-8111-000001095001"
    var machineId = ""
    var otherMachineId = ""
    var apiKey = ""
    var agentId = ""
    var otherAgentId = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "transcript-outcome-owner@outcome.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "transcript-outcome", name: "Transcript Outcome", ownerId: ownerId)
        machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "outcome-machine")
        otherMachineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "outcome-machine-2")
        apiKey = accounts.machineAPIKey(machineId: machineId) ?? ""
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "outcome-agent", creatorUserId: ownerId, runtime: "claude")
        otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "outcome-agent-2", creatorUserId: ownerId, runtime: "claude")
        accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
        accounts.assignAgentMachineForTesting(agentId: otherAgentId, machineId: otherMachineId)
    }
}

private func sign(_ client: any Client, _ fixture: OutcomeFixture, _ metadata: [String: Any]) async throws -> (status: HTTPResponse.Status, metadata: [String: Any], attestation: String) {
    let payload: [String: Any] = ["scope": "daemon-trace-bundle:create", "metadata": metadata]
    let data = try JSONSerialization.data(withJSONObject: payload)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.apiKey)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/machine/scope-attestation")) { request in
        request.body = .init(string: String(decoding: data, as: UTF8.self))
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body["metadata"] as? [String: Any] ?? [:], body["attestation"] as? String ?? "")
}

@Test func transcriptContentAndCountsAreSignedOrDroppedNeverCoerced() async throws {
    var fixture = OutcomeFixture()
    fixture.seed()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let ok = try await sign(client, fixture, [
                "bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512,
                "feedbackReportId": "6f1c2a52-0d4e-4c8b-9a51-3e2f7b9d1c40",
                "agentId": "0b7e4f9a-5c21-4d36-8e1f-a2c94d7b6e15",
                "feedbackTranscriptContent": "native_session_file",
                "feedbackTranscriptSourceBytes": 4096,
                "feedbackTranscriptBytes": 1024,
                "feedbackTranscriptRequestId": "req-1",
            ])
            #expect(ok.status == .ok)
            #expect(ok.metadata["feedbackTranscriptContent"] as? String == "native_session_file")
            #expect(ok.metadata["feedbackTranscriptSourceBytes"] as? Int == 4096)
            #expect(ok.metadata["feedbackTranscriptBytes"] as? Int == 1024)
            #expect(ok.metadata["feedbackTranscriptRequestId"] as? String == "req-1")

            let state = try await sign(client, fixture, ["bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512, "feedbackTranscriptContent": "native_state_file"])
            #expect(state.metadata["feedbackTranscriptContent"] as? String == "native_state_file")

            for bad: Any in ["placeholder", "absent", "x", 1, NSNull()] {
                let response = try await sign(client, fixture, ["bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512, "feedbackTranscriptContent": bad])
                #expect(response.status == .ok)
                #expect(response.metadata["feedbackTranscriptContent"] == nil)
            }
            for bad in [-1, 1.5, "12"] {
                let response = try await sign(client, fixture, ["bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512, "feedbackTranscriptSourceBytes": bad, "feedbackTranscriptBytes": bad])
                #expect(response.metadata["feedbackTranscriptSourceBytes"] == nil)
                #expect(response.metadata["feedbackTranscriptBytes"] == nil)
            }
            for bad in ["", String(repeating: "r", count: 129), "has space", 7] {
                let response = try await sign(client, fixture, ["bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512, "feedbackTranscriptRequestId": bad])
                #expect(response.metadata["feedbackTranscriptRequestId"] == nil)
            }
        }
    }
}

@Test func transcriptOutcomeRequiresReportAgentRequestIdAndMachineOwnership() async throws {
    var fixture = OutcomeFixture()
    fixture.seed()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            func outcome(_ extra: [String: Any]) async throws -> (status: HTTPResponse.Status, metadata: [String: Any], attestation: String) {
                try await sign(client, fixture, [
                    "bundleId": "bundle-1", "bundleSha256": String(repeating: "b", count: 64), "bundleSizeBytes": 512,
                    "feedbackAttachmentKind": "transcript_outcome",
                    "feedbackReportId": "6f1c2a52-0d4e-4c8b-9a51-3e2f7b9d1c40",
                    "agentId": fixture.agentId,
                    "feedbackTranscriptRequestId": "req-1",
                    "bundleContentType": "text/html",
                    "bundleContentEncoding": "br",
                    "feedbackTranscriptContent": "native_session_file",
                ].merging(extra) { _, new in new })
            }
            let ok = try await outcome([:])
            #expect(ok.status == .ok)
            #expect(ok.metadata["feedbackAttachmentKind"] as? String == "transcript_outcome")
            let objectKey = try #require(ok.metadata["objectKey"] as? String)
            #expect(objectKey.wholeMatch(of: /^feedback-transcript-outcomes\/[0-9a-f-]+\/[0-9a-f-]+\/[0-9a-f-]+\.json\.gz$/) != nil)
            #expect(ok.metadata["bundleContentType"] as? String == "application/json")
            #expect(ok.metadata["bundleContentEncoding"] as? String == "gzip")
            #expect((ok.metadata["maxBytes"] as? Int ?? 9999) <= 3072)
            #expect(ok.metadata["feedbackTranscriptRequestId"] as? String == "req-1")
            #expect(ok.metadata["feedbackTranscriptContent"] == nil)

            let oversized = try await outcome(["bundleSizeBytes": 64 * 1024])
            #expect(oversized.status == .badRequest)
            #expect(try await outcome(["feedbackTranscriptRequestId": NSNull()]).status == .badRequest)
            #expect(try await outcome(["feedbackReportId": NSNull()]).status == .badRequest)
            #expect(try await outcome(["agentId": NSNull()]).status == .badRequest)
            #expect(try await outcome(["agentId": fixture.otherAgentId]).status == .forbidden)
            #expect(try await outcome(["agentId": UUID().uuidString]).status == .forbidden)
        }
    }
}

@Test func transcriptOptionalKeysAtMaximumStayWithinAttestationBudget() async throws {
    var fixture = OutcomeFixture()
    fixture.seed()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let response = try await sign(client, fixture, [
                "bundleId": String(repeating: "b", count: 128),
                "bundleSha256": String(repeating: "b", count: 64),
                "bundleSizeBytes": 50 * 1024 * 1024,
                "bundleContentType": String(repeating: "t", count: 128),
                "bundleContentEncoding": String(repeating: "g", count: 64),
                "feedbackReportId": "ffffffff-ffff-4fff-bfff-ffffffffffff",
                "agentId": "ffffffff-ffff-4fff-bfff-fffffffffffe",
                "feedbackAttachmentKind": "session_transcript",
                "feedbackReportGeneratedAt": "2026-09-15T12:00:00.000Z",
                "feedbackReportTimeSource": "web_report_bundle",
                "feedbackReportWindowStartAt": "2026-09-15T11:45:00.000Z",
                "feedbackTranscriptWindowToleranceMs": 3_600_000,
                "feedbackTranscriptWindowCoverage": "timestamps_unavailable",
                "feedbackTranscriptTruncated": "true",
                "feedbackTranscriptTruncationDirection": "window",
                "feedbackTranscriptFirstEventAt": "2026-09-15T11:45:00.000Z",
                "feedbackTranscriptLastEventAt": "2026-09-15T12:00:00.000Z",
                "feedbackTranscriptContent": "native_session_file",
                "feedbackTranscriptSourceBytes": 9_007_199_254_740_991,
                "feedbackTranscriptBytes": 9_007_199_254_740_991,
                "feedbackTranscriptRequestId": String(repeating: "q", count: 128),
            ])
            #expect(response.status == .ok)
            #expect(response.metadata["feedbackTranscriptRequestId"] as? String == String(repeating: "q", count: 128))
            #expect(response.attestation.count <= 16 * 1024)
        }
    }
}
