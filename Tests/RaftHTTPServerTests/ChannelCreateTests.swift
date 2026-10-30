import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelCreateReturnsTheCreatorsInitialMuteAndReadState() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111279"
    let serverId = "33333333-3333-4333-8333-333333333466"
    accounts.addAccount(id: ownerId, email: "create-channel-mute@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "create-channel-mute", name: "Create Channel Mute Server", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"create-channel-mute@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"new-channel-mute\",\"description\":\"new channels should expose the header mute control immediately\"}")
            }
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["name"] as? String == "new-channel-mute")
            #expect(body?["joined"] as? Bool == true)
            #expect(body?["activityMuteSupported"] as? Bool == true)
            #expect(body?["activityMuted"] as? Bool == false)
            #expect(body?["muteFromSeq"] == nil || body?["muteFromSeq"] is NSNull)
            #expect(body?["prefsVersion"] as? Int == 0)
            #expect(body?["maxReadSeq"] as? Int == 0)
            #expect(body?["readStateVersion"] as? Int == 0)

            let list = try await client.send(.get, headers: headers, to: "/api/channels")
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.contains { $0["name"] as? String == "new-channel-mute" })
        }
    }
}
