import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelRenameReportsASystemMessageSeqButDescriptionDoesNot() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111441"
    let serverId = "33333333-3333-4333-8333-333333333559"
    accounts.addAccount(id: ownerId, email: "rename-notice@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "rename-notice", name: "Rename Notice", ownerId: ownerId)

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
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"rename-before\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            func patch(_ body: String) async throws -> [String: Any] {
                let response = try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)") { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let renamed = try await patch("{\"name\":\"rename-after\"}")
            #expect(renamed["name"] as? String == "rename-after")
            #expect(renamed["systemMessageSeq"] is Int)

            let described = try await patch("{\"description\":\"just a description\"}")
            #expect(described["description"] as? String == "just a description")
            #expect(described["systemMessageSeq"] == nil || described["systemMessageSeq"] is NSNull)
        }
    }
}
