import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func broadMessageSyncCoversOnlyVisibleChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111487"
    let memberId = "11111111-1111-4111-8111-111111111488"
    let serverId = "33333333-3333-4333-8333-333333333588"
    accounts.addAccount(id: ownerId, email: "broad-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "broad-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "broad-sync", name: "Broad Sync", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("broad-owner@slock.test")
            let memberToken = try await login("broad-member@slock.test")
            func createChannel(_ name: String) async throws -> String {
                let response = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                    request.body = .init(string: "{\"name\":\"\(name)\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            }
            func send(_ channelId: String, _ content: String) async throws {
                let response = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            let publicChannel = try await createChannel("broad-public")
            let privateChannel = try await createChannel("broad-private")
            accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: memberId, name: "broad-private")
            accounts.oauth.addChannelHuman(channelId: privateChannel, userId: memberId)
            #expect(try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(privateChannel)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }.status == .ok)
            let secretChannel = try await createChannel("broad-secret")
            #expect(try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(secretChannel)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }.status == .ok)
            try await send(publicChannel, "public broad")
            try await send(privateChannel, "private broad")
            try await send(secretChannel, "secret broad")

            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            memberHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let broad = try await client.send(.get, headers: memberHeaders, to: URI(string: "/api/messages/sync?since_seq=0&limit=100"))
            #expect(broad.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((broad.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let contents = Set(rows.compactMap { $0["content"] as? String })
            #expect(contents.contains("public broad"))
            #expect(contents.contains("private broad"))
            #expect(!contents.contains("secret broad"))

            let scopedSecret = try await client.send(.get, headers: memberHeaders, to: URI(string: "/api/messages/sync?channel_id=\(secretChannel)&since_seq=0"))
            #expect(scopedSecret.status == .notFound)
        }
    }
}
