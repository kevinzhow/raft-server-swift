import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func constructedMessageRoutesObserveVerificationWritesAndCredentialRevocation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111645"
    let serverId = "33333333-3333-4333-8333-333333333670"
    accounts.addAccount(id: ownerId, email: "message-construction@slock.test", password: "password123")
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-construction", name: "Message Construction", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "construction", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "construction")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "construction-agent", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "construction-read")
    accounts.setExperimentalSurfacesDisabledForTesting(false)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let syncURI = URI(string: "/api/messages/sync?channel_id=\(channelId)&since_seq=0")
            let unverified = try await client.get(syncURI, headers: headers)
            #expect(unverified.status == .forbidden)
            #expect(unverified.body.string == #"{"error":"Email verification required"}"#)

            accounts.markEmailVerified(userId: ownerId)
            let created = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"construction-boundary needle\"}")
            }
            #expect(created.status == .ok)
            #expect(created.body.string?.contains("construction-boundary needle") == true)
            let sync = try await client.get(syncURI, headers: headers)
            #expect(sync.status == .ok)
            #expect(sync.body.string?.contains("construction-boundary needle") == true)
            let search = try await client.get("/api/messages/search?q=construction-boundary", headers: headers)
            #expect(search.status == .ok)
            #expect(search.body.string?.contains("construction-boundary needle") == true)

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(key)"
            accounts.revokeAgentCredentialForTesting(apiKey: key)
            let legacyRead = try await client.get("/internal/agent-api/events", headers: agentHeaders)
            #expect(legacyRead.status == .ok)
            #expect(try JSONSerialization.jsonObject(with: Data((legacyRead.body.string ?? "").utf8)) is [String: Any])
            let liveRead = try await client.get("/internal/agent-api", headers: agentHeaders)
            #expect(liveRead.status == .unauthorized)

            accounts.revokeSessionFamilies(userId: ownerId)
            let revokedSync = try await client.get(syncURI, headers: headers)
            #expect(revokedSync.status == .unauthorized)
            #expect(revokedSync.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
            let revokedSearch = try await client.get("/api/messages/search?q=construction-boundary", headers: headers)
            #expect(revokedSearch.status == .unauthorized)
            let revokedCreate = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"refused after revocation\"}")
            }
            #expect(revokedCreate.status == .unauthorized)
        }
    }
}
