import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sparseSidebarPatchKeepsTheLiveChannelOrder() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111475"
    let serverId = "33333333-3333-4333-8333-333333333582"
    accounts.addAccount(id: ownerId, email: "sidebar-live@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sidebar-live", name: "Sidebar Live", ownerId: ownerId)
    let first = accounts.oauth.createChannel(serverId: serverId, name: "live-first", creatorUserId: ownerId)
    let deleted = accounts.oauth.createChannel(serverId: serverId, name: "deleted-middle", creatorUserId: ownerId)
    let last = accounts.oauth.createChannel(serverId: serverId, name: "live-last", creatorUserId: ownerId)
    for channel in [first, deleted, last] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "room")
    }
    accounts.oauth.setSidebarOrder(serverId: serverId, userId: ownerId, order: OAuthLedger.SidebarOrder(channelOrder: [last, deleted, first]))
    accounts.softDeletePostableChannelForTesting(channelId: deleted)

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
                request.body = .init(string: "{\"email\":\"sidebar-live@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let before = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/sidebar-order")
            let beforeBody = try JSONSerialization.jsonObject(with: Data((before.body.string ?? "").utf8)) as? [String: Any]
            #expect(beforeBody?["channelOrder"] as? [String] == [last, first])
            let version = beforeBody?["sectionsVersion"] as? Int ?? 0

            let patch = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/sidebar-order") { request in
                request.body = .init(string: "{\"customSections\":[{\"id\":\"project\",\"name\":\"Project\",\"emoji\":null,\"sortMode\":\"manual\"}],\"sectionOrder\":[\"project\"],\"sectionPlacements\":[],\"sectionsVersion\":\(version)}")
            }
            #expect(patch.status == .ok)
            let patchBody = try JSONSerialization.jsonObject(with: Data((patch.body.string ?? "").utf8)) as? [String: Any]
            #expect(patchBody?["channelOrder"] as? [String] == [last, first])
            #expect(patchBody?["sectionOrder"] as? [String] == ["project", "system:pinned", "system:joint", "system:channels", "system:dms"])
            #expect(patchBody?["sectionsVersion"] as? Int == version + 1)
        }
    }
}
