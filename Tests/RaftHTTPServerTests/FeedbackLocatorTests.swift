import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct FeedbackLocatorFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let agentId: String
    let apiKey: String
}

private func makeFeedbackLocatorFixture(suffix: String) throws -> FeedbackLocatorFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 400_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 950_000 + number)
    accounts.addAccount(id: ownerId, email: "feedback-locator-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "feedback-locator-\(suffix)", name: "Feedback Locator", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "FeedbackLocatorAgent-\(suffix)", runtime: "codex")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "proj-feedback", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "proj-feedback")
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "feedback-locator-\(suffix)")
    return FeedbackLocatorFixture(accounts: accounts, serverId: serverId, agentId: agent, apiKey: apiKey)
}

private func feedbackLocatorPayload(serverId: String, agentId: String, reportId: String) -> String {
    """
    {"schema_version":"raft.feedback.locator.v0","report_id":"\(reportId)","captured_at":"2026-08-09T02:30:00.000Z","producer":{"surface":"raft_cli","server_id":"\(serverId)","agent_id":"\(agentId)"},"capture_invocation":{"invocation_id":"\(UUID().uuidString.lowercased())","command_family":"feedback","arguments":[],"canonical_shape_sha256":"\(String(repeating: "a", count: 64))"},"locators":{"l0":{"runtime":"codex","identity":{"status":"unavailable","reason_code":"session_identity_unavailable"},"native":{"status":"not_attempted","reason_code":"session_identity_unavailable"},"handoff":{"status":"not_attempted","reason_code":"session_identity_unavailable"}},"l1":{"turn":{"status":"unsupported","reason_code":"runtime_turn_contract_unavailable"},"trace":{"status":"unsupported","reason_code":"runtime_trace_contract_unavailable"}},"l2":{"subject_call":{"status":"unavailable","reason_code":"subject_call_anchor_missing"}}},"exacts":[],"route":{"resolution":{"status":"resolved","target":{"kind":"public_channel","ref":"#proj-feedback"},"basis":"configured_project_channel"},"delivery":{"status":"dispatched_unconfirmed","reason_code":"fire_and_forget_no_receipt"}},"transport":{"artifact_kind":"raft-feedback-locator-v0","event_kind":"feedback-locator:created"}}
    """
}

private func feedbackLocatorObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func feedbackLocatorIngestReturnsOnlyTheTransactionBackedReceiptAndReplaysIt() async throws {
    let fixture = try makeFeedbackLocatorFixture(suffix: "721")
    let reportId = UUID().uuidString.lowercased()
    let payload = feedbackLocatorPayload(serverId: fixture.serverId, agentId: fixture.agentId, reportId: reportId)
    let body = "{\"artifact_kind\":\"raft-feedback-locator-v0\",\"event_kind\":\"feedback-locator:created\",\"payload\":\(payload)}"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.apiKey)"
            headers[.contentType] = "application/json"
            func ingest() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/internal/agent-api/feedback-locators") { request in
                    request.body = .init(string: body)
                }
            }

            let first = try await ingest()
            #expect(first.status == .ok)
            // The accepted body keeps the legacy key order through the route.
            #expect(first.body.string?.hasPrefix("{\"status\":\"accepted\",\"receipt_id\":\"") == true)
            let accepted = try feedbackLocatorObject(first)
            #expect(accepted["status"] as? String == "accepted")
            #expect(accepted["report_id"] as? String == reportId)
            #expect(accepted["duplicate"] as? Bool == false)
            let receiptId = accepted["receipt_id"] as? String ?? ""
            #expect(receiptId.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil)

            let retry = try await ingest()
            #expect(retry.status == .ok)
            let duplicate = try feedbackLocatorObject(retry)
            #expect(duplicate["status"] as? String == "accepted")
            #expect(duplicate["duplicate"] as? Bool == true)
            #expect(duplicate["receipt_id"] as? String == receiptId)
            #expect(duplicate["report_id"] as? String == reportId)

            let query = "?report_id=\(reportId)&runtime=codex&native_status=not_attempted&route_basis=configured_project_channel"
            let listed = try await client.get(URI(string: "/internal/agent-api/feedback-locators\(query)"), headers: headers)
            #expect(listed.status == .ok)
            let index = try feedbackLocatorObject(listed)
            let locators = index["locators"] as? [[String: Any]] ?? []
            #expect(locators.count == 1)
            let row = locators.first ?? [:]
            #expect(row["report_id"] as? String == reportId)
            #expect(row["receipt_id"] as? String == receiptId)
            #expect(row["captured_at"] as? String == "2026-08-09T02:30:00.000Z")
            #expect(row["runtime"] as? String == "codex")
            #expect(row["native_status"] as? String == "not_attempted")
            #expect(row["native_lookup_method"] as? String == "not_attempted")
            #expect(row["native_locator_kind"] as? String == "none")
            #expect(row["has_served_exact"] as? Bool == false)
            #expect(row["served_exact_sha256"] as? [String] == [])
            #expect(row["route_basis"] as? String == "configured_project_channel")
            #expect(row["route_target"] as? String == "#proj-feedback")
            #expect(row["payload"] == nil)
            #expect(row["session_id"] == nil)

            var missingScope = headers
            missingScope[.authorization] = "Bearer \(fixture.accounts.mintAgentCredential(agentId: fixture.agentId, scopes: ["read"], name: "no-send"))"
            let refused = try await client.send(.post, headers: missingScope, to: "/internal/agent-api/feedback-locators") { request in
                request.body = .init(string: body)
            }
            #expect(refused.status == .forbidden)
            #expect(try feedbackLocatorObject(refused)["code"] as? String == "capability_not_authorized")
            // The refusal keeps the legacy key order byte for byte through the
            // typed service and `respond`.
            #expect(refused.body.string == "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"send\"}")
        }
    }
}

@Test func feedbackLocatorIngestKeepsUnknownVersionsAndPrivateRoutesTyped() async throws {
    let fixture = try makeFeedbackLocatorFixture(suffix: "722")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.apiKey)"
            headers[.contentType] = "application/json"
            func ingest(_ payload: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/internal/agent-api/feedback-locators") { request in
                    request.body = .init(string: "{\"artifact_kind\":\"raft-feedback-locator-v0\",\"event_kind\":\"feedback-locator:created\",\"payload\":\(payload)}")
                }
            }
            func failure(_ response: ClientResponse) throws -> [String: Any] {
                try feedbackLocatorObject(response)
            }

            let unknown = feedbackLocatorPayload(
                serverId: fixture.serverId,
                agentId: fixture.agentId,
                reportId: UUID().uuidString.lowercased()
            ).replacingOccurrences(of: "raft.feedback.locator.v0", with: "raft.feedback.locator.v999")
            let unknownResponse = try await ingest(unknown)
            #expect(unknownResponse.status == .badRequest)
            #expect(try failure(unknownResponse) as NSDictionary == ["status": "failed", "reason_code": "unknown_schema_version"] as NSDictionary)

            let privateRoute = feedbackLocatorPayload(
                serverId: fixture.serverId,
                agentId: fixture.agentId,
                reportId: UUID().uuidString.lowercased()
            ).replacingOccurrences(
                of: "{\"kind\":\"public_channel\",\"ref\":\"#proj-feedback\"}",
                with: "{\"kind\":\"private_channel\",\"ref\":\"#secret\"}"
            )
            let privateResponse = try await ingest(privateRoute)
            #expect(privateResponse.status == .badRequest)
            #expect(try failure(privateResponse) as NSDictionary == ["status": "failed", "reason_code": "invalid_route_ref"] as NSDictionary)

            let foreignProducer = feedbackLocatorPayload(
                serverId: fixture.serverId,
                agentId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                reportId: UUID().uuidString.lowercased()
            )
            let foreignResponse = try await ingest(foreignProducer)
            #expect(foreignResponse.status == .badRequest)
            #expect(try failure(foreignResponse) as NSDictionary == ["status": "failed", "reason_code": "invalid_payload"] as NSDictionary)
        }
    }
}

@Test func feedbackLocatorIngestAcceptsAJSONBodyWithoutAContentType() async throws {
    let fixture = try makeFeedbackLocatorFixture(suffix: "723")
    let reportId = UUID().uuidString.lowercased()
    let payload = feedbackLocatorPayload(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: reportId
    )
    let body = "{\"artifact_kind\":\"raft-feedback-locator-v0\",\"event_kind\":\"feedback-locator:created\",\"payload\":\(payload)}"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            // The legacy route parsed the raw text, so a body sent without a
            // `Content-Type` header still reaches the locator service.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.apiKey)"
            let response = try await client.send(
                .post,
                headers: headers,
                to: "/internal/agent-api/feedback-locators"
            ) { request in
                request.body = .init(string: body)
            }
            #expect(response.status == .ok)
            #expect(try feedbackLocatorObject(response)["duplicate"] as? Bool == false)
            #expect(try feedbackLocatorObject(response)["report_id"] as? String == reportId)
        }
    }
}
