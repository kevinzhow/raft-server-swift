import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte- and header-exact locks for the migrated product-feedback submission
/// surface.
///
/// The legacy handlers built their bodies and header sets by hand; these tests
/// pin the exact bytes and the exact header presence/absence the migration must
/// keep (`X-Robots-Tag` is present on the error envelopes and the onboarding
/// ack, and deliberately absent from the `201` receipt, which publishes
/// `Cache-Control` and `Server-Timing` instead).

private struct ContractFixture {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107001"
    let token: String

    init(verified: Bool = true) {
        accounts.addAccount(id: userId, email: "feedback-contract@hands.test", password: "password123")
        if verified { accounts.markEmailVerified(userId: userId) }
        token = accounts.mintAccessTokenForTesting(userId: userId)
    }
}

private func multipart(_ fields: [String: String]) -> (body: String, contentType: String) {
    let boundary = "raft-contract-boundary"
    var body = ""
    for (name, value) in fields {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body += "--\(boundary)--\r\n"
    return (body, "multipart/form-data; boundary=\(boundary)")
}

private func submit(
    _ client: any Client,
    _ fixture: ContractFixture,
    _ fields: [String: String],
    clientKind: String? = nil
) async throws -> ClientResponse {
    let payload = multipart(fields)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.token)"
    headers[.contentType] = payload.contentType
    if let clientKind { headers[HTTPField.Name("X-Raft-Client-Kind")!] = clientKind }
    return try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
        request.body = .init(string: payload.body)
    }
}

@Test func unverifiedSubmissionAnswersTheLegacyByteExactEnvelope() async throws {
    let fixture = ContractFixture(verified: false)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let response = try await submit(client, fixture, [
                "type": "idea",
                "message": "Byte-exact contract.",
                "submission_id": "55555555-5555-4555-8555-555555555555",
            ])
            #expect(response.status == .forbidden)
            #expect(
                response.body.string
                    == #"{"error":"Email verification required"}"#
            )
            #expect(response.headers[.cacheControl] == "private, no-store")
            #expect(response.headers[.contentLength] == "39")
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(
                response.headers[.contentLength]
                    == String((response.body.string ?? "").utf8.count)
            )
        }
    }
}

@Test func invalidSubmissionAnswersTheLegacyByteExactEnvelope() async throws {
    let fixture = ContractFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let response = try await submit(client, fixture, [
                "type": "idea",
                "message": "Byte-exact contract.",
                "submission_id": "not-a-uuid",
            ])
            #expect(response.status == .badRequest)
            #expect(
                response.body.string
                    == #"{"error":"Invalid feedback submission","code":"feedback_invalid"}"#
            )
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
        }
    }
}

@Test func acceptedSubmissionKeepsTheReceiptBytesAndPrivateHeaderSet() async throws {
    let fixture = ContractFixture()
    fixture.accounts.setHandsFeedbackForTesting(
        baseURL: "https://hands.test",
        appId: "raft-web",
        appToken: "t",
        appSlug: "raft-web"
    )
    fixture.accounts.setHandsFeedbackUpstreamForTesting { _ in
        (201, ["Server-Timing": "hands_commit;dur=30.0, ticket_id;dur=1"], Data("{\"id\":\"ticket-contract\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let response = try await submit(client, fixture, [
                "type": "problem",
                "message": "Receipt bytes.",
                "submission_id": "66666666-6666-4666-8666-666666666666",
            ])
            #expect(response.status == .created)
            #expect(response.body.string == #"{"id":"ticket-contract","status":"open"}"#)
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            // The legacy 201 never published the robots tag; adding it would
            // change the header set a client observes.
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == nil)
            let timing = try #require(response.headers[HTTPField.Name("Server-Timing")!])
            #expect(timing.hasPrefix("raft_feedback_hands;dur="))
            #expect(timing.contains("hands_commit;dur=30.0"))
            #expect(!timing.contains("ticket_id"))
        }
    }
}

@Test func onboardingWizardAckKeepsTheLegacyJsonHeaderSet() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107002"
    let serverId = "33333333-3333-4333-8333-000001107002"
    accounts.addAccount(id: userId, email: "onboarding-contract@hands.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "onboarding-contract", name: "Onboarding", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(
                .post,
                headers: headers,
                to: URI(string: "/api/product-events/onboarding-wizard")
            ) { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.dismissed\",\"metadata\":{\"step_id\":\"create-agent\",\"latency_ms\":12.9}}")
            }
            #expect(response.status == .noContent)
            #expect((response.body.string ?? "").isEmpty)
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentLength] == "0")
            let rows = accounts.recordedProductEvents(subjectId: serverId)
            #expect(rows.count == 1)
            #expect(rows.first?.metadataJSON == #"{"latency_ms":12,"step_id":"create-agent"}"#)
        }
    }
}

@Test func onboardingWizardStillAcceptsABodyWithoutAContentType() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107003"
    let serverId = "33333333-3333-4333-8333-000001107003"
    accounts.addAccount(id: userId, email: "onboarding-noct@hands.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "onboarding-noct", name: "Onboarding", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(
                .post,
                headers: headers,
                to: URI(string: "/api/product-events/onboarding-wizard")
            ) { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.dismissed\",\"metadata\":{\"step_id\":\"create-agent\"}}")
            }
            #expect(response.status == .noContent)
            #expect(accounts.recordedProductEvents(subjectId: serverId).count == 1)
        }
    }
}
