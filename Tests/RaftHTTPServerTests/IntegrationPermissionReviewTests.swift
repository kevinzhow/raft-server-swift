import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct PermissionReviewFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let clientId: String
    let clientRecordId: String
}

private func makePermissionReviewFixture(suffix: String) throws -> PermissionReviewFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 180_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 210_000 + number)
    let ownerEmail = "review-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "review-\(suffix)", name: "review", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Review fixture",
        clientId: "review-\(suffix)",
        appType: "third_party_global"
    )
    accounts.oauth.publishClient(clientRecordId: created.id)
    accounts.setMarketplaceReviewerIdsForTesting([ownerId])
    return PermissionReviewFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        clientId: created.clientId,
        clientRecordId: created.id
    )
}

private func reviewLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func reviewHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func reviewListing(_ client: any Client, headers: HTTPFields) async throws -> [[String: Any]] {
    let response = try await client.get("/api/integrations/marketplace", headers: headers)
    #expect(response.status == .ok)
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
}

@Test func permissionReviewApprovalBindsTheDisplayedRevision() async throws {
    let fixture = try makePermissionReviewFixture(suffix: "841")
    let firstRevision = try #require(
        fixture.accounts.oauth.createAppOutboundPermissionRevision(clientRecordId: fixture.clientRecordId, groups: ["agent"])
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reviewLogin(client, email: fixture.ownerEmail)
            let headers = reviewHeaders(token, fixture.serverId)

            let listing = try await reviewListing(client, headers: headers)
            let row = try #require(listing.first { $0["id"] as? String == fixture.clientRecordId })
            #expect(row["appNotificationPendingGroups"] as? [String] == ["agent"])
            #expect(row["appNotificationPendingRevisionId"] as? String == firstRevision)
            #expect(row["canReviewAppNotifications"] as? Bool == true)

            func review(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/integrations/clients/\(fixture.clientRecordId)/app-notifications/permissions/review") { request in
                    request.body = .init(string: body)
                }
            }
            for invalid in ["null", "123", "\"not-a-uuid\"", "\"\""] {
                let response = try await review("{\"expected_revision_id\":\(invalid)}")
                #expect(response.status == .badRequest)
            }
            let stillPending = try await reviewListing(client, headers: headers)
            #expect(stillPending.first { $0["id"] as? String == fixture.clientRecordId }?["appNotificationPendingRevisionId"] as? String == firstRevision)

            let replacementRevision = try #require(
                fixture.accounts.oauth.createAppOutboundPermissionRevision(clientRecordId: fixture.clientRecordId, groups: ["agent", "server"])
            )
            let stale = try await review("{\"expected_revision_id\":\"\(firstRevision)\"}")
            #expect(stale.status == .conflict)
            #expect((try? JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "permission_revision_stale")

            let pendingAfterStale = try await reviewListing(client, headers: headers)
            #expect(pendingAfterStale.first { $0["id"] as? String == fixture.clientRecordId }?["appNotificationPendingRevisionId"] as? String == replacementRevision)

            let approved = try await review("{\"expected_revision_id\":\"\(replacementRevision)\"}")
            #expect(approved.status == .ok)
            let approvedBody = (try? JSONSerialization.jsonObject(with: Data((approved.body.string ?? "").utf8))) as? [String: Any]
            #expect((approvedBody?["groups"] as? [String])?.sorted() == ["agent", "server"])

            let approvedListing = try await reviewListing(client, headers: headers)
            let approvedRow = try #require(approvedListing.first { $0["id"] as? String == fixture.clientRecordId })
            #expect(approvedRow["appNotificationPendingRevisionId"] is NSNull)
            #expect(approvedRow["appNotificationPendingGroups"] as? [String] == [])
        }
    }
}
