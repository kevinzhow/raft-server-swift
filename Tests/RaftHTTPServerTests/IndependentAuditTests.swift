import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func auditPost(_ client: any Client, _ path: String, _ body: [String: Any], _ authorization: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization { headers[.authorization] = authorization }
    let data = try JSONSerialization.data(withJSONObject: body)
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(data: data)
    }
}

private func auditJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func loggedOutDeviceIssuedTokenCannotCreateAFreshSession() async throws {
    let accounts = EmailLoginDirectory()
    accounts.appURL = "http://127.0.0.1:4173"
    let ownerId = "11111111-1111-4111-8111-111111111656"
    accounts.addAccount(id: ownerId, email: "audit-device@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let login = try await auditPost(client, "/api/auth/login", ["email": "audit-device@slock.test", "password": "password123"])
            let ownerBearer = "Bearer \(auditJSON(login)["accessToken"] as? String ?? "")"
            func authorize() async throws -> (userCode: String, deviceCode: String) {
                let response = try await auditPost(client, "/api/auth/device/authorize", ["clientName": "audit-device"])
                #expect(response.status == .created)
                let body = auditJSON(response)
                return (body["userCode"] as? String ?? "", body["deviceCode"] as? String ?? "")
            }
            let grant = try await authorize()
            let approved = try await auditPost(client, "/api/auth/device/approve", ["userCode": grant.userCode], ownerBearer)
            #expect(approved.status == .ok)
            let issued = try await auditPost(client, "/api/auth/device/token", ["deviceCode": grant.deviceCode])
            #expect(issued.status == .ok)
            let session = auditJSON(issued)
            let originalAccess = session["accessToken"] as? String ?? ""
            let originalRefresh = session["refreshToken"] as? String ?? ""
            #expect(!originalAccess.isEmpty)
            #expect(!originalRefresh.isEmpty)

            let loggedOut = try await auditPost(client, "/api/auth/logout", ["refreshToken": originalRefresh])
            #expect(loggedOut.status == .ok)
            let oldRefresh = try await auditPost(client, "/api/auth/refresh", ["refreshToken": originalRefresh])
            #expect(oldRefresh.status == .unauthorized, "control: the original refresh session really was revoked")

            let attacker = try await authorize()
            let attempted = try await auditPost(client, "/api/auth/device/approve", ["userCode": attacker.userCode], "Bearer \(originalAccess)")
            #expect(attempted.status == .unauthorized, "a revoked access token cannot approve a device")
            if attempted.status == .ok {
                let fresh = try await auditPost(client, "/api/auth/device/token", ["deviceCode": attacker.deviceCode])
                #expect(fresh.status != .ok, "a revoked token must not mint a fresh session")
            }
        }
    }
}

@Test func guestGlobalSyncCannotReturnAChannelDeniedByScopedHistory() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111657"
    let guestId = "11111111-1111-4111-8111-111111111658"
    let serverId = "33333333-3333-4333-8333-333333333691"
    for (id, email) in [(ownerId, "audit-owner@slock.test"), (guestId, "audit-guest@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "audit", name: "Audit", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "audit-hidden", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: hidden, memberId: ownerId, name: "audit-hidden")
    accounts.oauth.addChannelHuman(channelId: hidden, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(channelId: hidden, content: "audit-hidden-from-guest", senderId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let scoped = try await client.get(URI(string: "/api/messages/channel/\(hidden)"), headers: headers)
            #expect(scoped.status == .forbidden || scoped.status == .notFound, "control: guest must be denied")
            let synced = try await client.get(URI(string: "/api/messages/sync?since_seq=0&limit=500"), headers: headers)
            #expect(synced.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((synced.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(!body.contains { ($0["id"] as? String) == message }, "omitting channel_id must not broaden a guest's visibility")
        }
    }
}
