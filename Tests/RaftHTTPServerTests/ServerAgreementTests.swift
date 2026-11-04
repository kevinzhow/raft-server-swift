import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgreementFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001091001"
    let ownerId = "11111111-1111-4111-8111-000001091001"
    let adminId = "11111111-1111-4111-8111-000001091002"
    let memberId = "11111111-1111-4111-8111-000001091003"
    let joinerId = "11111111-1111-4111-8111-000001091004"

    init() {
        for (id, email, role) in [
            (ownerId, "owner", "owner"), (adminId, "admin", "admin"),
            (memberId, "member", "member"), (joinerId, "joiner", "member"),
        ] {
            accounts.addAccount(id: id, email: "agreement-\(email)@test.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "agreement-server", name: "Agreement Server", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    }

    func headers(_ userId: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

@Test func agreementConfigurationIsOwnerAdminOnlyAndVersioned() async throws {
    let fixture = AgreementFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            func put(_ userId: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                let response = try await client.send(.put, headers: fixture.headers(userId), to: URI(string: "/api/servers/\(fixture.serverId)/agreement")) { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let denied = try await put(fixture.memberId, "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\"Be kind.\"}")
            #expect(denied.0 == .forbidden)
            #expect(denied.1["error"] as? String == "Only server owners and admins can manage the pre-join agreement")

            let first = try await put(fixture.adminId, "{\"enabled\":true,\"title\":\"Rules v1\",\"bodyMarkdown\":\"Be kind.\"}")
            #expect(first.0 == .ok)
            let firstAgreement = try #require(first.1["agreement"] as? [String: Any])
            #expect(firstAgreement["version"] as? Int == 1)
            let second = try await put(fixture.ownerId, "{\"enabled\":true,\"title\":\"Rules v2\",\"bodyMarkdown\":\"Be kind.\\nNo spam.\"}")
            #expect(second.0 == .ok)
            let secondAgreement = try #require(second.1["agreement"] as? [String: Any])
            #expect(secondAgreement["version"] as? Int == 2)
            #expect((secondAgreement["id"] as? String) != (firstAgreement["id"] as? String))

            let read = try await client.get(URI(string: "/api/servers/\(fixture.serverId)/agreement"), headers: fixture.headers(fixture.adminId))
            let readBody = try JSONSerialization.jsonObject(with: Data((read.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((readBody["agreement"] as? [String: Any])?["id"] as? String == secondAgreement["id"] as? String)
        }
    }
}

@Test func agreementBodyLengthBoundaryEnforced() async throws {
    let fixture = AgreementFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let prefix = "# Community Rules\n\n"
            let longBody = prefix + String(repeating: "A", count: 5000 - prefix.count)
            let payload = "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\(String(decoding: try JSONSerialization.data(withJSONObject: [longBody]), as: UTF8.self).dropFirst().dropLast())}"
            let accepted = try await client.send(.put, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/agreement")) { request in
                request.body = .init(string: payload)
            }
            #expect(accepted.status == .ok)
            let tooLong = String(repeating: "A", count: 5001)
            let rejectedPayload = "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\(String(decoding: try JSONSerialization.data(withJSONObject: [tooLong]), as: UTF8.self).dropFirst().dropLast())}"
            let rejected = try await client.send(.put, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/agreement")) { request in
                request.body = .init(string: rejectedPayload)
            }
            #expect(rejected.status == .badRequest)
            let rejectedBody = try JSONSerialization.jsonObject(with: Data((rejected.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(rejectedBody["error"] as? String == "Agreement body must be 5000 characters or fewer")
        }
    }
}

@Test func inviteAcceptanceRequiresCurrentAgreementAndWritesAudit() async throws {
    let fixture = AgreementFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            func putAgreement(_ title: String) async throws -> [String: Any] {
                let response = try await client.send(.put, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/agreement")) { request in
                    request.body = .init(string: "{\"enabled\":true,\"title\":\"\(title)\",\"bodyMarkdown\":\"Read this first.\"}")
                }
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return try #require(body["agreement"] as? [String: Any])
            }
            let first = try await putAgreement("Join Rules")
            let link = try await client.send(.post, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/join-links")) { request in
                request.body = .init(string: "{}")
            }
            let linkBody = try JSONSerialization.jsonObject(with: Data((link.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let token = try #require(linkBody["token"] as? String)

            let preview = try await client.get(URI(string: "/api/auth/invite-info?token=\(token)"))
            let previewBody = try JSONSerialization.jsonObject(with: Data((preview.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((previewBody["agreement"] as? [String: Any])?["id"] as? String == first["id"] as? String)
            #expect(previewBody["insideCountsHidden"] as? Bool == false)

            var joinHeaders = HTTPFields()
            joinHeaders[.authorization] = "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: fixture.joinerId))"
            joinHeaders[.contentType] = "application/json"
            let missing = try await client.send(.post, headers: joinHeaders, to: URI(string: "/api/auth/accept-invite")) { request in
                request.body = .init(string: "{\"token\":\"\(token)\"}")
            }
            #expect(missing.status == .conflict)
            let missingBody = try JSONSerialization.jsonObject(with: Data((missing.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(missingBody["error"] as? String == "agreement_required")
            #expect((missingBody["agreement"] as? [String: Any])?["id"] as? String == first["id"] as? String)

            let acceptHeaders = joinHeaders
            let accepted = try await client.send(.post, headers: acceptHeaders, to: URI(string: "/api/auth/accept-invite")) { request in
                request.body = .init(string: "{\"token\":\"\(token)\",\"agreementId\":\"\(first["id"] as? String ?? "")\"}")
            }
            #expect(accepted.status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.joinerId) == "member")
            let audits = fixture.accounts.membershipAgreementAuditsForTesting(serverId: fixture.serverId, subjectId: fixture.joinerId)
            #expect(audits.count == 1)
            #expect(audits[0].source == "invite")
            #expect(audits[0].actorUserId == fixture.joinerId)
            #expect(audits[0].agreementId == first["id"] as? String)
            #expect(audits[0].agreementVersion == 1)
            #expect(fixture.accounts.joinLinkUseCountForTesting(token: token) == 1)
        }
    }
}

@Test func invitePreviewHidesCountsWhenHumansAreHidden() async throws {
    let fixture = AgreementFixture()
    fixture.accounts.setServerHideHumansForTesting(serverId: fixture.serverId, hidden: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let link = try await client.send(.post, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/join-links")) { request in
                request.body = .init(string: "{}")
            }
            let linkBody = try JSONSerialization.jsonObject(with: Data((link.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let token = try #require(linkBody["token"] as? String)
            let preview = try await client.get(URI(string: "/api/auth/invite-info?token=\(token)"))
            let body = try JSONSerialization.jsonObject(with: Data((preview.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body["memberCount"] as? Int == 0)
            #expect(body["agentCount"] as? Int == 0)
            #expect(body["insideCountsHidden"] as? Bool == true)
        }
    }
}

@Test func staleAgreementIdIsRejectedBeforeMembershipCreation() async throws {
    let fixture = AgreementFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            func putAgreement(_ title: String) async throws -> [String: Any] {
                let response = try await client.send(.put, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/agreement")) { request in
                    request.body = .init(string: "{\"enabled\":true,\"title\":\"\(title)\",\"bodyMarkdown\":\"\(title).\"}")
                }
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return try #require(body["agreement"] as? [String: Any])
            }
            let first = try await putAgreement("Rules v1")
            let link = try await client.send(.post, headers: fixture.headers(fixture.ownerId), to: URI(string: "/api/servers/\(fixture.serverId)/join-links")) { request in
                request.body = .init(string: "{}")
            }
            let linkBody = try JSONSerialization.jsonObject(with: Data((link.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let token = try #require(linkBody["token"] as? String)
            _ = try await putAgreement("Rules v2")

            var joinHeaders = HTTPFields()
            joinHeaders[.authorization] = "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: fixture.joinerId))"
            joinHeaders[.contentType] = "application/json"
            let stale = try await client.send(.post, headers: joinHeaders, to: URI(string: "/api/auth/accept-invite")) { request in
                request.body = .init(string: "{\"token\":\"\(token)\",\"agreementId\":\"\(first["id"] as? String ?? "")\"}")
            }
            #expect(stale.status == .conflict)
            let staleBody = try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(staleBody["error"] as? String == "agreement_changed")
            #expect((staleBody["agreement"] as? [String: Any])?["title"] as? String == "Rules v2")
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.joinerId) == nil)
        }
    }
}
