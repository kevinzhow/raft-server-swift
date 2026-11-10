import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func guestAgentSummaryUsesTheBoundedProjection() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111598"
    let guestId = "11111111-1111-4111-8111-111111111599"
    let serverId = "33333333-3333-4333-8333-333333333650"
    accounts.addAccount(id: ownerId, email: "guest-summary-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "guest-summary-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "guest-summary", name: "Guest Summary", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "guest-visible-agent", description: "Objective channel-visible role description", creatorUserId: ownerId)
    // This fixture must prove a real readable relation, rather than treating the
    // server guest role itself as permission to enumerate every agent.
    accounts.createFeatureFlagForTesting(key: "server_guest_v0", defaultEnabled: true)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "guest-summary-readable", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "guest-summary-readable")
    accounts.setChannelGuestVisibleForTesting(channelId: channel, visible: true)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"guest-summary-guest@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/agents/\(agent)")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body["profileProjection"] as? String == "channel_summary")
            #expect(body["description"] as? String == "Objective channel-visible role description")
            for key in ["envVars", "runtimeConfig", "runtime", "model", "machineId", "creatorId", "creatorType"] {
                #expect(body[key] == nil)
            }
        }
    }
}
