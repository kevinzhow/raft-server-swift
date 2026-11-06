import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func inboxDoneSuppressesScopeFactsAndReadAllCoversEveryScope() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111459"
    let serverId = "33333333-3333-4333-8333-333333333570"
    accounts.addAccount(id: ownerId, email: "inbox-done@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-done", name: "Inbox Done", ownerId: ownerId)
    let parent = UUID().uuidString.lowercased()
    let thread = UUID().uuidString.lowercased()
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "inbox-done-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: UUID().uuidString.lowercased(), name: "thread")
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: parent, messageId: UUID().uuidString.lowercased())
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: UUID().uuidString.lowercased())
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: thread, parentMessageId: UUID().uuidString.lowercased())

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
                request.body = .init(string: "{\"email\":\"inbox-done@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func inbox() async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers, to: "/api/channels/inbox")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["items"] as? [[String: Any]] ?? []
            }
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            #expect(try await inbox().count == 2)

            #expect(try await post("/api/channels/inbox/done", "{\"channelId\":\"\(parent)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}").status == .ok)
            #expect(try await inbox().count == 1)

            #expect(try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(thread)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}").status == .ok)
            #expect(try await inbox().isEmpty)
            let followed = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            let followedBody = try JSONSerialization.jsonObject(with: Data((followed.body.string ?? "").utf8)) as? [String: Any]
            #expect((followedBody?["threads"] as? [[String: Any]] ?? []).isEmpty)

            let done = try await client.send(.get, headers: headers, to: "/api/channels/inbox/done?limit=30")
            #expect(done.status == .ok)
            let doneBody = try JSONSerialization.jsonObject(with: Data((done.body.string ?? "").utf8)) as? [String: Any]
            let doneThread = (doneBody?["items"] as? [[String: Any]] ?? []).first { $0["threadChannelId"] as? String == thread }
            #expect(doneThread?["kind"] as? String == "thread")
            #expect(doneThread?["isFollowing"] as? Bool == true)

            #expect(try await post("/api/channels/threads/undone", "{\"threadChannelId\":\"\(thread)\"}").status == .ok)
            #expect(try await inbox().count == 1)

            #expect(try await post("/api/channels/inbox/done", "{\"channelId\":\"\(thread)\"}").status == .notFound)

            let newParent = UUID().uuidString.lowercased()
            accounts.addPostableChannel(serverId: serverId, channelId: newParent, memberId: ownerId, name: "inbox-done-new")
            accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: newParent, messageId: UUID().uuidString.lowercased())
            let readAll = try await post("/api/channels/inbox/read-all", "{}")
            #expect(readAll.status == .ok)
            let readAllBody = try JSONSerialization.jsonObject(with: Data((readAll.body.string ?? "").utf8)) as? [String: Any]
            #expect(Set((readAllBody ?? [:]).keys) == ["ok", "markedCount", "scopes"])
            #expect((readAllBody?["markedCount"] as? Int ?? 0) >= 2)
            let scopes = (readAllBody?["scopes"] as? [[String: Any]] ?? []).compactMap { $0["scopeId"] as? String }
            #expect(scopes.contains(newParent))
            #expect(scopes.contains(thread))
            #expect(try await inbox().isEmpty)
        }
    }
}
