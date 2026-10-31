import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func defaultChannelListExcludesArchivedChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111434"
    let serverId = "33333333-3333-4333-8333-333333333555"
    accounts.addAccount(id: ownerId, email: "list-archive@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "list-archive", name: "List Archive", ownerId: ownerId)
    let live = accounts.oauth.createChannel(serverId: serverId, name: "live-room", creatorUserId: ownerId)
    let archived = accounts.oauth.createChannel(serverId: serverId, name: "archived-room", creatorUserId: ownerId)
    accounts.oauth.setChannelArchived(id: archived, archivedAt: Date())

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
                request.body = .init(string: "{\"email\":\"list-archive@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/channels")
            #expect(response.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let ids = rows.compactMap { $0["id"] as? String }
            #expect(ids.contains(live))
            #expect(!ids.contains(archived))
            #expect(rows.first { $0["id"] as? String == live }?["archivedAt"] == nil || rows.first { $0["id"] as? String == live }?["archivedAt"] is NSNull)

            let include = try await client.send(.get, headers: headers, to: URI(string: "/api/channels?archived=include"))
            #expect(include.status == .ok)
            let includeRows = try JSONSerialization.jsonObject(with: Data((include.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let archivedRow = includeRows.first { $0["id"] as? String == archived }
            #expect(archivedRow != nil)
            #expect(archivedRow?["archivedAt"] is String)
        }
    }
}
