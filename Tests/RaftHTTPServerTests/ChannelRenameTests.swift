import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func renamingAChannelWritesASystemMessageButDescriptionDoesNot() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111281"
    let serverId = "33333333-3333-4333-8333-333333333468"
    accounts.addAccount(id: ownerId, email: "rename-notice@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "rename-notice", name: "Rename Notice Server", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "rename-before", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"rename-notice@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func patch(_ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)") { request in
                    request.body = .init(string: body)
                }
            }

            let renamed = try await patch("{\"name\":\"rename-after\"}")
            #expect(renamed.status == .ok)
            let systems = accounts.oauth.systemMessages(channelId: channelId)
            #expect(systems.count == 1)
            let expected = "@rename-notice renamed this channel from #rename-before to #rename-after."
            #expect(systems.first?.content == expected)
            #expect(systems.first?.seq ?? 0 > 0)

            let described = try await patch("{\"description\":\"updated description\"}")
            #expect(described.status == .ok)
            #expect(accounts.oauth.systemMessages(channelId: channelId).count == 1)
            #expect(accounts.oauth.channelInfo(id: channelId)?.description == "updated description")
        }
    }
}
