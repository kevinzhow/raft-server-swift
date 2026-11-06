import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The locator service owns the two published operations. The HTTP route tests
/// lock status, parsed JSON and the auth refusals; these tests lock the exact
/// published bytes and the one store critical section the insert depends on.

private struct LocatorFixture {
    let directory: EmailLoginDirectory
    let serverId: String
    let agentId: String
    let apiKey: String
}

private func makeLocatorFixture(suffix: Int) -> LocatorFixture {
    let directory = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 500_000 + suffix)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 960_000 + suffix)
    directory.addAccount(
        id: ownerId,
        email: "locator-service-\(suffix)@slock.test",
        password: "password123"
    )
    directory.oauth.addOwnedServer(
        id: serverId,
        slug: "locator-service-\(suffix)",
        name: "Locator Service",
        ownerId: ownerId
    )
    let agentId = directory.oauth.createAgent(
        serverId: serverId,
        name: "LocatorAgent-\(suffix)",
        runtime: "codex"
    )
    let channelId = directory.oauth.createChannel(
        serverId: serverId,
        name: "proj-feedback",
        creatorUserId: ownerId
    )
    directory.addPostableChannel(
        serverId: serverId,
        channelId: channelId,
        memberId: ownerId,
        name: "proj-feedback"
    )
    let apiKey = directory.mintAgentCredential(
        agentId: agentId,
        scopes: ["send", "read"],
        name: "locator-service-\(suffix)"
    )
    return LocatorFixture(
        directory: directory,
        serverId: serverId,
        agentId: agentId,
        apiKey: apiKey
    )
}

private func locatorPayload(serverId: String, agentId: String, reportId: String) -> String {
    """
    {"schema_version":"raft.feedback.locator.v0","report_id":"\(reportId)","captured_at":"2026-08-09T02:30:00.000Z","producer":{"surface":"raft_cli","server_id":"\(serverId)","agent_id":"\(agentId)"},"capture_invocation":{"invocation_id":"\(UUID().uuidString.lowercased())","command_family":"feedback","arguments":[],"canonical_shape_sha256":"\(String(repeating: "a", count: 64))"},"locators":{"l0":{"runtime":"codex","identity":{"status":"unavailable","reason_code":"session_identity_unavailable"},"native":{"status":"not_attempted","reason_code":"session_identity_unavailable"},"handoff":{"status":"not_attempted","reason_code":"session_identity_unavailable"}},"l1":{"turn":{"status":"unsupported","reason_code":"runtime_turn_contract_unavailable"},"trace":{"status":"unsupported","reason_code":"runtime_trace_contract_unavailable"}},"l2":{"subject_call":{"status":"unavailable","reason_code":"subject_call_anchor_missing"}}},"exacts":[],"route":{"resolution":{"status":"resolved","target":{"kind":"public_channel","ref":"#proj-feedback"},"basis":"configured_project_channel"},"delivery":{"status":"dispatched_unconfirmed","reason_code":"fire_and_forget_no_receipt"}},"transport":{"artifact_kind":"raft-feedback-locator-v0","event_kind":"feedback-locator:created"}}
    """
}

private func locatorEnvelope(
    serverId: String,
    agentId: String,
    reportId: String
) -> FeedbackLocatorIngestRequest {
    let payload = locatorPayload(serverId: serverId, agentId: agentId, reportId: reportId)
    let body = "{\"artifact_kind\":\"raft-feedback-locator-v0\",\"event_kind\":\"feedback-locator:created\",\"payload\":\(payload)}"
    do {
        return try JSONDecoder().decode(
            FeedbackLocatorIngestRequest.self,
            from: Data(body.utf8)
        )
    } catch {
        Issue.record("fixture envelope must decode: \(error)")
        return FeedbackLocatorIngestRequest()
    }
}

private func locatorService(
    _ fixture: LocatorFixture,
    receiptId: String = "00000000-0000-4000-8000-000000000001"
) -> FeedbackLocatorService {
    FeedbackLocatorService(
        feedback: fixture.directory.feedbackStore,
        agents: fixture.directory.agentsRuntimeStore,
        channels: fixture.directory.serversAndChannelsStore,
        cards: fixture.directory.managedMCPAndCardsStore,
        oauth: fixture.directory.oauth,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        makeReceiptId: { receiptId }
    )
}

@Test func feedbackLocatorIngestPublishesTheLegacyAcceptedAndConflictBodies() throws {
    let fixture = makeLocatorFixture(suffix: 861)
    let reportId = "7a1cb0f2-75b4-4c4e-9c6f-3f7a5d2e9b10"
    let service = locatorService(fixture)
    let request = locatorEnvelope(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: reportId
    )

    let accepted = try service.ingest(
        authorization: "Bearer \(fixture.apiKey)",
        body: request
    )
    #expect(accepted.orderedJSONString() == """
    {"status":"accepted","receipt_id":"00000000-0000-4000-8000-000000000001","report_id":"7a1cb0f2-75b4-4c4e-9c6f-3f7a5d2e9b10","duplicate":false}
    """)

    // A replay answers the stored receipt and never grows a second row.
    let replay = try service.ingest(
        authorization: "Bearer \(fixture.apiKey)",
        body: request
    )
    #expect(replay.orderedJSONString() == """
    {"status":"accepted","receipt_id":"00000000-0000-4000-8000-000000000001","report_id":"7a1cb0f2-75b4-4c4e-9c6f-3f7a5d2e9b10","duplicate":true}
    """)
    #expect(fixture.directory.feedbackStore.feedbackLocatorRecords.count == 1)

    // A different payload under the same identity is the published 409. The
    // second envelope is structurally valid and differs only in the random
    // capture invocation id the digest covers.
    let changed = locatorEnvelope(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: reportId
    )
    #expect(throws: FeedbackLocatorError.reportIdentityConflict) {
        try service.ingest(authorization: "Bearer \(fixture.apiKey)", body: changed)
    }
    do {
        _ = try service.ingest(authorization: "Bearer \(fixture.apiKey)", body: changed)
    } catch let error as FeedbackLocatorError {
        #expect(error.orderedJSONString() == """
        {"status":"failed","reason_code":"report_identity_conflict"}
        """)
    }
}

@Test func feedbackLocatorListPublishesTheLegacyRowKeyOrder() throws {
    let fixture = makeLocatorFixture(suffix: 862)
    let reportId = "18f60b1d-9a4c-4b8a-a8de-2c1e6f4b7d55"
    let service = locatorService(fixture)
    let request = locatorEnvelope(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: reportId
    )
    _ = try service.ingest(authorization: "Bearer \(fixture.apiKey)", body: request)

    let listed = try service.list(
        authorization: "Bearer \(fixture.apiKey)",
        reportId: nil,
        runtime: nil,
        nativeStatus: nil,
        nativeLookupMethod: nil,
        servedExactSha256: nil,
        routeBasis: nil,
        limit: nil
    )
    #expect(listed.orderedJSONString() == """
    {"locators":[{"report_id":"18f60b1d-9a4c-4b8a-a8de-2c1e6f4b7d55","receipt_id":"00000000-0000-4000-8000-000000000001","captured_at":"2026-08-09T02:30:00.000Z","runtime":"codex","native_status":"not_attempted","native_lookup_method":"not_attempted","native_locator_kind":"none","has_served_exact":false,"served_exact_sha256":[],"route_basis":"configured_project_channel","route_target":"#proj-feedback"}]}
    """)
}

@Test func feedbackLocatorThrowsThePublishedCredentialBodies() throws {
    let fixture = makeLocatorFixture(suffix: 863)
    let request = locatorEnvelope(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: "2b6f6d38-9c2e-4a3c-9b7c-8c1f0e5a4d21"
    )
    let service = locatorService(fixture)

    #expect(throws: FeedbackLocatorError.missingAuthorization) {
        try service.ingest(authorization: nil, body: request)
    }
    do {
        _ = try service.ingest(authorization: nil, body: request)
    } catch let error as FeedbackLocatorError {
        #expect(error.status == 401)
        #expect(error.orderedJSONString() == """
        {"error":"Missing or invalid Authorization header","code":"auth_required"}
        """)
    }

    let readOnly = fixture.directory.mintAgentCredential(
        agentId: fixture.agentId,
        scopes: ["read"],
        name: "locator-read-only-863"
    )
    do {
        _ = try service.ingest(authorization: "Bearer \(readOnly)", body: request)
        Issue.record("a credential without send must be refused")
    } catch let error as FeedbackLocatorError {
        #expect(error.status == 403)
        #expect(error.orderedJSONString() == """
        {"error":"Agent credential is not authorized for this capability","code":"capability_not_authorized","requiredCapability":"send"}
        """)
    }
}

@Test func feedbackLocatorIngestIsOneStoreCriticalSection() async throws {
    let fixture = makeLocatorFixture(suffix: 864)
    let reportId = "5d3a1f7e-2c8b-4e6a-8f9d-0b4c7a1e3d62"
    let request = locatorEnvelope(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        reportId: reportId
    )
    let service = FeedbackLocatorService(directory: fixture.directory)
    let authorization = "Bearer \(fixture.apiKey)"

    // Every concurrent first report for the same identity must land as one
    // insert and the rest as duplicates; the store decides both under one lock.
    let duplicates = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                try service.ingest(authorization: authorization, body: request).duplicate
            }
        }
        var results: [Bool] = []
        for try await duplicate in group { results.append(duplicate) }
        return results
    }

    #expect(duplicates.filter { $0 == false }.count == 1)
    #expect(duplicates.filter { $0 == true }.count == 23)
    #expect(fixture.directory.feedbackStore.feedbackLocatorRecords.count == 1)
}
