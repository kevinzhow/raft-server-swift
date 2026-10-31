import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func inboxDmScopeKeepsDmsAndDmThreadsAndDropsDone() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111628"
    let peerId = "11111111-1111-4111-8111-111111111629"
    let serverId = "33333333-3333-4333-8333-333333333672"
    accounts.addAccount(id: ownerId, email: "inbox-dm-scope@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "inbox-dm-scope-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-dm-scope", name: "Inbox DM Scope", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")

    let channel = accounts.oauth.createChannel(serverId: serverId, name: "dm-scope-room", creatorUserId: ownerId)
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    let dmThread = accounts.oauth.createChannel(serverId: serverId, name: "dm-thread", creatorUserId: ownerId, type: "thread")
    for (scope, kind, parent) in [
        (channel, "channel", nil),
        (dm, "dm", nil),
        (dmThread, "thread", dm),
    ] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: scope,
            memberId: ownerId,
            kind: kind,
            parentChannelId: parent,
            parentMessageId: parent == nil ? nil : "dm-parent-message",
            name: kind == "dm" ? "" : "scope-room"
        )
        let message = accounts.oauth.createMessageRecord(channelId: scope, content: "activity", senderId: peerId)
        accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: scope, messageId: message.id)
    }
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: dmThread, parentMessageId: "dm-parent-message")

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
                request.body = .init(string: "{\"email\":\"inbox-dm-scope@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func inbox(_ query: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/inbox?\(query)"))
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let dms = try await inbox("scope=dms")
            #expect(dms["totalCount"] as? Int == 2)
            #expect(dms["totalUnreadCount"] as? Int == 2)
            let ids = (dms["items"] as? [[String: Any]] ?? []).compactMap { $0["channelId"] as? String ?? $0["threadChannelId"] as? String }
            #expect(Set(ids) == [dm, dmThread])
            #expect((dms["groups"] as? [[String: Any]] ?? []).allSatisfy { $0["channelType"] as? String == "dm" })

            let done = try await client.send(.post, headers: headers, to: "/api/channels/inbox/done") { request in
                request.body = .init(string: "{\"channelId\":\"\(dm)\"}")
            }
            #expect(done.status == .ok)
            let afterDone = try await inbox("scope=dms")
            #expect(afterDone["totalCount"] as? Int == 0)
        }
    }
}
