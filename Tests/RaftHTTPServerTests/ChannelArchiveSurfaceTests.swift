import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ArchiveSurfaceFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let channelId: String
    let channelName: String
    let parentMessageId: String
    let extraAgentId: String
    let token: String
}

private func makeArchiveSurfaceFixture(_ client: any Client) async throws -> ArchiveSurfaceFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111653"
    let serverId = "33333333-3333-4333-8333-333333333688"
    accounts.addAccount(id: ownerId, email: "archive-surface@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive-surface", name: "Archive Surface", ownerId: ownerId)
    var loginHeaders = HTTPFields()
    loginHeaders[.contentType] = "application/json"
    let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"archive-surface@slock.test\",\"password\":\"password123\"}")
    }
    let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))) as? [String: Any]
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token?["accessToken"] as? String ?? "")"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let created = try await client.send(.post, headers: headers, to: "/api/channels") { request in
        request.body = .init(string: "{\"name\":\"archive-surface-room\"}")
    }
    let channelId = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8))) as? [String: Any]
    let extraAgent = accounts.oauth.createAgent(serverId: serverId, name: "archive-extra", creatorUserId: ownerId)
    let parentMessage = accounts.addChannelMessageForTesting(
        channelId: channelId?["id"] as? String ?? "", content: "parent", senderId: ownerId
    )
    return ArchiveSurfaceFixture(
        accounts: accounts,
        ownerId: ownerId,
        serverId: serverId,
        channelId: channelId?["id"] as? String ?? "",
        channelName: "archive-surface-room",
        parentMessageId: parentMessage,
        extraAgentId: extraAgent,
        token: token?["accessToken"] as? String ?? ""
    )
}

@Test func archivedThreadInheritsTheParentFreezeAndLegacyRoutesAreGone() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111654"
    let serverId = "33333333-3333-4333-8333-333333333689"
    accounts.addAccount(id: ownerId, email: "archive-thread@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive-thread", name: "Archive Thread", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "thread-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "thread-parent")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let parent = accounts.addChannelMessageForTesting(channelId: channelId, content: "parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parent)
    accounts.addPostableChannel(
        serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread",
        parentChannelId: channelId, parentMessageId: parent, name: "thread"
    )
    let extraAgent = accounts.oauth.createAgent(serverId: serverId, name: "archive-extra", creatorUserId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            // Legacy channel-agent write routes must not be registered.
            let legacyAdd = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/agents") { request in
                request.body = .init(string: "{\"agentId\":\"\(extraAgent)\"}")
            }
            #expect(legacyAdd.status == .notFound)
            let legacyRemove = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/agents/\(extraAgent)")
            #expect(legacyRemove.status == .notFound)
            // The replacement member routes stay available.
            let memberAdd = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/members") { request in
                request.body = .init(string: "{\"agentId\":\"\(extraAgent)\"}")
            }
            #expect(memberAdd.status == .ok)
            let memberRemove = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/agent/\(extraAgent)")
            #expect(memberRemove.status == .ok)

            // Archiving the parent freezes writes into its threads.
            let archived = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive")
            #expect(archived.status == .ok)
            let threadSend = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"reply to archived thread\"}")
            }
            #expect(threadSend.status == .conflict)
            let code = (try JSONSerialization.jsonObject(with: Data((threadSend.body.string ?? "").utf8))) as? [String: Any]
            #expect(code?["code"] as? String == "channel_archived")
        }
    }
}

@Test func archivedChannelsStaySearchableWithTheArchiveMarker() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111655"
    let serverId = "33333333-3333-4333-8333-333333333690"
    accounts.addAccount(id: ownerId, email: "archive-search@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive-search", name: "Archive Search", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "archive-search-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "archive-search-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.addChannelMessageForTesting(channelId: channelId, content: "lorem zephyrglint ipsum", senderId: ownerId)
    let markerMessage = accounts.addChannelMessageForTesting(channelId: channelId, content: "lorem mothbolt ipsum", senderId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let archived = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive")
            #expect(archived.status == .ok)

            func search(_ query: String) async throws -> [[String: Any]] {
                let response = try await client.get(URI(string: "/api/messages/search?q=\(query)"), headers: headers)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                return (body?["results"] as? [[String: Any]]) ?? []
            }
            let hits = try await search("zephyrglint")
            let hit = try #require(hits.first { ($0["channelId"] as? String) == channelId })
            #expect(hit["channelArchivedAt"] is String, "search results must expose the archive marker")

            let context = try await client.get(URI(string: "/api/messages/context/\(hit["id"] as? String ?? "")?channelId=\(channelId)"), headers: headers)
            #expect(context.status == .ok)
            let contextBody = (try JSONSerialization.jsonObject(with: Data((context.body.string ?? "").utf8))) as? [String: Any]
            #expect(contextBody?["channelArchived"] as? Bool == true)
            #expect(contextBody?["channelId"] as? String == channelId)
            #expect(contextBody?["targetMessageId"] as? String == hit["id"] as? String)

            let scoped = try await search("mothbolt&channelId=\(channelId)")
            #expect(scoped.contains { ($0["id"] as? String) == markerMessage }, "a channelId filter still works on an archived channel")
        }
    }
}
