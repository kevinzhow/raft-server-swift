import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sidebarOrderDropsForeignAndMalformedIds() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111298"
    let peerId = "11111111-1111-4111-8111-111111111299"
    let serverId = "33333333-3333-4333-8333-333333333477"
    let otherServerId = "33333333-3333-4333-8333-333333333478"
    accounts.addAccount(id: ownerId, email: "sidebar-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "sidebar-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sidebar", name: "Sidebar", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "sidebar-other", name: "Sidebar Other", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "sidebar-channel", creatorUserId: ownerId)
    let foreignChannel = accounts.oauth.createChannel(serverId: otherServerId, name: "sidebar-foreign", creatorUserId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "sidebar-agent")
    let dmId = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    accounts.oauth.setSidebarOrder(serverId: serverId, userId: ownerId, order: OAuthLedger.SidebarOrder(
        channelOrder: ["not-a-uuid", channelId, foreignChannel, ""],
        agentOrder: [agentId, "system"],
        dmOrder: [dmId, "12345"],
        pinnedOrder: [channelId, agentId, dmId, "not-a-uuid"],
        hiddenDmIds: ["garbage", dmId]
    ))

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
                request.body = .init(string: "{\"email\":\"sidebar-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/sidebar-order")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["channelOrder"] as? [String] == [channelId])
            #expect(body?["agentOrder"] as? [String] == [agentId])
            #expect(body?["dmOrder"] as? [String] == [dmId])
            #expect(body?["pinnedOrder"] as? [String] == [channelId, agentId, dmId])
            #expect(body?["hiddenDmIds"] as? [String] == [dmId])
        }
    }
}
